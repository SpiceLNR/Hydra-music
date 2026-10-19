//! Фоновая работа сети: приём подключений, обнаружение устройств, сопряжение и сеансы.
//!
//! Одновременно идёт только один сеанс (два сеанса вперемешку портили бы друг другу
//! состояние библиотеки). Входящее подключение во время чужого сеанса просто отклоняется:
//! другое устройство повторит попытку позже.

use super::channel::{handshake_initiator, handshake_responder};
use super::identity::{Family, Identity};
use super::session::{run_session, Hello, LibHandle, Role, SessionReport};
use super::{hex, now_ms, unhex};
use crate::{Error, Result};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

pub const TCP_PORT: u16 = 47475;
pub const DISCOVERY_PORT: u16 = 47476;
const OFFER_TTL: Duration = Duration::from_secs(180);
const ONLINE_MS: u64 = 20_000;

/// Одноразовое предложение сопряжения (его секрет лежит в QR-коде).
pub struct Offer {
    secret: [u8; 32],
    created: Instant,
}

#[derive(Default)]
struct Status {
    port: u16,
    busy: bool,
    message: String,
    error: String,
    /// Растёт после каждого успешного сеанса: по нему интерфейс понимает, что пора обновить списки.
    generation: u64,
    /// Растёт, когда в семью добавлено устройство.
    family_generation: u64,
    log: VecDeque<String>,
    report: Option<Value>,
    /// device_id -> (адрес ip:порт, когда замечено)
    found: HashMap<String, (String, u64)>,
}

pub struct Node<H> {
    ident: Identity,
    family: Mutex<Family>,
    handle: Arc<H>,
    offer: Mutex<Option<Offer>>,
    session: Mutex<()>,
    st: Mutex<Status>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

fn bad<E: std::fmt::Display>(e: E) -> Error {
    Error::Invalid(e.to_string())
}

fn key32(secret_hex: &str) -> Result<[u8; 32]> {
    let v = unhex(secret_hex).ok_or_else(|| bad("секрет сопряжения повреждён"))?;
    v.try_into().map_err(|_| bad("секрет сопряжения повреждён"))
}

impl<H: LibHandle + Send + Sync + 'static> Node<H> {
    pub fn new(ident: Identity, family: Family, handle: Arc<H>) -> Arc<Node<H>> {
        Arc::new(Node {
            ident,
            family: Mutex::new(family),
            handle,
            offer: Mutex::new(None),
            session: Mutex::new(()),
            st: Mutex::new(Status::default()),
        })
    }

    fn log(&self, text: &str) {
        let mut st = lock(&self.st);
        st.log.push_back(text.to_string());
        while st.log.len() > 30 {
            st.log.pop_front();
        }
    }

    fn set_message(&self, text: &str) {
        lock(&self.st).message = text.to_string();
    }

    fn try_session(&self) -> Option<MutexGuard<'_, ()>> {
        match self.session.try_lock() {
            Ok(g) => Some(g),
            Err(TryLockError::Poisoned(p)) => Some(p.into_inner()),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    fn hello(&self) -> Hello {
        Hello::new(&self.ident.device_id, &self.ident.name, lock(&self.st).port)
    }

    // ---------- запуск ----------

    /// Начинает слушать порт и искать устройства. Повторный вызов ничего не меняет.
    /// Возвращает порт.
    pub fn start(self: &Arc<Self>) -> Result<u16> {
        if lock(&self.st).port != 0 {
            return Ok(lock(&self.st).port);
        }
        let listener = TcpListener::bind(("0.0.0.0", TCP_PORT))
            .or_else(|_| TcpListener::bind(("0.0.0.0", 0)))?;
        let port = listener.local_addr()?.port();
        lock(&self.st).port = port;
        self.log(&format!("Слушаю порт {port}"));

        let me = Arc::clone(self);
        thread::spawn(move || {
            for conn in listener.incoming() {
                let Ok(stream) = conn else { continue };
                let node = Arc::clone(&me);
                thread::spawn(move || node.incoming(stream));
            }
        });
        self.start_discovery(port);
        Ok(port)
    }

    fn start_discovery(self: &Arc<Self>, port: u16) {
        // объявляем себя
        let me = Arc::clone(self);
        thread::spawn(move || {
            let Ok(sock) = UdpSocket::bind("0.0.0.0:0") else {
                return;
            };
            let _ = sock.set_broadcast(true);
            let msg = format!("HYDRA1|{}|{}", me.ident.device_id, port);
            loop {
                let _ = sock.send_to(msg.as_bytes(), ("255.255.255.255", DISCOVERY_PORT));
                thread::sleep(Duration::from_secs(5));
            }
        });
        // слушаем остальных
        let me = Arc::clone(self);
        thread::spawn(move || {
            let sock = match UdpSocket::bind(("0.0.0.0", DISCOVERY_PORT)) {
                Ok(s) => s,
                Err(e) => {
                    me.log(&format!("Поиск устройств недоступен: {e}"));
                    return;
                }
            };
            let mut buf = [0u8; 256];
            loop {
                let Ok((n, src)) = sock.recv_from(&mut buf) else {
                    continue;
                };
                let Ok(text) = std::str::from_utf8(&buf[..n]) else {
                    continue;
                };
                let parts: Vec<&str> = text.split('|').collect();
                if parts.len() != 3 || parts[0] != "HYDRA1" || parts[1] == me.ident.device_id {
                    continue;
                }
                let Ok(p) = parts[2].parse::<u16>() else {
                    continue;
                };
                // запоминаем только своих: чужие устройства нас не интересуют
                if lock(&me.family).by_id(parts[1]).is_some() {
                    let addr = format!("{}:{}", src.ip(), p);
                    lock(&me.st)
                        .found
                        .insert(parts[1].to_string(), (addr, now_ms()));
                }
            }
        });
    }

    // ---------- сопряжение ----------

    /// Новое предложение сопряжения: секрет живёт 3 минуты и работает один раз.
    pub fn pair_offer(&self) -> Value {
        let mut secret = [0u8; 32];
        secret[..16].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
        secret[16..].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
        *lock(&self.offer) = Some(Offer {
            secret,
            created: Instant::now(),
        });
        json!({
            "device_id": self.ident.device_id,
            "name": self.ident.name,
            "public_key": self.ident.public_hex(),
            "secret": hex(&secret),
            "port": lock(&self.st).port,
            "ttl_secs": OFFER_TTL.as_secs(),
        })
    }

    pub fn pair_cancel(&self) {
        *lock(&self.offer) = None;
    }

    fn current_psk(&self) -> Option<[u8; 32]> {
        let mut o = lock(&self.offer);
        match o.as_ref() {
            Some(x) if x.created.elapsed() <= OFFER_TTL => Some(x.secret),
            Some(_) => {
                *o = None;
                None
            }
            None => None,
        }
    }

    // ---------- входящие ----------

    fn incoming(self: Arc<Self>, stream: TcpStream) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(20)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(20)));
        let ip = stream
            .peer_addr()
            .map(|a| a.ip().to_string())
            .unwrap_or_default();
        let Some(_guard) = self.try_session() else {
            return; // занято: собеседник повторит попытку
        };
        lock(&self.st).busy = true;
        lock(&self.st).error.clear();
        let res = self.incoming_session(stream, &ip);
        match &res {
            Ok(_) => {}
            // чужие/случайные подключения (сканеры портов и т. п.) не показываем как сбой
            Err(e) => self.log(&format!("Входящее подключение от {ip}: {e}")),
        }
        self.finish(res, true);
    }

    fn incoming_session(&self, stream: TcpStream, ip: &str) -> Result<SessionReport> {
        let (mut ch, pairing) = handshake_responder(stream, &self.ident.keys, self.current_psk())?;
        let key = ch.remote_static.clone();
        let known = lock(&self.family).by_key(&key).cloned();
        if !pairing && known.is_none() {
            return Err(bad("устройство не входит в семью"));
        }
        self.set_message(if pairing {
            "Сопряжение"
        } else {
            "Синхронизация"
        });
        let verify = |hello: &Hello| -> Result<()> {
            let addr = if hello.port == 0 {
                String::new()
            } else {
                format!("{ip}:{}", hello.port)
            };
            self.verify(
                hello,
                &key,
                pairing,
                known.as_ref().map(|p| p.device_id.as_str()),
                &addr,
            )
        };
        run_session(
            &mut ch,
            &*self.handle,
            Role::Responder,
            &self.hello(),
            &verify,
            &|m| self.set_message(m),
        )
    }

    /// Проверка собеседника после приветствия.
    fn verify(
        &self,
        hello: &Hello,
        key: &[u8],
        pairing: bool,
        expected_id: Option<&str>,
        addr: &str,
    ) -> Result<()> {
        if hello.device_id == self.ident.device_id {
            return Err(bad("нельзя синхронизироваться с самим собой"));
        }
        if pairing {
            lock(&self.family).upsert(&hello.device_id, &hello.name, key, addr)?;
            *lock(&self.offer) = None;
            lock(&self.st).family_generation += 1;
            self.log(&format!("Добавлено устройство «{}»", hello.name));
            Ok(())
        } else if expected_id == Some(hello.device_id.as_str()) {
            // обновляем последний известный адрес (он мог смениться)
            lock(&self.family).upsert(&hello.device_id, &hello.name, key, addr)?;
            Ok(())
        } else {
            Err(bad("устройство представилось чужим именем"))
        }
    }

    // ---------- исходящие ----------

    fn connect(addrs: &[String]) -> Result<(TcpStream, String)> {
        let mut last = bad("нет адреса устройства");
        for a in addrs {
            let Ok(sa) = a.parse::<SocketAddr>() else {
                continue;
            };
            match TcpStream::connect_timeout(&sa, Duration::from_secs(4)) {
                Ok(s) => {
                    let _ = s.set_read_timeout(Some(Duration::from_secs(20)));
                    let _ = s.set_write_timeout(Some(Duration::from_secs(20)));
                    return Ok((s, a.clone()));
                }
                Err(e) => last = bad(format!("не удалось подключиться к {a}: {e}")),
            }
        }
        Err(last)
    }

    /// Запускает задачу в фоне. Состояние смотрите через `status`.
    fn spawn_job(
        self: &Arc<Self>,
        title: &str,
        job: impl FnOnce(&Arc<Self>) -> Result<SessionReport> + Send + 'static,
    ) {
        let me = Arc::clone(self);
        let title = title.to_string();
        thread::spawn(move || {
            let Some(_guard) = me.try_session() else {
                me.fail("Уже идёт другая синхронизация, подождите");
                return;
            };
            {
                let mut st = lock(&me.st);
                st.busy = true;
                st.error.clear();
                st.message = title;
            }
            let res = job(&me);
            me.finish(res, false);
        });
    }

    fn fail(&self, text: &str) {
        let mut st = lock(&self.st);
        st.error = text.to_string();
        st.message.clear();
        st.busy = false;
        drop(st);
        self.log(text);
    }

    fn finish(&self, res: Result<SessionReport>, incoming: bool) {
        match res {
            Ok(rep) => {
                let _ = lock(&self.family).touch(&rep.peer_device_id, "");
                let mut st = lock(&self.st);
                st.busy = false;
                st.generation += 1;
                st.message = "Готово".to_string();
                st.report = serde_json::to_value(&rep).ok();
                drop(st);
                self.log(&format!(
                    "Синхронизация с «{}»: получено файлов {}, отправлено {}",
                    rep.peer_name, rep.files_received, rep.files_sent
                ));
            }
            Err(e) => {
                let mut st = lock(&self.st);
                st.busy = false;
                st.message.clear();
                // входящие сбои (чужие подключения) в «ошибку» не выносим
                if !incoming {
                    st.error = e.to_string();
                }
                drop(st);
                if !incoming {
                    self.log(&format!("Ошибка: {e}"));
                }
            }
        }
    }

    /// Подключиться к устройству по данным из QR-кода и добавить его в семью.
    pub fn pair_with(
        self: &Arc<Self>,
        addrs: Vec<String>,
        public_hex: &str,
        secret_hex: &str,
    ) -> Result<()> {
        let psk = key32(secret_hex)?;
        let expected = unhex(public_hex).ok_or_else(|| bad("ключ устройства повреждён"))?;
        self.spawn_job("Сопряжение", move |me| {
            let (stream, addr) = Self::connect(&addrs)?;
            let mut ch = handshake_initiator(stream, &me.ident.keys, Some(psk))?;
            if ch.remote_static != expected {
                return Err(bad("ключ устройства не совпал с QR-кодом"));
            }
            let key = ch.remote_static.clone();
            let verify = |hello: &Hello| me.verify(hello, &key, true, None, &addr);
            run_session(
                &mut ch,
                &*me.handle,
                Role::Initiator,
                &me.hello(),
                &verify,
                &|m| me.set_message(m),
            )
        });
        Ok(())
    }

    /// Синхронизация с устройством из семьи.
    pub fn sync_peer(self: &Arc<Self>, device_id: &str) -> Result<()> {
        let peer = lock(&self.family)
            .by_id(device_id)
            .cloned()
            .ok_or_else(|| bad("такого устройства нет в семье"))?;
        let found = lock(&self.st).found.get(device_id).cloned();
        let mut addrs = Vec::new();
        if let Some((a, seen)) = found {
            if now_ms().saturating_sub(seen) < ONLINE_MS * 3 {
                addrs.push(a);
            }
        }
        if !peer.last_addr.is_empty() && !addrs.contains(&peer.last_addr) {
            addrs.push(peer.last_addr.clone());
        }
        if addrs.is_empty() {
            return Err(bad(format!("«{}» сейчас не видно в сети", peer.name)));
        }
        let title = format!("Синхронизация с «{}»", peer.name);
        self.spawn_job(&title, move |me| {
            let (stream, addr) = Self::connect(&addrs)?;
            let mut ch = handshake_initiator(stream, &me.ident.keys, None)?;
            if hex(&ch.remote_static) != peer.public_key {
                return Err(bad(
                    "ключ устройства изменился: отзовите его и добавьте заново",
                ));
            }
            let key = ch.remote_static.clone();
            let id = peer.device_id.clone();
            let verify = |hello: &Hello| me.verify(hello, &key, false, Some(&id), &addr);
            let rep = run_session(
                &mut ch,
                &*me.handle,
                Role::Initiator,
                &me.hello(),
                &verify,
                &|m| me.set_message(m),
            )?;
            let _ = lock(&me.family).touch(&id, &addr);
            Ok(rep)
        });
        Ok(())
    }

    // ---------- состояние для интерфейса ----------

    pub fn forget(&self, device_id: &str) -> Result<bool> {
        lock(&self.st).found.remove(device_id);
        lock(&self.family).remove(device_id)
    }

    pub fn family_json(&self) -> Value {
        let found = lock(&self.st).found.clone();
        let now = now_ms();
        let peers: Vec<Value> = lock(&self.family)
            .peers
            .iter()
            .map(|p| {
                let online = found
                    .get(&p.device_id)
                    .map(|f| now.saturating_sub(f.1) < ONLINE_MS)
                    .unwrap_or(false);
                json!({
                    "device_id": p.device_id,
                    "name": p.name,
                    "last_sync_ms": p.last_sync_ms,
                    "online": online,
                })
            })
            .collect();
        Value::Array(peers)
    }

    pub fn status_json(&self) -> Value {
        let st = lock(&self.st);
        json!({
            "device_id": self.ident.device_id,
            "name": self.ident.name,
            "port": st.port,
            "busy": st.busy,
            "message": st.message,
            "error": st.error,
            "generation": st.generation,
            "family_generation": st.family_generation,
            "log": st.log.iter().collect::<Vec<_>>(),
            "report": st.report,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::Library;
    use std::fs;
    use std::path::Path;

    type TestNode = Arc<Node<Mutex<Library>>>;

    fn make(tmp: &Path, name: &str) -> (TestNode, Arc<Mutex<Library>>) {
        let base = tmp.join(name);
        fs::create_dir_all(&base).unwrap();
        let lib = Library::open(&base.join("Hydra"), &base.join("hydra.db"), name, 1_000).unwrap();
        let lib = Arc::new(Mutex::new(lib));
        let ident = Identity::load_or_create(&base, name, name).unwrap();
        (Node::new(ident, Family::load(&base), lib.clone()), lib)
    }

    fn put(lib: &Arc<Mutex<Library>>, playlist: &str, file: &str, content: &str) {
        let mut l = lock(lib);
        let dir = l.root().join(playlist);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(file), content).unwrap();
        l.scan(2_000).unwrap();
    }

    /// Ждёт завершения очередной задачи: успех (generation вырос) или ошибка.
    fn wait_done(n: &TestNode, generation_before: u64) -> Value {
        for _ in 0..400 {
            let st = n.status_json();
            let done = st["generation"].as_u64().unwrap() > generation_before
                || !st["error"].as_str().unwrap().is_empty();
            if done && !st["busy"].as_bool().unwrap() {
                return st;
            }
            thread::sleep(Duration::from_millis(50));
        }
        panic!("синхронизация не завершилась: {}", n.status_json());
    }

    fn wait_idle(n: &TestNode) {
        for _ in 0..400 {
            if !n.status_json()["busy"].as_bool().unwrap() {
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
        panic!("узел всё ещё занят");
    }

    fn generation(n: &TestNode) -> u64 {
        n.status_json()["generation"].as_u64().unwrap()
    }

    #[test]
    fn pairing_then_sync_over_loopback() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, lib_a) = make(tmp.path(), "phone");
        let (b, lib_b) = make(tmp.path(), "pc");
        let (c, _lib_c) = make(tmp.path(), "stranger");
        put(&lib_a, "Rock", "a.mp3", "a-bytes");
        let port = a.start().unwrap();
        b.start().unwrap();
        let addr = vec![format!("127.0.0.1:{port}")];

        // чужой секрет не подходит
        let offer = a.pair_offer();
        let wrong = hex(&[7u8; 32]);
        c.pair_with(addr.clone(), offer["public_key"].as_str().unwrap(), &wrong)
            .unwrap();
        let st = wait_done(&c, 0);
        assert!(
            !st["error"].as_str().unwrap().is_empty(),
            "с чужим секретом пускать нельзя"
        );
        assert!(a.family_json().as_array().unwrap().is_empty());

        // настоящий секрет: устройства узнают друг друга и сразу синхронизируются
        let before = generation(&b);
        b.pair_with(
            addr.clone(),
            offer["public_key"].as_str().unwrap(),
            offer["secret"].as_str().unwrap(),
        )
        .unwrap();
        wait_done(&b, before);
        assert_eq!(a.family_json().as_array().unwrap().len(), 1);
        assert_eq!(b.family_json().as_array().unwrap().len(), 1);
        let got = lock(&lib_b).root().join("Rock").join("a.mp3");
        assert_eq!(fs::read_to_string(got).unwrap(), "a-bytes");

        // одноразовый секрет второй раз не работает
        let (d, _lib_d) = make(tmp.path(), "late");
        d.pair_with(
            addr,
            offer["public_key"].as_str().unwrap(),
            offer["secret"].as_str().unwrap(),
        )
        .unwrap();
        assert!(!wait_done(&d, 0)["error"].as_str().unwrap().is_empty());

        // новая песня на телефоне доезжает по обычной синхронизации
        wait_idle(&a);
        put(&lib_a, "Rock", "b.mp3", "b-bytes");
        let before = generation(&b);
        let a_id = a.status_json()["device_id"].as_str().unwrap().to_string();
        b.sync_peer(&a_id).unwrap();
        wait_done(&b, before);
        let got = lock(&lib_b).root().join("Rock").join("b.mp3");
        assert_eq!(fs::read_to_string(got).unwrap(), "b-bytes");

        // посторонний без пары синхронизироваться не может
        assert!(c.sync_peer(&a_id).is_err());
    }
}
