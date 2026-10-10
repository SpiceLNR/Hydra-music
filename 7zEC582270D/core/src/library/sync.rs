//! Слияние библиотек двух устройств (без сети: сеть только возит эти данные).
//!
//! Порядок одного сеанса (его ведёт `net`, здесь каждый шаг отдельная функция):
//!  1. `sync_inventory` - обменяться описью (плейлисты и треки с хэшами);
//!  2. `sync_adopt` - «усыновить» общие id: один и тот же плейлист (по имени) и один и тот же
//!     файл (по хэшу) получают одинаковый id на обоих устройствах, поэтому дублей не будет;
//!  3. `sync_prepare` - дописать в журнал плейлистов то, чего там ещё нет;
//!  4. `sync_vector` / `sync_batch_for` - обменяться недостающими операциями журнала;
//!  5. `sync_apply` - применить чужие операции: плейлисты, переименования, перемещения,
//!     удаления (в корзину), порядок. Файлы, которых ещё нет, помечаются `pending`;
//!  6. `sync_needs` + `sync_file_for` + `sync_store_file` - докачать недостающие файлы.
//!
//! Источник правды - журнал. Всё применяется идемпотентно и в любом порядке доставки.

use super::*;
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};

/// Состояние журнала устройства: для каждого автора операций - самая поздняя метка.
pub type Vector = BTreeMap<String, String>;

/// Операция журнала плейлистов.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlOp {
    pub op_id: String,
    pub hlc: Hlc,
    pub device_id: String,
    /// Пустая строка - операция над списком плейлистов целиком (порядок).
    pub playlist_id: String,
    /// `{"name": ..}`, `{"deleted": bool}` или `{"order": [id, ..]}`.
    pub payload: serde_json::Value,
}

/// Пачка операций для передачи другому устройству.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SyncBatch {
    pub ops: Vec<Op>,
    pub pl_ops: Vec<PlOp>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InvPlaylist {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InvTrack {
    pub id: String,
    pub playlist_id: String,
    pub sha256: String,
}

/// Опись библиотеки: нужна только чтобы договориться об общих id.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Inventory {
    pub playlists: Vec<InvPlaylist>,
    pub tracks: Vec<InvTrack>,
}

/// Файл, который нужно получить от другого устройства.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileNeed {
    pub track_id: String,
    pub sha256: String,
    pub file_name: String,
    pub playlist: String,
}

#[derive(Debug, Default, Clone, PartialEq, Serialize)]
pub struct MergeReport {
    /// Сколько новых операций (треков и плейлистов) принято.
    pub new_ops: usize,
    pub moved: usize,
    pub trashed: usize,
    pub pending_files: usize,
}

impl Library {
    // ---------- 1-2. общие идентификаторы ----------

    pub fn sync_inventory(&self) -> Result<Inventory> {
        let playlists = self
            .all_playlists()?
            .into_iter()
            .filter(|p| !p.deleted)
            .map(|p| InvPlaylist { id: p.id, name: p.dir_name })
            .collect();
        let mut stmt = self.conn.prepare(
            "SELECT track_id, playlist_id, sha256 FROM tracks
             WHERE deleted = 0 OR track_id IN (SELECT track_id FROM trash)
             ORDER BY track_id",
        )?;
        let tracks = stmt
            .query_map([], |r| {
                Ok(InvTrack { id: r.get(0)?, playlist_id: r.get(1)?, sha256: r.get(2)? })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(Inventory { playlists, tracks })
    }

    /// Приводит id общих плейлистов и треков к одинаковым (берётся меньший из двух).
    /// Оба устройства считают одно и то же по одним и тем же описям, поэтому договариваться
    /// дополнительно не нужно. Возвращает число изменённых id.
    pub fn sync_adopt(&mut self, remote: &Inventory) -> Result<usize> {
        let mut changed = 0;

        // плейлисты: одинаковое имя (без учёта регистра) = один плейлист
        let local: Vec<PlaylistRow> =
            self.all_playlists()?.into_iter().filter(|p| !p.deleted).collect();
        let mut canon_remote: HashMap<String, String> = HashMap::new();
        let mut renames: Vec<(String, String)> = Vec::new();
        for r in &remote.playlists {
            let key = naming::fold_key(&r.name);
            match local.iter().find(|l| naming::fold_key(&l.dir_name) == key) {
                Some(l) => {
                    let canon = if l.id <= r.id { l.id.clone() } else { r.id.clone() };
                    canon_remote.insert(r.id.clone(), canon.clone());
                    if l.id != canon {
                        renames.push((l.id.clone(), canon));
                    }
                }
                None => {
                    canon_remote.insert(r.id.clone(), r.id.clone());
                }
            }
        }
        for (old, new) in renames {
            if self.playlist_row_exists(&new)? {
                continue;
            }
            self.remap_playlist(&old, &new)?;
            changed += 1;
        }

        // треки: одинаковый плейлист и одинаковый хэш = один и тот же файл
        let mut local_groups: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
        for t in self.sync_inventory()?.tracks {
            if !t.sha256.is_empty() {
                local_groups.entry((t.playlist_id, t.sha256)).or_default().push(t.id);
            }
        }
        let mut remote_groups: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
        for t in &remote.tracks {
            if t.sha256.is_empty() {
                continue;
            }
            let pid = canon_remote.get(&t.playlist_id).cloned().unwrap_or_else(|| t.playlist_id.clone());
            remote_groups.entry((pid, t.sha256.clone())).or_default().push(t.id.clone());
        }
        let mut track_renames: Vec<(String, String)> = Vec::new();
        for (key, mut lids) in local_groups {
            let Some(mut rids) = remote_groups.remove(&key) else { continue };
            lids.sort();
            rids.sort();
            for (l, r) in lids.iter().zip(rids.iter()) {
                if l > r {
                    track_renames.push((l.clone(), r.clone()));
                }
            }
        }
        for (old, new) in track_renames {
            if self.track_row_exists(&new)? {
                continue;
            }
            self.remap_track(&old, &new)?;
            changed += 1;
        }
        Ok(changed)
    }

    fn playlist_row_exists(&self, id: &str) -> Result<bool> {
        let n: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM playlists WHERE playlist_id = ?1",
            [id],
            |r| r.get(0),
        )?;
        Ok(n > 0)
    }

    fn track_row_exists(&self, id: &str) -> Result<bool> {
        let n: i64 =
            self.conn.query_row("SELECT COUNT(*) FROM tracks WHERE track_id = ?1", [id], |r| r.get(0))?;
        Ok(n > 0)
    }

    /// Меняет id плейлиста везде: таблицы, журналы (включая id внутри содержимого операций).
    fn remap_playlist(&mut self, old: &str, new: &str) -> Result<()> {
        for sql in [
            "UPDATE playlists SET playlist_id = ?2 WHERE playlist_id = ?1",
            "UPDATE tracks SET playlist_id = ?2 WHERE playlist_id = ?1",
            "UPDATE trash SET playlist_id = ?2 WHERE playlist_id = ?1",
            "UPDATE pl_ops SET playlist_id = ?2 WHERE playlist_id = ?1",
        ] {
            self.conn.execute(sql, params![old, new])?;
        }
        for (table, id_col) in [("ops", "op_id"), ("pl_ops", "op_id")] {
            let rows: Vec<(String, String)> = {
                let mut stmt = self.conn.prepare(&format!(
                    "SELECT {id_col}, payload FROM {table} WHERE payload LIKE '%' || ?1 || '%'"
                ))?;
                let collected = stmt
                    .query_map([old], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                collected
            };
            for (op_id, payload) in rows {
                let mut v: serde_json::Value = serde_json::from_str(&payload)?;
                if replace_id(&mut v, old, new) {
                    self.conn.execute(
                        &format!("UPDATE {table} SET payload = ?2 WHERE {id_col} = ?1"),
                        params![op_id, serde_json::to_string(&v)?],
                    )?;
                }
            }
        }
        let _ = self.write_manifest(new);
        Ok(())
    }

    /// Меняет id трека везде (в том числе папку в корзине).
    fn remap_track(&mut self, old: &str, new: &str) -> Result<()> {
        for sql in [
            "UPDATE tracks SET track_id = ?2 WHERE track_id = ?1",
            "UPDATE ops SET track_id = ?2 WHERE track_id = ?1",
            "UPDATE trash SET track_id = ?2 WHERE track_id = ?1",
        ] {
            self.conn.execute(sql, params![old, new])?;
        }
        let old_dir = self.trash_dir(old);
        let new_dir = self.trash_dir(new);
        if old_dir.is_dir() && !new_dir.exists() {
            let _ = fs::rename(&old_dir, &new_dir);
            self.write_trash_meta(new);
        }
        if let Some(t) = journal::get_track(&self.conn, new)? {
            let _ = self.write_manifest(&t.playlist_id);
        }
        Ok(())
    }

    // ---------- 3. журнал плейлистов ----------

    /// Дописывает в журнал плейлистов то, чего там ещё нет: у плейлистов, созданных до
    /// появления синхронизации, и у порядка списка. Безопасно вызывать сколько угодно раз.
    pub fn sync_prepare(&mut self, now_ms: u64) -> Result<()> {
        for p in self.all_playlists()? {
            let n: i64 = self.conn.query_row(
                "SELECT COUNT(*) FROM pl_ops WHERE playlist_id = ?1",
                [&p.id],
                |r| r.get(0),
            )?;
            if n == 0 {
                self.record_pl(now_ms, &p.id, json!({ "name": p.dir_name, "deleted": p.deleted }))?;
            }
        }
        let has_order: i64 =
            self.conn.query_row("SELECT COUNT(*) FROM pl_ops WHERE playlist_id = ''", [], |r| r.get(0))?;
        if has_order == 0 {
            let ids: Vec<String> = self.playlists()?.into_iter().map(|p| p.playlist_id).collect();
            if !ids.is_empty() {
                self.record_pl(now_ms, "", json!({ "order": ids }))?;
            }
        }
        Ok(())
    }

    // ---------- 4. обмен операциями ----------

    pub fn sync_vector(&self) -> Result<Vector> {
        let mut v = Vector::new();
        for table in ["ops", "pl_ops"] {
            let mut stmt =
                self.conn.prepare(&format!("SELECT device_id, MAX(hlc) FROM {table} GROUP BY device_id"))?;
            let rows = stmt
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            for (dev, hlc) in rows {
                let slot = v.entry(dev).or_default();
                if hlc > *slot {
                    *slot = hlc;
                }
            }
        }
        Ok(v)
    }

    /// Операции, которых по `remote` у собеседника ещё нет.
    pub fn sync_batch_for(&self, remote: &Vector) -> Result<SyncBatch> {
        let mut batch = SyncBatch::default();
        let devices: Vec<String> = self.sync_vector()?.into_keys().collect();
        for dev in devices {
            let since = remote.get(&dev).cloned().unwrap_or_default();

            let mut stmt = self.conn.prepare(
                "SELECT op_id, hlc, device_id, kind, track_id, payload
                 FROM ops WHERE device_id = ?1 AND hlc > ?2 ORDER BY hlc ASC",
            )?;
            let rows = stmt
                .query_map(params![dev, since], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                        r.get::<_, String>(5)?,
                    ))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            for (op_id, hlc, device_id, kind, track_id, payload) in rows {
                batch.ops.push(Op {
                    op_id,
                    hlc: Hlc::decode(&hlc).ok_or_else(|| Error::Invalid(format!("hlc {hlc}")))?,
                    device_id,
                    kind: parse_kind(&kind)?,
                    track_id,
                    payload: serde_json::from_str(&payload)?,
                });
            }
            drop(stmt);

            let mut stmt = self.conn.prepare(
                "SELECT op_id, hlc, device_id, playlist_id, payload
                 FROM pl_ops WHERE device_id = ?1 AND hlc > ?2 ORDER BY hlc ASC",
            )?;
            let rows = stmt
                .query_map(params![dev, since], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            for (op_id, hlc, device_id, playlist_id, payload) in rows {
                batch.pl_ops.push(PlOp {
                    op_id,
                    hlc: Hlc::decode(&hlc).ok_or_else(|| Error::Invalid(format!("hlc {hlc}")))?,
                    device_id,
                    playlist_id,
                    payload: serde_json::from_str(&payload)?,
                });
            }
        }
        batch.ops.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        batch.pl_ops.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        Ok(batch)
    }

    // ---------- 5. применение чужих операций ----------

    pub fn sync_apply(&mut self, batch: &SyncBatch, now_ms: u64) -> Result<MergeReport> {
        let mut report = MergeReport::default();

        // 5a. плейлисты
        let mut touched: Vec<String> = Vec::new();
        let mut order_touched = false;
        let mut pl_ops: Vec<&PlOp> = batch.pl_ops.iter().collect();
        pl_ops.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        for op in pl_ops {
            self.clock.observe(&op.hlc, now_ms);
            let inserted = self.conn.execute(
                "INSERT OR IGNORE INTO pl_ops(op_id, hlc, device_id, playlist_id, payload)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    op.op_id,
                    op.hlc.encode(),
                    op.device_id,
                    op.playlist_id,
                    serde_json::to_string(&op.payload)?
                ],
            )?;
            if inserted == 0 {
                continue;
            }
            report.new_ops += 1;
            if op.playlist_id.is_empty() {
                order_touched = true;
            } else if !touched.contains(&op.playlist_id) {
                touched.push(op.playlist_id.clone());
            }
        }
        for pid in &touched {
            self.apply_playlist_state(pid, now_ms)?;
        }
        if order_touched {
            self.apply_order_state()?;
        }

        // 5b. треки: запоминаем, где лежали файлы до применения операций
        let mut affected: Vec<String> = Vec::new();
        for op in &batch.ops {
            if !affected.contains(&op.track_id) {
                affected.push(op.track_id.clone());
            }
        }
        let mut before: HashMap<String, TrackState> = HashMap::new();
        for id in &affected {
            if let Some(t) = journal::get_track(&self.conn, id)? {
                before.insert(id.clone(), t);
            }
        }
        let mut ops: Vec<&Op> = batch.ops.iter().collect();
        ops.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        let mut changed: Vec<String> = Vec::new();
        for op in ops {
            if journal::apply_remote(&self.conn, &mut self.clock, op, now_ms)? == journal::Applied::New {
                report.new_ops += 1;
                if !changed.contains(&op.track_id) {
                    changed.push(op.track_id.clone());
                }
            }
        }

        // 5c. файлы на диске приводим в соответствие с новым состоянием
        let mut manifests: Vec<String> = Vec::new();
        for id in &changed {
            let Some(now) = journal::get_track(&self.conn, id)? else { continue };
            let prior = before.get(id);
            if let Some(p) = prior {
                if !manifests.contains(&p.playlist_id) {
                    manifests.push(p.playlist_id.clone());
                }
            }
            if !manifests.contains(&now.playlist_id) {
                manifests.push(now.playlist_id.clone());
            }

            if now.deleted {
                if self.trash_remote_deleted(&now, prior)? {
                    report.trashed += 1;
                }
                self.set_pending(id, false)?;
                continue;
            }

            self.ensure_playlist_row(&now.playlist_id, now_ms)?;
            let dir = self.playlist_dir(&now.playlist_id)?;
            fs::create_dir_all(&dir)?;
            let expected = dir.join(&now.file_name);
            let sha_changed = prior.map_or(true, |p| p.sha256 != now.sha256);

            if expected.is_file() {
                // файл на месте; хэш сверяем, только если он мог измениться
                let ok = if sha_changed && !now.sha256.is_empty() {
                    sha256_file(&expected)? == now.sha256
                } else {
                    true
                };
                self.set_pending(id, !ok)?;
                continue;
            }

            // файла на новом месте нет: ищем, где он лежит (прежнее место или корзина)
            let mut sources: Vec<PathBuf> = Vec::new();
            if let Some(p) = prior {
                if let Ok(pdir) = self.playlist_dir(&p.playlist_id) {
                    sources.push(pdir.join(&p.file_name));
                }
            }
            sources.push(self.trash_dir(id).join(&now.file_name));
            if let Some(p) = prior {
                sources.push(self.trash_dir(id).join(&p.file_name));
            }
            let found = sources.into_iter().find(|s| s.is_file());
            match found {
                Some(src) => {
                    fs::rename(&src, &expected)?;
                    let _ = fs::remove_dir_all(self.trash_dir(id));
                    report.moved += 1;
                    self.set_pending(id, sha_changed && prior.is_some_and(|p| p.sha256 != now.sha256))?;
                }
                None => self.set_pending(id, true)?,
            }
        }
        for pid in manifests {
            let _ = self.write_manifest(&pid);
        }
        self.write_playlist_order()?;
        report.pending_files = self.pending_ids()?.len();
        Ok(report)
    }

    fn set_pending(&self, track_id: &str, pending: bool) -> Result<()> {
        self.conn
            .execute("UPDATE tracks SET pending = ?2 WHERE track_id = ?1", params![track_id, pending as i32])?;
        Ok(())
    }

    /// Чужое удаление: файл уходит в нашу корзину (как при удалении здесь).
    fn trash_remote_deleted(&self, now: &TrackState, prior: Option<&TrackState>) -> Result<bool> {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Some(p) = prior {
            if let Ok(d) = self.playlist_dir(&p.playlist_id) {
                candidates.push(d.join(&p.file_name));
            }
        }
        if let Ok(d) = self.playlist_dir(&now.playlist_id) {
            candidates.push(d.join(&now.file_name));
        }
        let Some(src) = candidates.into_iter().find(|c| c.is_file()) else { return Ok(false) };
        let tdir = self.trash_dir(&now.track_id);
        fs::create_dir_all(&tdir)?;
        let target = tdir.join(&now.file_name);
        if !target.exists() {
            fs::rename(&src, &target)?;
        }
        self.write_trash_meta(&now.track_id);
        Ok(true)
    }

    /// Если трек ссылается на плейлист, о котором мы ещё ничего не знаем, заводим заглушку.
    fn ensure_playlist_row(&mut self, playlist_id: &str, now_ms: u64) -> Result<()> {
        if playlist_id.is_empty() || self.playlist_row_exists(playlist_id)? {
            return Ok(());
        }
        let short: String = playlist_id.chars().take(8).collect();
        let name = self.free_dir_name(&format!("Sync {short}"), "")?;
        fs::create_dir_all(self.root.join(&name))?;
        self.insert_playlist_with_id(playlist_id, &name, false, now_ms)
    }

    /// Свободное имя папки среди плейлистов и содержимого корня (`except_id` не учитывается).
    fn free_dir_name(&self, wanted: &str, except_id: &str) -> Result<String> {
        let mut existing: Vec<String> = self
            .all_playlists()?
            .into_iter()
            .filter(|p| !p.deleted && p.id != except_id)
            .map(|p| p.dir_name)
            .collect();
        if let Ok(rd) = fs::read_dir(&self.root) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_string();
                let own = self
                    .all_playlists()?
                    .into_iter()
                    .any(|p| p.id == except_id && naming::fold_key(&p.dir_name) == naming::fold_key(&n));
                if !own {
                    existing.push(n);
                }
            }
        }
        Ok(naming::unique_name(wanted, &existing))
    }

    fn insert_playlist_with_id(&mut self, id: &str, dir_name: &str, deleted: bool, now_ms: u64) -> Result<()> {
        let hlc = self.clock.tick(now_ms).encode();
        let max: i64 = self.conn.query_row("SELECT COALESCE(MAX(sort_order), 0) FROM playlists", [], |r| r.get(0))?;
        self.conn.execute(
            "INSERT INTO playlists(playlist_id, dir_name, deleted, hlc, sort_order) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, dir_name, deleted as i32, hlc, max + 1],
        )?;
        Ok(())
    }

    /// Приводит плейлист (папку и запись) к состоянию из журнала плейлистов.
    fn apply_playlist_state(&mut self, playlist_id: &str, now_ms: u64) -> Result<()> {
        let mut stmt =
            self.conn.prepare("SELECT payload FROM pl_ops WHERE playlist_id = ?1 ORDER BY hlc ASC")?;
        let payloads = stmt
            .query_map([playlist_id], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        let mut name: Option<String> = None;
        let mut deleted: Option<bool> = None;
        for p in payloads {
            let v: serde_json::Value = serde_json::from_str(&p)?;
            if let Some(n) = v.get("name").and_then(|x| x.as_str()) {
                name = Some(n.to_string());
            }
            if let Some(d) = v.get("deleted").and_then(|x| x.as_bool()) {
                deleted = Some(d);
            }
        }

        let row = self.all_playlists()?.into_iter().find(|p| p.id == playlist_id);
        match row {
            None => {
                let Some(n) = name else { return Ok(()) };
                let dir_name = self.free_dir_name(&n, "")?;
                let is_deleted = deleted.unwrap_or(false);
                if !is_deleted {
                    fs::create_dir_all(self.root.join(&dir_name))?;
                }
                self.insert_playlist_with_id(playlist_id, &dir_name, is_deleted, now_ms)?;
                if !is_deleted {
                    self.write_manifest(playlist_id)?;
                }
            }
            Some(row) => {
                if deleted == Some(true) && !row.deleted {
                    let live: i64 = self.conn.query_row(
                        "SELECT COUNT(*) FROM tracks WHERE playlist_id = ?1 AND deleted = 0",
                        [playlist_id],
                        |r| r.get(0),
                    )?;
                    if live == 0 {
                        let dir = self.root.join(&row.dir_name);
                        let only_hidden = fs::read_dir(&dir)
                            .map(|rd| rd.flatten().all(|e| e.file_name().to_string_lossy().starts_with('.')))
                            .unwrap_or(true);
                        if only_hidden {
                            let _ = fs::remove_dir_all(&dir);
                            self.conn.execute(
                                "UPDATE playlists SET deleted = 1 WHERE playlist_id = ?1",
                                [playlist_id],
                            )?;
                        }
                    }
                    // в плейлисте есть наши треки: удаление не применяем, плейлист остаётся
                } else if deleted == Some(false) && row.deleted {
                    let dir_name = self.free_dir_name(&name.clone().unwrap_or(row.dir_name.clone()), playlist_id)?;
                    fs::create_dir_all(self.root.join(&dir_name))?;
                    self.conn.execute(
                        "UPDATE playlists SET deleted = 0, dir_name = ?2 WHERE playlist_id = ?1",
                        params![playlist_id, dir_name],
                    )?;
                    self.write_manifest(playlist_id)?;
                } else if !row.deleted {
                    if let Some(n) = name {
                        let target = self.free_dir_name(&n, playlist_id)?;
                        if naming::fold_key(&target) != naming::fold_key(&row.dir_name) {
                            self.rename_playlist_dir(playlist_id, &n)?;
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// Порядок списка плейлистов: берётся самая поздняя операция порядка.
    fn apply_order_state(&mut self) -> Result<()> {
        let payload: Option<String> = self
            .conn
            .query_row(
                "SELECT payload FROM pl_ops WHERE playlist_id = '' ORDER BY hlc DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        let Some(payload) = payload else { return Ok(()) };
        let v: serde_json::Value = serde_json::from_str(&payload)?;
        let listed: Vec<String> = v["order"]
            .as_array()
            .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
            .unwrap_or_default();
        let current: Vec<String> = self.playlists()?.into_iter().map(|p| p.playlist_id).collect();
        let mut final_order: Vec<String> = listed.into_iter().filter(|id| current.contains(id)).collect();
        for id in current {
            if !final_order.contains(&id) {
                final_order.push(id);
            }
        }
        for (i, id) in final_order.iter().enumerate() {
            self.conn.execute(
                "UPDATE playlists SET sort_order = ?2 WHERE playlist_id = ?1",
                params![id, i as i64 + 1],
            )?;
        }
        Ok(())
    }

    // ---------- 6. файлы ----------

    /// Файлы, которых не хватает.
    pub fn sync_needs(&self) -> Result<Vec<FileNeed>> {
        let mut stmt = self.conn.prepare(
            "SELECT t.track_id, t.sha256, t.file_name, p.dir_name
             FROM tracks t JOIN playlists p ON p.playlist_id = t.playlist_id
             WHERE t.deleted = 0 AND t.pending = 1 ORDER BY t.track_id",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(FileNeed {
                    track_id: r.get(0)?,
                    sha256: r.get(1)?,
                    file_name: r.get(2)?,
                    playlist: r.get(3)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Файл трека для отправки другому устройству: путь и хэш. `None`, если файла у нас нет
    /// (или он сам ещё не получен).
    pub fn sync_file_for(&self, track_id: &str) -> Result<Option<(PathBuf, String)>> {
        let Some(t) = journal::get_track(&self.conn, track_id)? else { return Ok(None) };
        if t.deleted || self.pending_ids()?.contains(track_id) {
            return Ok(None);
        }
        let path = self.playlist_dir(&t.playlist_id)?.join(&t.file_name);
        if !path.is_file() {
            return Ok(None);
        }
        let sha = sha256_file(&path)?;
        Ok(Some((path, sha)))
    }

    /// Куда складывать скачиваемый файл до проверки (скрытая папка внутри библиотеки,
    /// чтобы переименование в плейлист было мгновенным).
    pub fn sync_tmp_path(&self, track_id: &str) -> Result<PathBuf> {
        let dir = self.tmp_dir();
        fs::create_dir_all(&dir)?;
        Ok(dir.join(format!("{track_id}.part")))
    }

    /// Принимает скачанный файл: проверяет хэш и одним действием переносит в плейлист.
    /// Возвращает `false`, если файл не подошёл (его нужно запросить заново позже).
    pub fn sync_store_file(&mut self, track_id: &str, tmp: &Path, sha256: &str) -> Result<bool> {
        let Some(t) = journal::get_track(&self.conn, track_id)? else {
            let _ = fs::remove_file(tmp);
            return Ok(false);
        };
        let actual = sha256_file(tmp)?;
        // хэш должен совпасть и с заявленным отправителем, и с тем, что записано в журнале
        if actual != sha256 || (!t.sha256.is_empty() && actual != t.sha256) || t.deleted {
            let _ = fs::remove_file(tmp);
            return Ok(false);
        }
        let dir = self.playlist_dir(&t.playlist_id)?;
        fs::create_dir_all(&dir)?;
        let dest = dir.join(&t.file_name);
        if dest.exists() {
            fs::remove_file(&dest)?;
        }
        fs::rename(tmp, &dest)?;
        self.set_pending(track_id, false)?;
        self.write_manifest(&t.playlist_id)?;
        Ok(true)
    }
}

fn parse_kind(s: &str) -> Result<Kind> {
    Ok(match s {
        "add" => Kind::Add,
        "move" => Kind::Move,
        "delete" => Kind::Delete,
        "edit" => Kind::Edit,
        "reorder" => Kind::Reorder,
        other => return Err(Error::Invalid(format!("kind {other}"))),
    })
}

/// Заменяет строку `old` на `new` везде внутри JSON (id плейлиста лежит и в полях, и в списках).
fn replace_id(v: &mut serde_json::Value, old: &str, new: &str) -> bool {
    match v {
        serde_json::Value::String(s) if s == old => {
            *s = new.to_string();
            true
        }
        serde_json::Value::Array(a) => a.iter_mut().fold(false, |acc, x| replace_id(x, old, new) || acc),
        serde_json::Value::Object(o) => o.values_mut().fold(false, |acc, x| replace_id(x, old, new) || acc),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    const T0: u64 = 5_000_000;

    fn device(tmp: &TempDir, name: &str) -> Library {
        let base = tmp.path().join(name);
        fs::create_dir_all(&base).unwrap();
        Library::open(&base.join("Hydra"), &base.join("hydra.db"), name, T0).unwrap()
    }

    fn put(lib: &Library, playlist: &str, file: &str, content: &str) {
        let dir = lib.root().join(playlist);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(file), content).unwrap();
    }

    fn names(lib: &Library, playlist: &str) -> Vec<String> {
        let id = lib
            .playlists()
            .unwrap()
            .into_iter()
            .find(|p| p.name.to_lowercase() == playlist.to_lowercase())
            .unwrap_or_else(|| panic!("нет плейлиста {playlist}"))
            .playlist_id;
        lib.tracks(&id).unwrap().into_iter().map(|t| t.file_name).collect()
    }

    fn playlist_names(lib: &Library) -> Vec<String> {
        lib.playlists().unwrap().into_iter().map(|p| p.name).collect()
    }

    /// Полный сеанс между двумя библиотеками без сети: то же самое делает `net`.
    fn sync_pair(a: &mut Library, b: &mut Library, now: u64) -> (MergeReport, MergeReport) {
        let ia = a.sync_inventory().unwrap();
        let ib = b.sync_inventory().unwrap();
        a.sync_adopt(&ib).unwrap();
        b.sync_adopt(&ia).unwrap();
        a.sync_prepare(now).unwrap();
        b.sync_prepare(now).unwrap();
        let va = a.sync_vector().unwrap();
        let vb = b.sync_vector().unwrap();
        let from_a = a.sync_batch_for(&vb).unwrap();
        let from_b = b.sync_batch_for(&va).unwrap();
        let ra = a.sync_apply(&from_b, now).unwrap();
        let rb = b.sync_apply(&from_a, now).unwrap();
        transfer_files(a, b);
        transfer_files(b, a);
        (ra, rb)
    }

    /// `to` докачивает недостающие файлы у `from`.
    fn transfer_files(to: &mut Library, from: &Library) {
        for need in to.sync_needs().unwrap() {
            if let Some((path, sha)) = from.sync_file_for(&need.track_id).unwrap() {
                let tmp = to.sync_tmp_path(&need.track_id).unwrap();
                fs::copy(path, &tmp).unwrap();
                assert!(to.sync_store_file(&need.track_id, &tmp, &sha).unwrap());
            }
        }
    }

    #[test]
    fn two_devices_with_same_music_do_not_duplicate_and_exchange_the_rest() {
        let tmp = tempfile::tempdir().unwrap();
        let mut a = device(&tmp, "phone");
        let mut b = device(&tmp, "pc");
        // общий трек лежит и там и там, у каждого есть свой
        put(&a, "Rock", "common.mp3", "common-bytes");
        put(&a, "Rock", "only-a.mp3", "a-bytes");
        put(&a, "Jazz", "j.mp3", "jazz-bytes");
        put(&b, "rock", "common.mp3", "common-bytes"); // имя папки в другом регистре
        put(&b, "Rock", "only-b.mp3", "b-bytes");
        a.scan(T0 + 1).unwrap();
        b.scan(T0 + 2).unwrap();

        sync_pair(&mut a, &mut b, T0 + 10);

        for lib in [&a, &b] {
            assert_eq!(lib.playlists().unwrap().len(), 2, "без дублей плейлистов");
            let mut rock = names(lib, "Rock");
            rock.sort();
            assert_eq!(rock, ["common.mp3", "only-a.mp3", "only-b.mp3"]);
            assert_eq!(names(lib, "Jazz"), ["j.mp3"]);
            assert!(lib.sync_needs().unwrap().is_empty());
        }
        assert!(b.root().join("Jazz").join("j.mp3").is_file());
        assert!(a.root().join("Rock").join("only-b.mp3").is_file());

        // повторный сеанс ничего не меняет
        let (ra, rb) = sync_pair(&mut a, &mut b, T0 + 20);
        assert_eq!(ra.new_ops, 0);
        assert_eq!(rb.new_ops, 0);
    }

    #[test]
    fn scan_does_not_delete_tracks_whose_files_are_still_on_the_way() {
        let tmp = tempfile::tempdir().unwrap();
        let mut a = device(&tmp, "phone");
        let mut b = device(&tmp, "pc");
        put(&a, "Rock", "x.mp3", "xxx");
        a.scan(T0 + 1).unwrap();
        // b получает только журнал, файлы ещё не пришли
        let ia = a.sync_inventory().unwrap();
        b.sync_adopt(&ia).unwrap();
        b.sync_prepare(T0 + 5).unwrap();
        a.sync_prepare(T0 + 5).unwrap();
        let batch = a.sync_batch_for(&b.sync_vector().unwrap()).unwrap();
        let report = b.sync_apply(&batch, T0 + 6).unwrap();
        assert_eq!(report.pending_files, 1);

        let scan = b.scan(T0 + 7).unwrap();
        assert_eq!(scan.removed, 0, "ожидающий файл нельзя считать пропавшим");
        assert_eq!(names(&b, "Rock"), ["x.mp3"]);
        assert!(b.tracks(&b.playlists().unwrap()[0].playlist_id).unwrap()[0].pending);

        transfer_files(&mut b, &a);
        assert!(b.sync_needs().unwrap().is_empty());
        assert!(b.root().join("Rock").join("x.mp3").is_file());
        assert_eq!(b.scan(T0 + 8).unwrap().removed, 0);
    }

    #[test]
    fn delete_rename_and_move_travel_between_devices() {
        let tmp = tempfile::tempdir().unwrap();
        let mut a = device(&tmp, "phone");
        let mut b = device(&tmp, "pc");
        put(&a, "Rock", "a.mp3", "aaa");
        put(&a, "Rock", "b.mp3", "bbb");
        put(&a, "Jazz", "j.mp3", "jjj");
        a.scan(T0 + 1).unwrap();
        sync_pair(&mut a, &mut b, T0 + 10);
        assert_eq!(names(&b, "Rock").len(), 2);

        // на телефоне: удалить трек, перенести трек, переименовать плейлист
        let rock = a.playlists().unwrap().into_iter().find(|p| p.name == "Rock").unwrap().playlist_id;
        let jazz = a.playlists().unwrap().into_iter().find(|p| p.name == "Jazz").unwrap().playlist_id;
        let tracks = a.tracks(&rock).unwrap();
        let del = tracks.iter().find(|t| t.file_name == "a.mp3").unwrap().track_id.clone();
        let mv = tracks.iter().find(|t| t.file_name == "b.mp3").unwrap().track_id.clone();
        a.delete_track(&del, T0 + 20).unwrap();
        a.move_track(&mv, &jazz, T0 + 21).unwrap();
        a.rename_playlist(&jazz, "Jazz Classics").unwrap();

        sync_pair(&mut a, &mut b, T0 + 30);

        assert_eq!(playlist_names(&b).len(), 2);
        let mut jc = names(&b, "Jazz Classics");
        jc.sort();
        assert_eq!(jc, ["b.mp3", "j.mp3"]);
        assert!(names(&b, "Rock").is_empty());
        assert!(!b.root().join("Rock").join("a.mp3").exists());
        // удалённое на другом устройстве лежит в корзине здесь
        assert_eq!(b.trash_items().unwrap().len(), 1);
        assert!(b.root().join("Jazz Classics").join("b.mp3").is_file());
        assert!(!b.root().join("Jazz").exists());
    }

    #[test]
    fn playlist_created_deleted_and_reordered_remotely() {
        let tmp = tempfile::tempdir().unwrap();
        let mut a = device(&tmp, "phone");
        let mut b = device(&tmp, "pc");
        a.create_playlist("One", T0 + 1).unwrap();
        a.create_playlist("Two", T0 + 2).unwrap();
        a.create_playlist("Three", T0 + 3).unwrap();
        sync_pair(&mut a, &mut b, T0 + 10);
        assert_eq!(playlist_names(&b), ["One", "Two", "Three"]);
        assert!(b.root().join("Two").is_dir());

        let three = a.playlists().unwrap().into_iter().find(|p| p.name == "Three").unwrap().playlist_id;
        let two = a.playlists().unwrap().into_iter().find(|p| p.name == "Two").unwrap().playlist_id;
        a.reorder_playlist(&three, 0).unwrap();
        a.delete_playlist(&two).unwrap();
        sync_pair(&mut a, &mut b, T0 + 20);

        assert_eq!(playlist_names(&b), ["Three", "One"]);
        assert!(!b.root().join("Two").exists());
        assert_eq!(playlist_names(&a), playlist_names(&b));
    }

    #[test]
    fn edited_file_is_fetched_again() {
        let tmp = tempfile::tempdir().unwrap();
        let mut a = device(&tmp, "phone");
        let mut b = device(&tmp, "pc");
        put(&a, "Rock", "a.mp3", "old-bytes");
        a.scan(T0 + 1).unwrap();
        sync_pair(&mut a, &mut b, T0 + 10);

        // «правка тегов» на телефоне меняет содержимое файла и хэш
        let rock = a.playlists().unwrap()[0].playlist_id.clone();
        let id = a.tracks(&rock).unwrap()[0].track_id.clone();
        let path = a.root().join("Rock").join("a.mp3");
        fs::write(&path, "new-bytes").unwrap();
        let sha = sha256_file(&path).unwrap();
        a.record(T0 + 20, Kind::Edit, &id, json!({ "title": "New", "sha256": sha })).unwrap();

        sync_pair(&mut a, &mut b, T0 + 30);
        let got = fs::read_to_string(b.root().join("Rock").join("a.mp3")).unwrap();
        assert_eq!(got, "new-bytes");
        assert!(b.sync_needs().unwrap().is_empty());
    }

    #[test]
    fn corrupted_download_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let mut a = device(&tmp, "phone");
        let mut b = device(&tmp, "pc");
        put(&a, "Rock", "a.mp3", "good-bytes");
        a.scan(T0 + 1).unwrap();
        a.sync_prepare(T0 + 2).unwrap();
        b.sync_prepare(T0 + 2).unwrap();
        let batch = a.sync_batch_for(&b.sync_vector().unwrap()).unwrap();
        b.sync_apply(&batch, T0 + 3).unwrap();

        let need = b.sync_needs().unwrap().remove(0);
        let tmp_file = b.sync_tmp_path(&need.track_id).unwrap();
        fs::write(&tmp_file, "garbage").unwrap();
        let (_, real_sha) = a.sync_file_for(&need.track_id).unwrap().unwrap();
        assert!(!b.sync_store_file(&need.track_id, &tmp_file, &real_sha).unwrap());
        assert_eq!(b.sync_needs().unwrap().len(), 1, "файл всё ещё нужен");
        assert!(!b.root().join("Rock").join("a.mp3").exists());
    }
}
