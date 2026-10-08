//! Библиотека на диске: папка Hydra, плейлисты-папки, треки-файлы.
//!
//! Связывает файловую систему с журналом операций:
//!  * `scan` сравнивает папку с базой и записывает add / move / delete в журнал;
//!  * перемещение файла между папками распознаётся по хэшу содержимого, поэтому
//!    перенос в Проводнике и переименование папки не создают «новых» треков;
//!  * теги читаются ТОЛЬКО при добавлении нового файла;
//!  * удаление из приложения кладёт файл в скрытую папку `.trash/<id>/` рядом с плейлистами
//!    (30 дней); рядом лежит `item.json`, по нему корзина восстанавливается после переустановки;
//!  * скрытый `.<Плейлист>.json` в папке плейлиста перегенерируется из журнала.
//!
//! Внутренняя папка `.hydra/` и любые имена с точкой в начале сканером игнорируются.

use crate::clock::{Clock, Hlc};
use crate::journal::{self, Kind, TrackState};
use crate::{db, naming, tags, Error, Result};
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
/// Корзина: скрытая папка в корне библиотеки (переживает переустановку приложения).
pub const TRASH_DIR: &str = ".trash";
const TRASH_META: &str = "item.json";
const PLAYLIST_ORDER_FILE: &str = ".playlists.json";

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
    sort_order: i64,
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
        fs::create_dir_all(root.join(INTERNAL_DIR))?;
        fs::create_dir_all(root.join(TRASH_DIR))?;
        hide(&root.join(INTERNAL_DIR));
        hide(&root.join(TRASH_DIR));
        migrate_legacy_trash(root);
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
        let mut rows: Vec<(i64, PlaylistInfo)> = Vec::new();
        for p in self.all_playlists()?.into_iter().filter(|p| !p.deleted) {
            let n: i64 = self.conn.query_row(
                "SELECT COUNT(*) FROM tracks WHERE playlist_id = ?1 AND deleted = 0",
                [&p.id],
                |r| r.get(0),
            )?;
            rows.push((
                p.sort_order,
                PlaylistInfo { playlist_id: p.id, name: p.dir_name, track_count: n as usize },
            ));
        }
        rows.sort_by_key(|(order, p)| (*order, naming::fold_key(&p.name)));
        Ok(rows.into_iter().map(|(_, p)| p).collect())
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
            let front = t
                .pictures()
                .iter()
                .find(|p| p.pic_type() == lofty::picture::PictureType::CoverFront);
            front.or_else(|| t.pictures().first()).map(|p| {
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
        self.write_playlist_order()?;
        Ok(PlaylistInfo { playlist_id: id, name: dir_name, track_count: 0 })
    }

    /// Переименовывает плейлист: меняется и папка на диске, и скрытый json.
    pub fn rename_playlist(&mut self, playlist_id: &str, new_name: &str) -> Result<PlaylistInfo> {
        let row = self
            .all_playlists()?
            .into_iter()
            .find(|p| p.id == playlist_id && !p.deleted)
            .ok_or_else(|| Error::Invalid(format!("playlist {playlist_id} not found")))?;
        let mut existing: Vec<String> = self
            .all_playlists()?
            .into_iter()
            .filter(|p| !p.deleted && p.id != playlist_id)
            .map(|p| p.dir_name)
            .collect();
        if let Ok(rd) = fs::read_dir(&self.root) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_string();
                if naming::fold_key(&n) != naming::fold_key(&row.dir_name) {
                    existing.push(n);
                }
            }
        }
        let new_dir = naming::unique_name(new_name, &existing);
        if new_dir != row.dir_name {
            let old_path = self.root.join(&row.dir_name);
            let new_path = self.root.join(&new_dir);
            if old_path.is_dir() {
                fs::rename(&old_path, &new_path)?;
            } else {
                fs::create_dir_all(&new_path)?;
            }
            // старый скрытый json переехал вместе с папкой: убираем его, пишем новый
            let _ = fs::remove_file(new_path.join(naming::playlist_manifest_name(&row.dir_name)));
            self.conn.execute(
                "UPDATE playlists SET dir_name = ?2 WHERE playlist_id = ?1",
                params![playlist_id, new_dir],
            )?;
            self.write_manifest(playlist_id)?;
            self.write_playlist_order()?;
            self.refresh_trash_meta_for_playlist(playlist_id);
        }
        let n: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM tracks WHERE playlist_id = ?1 AND deleted = 0",
            [playlist_id],
            |r| r.get(0),
        )?;
        Ok(PlaylistInfo { playlist_id: playlist_id.to_string(), name: new_dir, track_count: n as usize })
    }

    /// Удаляет плейлист, только если в нём нет треков и в папке нет чужих файлов.
    pub fn delete_playlist(&mut self, playlist_id: &str) -> Result<()> {
        let row = self
            .all_playlists()?
            .into_iter()
            .find(|p| p.id == playlist_id && !p.deleted)
            .ok_or_else(|| Error::Invalid(format!("playlist {playlist_id} not found")))?;
        let n: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM tracks WHERE playlist_id = ?1 AND deleted = 0",
            [playlist_id],
            |r| r.get(0),
        )?;
        if n > 0 {
            return Err(Error::Invalid("в плейлисте есть треки: сначала удалите или перенесите их".into()));
        }
        let dir = self.root.join(&row.dir_name);
        if dir.is_dir() {
            // допустимы только скрытые служебные файлы (манифест)
            for e in fs::read_dir(&dir)? {
                let e = e?;
                if !e.file_name().to_string_lossy().starts_with('.') {
                    return Err(Error::Invalid(
                        "в папке плейлиста остались посторонние файлы; приложение их не удаляет".into(),
                    ));
                }
            }
            fs::remove_dir_all(&dir)?;
        }
        self.conn.execute("UPDATE playlists SET deleted = 1 WHERE playlist_id = ?1", [playlist_id])?;
        self.write_playlist_order()?;
        Ok(())
    }

    /// Ставит плейлист на позицию `new_index` (0 - первый).
    pub fn reorder_playlist(&mut self, playlist_id: &str, new_index: usize) -> Result<()> {
        let mut ids: Vec<String> = self.playlists()?.into_iter().map(|p| p.playlist_id).collect();
        let pos = ids
            .iter()
            .position(|i| i == playlist_id)
            .ok_or_else(|| Error::Invalid(format!("playlist {playlist_id} not found")))?;
        let id = ids.remove(pos);
        ids.insert(new_index.min(ids.len()), id);
        for (i, id) in ids.iter().enumerate() {
            self.conn.execute(
                "UPDATE playlists SET sort_order = ?2 WHERE playlist_id = ?1",
                params![id, i as i64 + 1],
            )?;
        }
        self.write_playlist_order()
    }

    /// Меняет название трека. Название записывается и в теги файла, если формат это
    /// позволяет; иначе оно хранится только в приложении. Возвращает `true`, если теги записаны.
    pub fn rename_track(&mut self, track_id: &str, title: &str, now_ms: u64) -> Result<bool> {
        let title = title.trim();
        if title.is_empty() {
            return Err(Error::Invalid("название не может быть пустым".into()));
        }
        if title.chars().count() > 200 {
            return Err(Error::Invalid("название слишком длинное".into()));
        }
        let t = self.live_track(track_id)?;
        let path = self.playlist_dir(&t.playlist_id)?.join(&t.file_name);
        let written = path.is_file() && tags::write_title(&path, title, &self.tmp_dir()).is_ok();
        let mut payload = json!({ "title": title });
        if written {
            payload["sha256"] = json!(sha256_file(&path)?);
        }
        self.record(now_ms, Kind::Edit, track_id, payload)?;
        self.write_manifest(&t.playlist_id)?;
        Ok(written)
    }

    /// Заменяет обложку: картинка уменьшается, сжимается в jpeg и встраивается в файл.
    pub fn set_cover(&mut self, track_id: &str, image_path: &Path, now_ms: u64) -> Result<()> {
        let t = self.live_track(track_id)?;
        let path = self.playlist_dir(&t.playlist_id)?.join(&t.file_name);
        if !path.is_file() {
            return Err(Error::Invalid("файла трека нет на диске".into()));
        }
        let jpeg = tags::prepare_cover(image_path)?;
        tags::write_cover(&path, &jpeg, &self.tmp_dir())?;
        let payload = json!({ "sha256": sha256_file(&path)? });
        self.record(now_ms, Kind::Edit, track_id, payload)?;
        self.write_manifest(&t.playlist_id)?;
        Ok(())
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

    /// Удаление из приложения: файл уходит в `.trash/<id>/` на 30 дней.
    pub fn delete_track(&mut self, track_id: &str, now_ms: u64) -> Result<()> {
        let t = self.live_track(track_id)?;
        let src = self.playlist_dir(&t.playlist_id)?.join(&t.file_name);
        let tdir = self.trash_dir(track_id);
        fs::create_dir_all(&tdir)?;
        if src.exists() {
            fs::rename(&src, tdir.join(&t.file_name))?;
        }
        self.record(now_ms, Kind::Delete, track_id, json!({}))?;
        self.write_trash_meta(track_id);
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
        let _ = fs::remove_dir_all(self.trash_dir(track_id));
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

    /// Стирает всё содержимое корзины. Записи об удалении в журнале остаются.
    /// Возвращает число стёртых треков.
    pub fn empty_trash(&mut self) -> Result<usize> {
        let mut stmt = self.conn.prepare("SELECT track_id FROM trash")?;
        let ids = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        for id in &ids {
            let _ = fs::remove_dir_all(self.trash_dir(id));
            journal::forget_trashed(&self.conn, id)?;
        }
        // остатки без записи в базе (например, после сбоя)
        if let Ok(rd) = fs::read_dir(self.root.join(TRASH_DIR)) {
            for e in rd.flatten() {
                let _ = fs::remove_dir_all(e.path());
            }
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

    /// Расставляет треки плейлиста в заданном порядке одной операцией (сортировка).
    /// `ordered` - идентификаторы треков в нужном порядке; не названные остаются в конце.
    /// Всё записывается в журнал как обычные перестановки, поэтому синхронизируется.
    pub fn set_track_order(&mut self, playlist_id: &str, ordered: &[String], now_ms: u64) -> Result<()> {
        self.conn.execute_batch("BEGIN")?;
        let mut outcome: Result<()> = Ok(());
        for (i, id) in ordered.iter().enumerate() {
            if let Err(e) = journal::reorder_within(
                &self.conn,
                &mut self.clock,
                now_ms,
                &self.device_id,
                id,
                i,
            ) {
                outcome = Err(e);
                break;
            }
        }
        match outcome {
            Ok(()) => self.conn.execute_batch("COMMIT")?,
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                return Err(e);
            }
        }
        self.write_manifest(playlist_id)
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

        // 1b. Корзина-папка: подхватываем то, что осталось после переустановки
        self.recover_trash(now_ms)?;

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
        self.write_playlist_order()?;
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
        self.root.join(TRASH_DIR).join(track_id)
    }

    fn tmp_dir(&self) -> PathBuf {
        self.root.join(INTERNAL_DIR).join("tmp")
    }

    /// Пишет `item.json` рядом с файлом в корзине. Ошибка не критична: это запасная копия
    /// сведений для восстановления после переустановки.
    fn write_trash_meta(&self, track_id: &str) {
        let _ = self.try_write_trash_meta(track_id);
    }

    fn try_write_trash_meta(&self, track_id: &str) -> Result<()> {
        let Some(t) = journal::get_track(&self.conn, track_id)? else { return Ok(()) };
        let deleted_ms: Option<i64> = self
            .conn
            .query_row("SELECT deleted_ms FROM trash WHERE track_id = ?1", [track_id], |r| r.get(0))
            .optional()?;
        let Some(deleted_ms) = deleted_ms else { return Ok(()) };
        let dir = self.trash_dir(track_id);
        if !dir.is_dir() {
            return Ok(());
        }
        let playlist_name: Option<String> = self
            .conn
            .query_row(
                "SELECT dir_name FROM playlists WHERE playlist_id = ?1",
                [&t.playlist_id],
                |r| r.get(0),
            )
            .optional()?;
        let meta = json!({
            "version": 1,
            "track_id": t.track_id,
            "file_name": t.file_name,
            "sha256": t.sha256,
            "playlist_name": playlist_name.unwrap_or_default(),
            "title": t.title,
            "artist": t.artist,
            "deleted_ms": deleted_ms,
        });
        fs::write(dir.join(TRASH_META), serde_json::to_string_pretty(&meta)?)?;
        Ok(())
    }

    fn refresh_trash_meta_for_playlist(&self, playlist_id: &str) {
        let ids: Vec<String> = self
            .conn
            .prepare("SELECT track_id FROM trash WHERE playlist_id = ?1")
            .and_then(|mut s| {
                s.query_map([playlist_id], |r| r.get::<_, String>(0))?
                    .collect::<std::result::Result<Vec<_>, _>>()
            })
            .unwrap_or_default();
        for id in ids {
            self.write_trash_meta(&id);
        }
    }

    /// После переустановки база пуста, а `.trash/` осталась. Каждая папка с `item.json`
    /// превращается обратно в «добавлен, затем удалён» с прежней датой удаления.
    /// Заодно дописывает `item.json` тем записям, у которых его ещё нет (старая корзина).
    fn recover_trash(&mut self, now_ms: u64) -> Result<()> {
        let trash_root = self.root.join(TRASH_DIR);
        let Ok(rd) = fs::read_dir(&trash_root) else { return Ok(()) };
        let mut dirs: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
        dirs.sort();
        for dir in dirs {
            let Some(id) = dir.file_name().map(|n| n.to_string_lossy().to_string()) else { continue };
            if Uuid::parse_str(&id).is_err() {
                continue;
            }
            if journal::get_track(&self.conn, &id)?.is_some() {
                if !dir.join(TRASH_META).exists() {
                    self.write_trash_meta(&id);
                }
                continue;
            }
            // неизвестный базе трек: восстанавливаем по item.json
            let Ok(text) = fs::read_to_string(dir.join(TRASH_META)) else { continue };
            let Ok(meta) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
            let Some(file_name) = meta["file_name"].as_str().map(|s| s.to_string()) else { continue };
            // имя файла из чужого json: только простое имя, без путей
            if file_name.contains(['/', '\\']) || file_name.starts_with('.') || !dir.join(&file_name).is_file() {
                continue;
            }
            let playlist_name = meta["playlist_name"].as_str().unwrap_or("").to_string();
            let playlist_name = if playlist_name.trim().is_empty() {
                "Restored".to_string()
            } else {
                naming::sanitize(&playlist_name)
            };
            let pid = self.find_or_create_playlist(&playlist_name, now_ms)?;
            let sha = meta["sha256"].as_str().unwrap_or("").to_string();
            let title = meta["title"].as_str().map(|s| s.to_string());
            let artist = meta["artist"].as_str().map(|s| s.to_string());
            let key = journal::append_key(&self.conn, &pid)?;
            let payload = journal::add_payload(&pid, &file_name, &sha, title.as_deref(), artist.as_deref(), &key);
            self.record(now_ms, Kind::Add, &id, payload)?;
            self.record(now_ms, Kind::Delete, &id, json!({}))?;
            if let Some(ms) = meta["deleted_ms"].as_i64() {
                self.conn.execute("UPDATE trash SET deleted_ms = ?2 WHERE track_id = ?1", params![id, ms])?;
            }
        }
        Ok(())
    }

    /// Плейлист по имени (без учёта регистра). Если такого нет, создаёт запись помеченной
    /// удалённой: папку заново создаёт `restore_track`, когда трек вернут из корзины.
    fn find_or_create_playlist(&mut self, name: &str, now_ms: u64) -> Result<String> {
        let key = naming::fold_key(name);
        let found = self
            .all_playlists()?
            .into_iter()
            .filter(|p| naming::fold_key(&p.dir_name) == key)
            .min_by_key(|p| p.deleted);
        if let Some(p) = found {
            return Ok(p.id);
        }
        let id = self.insert_playlist(name, now_ms)?;
        self.conn.execute("UPDATE playlists SET deleted = 1 WHERE playlist_id = ?1", [&id])?;
        Ok(id)
    }

    /// Порядок плейлистов в скрытом `.playlists.json`: после переустановки он возвращается.
    fn write_playlist_order(&self) -> Result<()> {
        let names: Vec<String> = self.playlists()?.into_iter().map(|p| p.name).collect();
        let content = serde_json::to_string_pretty(&json!({ "version": 1, "order": names }))?;
        let path = self.root.join(PLAYLIST_ORDER_FILE);
        if fs::read_to_string(&path).ok().as_deref() == Some(content.as_str()) {
            return Ok(());
        }
        let _ = fs::remove_file(&path);
        fs::write(&path, content)?;
        hide(&path);
        Ok(())
    }

    fn saved_playlist_order(&self) -> Vec<String> {
        fs::read_to_string(self.root.join(PLAYLIST_ORDER_FILE))
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .and_then(|v| {
                v["order"].as_array().map(|a| {
                    a.iter().filter_map(|x| x.as_str().map(|s| naming::fold_key(s))).collect()
                })
            })
            .unwrap_or_default()
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
            .prepare("SELECT playlist_id, dir_name, deleted, sort_order FROM playlists ORDER BY dir_name")?;
        let rows = stmt
            .query_map([], |r| {
                Ok(PlaylistRow {
                    id: r.get(0)?,
                    dir_name: r.get(1)?,
                    deleted: r.get::<_, i32>(2)? != 0,
                    sort_order: r.get(3)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn insert_playlist(&mut self, dir_name: &str, now_ms: u64) -> Result<String> {
        let id = Uuid::new_v4().to_string();
        let hlc = self.clock.tick(now_ms).encode();
        // место в списке: как в сохранённом `.playlists.json`, иначе в конец
        let saved = self.saved_playlist_order();
        let sort_order: i64 = match saved.iter().position(|n| *n == naming::fold_key(dir_name)) {
            Some(i) => i as i64 + 1,
            None => {
                let max: i64 = self.conn.query_row(
                    "SELECT COALESCE(MAX(sort_order), 0) FROM playlists",
                    [],
                    |r| r.get(0),
                )?;
                max.max(saved.len() as i64) + 1
            }
        };
        self.conn.execute(
            "INSERT INTO playlists(playlist_id, dir_name, deleted, hlc, sort_order) VALUES (?1, ?2, 0, ?3, ?4)",
            params![id, dir_name, hlc, sort_order],
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

/// Старая корзина лежала в `.hydra/trash/<id>/`: переносим её в `.trash/`.
fn migrate_legacy_trash(root: &Path) {
    let old = root.join(INTERNAL_DIR).join("trash");
    let Ok(rd) = fs::read_dir(&old) else { return };
    for e in rd.flatten() {
        let target = root.join(TRASH_DIR).join(e.file_name());
        if !target.exists() {
            let _ = fs::rename(e.path(), target);
        }
    }
    let _ = fs::remove_dir(&old);
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
        assert!(lib.root().join(TRASH_DIR).join(&id).join("a.mp3").exists());
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
        assert!(!lib.root().join(TRASH_DIR).join(&id).exists());
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
        assert!(!lib.root().join(TRASH_DIR).join(&id).exists());
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
    fn set_track_order_sorts_whole_playlist() {
        let (_t, mut lib) = setup();
        for n in ["c.mp3", "a.mp3", "d.mp3", "b.mp3"] {
            put(&lib, "Rock", n, n);
        }
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let mut tracks = lib.tracks(&rock).unwrap();
        tracks.sort_by(|x, y| x.file_name.cmp(&y.file_name));
        let ids: Vec<String> = tracks.into_iter().map(|t| t.track_id).collect();
        lib.set_track_order(&rock, &ids, T0 + 2).unwrap();
        assert_eq!(names(&lib, "Rock"), ["a.mp3", "b.mp3", "c.mp3", "d.mp3"]);

        // обратный порядок
        let rev: Vec<String> = ids.iter().rev().cloned().collect();
        lib.set_track_order(&rock, &rev, T0 + 3).unwrap();
        assert_eq!(names(&lib, "Rock"), ["d.mp3", "c.mp3", "b.mp3", "a.mp3"]);
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

    fn tiny_mp3() -> Vec<u8> {
        // 20 одинаковых тихих кадров MPEG-1 Layer III, 128 кбит/с, 44,1 кГц (по 417 байт)
        let mut v = Vec::new();
        for _ in 0..20 {
            v.extend_from_slice(&[0xFF, 0xFB, 0x90, 0x00]);
            v.extend(std::iter::repeat(0u8).take(413));
        }
        v
    }

    fn put_bytes(lib: &Library, playlist: &str, file: &str, bytes: &[u8]) -> PathBuf {
        let dir = lib.root().join(playlist);
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join(file);
        fs::write(&p, bytes).unwrap();
        p
    }

    fn reopen(tmp: &TempDir, db: &str, now: u64) -> Library {
        Library::open(&tmp.path().join("Hydra"), &tmp.path().join(db), "dev-a", now).unwrap()
    }

    fn playlist_names(lib: &Library) -> Vec<String> {
        lib.playlists().unwrap().into_iter().map(|p| p.name).collect()
    }

    #[test]
    fn rename_playlist_moves_folder_and_manifest() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();

        let r = lib.rename_playlist(&rock, "Hard/Rock").unwrap();
        assert_eq!(r.name, "Hard_Rock");
        assert!(!lib.root().join("Rock").exists());
        assert!(lib.root().join("Hard_Rock").join("a.mp3").exists());
        assert!(lib.root().join("Hard_Rock").join(".Hard_Rock.json").exists());
        assert!(!lib.root().join("Hard_Rock").join(".Rock.json").exists());
        // треки и их UUID на месте, повторный скан ничего не меняет
        assert_eq!(lib.tracks(&rock).unwrap()[0].track_id, id);
        assert_eq!(lib.scan(T0 + 2).unwrap(), ScanReport::default());
        assert_eq!(playlist_names(&lib), ["Hard_Rock"]);
    }

    #[test]
    fn rename_playlist_avoids_clashes() {
        let (_t, mut lib) = setup();
        lib.create_playlist("Rock", T0 + 1).unwrap();
        let jazz = lib.create_playlist("Jazz", T0 + 2).unwrap();
        let r = lib.rename_playlist(&jazz.playlist_id, "rock").unwrap();
        assert_eq!(r.name, "rock (2)");
        // тот же регистр/имя: ничего не ломается
        let again = lib.rename_playlist(&jazz.playlist_id, "rock (2)").unwrap();
        assert_eq!(again.name, "rock (2)");
    }

    #[test]
    fn playlists_can_be_reordered_and_order_survives_reinstall() {
        let (t, mut lib) = setup();
        lib.create_playlist("A", T0 + 1).unwrap();
        lib.create_playlist("B", T0 + 2).unwrap();
        let c = lib.create_playlist("C", T0 + 3).unwrap();
        assert_eq!(playlist_names(&lib), ["A", "B", "C"]);
        lib.reorder_playlist(&c.playlist_id, 0).unwrap();
        assert_eq!(playlist_names(&lib), ["C", "A", "B"]);

        // «переустановка»: новая база при той же папке Hydra
        drop(lib);
        let mut lib2 = reopen(&t, "fresh.db", T0 + 10);
        lib2.scan(T0 + 11).unwrap();
        assert_eq!(playlist_names(&lib2), ["C", "A", "B"]);
    }

    #[test]
    fn playlist_can_be_deleted_only_when_empty() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Jazz", "z.mp3", "zzz");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        assert!(lib.delete_playlist(&rock).is_err(), "с треками удалять нельзя");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();
        lib.delete_track(&id, T0 + 2).unwrap();
        lib.delete_playlist(&rock).unwrap();
        assert!(!lib.root().join("Rock").exists());
        assert_eq!(playlist_names(&lib), ["Jazz"]);
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());
        // трек из корзины возвращает и плейлист
        lib.restore_track(&id, T0 + 4).unwrap();
        assert_eq!(playlist_names(&lib), ["Jazz", "Rock"]);
        assert!(lib.root().join("Rock").join("a.mp3").exists());
    }

    #[test]
    fn playlist_with_foreign_files_is_not_deleted() {
        let (_t, mut lib) = setup();
        let p = lib.create_playlist("Misc", T0 + 1).unwrap();
        fs::write(lib.root().join("Misc").join("notes.txt"), "hi").unwrap();
        assert!(lib.delete_playlist(&p.playlist_id).is_err());
        assert!(lib.root().join("Misc").join("notes.txt").exists());
    }

    #[test]
    fn trash_lives_in_hidden_folder_and_survives_reinstall() {
        let (t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let a = lib.tracks(&rock).unwrap()[0].track_id.clone();
        lib.delete_track(&a, T0 + 2).unwrap();
        assert!(lib.root().join(TRASH_DIR).join(&a).join("a.mp3").exists());
        assert!(lib.root().join(TRASH_DIR).join(&a).join("item.json").exists());

        // «переустановка»: база новая, папка Hydra та же
        drop(lib);
        let mut lib2 = reopen(&t, "fresh.db", T0 + 100);
        lib2.scan(T0 + 101).unwrap();
        let items = lib2.trash_items().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].track_id, a, "тот же UUID");
        assert_eq!(items[0].title, "a");
        assert_eq!(items[0].deleted_ms, (T0 + 2) as i64, "дата удаления сохранилась");
        // повторный скан ничего не дублирует, трек из корзины не воскресает сам
        assert_eq!(lib2.scan(T0 + 102).unwrap(), ScanReport::default());
        assert_eq!(names(&lib2, "Rock"), ["b.mp3"]);
        // и его можно вернуть
        lib2.restore_track(&a, T0 + 103).unwrap();
        assert!(lib2.root().join("Rock").join("a.mp3").exists());
        assert!(lib2.trash_items().unwrap().is_empty());
    }

    #[test]
    fn trash_of_a_vanished_playlist_is_recovered_too() {
        let (t, mut lib) = setup();
        put(&lib, "Old", "a.mp3", "aaa");
        put(&lib, "Keep", "k.mp3", "kkk");
        lib.scan(T0 + 1).unwrap();
        let old = playlist_id(&lib, "Old");
        let a = lib.tracks(&old).unwrap()[0].track_id.clone();
        lib.delete_track(&a, T0 + 2).unwrap();
        lib.delete_playlist(&old).unwrap();

        drop(lib);
        let mut lib2 = reopen(&t, "fresh.db", T0 + 100);
        lib2.scan(T0 + 101).unwrap();
        assert_eq!(playlist_names(&lib2), ["Keep"]);
        assert_eq!(lib2.trash_items().unwrap().len(), 1);
        lib2.restore_track(&a, T0 + 102).unwrap();
        assert_eq!(playlist_names(&lib2), ["Keep", "Old"]);
        assert!(lib2.root().join("Old").join("a.mp3").exists());
    }

    #[test]
    fn legacy_trash_is_migrated() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("Hydra");
        let id = Uuid::new_v4().to_string();
        let old = root.join(INTERNAL_DIR).join("trash").join(&id);
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join("x.mp3"), "xxx").unwrap();
        let _lib = Library::open(&root, &tmp.path().join("h.db"), "dev-a", T0).unwrap();
        assert!(root.join(TRASH_DIR).join(&id).join("x.mp3").exists());
        assert!(!old.exists());
    }

    #[test]
    fn empty_trash_erases_everything() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        put(&lib, "Rock", "c.mp3", "ccc");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let ids: Vec<String> = lib.tracks(&rock).unwrap().into_iter().map(|t| t.track_id).collect();
        lib.delete_track(&ids[0], T0 + 2).unwrap();
        lib.delete_track(&ids[1], T0 + 3).unwrap();
        assert_eq!(lib.empty_trash().unwrap(), 2);
        assert!(lib.trash_items().unwrap().is_empty());
        assert!(fs::read_dir(lib.root().join(TRASH_DIR)).unwrap().next().is_none());
        assert_eq!(names(&lib, "Rock"), ["c.mp3"]);
        assert_eq!(lib.scan(T0 + 4).unwrap(), ScanReport::default());
    }

    #[test]
    fn rename_track_in_a_file_without_tags_keeps_title_in_app() {
        let (_t, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "not really an mp3");
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();
        assert!(lib.rename_track(&id, "   ", T0 + 2).is_err());
        let written = lib.rename_track(&id, "  Новое имя ", T0 + 2).unwrap();
        assert!(!written, "в нечитаемый файл теги не пишутся");
        assert_eq!(lib.tracks(&rock).unwrap()[0].title, "Новое имя");
        // файл не тронут, лишних копий нет
        assert_eq!(fs::read_to_string(lib.root().join("Rock").join("a.mp3")).unwrap(), "not really an mp3");
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());
    }

    #[test]
    fn rename_track_writes_the_title_into_a_real_mp3() {
        use lofty::prelude::*;
        let (_t, mut lib) = setup();
        let path = put_bytes(&lib, "Rock", "a.mp3", &tiny_mp3());
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();

        assert!(lib.rename_track(&id, "Hydra Song", T0 + 2).unwrap(), "теги должны записаться");
        let tagged = lofty::read_from_path(&path).unwrap();
        let tag = tagged.primary_tag().or_else(|| tagged.first_tag()).unwrap();
        assert_eq!(tag.title().as_deref(), Some("Hydra Song"));
        assert_eq!(lib.tracks(&rock).unwrap()[0].title, "Hydra Song");
        // скан видит тот же файл (хэш обновлён), а не «удалён + добавлен»
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());
        assert!(!lib.root().join(INTERNAL_DIR).join("tmp").read_dir().map(|mut d| d.next().is_some()).unwrap_or(false));
    }

    #[test]
    fn set_cover_embeds_the_picture_in_the_file() {
        let (t, mut lib) = setup();
        put_bytes(&lib, "Rock", "a.mp3", &tiny_mp3());
        lib.scan(T0 + 1).unwrap();
        let rock = playlist_id(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();
        assert!(lib.cover(&id).unwrap().is_none());

        let png = t.path().join("pic.png");
        image::RgbImage::from_pixel(8, 8, image::Rgb([200, 30, 30])).save(&png).unwrap();
        lib.set_cover(&id, &png, T0 + 2).unwrap();
        let (mime, bytes) = lib.cover(&id).unwrap().expect("обложка должна появиться");
        assert!(mime.contains("jpeg"), "{mime}");
        assert!(bytes.len() > 100);
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());

        // повторная замена не копит обложки
        lib.set_cover(&id, &png, T0 + 4).unwrap();
        assert!(lib.cover(&id).unwrap().is_some());
        // не картинка - понятная ошибка, файл цел
        let bad = t.path().join("bad.png");
        fs::write(&bad, "nope").unwrap();
        assert!(lib.set_cover(&id, &bad, T0 + 5).is_err());
        assert!(lib.cover(&id).unwrap().is_some());
    }
}
