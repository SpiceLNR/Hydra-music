//! Библиотека на диске: папка Hydra, плейлисты-папки, треки-файлы.
//!
//! Связывает файловую систему с журналом операций:
//!  * `scan` сравнивает папку с базой и записывает add / move / delete в журнал;
//!  * перемещение файла между папками распознаётся по хэшу содержимого, поэтому
//!    перенос в Проводнике и переименование папки не создают «новых» треков;
//!  * теги читаются ТОЛЬКО при добавлении нового файла;
//!  * удаление из приложения кладёт файл в `.hydra/trash/` (30 дней);
//!  * скрытый `.<Плейлист>.json` в папке плейлиста перегенерируется из журнала.
//!
//! Внутренняя папка `.hydra/` и любые имена с точкой в начале сканером игнорируются.

use crate::clock::{Clock, Hlc};
use crate::journal::{self, Kind, TrackState};
use crate::{db, naming, Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub const INTERNAL_DIR: &str = ".hydra";

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PlaylistInfo {
    pub playlist_id: String,
    pub name: String,
    pub track_count: usize,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct TrackInfo {
    pub track_id: String,
    pub playlist_id: String,
    pub title: String,
    pub artist: Option<String>,
    pub file_name: String,
    pub path: String,
    pub is_video: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct TrashItem {
    pub track_id: String,
    pub title: String,
    pub file_name: String,
    pub deleted_ms: i64,
}

#[derive(Debug, Default, Clone, Serialize, PartialEq)]
pub struct ScanReport {
    pub added: usize,
    pub moved: usize,
    pub removed: usize,
    pub playlists_created: usize,
}

struct PlaylistRow {
    id: String,
    dir_name: String,
    deleted: bool,
}

pub struct Library {
    root: PathBuf,
    device_id: String,
    conn: Connection,
    clock: Clock,
}

impl Library {
    /// `root` - папка Hydra (Music/Hydra), `db_path` - база в приватной папке приложения.
    pub fn open(root: &Path, db_path: &Path, device_id: &str, now_ms: u64) -> Result<Self> {
        fs::create_dir_all(root.join(INTERNAL_DIR).join("trash"))?;
        hide(&root.join(INTERNAL_DIR));
        let conn = db::open(db_path)?;
        let mut clock = Clock::new(device_id);
        // Часы не должны откатываться после перезапуска.
        let max: Option<String> = conn.query_row("SELECT MAX(hlc) FROM ops", [], |r| r.get(0))?;
        if let Some(h) = max.and_then(|s| Hlc::decode(&s)) {
            clock.observe(&h, now_ms);
        }
        Ok(Self { root: root.to_path_buf(), device_id: device_id.to_string(), conn, clock })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    // ---------- чтение ----------

    pub fn playlists(&self) -> Result<Vec<PlaylistInfo>> {
        let mut rows: Vec<PlaylistInfo> = Vec::new();
        for p in self.all_playlists()?.into_iter().filter(|p| !p.deleted) {
            let n: i64 = self.conn.query_row(
                "SELECT COUNT(*) FROM tracks WHERE playlist_id = ?1 AND deleted = 0",
                [&p.id],
                |r| r.get(0),
            )?;
            rows.push(PlaylistInfo { playlist_id: p.id, name: p.dir_name, track_count: n as usize });
        }
        rows.sort_by_key(|p| naming::fold_key(&p.name));
        Ok(rows)
    }

    pub fn tracks(&self, playlist_id: &str) -> Result<Vec<TrackInfo>> {
        let dir = self.playlist_dir(playlist_id)?;
        Ok(journal::playlist_tracks(&self.conn, playlist_id)?
            .iter()
            .map(|t| to_info(t, &dir))
            .collect())
    }

    pub fn trash_items(&self) -> Result<Vec<TrashItem>> {
        let mut stmt = self.conn.prepare(
            "SELECT t.track_id, t.file_name, t.deleted_ms, k.title
             FROM trash t LEFT JOIN tracks k ON k.track_id = t.track_id
             ORDER BY t.deleted_ms DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                let file_name: String = r.get(1)?;
                let title: Option<String> = r.get(3)?;
                Ok(TrashItem {
                    track_id: r.get(0)?,
                    title: title
                        .filter(|s| !s.trim().is_empty())
                        .unwrap_or_else(|| stem(&file_name)),
                    file_name,
                    deleted_ms: r.get(2)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Обложка из тегов файла (читается по запросу, не хранится).
    pub fn cover(&self, track_id: &str) -> Result<Option<(String, Vec<u8>)>> {
        use lofty::prelude::*;
        let t = journal::get_track(&self.conn, track_id)?
            .ok_or_else(|| Error::Invalid(format!("track {track_id} not found")))?;
        let path = self.playlist_dir(&t.playlist_id)?.join(&t.file_name);
        let Ok(tagged) = lofty::read_from_path(&path) else { return Ok(None) };
        let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
        Ok(tag.and_then(|t| {
            t.pictures().first().map(|p| {
                let mime = p
                    .mime_type()
                    .map(|m| m.as_str().to_string())
                    .unwrap_or_else(|| "image/jpeg".to_string());
                (mime, p.data().to_vec())
            })
        }))
    }

    // ---------- действия пользователя ----------

    pub fn create_playlist(&mut self, name: &str, now_ms: u64) -> Result<PlaylistInfo> {
        let mut existing: Vec<String> = self
            .all_playlists()?
            .into_iter()
            .filter(|p| !p.deleted)
            .map(|p| p.dir_name)
            .collect();
        if let Ok(rd) = fs::read_dir(&self.root) {
            for e in rd.flatten() {
                existing.push(e.file_name().to_string_lossy().to_string());
            }
        }
        let dir_name = naming::unique_name(name, &existing);
        fs::create_dir_all(self.root.join(&dir_name))?;
        let id = self.insert_playlist(&dir_name, now_ms)?;
        self.write_manifest(&id)?;
        Ok(PlaylistInfo { playlist_id: id, name: dir_name, track_count: 0 })
    }

    /// Физически переносит файл в другой плейлист и пишет операцию `move`.
    pub fn move_track(&mut self, track_id: &str, to_playlist_id: &str, now_ms: u64) -> Result<()> {
        let t = self.live_track(track_id)?;
        if t.playlist_id == to_playlist_id {
            return Ok(());
        }
        let src = self.playlist_dir(&t.playlist_id)?.join(&t.file_name);
        let dst_dir = self.playlist_dir(to_playlist_id)?;
        fs::create_dir_all(&dst_dir)?;
        let new_name = naming::unique_file_name(&t.file_name, &list_names(&dst_dir));
        fs::rename(&src, dst_dir.join(&new_name))?;
        let key = journal::append_key(&self.conn, to_playlist_id)?;
        self.record(
            now_ms,
            Kind::Move,
            track_id,
            json!({"to_playlist_id": to_playlist_id, "file_name": new_name, "order_key": key}),
        )?;
        self.write_manifest(&t.playlist_id)?;
        self.write_manifest(to_playlist_id)?;
        Ok(())
    }

    /// Удаление из приложения: файл уходит в `.hydra/trash/<id>/` на 30 дней.
    pub fn delete_track(&mut self, track_id: &str, now_ms: u64) -> Result<()> {
        let t = self.live_track(track_id)?;
        let src = self.playlist_dir(&t.playlist_id)?.join(&t.file_name);
        let tdir = self.trash_dir(track_id);
        fs::create_dir_all(&tdir)?;
        if src.exists() {
            fs::rename(&src, tdir.join(&t.file_name))?;
        }
        self.record(now_ms, Kind::Delete, track_id, json!({}))?;
        self.write_manifest(&t.playlist_id)?;
        Ok(())
    }

    /// Возвращает трек из корзины в его плейлист.
    pub fn restore_track(&mut self, track_id: &str, now_ms: u64) -> Result<()> {
        let t = journal::get_track(&self.conn, track_id)?
            .filter(|t| t.deleted)
            .ok_or_else(|| Error::Invalid(format!("track {track_id} is not in trash")))?;
        let saved = self.trash_dir(track_id).join(&t.file_name);
        if !saved.exists() {
            return Err(Error::Invalid("файла уже нет в корзине (удалён вне приложения)".into()));
        }
        let pdir = self.playlist_dir(&t.playlist_id)?;
        self.conn
            .execute("UPDATE playlists SET deleted = 0 WHERE playlist_id = ?1", [&t.playlist_id])?;
        fs::create_dir_all(&pdir)?;
        let new_name = naming::unique_file_name(&t.file_name, &list_names(&pdir));
        fs::rename(&saved, pdir.join(&new_name))?;
        let _ = fs::remove_dir(self.trash_dir(track_id));
        self.record(
            now_ms,
            Kind::Move,
            track_id,
            json!({"to_playlist_id": t.playlist_id, "file_name": new_name}),
        )?;
        self.write_manifest(&t.playlist_id)?;
        Ok(())
    }

    /// Окончательно стирает трек из корзины. Запись об удалении в журнале остаётся,
    /// чтобы другие устройства тоже знали, что трек удалён.
    pub fn purge_track(&mut self, track_id: &str) -> Result<()> {
        journal::get_track(&self.conn, track_id)?
            .filter(|t| t.deleted)
            .ok_or_else(|| Error::Invalid(format!("track {track_id} is not in trash")))?;
        let _ = fs::remove_dir_all(self.trash_dir(track_id));
        journal::forget_trashed(&self.conn, track_id)
    }

    /// Удаляет из корзины всё старше 30 дней. Возвращает число очищенных треков.
    pub fn purge_expired_trash(&mut self, now_ms: u64) -> Result<usize> {
        let ids = journal::expired_trash(&self.conn, now_ms)?;
        for id in &ids {
            let _ = fs::remove_dir_all(self.trash_dir(id));
            journal::forget_trashed(&self.conn, id)?;
        }
        Ok(ids.len())
    }

    /// Ставит трек на позицию `new_index` в его плейлисте.
    pub fn reorder(&mut self, track_id: &str, new_index: usize, now_ms: u64) -> Result<()> {
        let t = self.live_track(track_id)?;
        journal::reorder_within(
            &self.conn,
            &mut self.clock,
            now_ms,
            &self.device_id,
            track_id,
            new_index,
        )?;
        self.write_manifest(&t.playlist_id)
    }

    // ---------- сканирование ----------

    /// Сверяет папку Hydra с базой и записывает найденные изменения в журнал.
    pub fn scan(&mut self, now_ms: u64) -> Result<ScanReport> {
        let mut report = ScanReport::default();

        // 1. Подпапки = плейлисты
        let mut entries: Vec<fs::DirEntry> =
            fs::read_dir(&self.root)?.collect::<std::result::Result<Vec<_>, _>>()?;
        entries.sort_by_key(|e| e.file_name());
        let mut dirs: Vec<(String, PathBuf)> = Vec::new();
        for entry in entries {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || !entry.file_type()?.is_dir() {
                continue;
            }
            let pid = self.ensure_playlist(&name, now_ms, &mut report)?;
            dirs.push((pid, entry.path()));
        }

        // 2. Файлы в папках: известные, новые, и какие известные пропали
        let live = journal::live_tracks(&self.conn)?;
        let known: HashSet<(String, String)> = live
            .iter()
            .map(|t| (t.playlist_id.clone(), naming::fold_key(&t.file_name)))
            .collect();
        let mut present: HashSet<(String, String)> = HashSet::new();
        let mut new_files: Vec<(String, String, PathBuf)> = Vec::new();
        for (pid, dir) in &dirs {
            for f in fs::read_dir(dir)? {
                let f = f?;
                if !f.file_type()?.is_file() {
                    continue;
                }
                let fname = f.file_name().to_string_lossy().to_string();
                if fname.starts_with('.') || !naming::is_supported_audio(&fname) {
                    continue;
                }
                let key = (pid.clone(), naming::fold_key(&fname));
                if !known.contains(&key) {
                    new_files.push((pid.clone(), fname, f.path()));
                }
                present.insert(key);
            }
        }

        // Защита: пустая папка при непустой базе - скорее всего пропал доступ к хранилищу.
        if present.is_empty() && new_files.is_empty() && !live.is_empty() {
            return Err(Error::Invalid(
                "папка библиотеки выглядит пустой; удаление треков отменено".into(),
            ));
        }

        let mut missing: Vec<TrackState> = live
            .into_iter()
            .filter(|t| !present.contains(&(t.playlist_id.clone(), naming::fold_key(&t.file_name))))
            .collect();
        new_files.sort_by(|a, b| {
            (a.0.as_str(), naming::fold_key(&a.1)).cmp(&(b.0.as_str(), naming::fold_key(&b.1)))
        });

        // 3. Новые файлы: перемещение (по хэшу) или совсем новый трек
        for (pid, fname, path) in new_files {
            let sha = sha256_file(&path)?;
            if let Some(pos) = missing.iter().position(|m| m.sha256 == sha) {
                let m = missing.remove(pos);
                let mut payload = json!({"to_playlist_id": pid, "file_name": fname});
                if m.playlist_id != pid {
                    payload["order_key"] = json!(journal::append_key(&self.conn, &pid)?);
                }
                self.record(now_ms, Kind::Move, &m.track_id, payload)?;
                report.moved += 1;
            } else {
                // Теги читаются только здесь, при добавлении.
                let (title, artist) = read_tags(&path);
                let track_id = Uuid::new_v4().to_string();
                let key = journal::append_key(&self.conn, &pid)?;
                let payload = journal::add_payload(
                    &pid,
                    &fname,
                    &sha,
                    title.as_deref(),
                    artist.as_deref(),
                    &key,
                );
                self.record(now_ms, Kind::Add, &track_id, payload)?;
                report.added += 1;
            }
        }

        // 4. Файлы, которые пропали и не нашлись в другом месте: удалены вне приложения
        for m in missing {
            self.record(now_ms, Kind::Delete, &m.track_id, json!({"external": true}))?;
            report.removed += 1;
        }

        // 5. Плейлисты, чьих папок больше нет
        let on_disk: HashSet<&String> = dirs.iter().map(|(id, _)| id).collect();
        for p in self.all_playlists()? {
            if !p.deleted && !on_disk.contains(&p.id) {
                self.conn
                    .execute("UPDATE playlists SET deleted = 1 WHERE playlist_id = ?1", [&p.id])?;
            }
        }

        // 6. Скрытые манифесты порядка (пишутся только если содержимое изменилось)
        for (pid, _) in &dirs {
            self.write_manifest(pid)?;
        }
        Ok(report)
    }

    // ---------- внутреннее ----------

    fn record(&mut self, now_ms: u64, kind: Kind, track_id: &str, payload: serde_json::Value) -> Result<()> {
        journal::record_local(
            &self.conn,
            &mut self.clock,
            now_ms,
            &self.device_id,
            kind,
            track_id,
            payload,
        )?;
        Ok(())
    }

    fn live_track(&self, track_id: &str) -> Result<TrackState> {
        journal::get_track(&self.conn, track_id)?
            .filter(|t| !t.deleted)
            .ok_or_else(|| Error::Invalid(format!("track {track_id} not found")))
    }

    fn trash_dir(&self, track_id: &str) -> PathBuf {
        self.root.join(INTERNAL_DIR).join("trash").join(track_id)
    }

    fn playlist_dir(&self, playlist_id: &str) -> Result<PathBuf> {
        let name: Option<String> = self
            .conn
            .query_row(
                "SELECT dir_name FROM playlists WHERE playlist_id = ?1",
                [playlist_id],
                |r| r.get(0),
            )
            .optional()?;
        name.map(|n| self.root.join(n))
            .ok_or_else(|| Error::Invalid(format!("playlist {playlist_id} not found")))
    }

    fn all_playlists(&self) -> Result<Vec<PlaylistRow>> {
        let mut stmt = self
            .conn
            .prepare("SELECT playlist_id, dir_name, deleted FROM playlists ORDER BY dir_name")?;
        let rows = stmt
            .query_map([], |r| {
                Ok(PlaylistRow {
                    id: r.get(0)?,
                    dir_name: r.get(1)?,
                    deleted: r.get::<_, i32>(2)? != 0,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn insert_playlist(&mut self, dir_name: &str, now_ms: u64) -> Result<String> {
        let id = Uuid::new_v4().to_string();
        let hlc = self.clock.tick(now_ms).encode();
        self.conn.execute(
            "INSERT INTO playlists(playlist_id, dir_name, deleted, hlc) VALUES (?1, ?2, 0, ?3)",
            params![id, dir_name, hlc],
        )?;
        Ok(id)
    }

    /// Находит плейлист по имени папки (без учёта регистра), при необходимости воскрешает.
    fn ensure_playlist(&mut self, dir_name: &str, now_ms: u64, report: &mut ScanReport) -> Result<String> {
        let key = naming::fold_key(dir_name);
        let found = self
            .all_playlists()?
            .into_iter()
            .filter(|p| naming::fold_key(&p.dir_name) == key)
            .min_by_key(|p| p.deleted);
        match found {
            Some(p) => {
                if p.deleted || p.dir_name != dir_name {
                    self.conn.execute(
                        "UPDATE playlists SET deleted = 0, dir_name = ?2 WHERE playlist_id = ?1",
                        params![p.id, dir_name],
                    )?;
                }
                Ok(p.id)
            }
            None => {
                report.playlists_created += 1;
                self.insert_playlist(dir_name, now_ms)
            }
        }
    }

    /// Пишет скрытый `.<Плейлист>.json` рядом с треками, только если он изменился.
    pub fn write_manifest(&self, playlist_id: &str) -> Result<()> {
        let dir = self.playlist_dir(playlist_id)?;
        if !dir.is_dir() {
            return Ok(());
        }
        let name = dir.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let path = dir.join(naming::playlist_manifest_name(&name));
        let content = journal::manifest_json(&self.conn, playlist_id)?;
        if fs::read_to_string(&path).ok().as_deref() == Some(content.as_str()) {
            return Ok(());
        }
        // На Windows запись в файл с атрибутом Hidden отклоняется, поэтому удаляем и пишем заново.
        let _ = fs::remove_file(&path);
        fs::write(&path, content)?;
        hide(&path);
        Ok(())
    }
}

fn to_info(t: &TrackState, dir: &Path) -> TrackInfo {
    let title = t
        .title
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| stem(&t.file_name));
    TrackInfo {
        track_id: t.track_id.clone(),
        playlist_id: t.playlist_id.clone(),
        title,
        artist: t.artist.clone(),
        file_name: t.file_name.clone(),
        path: dir.join(&t.file_name).to_string_lossy().to_string(),
        is_video: naming::is_video_container(&t.file_name),
    }
}

fn stem(name: &str) -> String {
    match name.rsplit_once('.') {
        Some((s, _)) if !s.is_empty() => s.to_string(),
        _ => name.to_string(),
    }
}

fn list_names(dir: &Path) -> Vec<String> {
    fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default()
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut f = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Название и исполнитель из тегов. Файлы от других устройств считаются недоверенным
/// вводом: любая ошибка чтения даёт «нет тегов», а не падение.
fn read_tags(path: &Path) -> (Option<String>, Option<String>) {
    use lofty::prelude::*;
    let Ok(tagged) = lofty::read_from_path(path) else { return (None, None) };
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return (None, None);
    };
    (
        tag.title().map(|s| s.to_string()).filter(|s| !s.trim().is_empty()),
        tag.artist().map(|s| s.to_string()).filter(|s| !s.trim().is_empty()),
    )
}

/// Скрытый атрибут на Windows; на Android и Linux скрытость задаёт точка в имени.
#[cfg(windows)]
fn hide(path: &Path) {
    use std::os::windows::process::CommandExt;
    let _ = std::process::Command::new("attrib")
        .arg("+h")
        .arg(path)
        .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
        .status();
}

#[cfg(not(windows))]
fn hide(_path: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    const T0: u64 = 1_000_000;

    fn setup() -> (TempDir, Library) {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open(&tmp.path().join("Hydra"), &tmp.path().join("hydra.db"), "dev-a", T0)
            .unwrap();
        (tmp, lib)
    }

    /// Создаёт файл с уникальным содержимым (оно же даёт уникальный хэш).
    fn put(lib: &Library, playlist: &str, file: &str, content: &str) -> PathBuf {
        let dir = lib.root().join(playlist);
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join(file);
        fs::write(&p, content).unwrap();
        p
    }

    fn names(lib: &Library, playlist: &str) -> Vec<String> {
        let id = lib
            .playlists()
            .unwrap()
            .into_iter()
            .find(|p| p.name == playlist)
            .unwrap_or_else(|| panic!("нет плейлиста {playlist}"))
            .playlist_id;
        lib.tracks(&id).unwrap().into_iter().map(|t| t.file_name).collect()
    }

    fn playlist_id(lib: &Library, name: &str) -> String {
        lib.playlists().unwrap().into_iter().find(|p| p.name == name).unwrap().playlist_id
    }

    #[test]
    fn scan_picks_up_audio_files_and_ignores_the_rest() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "b.flac", "bbb");
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "cover.jpg", "img");
        put(&lib, "Rock", ".hidden.mp3", "hid");
        put(&lib, "Jazz", "c.ogg", "ccc");
        let r = lib.scan(T0 + 1).unwrap();
        assert_eq!(r, ScanReport { added: 3, moved: 0, removed: 0, playlists_created: 2 });
        assert_eq!(names(&lib, "Rock"), ["a.mp3", "b.flac"]);
        assert_eq!(names(&lib, "Jazz"), ["c.ogg"]);
        // название без тегов берётся из имени файла
        let rock = playlist_id(&lib, "Rock");
        assert_eq!(lib.tracks(&rock).unwrap()[0].title, "a");
    }

    #[test]
    fn rescan_changes_nothing() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let r = lib.scan(T0 + 2).unwrap();
        assert_eq!(r, ScanReport::default());
    }

    #[test]
    fn move_in_file_manager_is_detected_by_hash() {
        let (_t, mut lib) = setup();
        let p = put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Jazz", "z.mp3", "zzz");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();

        fs::rename(&p, lib.root().join("Jazz").join("a.mp3")).unwrap();
        let r = lib.scan(T0 + 2).unwrap();
        assert_eq!((r.added, r.moved, r.removed), (0, 1, 0));
        let jazz = playlist_id(&lib, "Jazz");
        let ids: Vec<String> = lib.tracks(&jazz).unwrap().into_iter().map(|t| t.track_id).collect();
        assert!(ids.contains(&id), "UUID трека должен сохраниться при перемещении");
        assert_eq!(names(&lib, "Jazz"), ["z.mp3", "a.mp3"], "перемещённый трек встаёт в конец");
    }

    #[test]
    fn renaming_a_file_keeps_its_identity() {
        let (_t, mut lib) = setup();
        let p = put(&lib, "Rock", "old.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();
        fs::rename(&p, lib.root().join("Rock").join("new.mp3")).unwrap();
        let r = lib.scan(T0 + 2).unwrap();
        assert_eq!((r.added, r.moved, r.removed), (0, 1, 0));
        let t = &lib.tracks(&rock).unwrap()[0];
        assert_eq!((t.track_id.as_str(), t.file_name.as_str()), (id.as_str(), "new.mp3"));
    }

    #[test]
    fn renaming_a_folder_does_not_lose_tracks() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let before: Vec<String> = lib.tracks(&rock).unwrap().into_iter().map(|t| t.track_id).collect();

        fs::rename(lib.root().join("Rock"), lib.root().join("Rock2")).unwrap();
        let r = lib.scan(T0 + 2).unwrap();
        assert_eq!((r.added, r.moved, r.removed, r.playlists_created), (0, 2, 0, 1));
        let pls: Vec<String> = lib.playlists().unwrap().into_iter().map(|p| p.name).collect();
        assert_eq!(pls, ["Rock2"], "старый плейлист исчезает, новый содержит те же треки");
        let rock2 = playlist_id(&lib, "Rock2");
        let mut after: Vec<String> = lib.tracks(&rock2).unwrap().into_iter().map(|t| t.track_id).collect();
        let mut before = before;
        before.sort();
        after.sort();
        assert_eq!(before, after);
    }

    #[test]
    fn duplicate_copy_becomes_a_separate_track() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "same");
        lib.scan(T0 + 1).unwrap();
        put(&lib, "Jazz", "a.mp3", "same");
        let r = lib.scan(T0 + 2).unwrap();
        assert_eq!((r.added, r.moved, r.removed), (1, 0, 0), "копия при живом оригинале - новый трек");
    }

    #[test]
    fn external_delete_is_recorded() {
        let (_t, mut lib) = setup();
        let p = put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        fs::remove_file(p).unwrap();
        let r = lib.scan(T0 + 2).unwrap();
        assert_eq!((r.added, r.moved, r.removed), (0, 0, 1));
        assert_eq!(names(&lib, "Rock"), ["b.mp3"]);
    }

    #[test]
    fn refuses_to_wipe_library_when_folder_looks_empty() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        fs::remove_dir_all(lib.root().join("Rock")).unwrap();
        assert!(lib.scan(T0 + 2).is_err());
        // треки на месте в базе
        let pls = lib.playlists().unwrap();
        assert_eq!(pls[0].track_count, 1);
    }

    #[test]
    fn app_move_is_physical_and_resolves_name_clash() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Jazz", "a.mp3", "different");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let jazz = playlist_id(&lib, "Jazz");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();

        lib.move_track(&id, &jazz, T0 + 2).unwrap();
        assert!(!lib.root().join("Rock").join("a.mp3").exists());
        assert!(lib.root().join("Jazz").join("a (2).mp3").exists());
        assert_eq!(names(&lib, "Jazz"), ["a.mp3", "a (2).mp3"]);
        // повторный скан ничего не меняет
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());
    }

    #[test]
    fn delete_goes_to_trash_and_can_be_restored() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();

        lib.delete_track(&id, T0 + 2).unwrap();
        assert!(!lib.root().join("Rock").join("a.mp3").exists());
        assert!(lib.root().join(INTERNAL_DIR).join("trash").join(&id).join("a.mp3").exists());
        assert_eq!(lib.trash_items().unwrap().len(), 1);
        assert!(lib.tracks(&rock).unwrap().is_empty());
        // скан не воскрешает и не дублирует удалённое
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());

        lib.restore_track(&id, T0 + 4).unwrap();
        assert!(lib.root().join("Rock").join("a.mp3").exists());
        assert!(lib.trash_items().unwrap().is_empty());
        assert_eq!(names(&lib, "Rock"), ["a.mp3"]);
        assert_eq!(lib.scan(T0 + 5).unwrap(), ScanReport::default());
    }

    #[test]
    fn purge_track_erases_file_but_keeps_tombstone() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();
        // из корзины можно стирать только удалённое
        assert!(lib.purge_track(&id).is_err());
        lib.delete_track(&id, T0 + 2).unwrap();
        lib.purge_track(&id).unwrap();
        assert!(lib.trash_items().unwrap().is_empty());
        assert!(!lib.root().join(INTERNAL_DIR).join("trash").join(&id).exists());
        assert!(lib.restore_track(&id, T0 + 3).is_err());
        // повторный скан не воскрешает стёртый трек
        assert_eq!(lib.scan(T0 + 4).unwrap(), ScanReport::default());
        assert_eq!(names(&lib, "Rock"), ["b.mp3"]);
    }

    #[test]
    fn trash_is_purged_after_30_days() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();
        lib.delete_track(&id, T0 + 2).unwrap();
        let day = 24 * 3600 * 1000u64;
        assert_eq!(lib.purge_expired_trash(T0 + 10 * day).unwrap(), 0);
        assert_eq!(lib.purge_expired_trash(T0 + 31 * day).unwrap(), 1);
        assert!(!lib.root().join(INTERNAL_DIR).join("trash").join(&id).exists());
        assert!(lib.restore_track(&id, T0 + 32 * day).is_err());
    }

    #[test]
    fn create_playlist_sanitizes_and_avoids_case_clashes() {
        let (_t, mut lib) = setup();
        let a = lib.create_playlist("AC/DC", T0 + 1).unwrap();
        assert_eq!(a.name, "AC_DC");
        let b = lib.create_playlist("ac_dc", T0 + 2).unwrap();
        assert_eq!(b.name, "ac_dc (2)");
        assert!(lib.root().join("AC_DC").is_dir() && lib.root().join("ac_dc (2)").is_dir());
        assert_eq!(lib.playlists().unwrap().len(), 2);
    }

    #[test]
    fn reorder_updates_hidden_manifest() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        put(&lib, "Rock", "c.mp3", "ccc");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let c = lib.tracks(&rock).unwrap().into_iter().find(|t| t.file_name == "c.mp3").unwrap();
        lib.reorder(&c.track_id, 0, T0 + 2).unwrap();
        assert_eq!(names(&lib, "Rock"), ["c.mp3", "a.mp3", "b.mp3"]);

        let manifest = lib.root().join("Rock").join(".Rock.json");
        let v: serde_json::Value = serde_json::from_str(&fs::read_to_string(manifest).unwrap()).unwrap();
        let order: Vec<String> =
            v["order"].as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect();
        let expected: Vec<String> =
            lib.tracks(&rock).unwrap().into_iter().map(|t| t.track_id).collect();
        assert_eq!(order, expected);
        // манифест не считается треком
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());
    }

    #[test]
    fn reopening_keeps_state_and_clock_moves_forward() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("Hydra");
        let db = tmp.path().join("hydra.db");
        {
            let mut lib = Library::open(&root, &db, "dev-a", T0).unwrap();
            put(&lib, "Rock", "a.mp3", "aaa");
            lib.scan(T0 + 5_000).unwrap();
        }
        // «часы устройства откатились» после перезапуска
        let mut lib = Library::open(&root, &db, "dev-a", T0).unwrap();
        assert_eq!(lib.playlists().unwrap()[0].track_count, 1);
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        assert_eq!(names(&lib, "Rock"), ["a.mp3", "b.mp3"]);
    }
}
