//! Один сеанс синхронизации двух устройств по уже защищённому каналу.
//!
//! Обе стороны выполняют одни и те же шаги; чтобы не было взаимной блокировки
//! (оба пишут большое сообщение и никто не читает), в каждом обмене сначала говорит
//! инициатор (тот, кто подключился), потом отвечающий.

use super::channel::Secure;
use super::now_ms;
use crate::library::{FileNeed, Inventory, Library, MergeReport, SyncBatch, Vector};
use crate::{Error, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::fs;
use std::io::{Read, Write};
use std::sync::Mutex;

const PROTOCOL: u32 = 1;
/// Размер куска файла (одним сообщением).
const FILE_PART: usize = 1 << 20;

/// Доступ к библиотеке. Замок библиотеки держится только внутри одного вызова,
/// пока идёт передача по сети, интерфейс остаётся живым.
pub trait LibHandle {
    fn with<R>(&self, f: impl FnOnce(&mut Library) -> Result<R>) -> Result<R>;
}

impl LibHandle for Mutex<Library> {
    fn with<R>(&self, f: impl FnOnce(&mut Library) -> Result<R>) -> Result<R> {
        let mut g = self.lock().unwrap_or_else(|p| p.into_inner());
        f(&mut g)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Initiator,
    Responder,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Hello {
    pub proto: u32,
    pub device_id: String,
    pub name: String,
    /// Порт, на котором это устройство принимает подключения (чтобы другая сторона
    /// могла потом сама найти дорогу обратно, даже если поиск по сети не работает).
    #[serde(default)]
    pub port: u16,
    /// Адрес этого устройства для связи через интернет (id iroh); пусто, если не включено.
    #[serde(default)]
    pub endpoint: String,
    /// «Я убрал вас из своего списка»: собеседник тоже убирает это устройство и сеанс на этом заканчивается.
    #[serde(default)]
    pub goodbye: bool,
}

impl Hello {
    pub fn new(device_id: &str, name: &str, port: u16) -> Hello {
        Hello {
            proto: PROTOCOL,
            device_id: device_id.to_string(),
            name: name.to_string(),
            port,
            endpoint: String::new(),
            goodbye: false,
        }
    }

    pub fn with_goodbye(mut self) -> Hello {
        self.goodbye = true;
        self
    }

    pub fn with_endpoint(mut self, endpoint: String) -> Hello {
        self.endpoint = endpoint;
        self
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SessionReport {
    /// Сеанс был только прощанием: удаление устройства, ничего не синхронизировалось.
    pub goodbye: bool,
    pub peer_device_id: String,
    pub peer_name: String,
    pub merge: MergeReport,
    pub files_received: usize,
    pub files_sent: usize,
    /// Файлы, которые не удалось получить сейчас (будут запрошены в следующий раз).
    pub files_failed: usize,
}

#[derive(Serialize, Deserialize)]
struct FileHeader {
    track_id: String,
    sha256: String,
    size: u64,
    present: bool,
}

fn bad<E: std::fmt::Display>(e: E) -> Error {
    Error::Invalid(format!("синхронизация: {e}"))
}

/// Обмен одним значением: инициатор говорит первым.
fn xchg<T: Serialize + DeserializeOwned>(ch: &mut Secure, role: Role, mine: &T) -> Result<T> {
    let bytes = serde_json::to_vec(mine)?;
    let theirs = match role {
        Role::Initiator => {
            ch.send(&bytes)?;
            ch.recv()?
        }
        Role::Responder => {
            let r = ch.recv()?;
            ch.send(&bytes)?;
            r
        }
    };
    Ok(serde_json::from_slice(&theirs)?)
}

/// Выполняет сеанс. `verify` вызывается сразу после обмена приветствиями: там проверяется,
/// кто пришёл (и при сопряжении запоминается новое устройство).
pub fn run_session<H: LibHandle>(
    ch: &mut Secure,
    h: &H,
    role: Role,
    me: &Hello,
    verify: &dyn Fn(&Hello) -> Result<()>,
    progress: &dyn Fn(&str),
) -> Result<SessionReport> {
    ch.set_timeout(90);
    let remote: Hello = xchg(ch, role, me)?;
    if remote.proto != PROTOCOL {
        return Err(bad(format!(
            "у «{}» другая версия протокола ({}), обновите приложение на обоих устройствах",
            remote.name, remote.proto
        )));
    }
    verify(&remote)?;
    let mut report = SessionReport {
        peer_device_id: remote.device_id.clone(),
        peer_name: remote.name.clone(),
        ..SessionReport::default()
    };
    if me.goodbye || remote.goodbye {
        report.goodbye = true;
        return Ok(report);
    }

    progress("Сверяю списки");
    let my_inv = h.with(|l| l.sync_inventory())?;
    let remote_inv: Inventory = xchg(ch, role, &my_inv)?;
    let adopted = h.with(|l| l.sync_adopt(&remote_inv))?;
    let no_sha = |i: &Inventory| i.tracks.iter().filter(|t| t.sha256.is_empty()).count();
    progress(&format!(
        "#Описи: у меня {} треков (без хэша {}), у них {} (без хэша {}); совмещено id: {}",
        my_inv.tracks.len(),
        no_sha(&my_inv),
        remote_inv.tracks.len(),
        no_sha(&remote_inv),
        adopted
    ));

    progress("Обмениваюсь изменениями");
    h.with(|l| l.sync_prepare(now_ms()))?;
    let my_vec = h.with(|l| l.sync_vector())?;
    let remote_vec: Vector = xchg(ch, role, &my_vec)?;
    let my_batch = h.with(|l| l.sync_batch_for(&remote_vec))?;
    let remote_batch: SyncBatch = xchg(ch, role, &my_batch)?;
    report.merge = h.with(|l| l.sync_apply(&remote_batch, now_ms()))?;

    let my_needs: Vec<FileNeed> = h.with(|l| l.sync_needs())?;
    let remote_needs: Vec<FileNeed> = xchg(ch, role, &my_needs)?;
    if !report.merge.trashed_sample.is_empty() {
        progress(&format!(
            "#В корзину из-за чужого удаления, например: {}",
            report.merge.trashed_sample.join(", ")
        ));
    }
    if report.merge.hash_mismatch > 0 {
        progress(&format!(
            "#Файл на месте, но хэш не совпал: {}, например: {}",
            report.merge.hash_mismatch,
            report.merge.mismatch_sample.join(", ")
        ));
    }
    if !my_needs.is_empty() {
        let sample: Vec<String> = my_needs
            .iter()
            .take(3)
            .map(|n| format!("{}/{}", n.playlist, n.file_name))
            .collect();
        progress(&format!("#Мне нужны, например: {}", sample.join(", ")));
    }
    progress(&format!(
        "#Принято операций {}, в корзину {}; мне нужно файлов {}, им нужно {}",
        report.merge.new_ops,
        report.merge.trashed,
        my_needs.len(),
        remote_needs.len()
    ));

    // сначала отвечающий присылает файлы инициатору, потом наоборот
    match role {
        Role::Initiator => {
            receive_files(ch, h, &my_needs, &mut report, progress)?;
            send_files(ch, h, &remote_needs, &mut report, progress)?;
        }
        Role::Responder => {
            send_files(ch, h, &remote_needs, &mut report, progress)?;
            receive_files(ch, h, &my_needs, &mut report, progress)?;
        }
    }
    Ok(report)
}

fn send_files<H: LibHandle>(
    ch: &mut Secure,
    h: &H,
    needs: &[FileNeed],
    report: &mut SessionReport,
    progress: &dyn Fn(&str),
) -> Result<()> {
    let total = needs.len();
    for (i, need) in needs.iter().enumerate() {
        let found = h.with(|l| l.sync_file_for(&need.track_id))?;
        let Some((path, sha)) = found else {
            let hdr = FileHeader {
                track_id: need.track_id.clone(),
                sha256: String::new(),
                size: 0,
                present: false,
            };
            ch.send(&serde_json::to_vec(&hdr)?)?;
            continue;
        };
        let mut f = fs::File::open(&path)?;
        let size = f.metadata()?.len();
        progress(&format!("Отправляю файлы: {} из {}", i + 1, total));
        let hdr = FileHeader {
            track_id: need.track_id.clone(),
            sha256: sha,
            size,
            present: true,
        };
        ch.send(&serde_json::to_vec(&hdr)?)?;
        let mut buf = vec![0u8; FILE_PART];
        let mut left = size;
        while left > 0 {
            let want = buf.len().min(left as usize);
            f.read_exact(&mut buf[..want])?;
            ch.send(&buf[..want])?;
            left -= want as u64;
        }
        report.files_sent += 1;
    }
    Ok(())
}

fn receive_files<H: LibHandle>(
    ch: &mut Secure,
    h: &H,
    needs: &[FileNeed],
    report: &mut SessionReport,
    progress: &dyn Fn(&str),
) -> Result<()> {
    let total = needs.len();
    for (i, need) in needs.iter().enumerate() {
        let raw = ch.recv()?;
        let hdr: FileHeader = serde_json::from_slice(&raw)?;
        if hdr.track_id != need.track_id {
            return Err(bad("файлы пришли не в том порядке"));
        }
        if !hdr.present {
            report.files_failed += 1;
            continue;
        }
        progress(&format!("Получаю файлы: {} из {}", i + 1, total));
        let tmp = h.with(|l| l.sync_tmp_path(&need.track_id))?;
        let mut f = fs::File::create(&tmp)?;
        let mut got: u64 = 0;
        while got < hdr.size {
            let part = ch.recv()?;
            got += part.len() as u64;
            if got > hdr.size {
                let _ = fs::remove_file(&tmp);
                return Err(bad("файл длиннее, чем объявлено"));
            }
            f.write_all(&part)?;
        }
        f.flush()?;
        drop(f);
        let ok = h.with(|l| l.sync_store_file(&need.track_id, &tmp, &hdr.sha256))?;
        if ok {
            report.files_received += 1;
        } else {
            report.files_failed += 1;
        }
    }
    Ok(())
}
