//! Журнал операций и разрешение конфликтов.
//!
//! Состояние трека всегда получается «проигрыванием» всех его операций в порядке
//! гибридных часов. Поэтому:
//!  * повторная доставка операции безопасна (идемпотентность по op_id);
//!  * операции могут приходить в любом порядке (move раньше add и т.п.);
//!  * при конфликте побеждает операция с более поздней меткой (правило «по дате»);
//!  * удаление не уничтожает данные: трек попадает в корзину на 30 дней, а более
//!    поздняя правка/перемещение возвращает его из корзины.

use crate::clock::{Clock, Hlc};
use crate::order;
use crate::{Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub const TRASH_RETENTION_DAYS: u64 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Add,
    Move,
    Delete,
    Edit,
    /// Изменение позиции трека внутри плейлиста (payload: {"order_key": ...}).
    Reorder,
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Kind::Add => "add",
            Kind::Move => "move",
            Kind::Delete => "delete",
            Kind::Edit => "edit",
            Kind::Reorder => "reorder",
        }
    }
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "add" => Kind::Add,
            "move" => Kind::Move,
            "delete" => Kind::Delete,
            "edit" => Kind::Edit,
            "reorder" => Kind::Reorder,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Op {
    pub op_id: String,
    pub hlc: Hlc,
    pub device_id: String,
    pub kind: Kind,
    pub track_id: String,
    pub payload: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    /// Новая операция записана и состояние пересчитано.
    New,
    /// Такая операция уже была — ничего не изменилось.
    Duplicate,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TrackState {
    pub track_id: String,
    pub playlist_id: String,
    pub file_name: String,
    pub sha256: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub deleted: bool,
    /// Позиция в плейлисте (дробный ключ, см. `order`). Пустая строка = ключ не задан.
    pub order_key: String,
}

/// Создаёт локальную операцию (действие пользователя) и применяет её.
pub fn record_local(
    conn: &Connection,
    clock: &mut Clock,
    now_ms: u64,
    device_id: &str,
    kind: Kind,
    track_id: &str,
    payload: Value,
) -> Result<Op> {
    let op = Op {
        op_id: Uuid::new_v4().to_string(),
        hlc: clock.tick(now_ms),
        device_id: device_id.to_string(),
        kind,
        track_id: track_id.to_string(),
        payload,
    };
    apply(conn, &op, now_ms)?;
    Ok(op)
}

/// Принимает операцию от другого устройства.
pub fn apply_remote(conn: &Connection, clock: &mut Clock, op: &Op, now_ms: u64) -> Result<Applied> {
    clock.observe(&op.hlc, now_ms);
    apply(conn, op, now_ms)
}

/// Записывает операцию (если её ещё нет) и пересчитывает состояние трека.
pub fn apply(conn: &Connection, op: &Op, now_ms: u64) -> Result<Applied> {
    let reason = if op.device_id.is_empty() {
        "sync"
    } else {
        "user"
    };
    let inserted = conn.execute(
        "INSERT OR IGNORE INTO ops(op_id, hlc, device_id, kind, track_id, payload)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            op.op_id,
            op.hlc.encode(),
            op.device_id,
            op.kind.as_str(),
            op.track_id,
            serde_json::to_string(&op.payload)?
        ],
    )?;
    if inserted == 0 {
        return Ok(Applied::Duplicate);
    }
    rebuild_track(conn, &op.track_id, now_ms, reason)?;
    Ok(Applied::New)
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).map(|s| s.to_string())
}

/// Проигрывает все операции трека по порядку меток и обновляет таблицы tracks/trash.
fn rebuild_track(conn: &Connection, track_id: &str, now_ms: u64, reason: &str) -> Result<()> {
    let mut stmt =
        conn.prepare("SELECT hlc, kind, payload FROM ops WHERE track_id = ?1 ORDER BY hlc ASC")?;
    let rows = stmt.query_map([track_id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;

    let mut state: Option<TrackState> = None;
    let mut last_hlc = String::new();
    for row in rows {
        let (hlc, kind, payload) = row?;
        let kind = Kind::parse(&kind).ok_or_else(|| Error::Invalid(format!("kind {kind}")))?;
        let payload: Value = serde_json::from_str(&payload)?;
        match kind {
            Kind::Add => {
                if state.is_none() {
                    state = Some(TrackState {
                        track_id: track_id.to_string(),
                        playlist_id: str_field(&payload, "playlist_id").unwrap_or_default(),
                        file_name: str_field(&payload, "file_name").unwrap_or_default(),
                        sha256: str_field(&payload, "sha256").unwrap_or_default(),
                        title: str_field(&payload, "title"),
                        artist: str_field(&payload, "artist"),
                        deleted: false,
                        order_key: str_field(&payload, "order_key").unwrap_or_default(),
                    });
                }
            }
            Kind::Move => {
                if let Some(s) = state.as_mut() {
                    if let Some(to) = str_field(&payload, "to_playlist_id") {
                        s.playlist_id = to;
                        s.deleted = false; // более поздняя правка возвращает из корзины
                                           // файл мог быть переименован при перемещении (конфликт имён в целевой папке)
                        if let Some(f) = str_field(&payload, "file_name") {
                            s.file_name = f;
                        }
                        // позиция в новом плейлисте; если не указана, ключ остаётся прежним
                        if let Some(k) = str_field(&payload, "order_key") {
                            s.order_key = k;
                        }
                    }
                }
            }
            Kind::Reorder => {
                // Перестановка не возвращает трек из корзины: пользователь двигает
                // только видимые треки, а удаление на другом устройстве уважается.
                if let Some(s) = state.as_mut() {
                    if let Some(k) = str_field(&payload, "order_key") {
                        s.order_key = k;
                    }
                }
            }
            Kind::Edit => {
                if let Some(s) = state.as_mut() {
                    if let Some(v) = str_field(&payload, "title") {
                        s.title = Some(v);
                    }
                    if let Some(v) = str_field(&payload, "artist") {
                        // пустая строка = исполнитель убран
                        s.artist = if v.trim().is_empty() { None } else { Some(v) };
                    }
                    if let Some(v) = str_field(&payload, "sha256") {
                        s.sha256 = v;
                    }
                    s.deleted = false;
                }
            }
            Kind::Delete => {
                if let Some(s) = state.as_mut() {
                    s.deleted = true;
                }
            }
        }
        last_hlc = hlc;
    }
    drop(stmt);

    // Если add ещё не пришёл (операции приехали не по порядку) — состояния пока нет.
    let Some(s) = state else { return Ok(()) };

    conn.execute(
        "INSERT INTO tracks(track_id, playlist_id, file_name, sha256, title, artist, deleted, hlc, order_key)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(track_id) DO UPDATE SET
            playlist_id=excluded.playlist_id, file_name=excluded.file_name,
            sha256=excluded.sha256, title=excluded.title, artist=excluded.artist,
            deleted=excluded.deleted, hlc=excluded.hlc, order_key=excluded.order_key",
        params![
            s.track_id, s.playlist_id, s.file_name, s.sha256, s.title, s.artist,
            s.deleted as i32, last_hlc, s.order_key
        ],
    )?;

    if s.deleted {
        conn.execute(
            "INSERT OR IGNORE INTO trash(track_id, file_name, playlist_id, deleted_ms, reason)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                s.track_id,
                s.file_name,
                s.playlist_id,
                now_ms as i64,
                reason
            ],
        )?;
    } else {
        conn.execute("DELETE FROM trash WHERE track_id = ?1", [&s.track_id])?;
    }
    Ok(())
}

const TRACK_COLUMNS: &str =
    "track_id, playlist_id, file_name, sha256, title, artist, deleted, order_key";

fn row_to_track(r: &rusqlite::Row<'_>) -> rusqlite::Result<TrackState> {
    Ok(TrackState {
        track_id: r.get(0)?,
        playlist_id: r.get(1)?,
        file_name: r.get(2)?,
        sha256: r.get(3)?,
        title: r.get(4)?,
        artist: r.get(5)?,
        deleted: r.get::<_, i32>(6)? != 0,
        order_key: r.get(7)?,
    })
}

pub fn get_track(conn: &Connection, track_id: &str) -> Result<Option<TrackState>> {
    Ok(conn
        .query_row(
            &format!("SELECT {TRACK_COLUMNS} FROM tracks WHERE track_id = ?1"),
            [track_id],
            row_to_track,
        )
        .optional()?)
}

/// Все неудалённые треки (для сравнения с содержимым папки на диске).
pub fn live_tracks(conn: &Connection) -> Result<Vec<TrackState>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {TRACK_COLUMNS} FROM tracks WHERE deleted = 0 ORDER BY track_id ASC"
    ))?;
    let rows = stmt
        .query_map([], row_to_track)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Видимые треки плейлиста в порядке воспроизведения.
/// При одинаковых ключах (одновременные добавления на разных устройствах)
/// порядок определяется по track_id, поэтому он одинаков на всех устройствах.
pub fn playlist_tracks(conn: &Connection, playlist_id: &str) -> Result<Vec<TrackState>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {TRACK_COLUMNS} FROM tracks
         WHERE playlist_id = ?1 AND deleted = 0
         ORDER BY order_key ASC, track_id ASC"
    ))?;
    let rows = stmt
        .query_map([playlist_id], row_to_track)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Ключ для трека, который добавляется в конец плейлиста.
pub fn append_key(conn: &Connection, playlist_id: &str) -> Result<String> {
    let tracks = playlist_tracks(conn, playlist_id)?;
    let last = tracks
        .last()
        .map(|t| t.order_key.as_str())
        .filter(|k| order::is_valid_key(k));
    order::key_between(last, None)
}

/// Ставит трек на позицию `new_index` (счёт с нуля) внутри его плейлиста.
/// Обычно это одна операция `reorder`. Если ключи соседей совпали (одновременные
/// добавления на разных устройствах) или не заданы, плейлист перебалансируется:
/// операции получают только те треки, чей ключ изменился.
pub fn reorder_within(
    conn: &Connection,
    clock: &mut Clock,
    now_ms: u64,
    device_id: &str,
    track_id: &str,
    new_index: usize,
) -> Result<Vec<Op>> {
    let track = get_track(conn, track_id)?
        .filter(|t| !t.deleted)
        .ok_or_else(|| Error::Invalid(format!("track {track_id} not found")))?;
    let others: Vec<TrackState> = playlist_tracks(conn, &track.playlist_id)?
        .into_iter()
        .filter(|t| t.track_id != track_id)
        .collect();
    let idx = new_index.min(others.len());

    let before = if idx > 0 {
        Some(others[idx - 1].order_key.as_str())
    } else {
        None
    };
    let after = others.get(idx).map(|t| t.order_key.as_str());

    let usable = |k: Option<&str>| k.map_or(true, order::is_valid_key);
    let cheap = if usable(before) && usable(after) {
        order::key_between(before, after).ok()
    } else {
        None
    };

    if let Some(key) = cheap {
        if key == track.order_key {
            return Ok(vec![]);
        }
        let op = record_local(
            conn,
            clock,
            now_ms,
            device_id,
            Kind::Reorder,
            track_id,
            json!({ "order_key": key }),
        )?;
        return Ok(vec![op]);
    }

    // Перебалансировка: итоговый порядок и свежие равномерные ключи.
    let mut desired: Vec<(String, String)> = others
        .iter()
        .map(|t| (t.track_id.clone(), t.order_key.clone()))
        .collect();
    desired.insert(idx, (track_id.to_string(), track.order_key.clone()));
    let keys = order::spread_keys(desired.len())?;
    let mut ops = Vec::new();
    for ((id, old_key), new_key) in desired.into_iter().zip(keys) {
        if old_key != new_key {
            ops.push(record_local(
                conn,
                clock,
                now_ms,
                device_id,
                Kind::Reorder,
                &id,
                json!({ "order_key": new_key }),
            )?);
        }
    }
    Ok(ops)
}

/// Содержимое скрытого `.<Плейлист>.json`: порядок воспроизведения по UUID треков.
/// Файл производный: источник правды - журнал, а JSON перегенерируется после синхронизации.
pub fn manifest_json(conn: &Connection, playlist_id: &str) -> Result<String> {
    let order: Vec<String> = playlist_tracks(conn, playlist_id)?
        .into_iter()
        .map(|t| t.track_id)
        .collect();
    Ok(serde_json::to_string_pretty(&json!({
        "version": 1,
        "playlist_id": playlist_id,
        "order": order,
    }))?)
}

/// Операции, которых у собеседника ещё нет (по метке). Для обмена между устройствами.
pub fn ops_since(conn: &Connection, since: Option<&Hlc>) -> Result<Vec<Op>> {
    let since_enc = since.map(|h| h.encode()).unwrap_or_default();
    let mut stmt = conn.prepare(
        "SELECT op_id, hlc, device_id, kind, track_id, payload
         FROM ops WHERE hlc > ?1 ORDER BY hlc ASC",
    )?;
    let rows = stmt.query_map([since_enc], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
            r.get::<_, String>(5)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (op_id, hlc, device_id, kind, track_id, payload) = row?;
        out.push(Op {
            op_id,
            hlc: Hlc::decode(&hlc).ok_or_else(|| Error::Invalid(format!("hlc {hlc}")))?,
            device_id,
            kind: Kind::parse(&kind).ok_or_else(|| Error::Invalid(format!("kind {kind}")))?,
            track_id,
            payload: serde_json::from_str(&payload)?,
        });
    }
    Ok(out)
}

/// Треки, пролежавшие в корзине дольше срока хранения. Файлы удаляет вызывающий код,
/// после чего вызывает `forget_trashed`.
pub fn expired_trash(conn: &Connection, now_ms: u64) -> Result<Vec<String>> {
    let limit = now_ms.saturating_sub(TRASH_RETENTION_DAYS * 24 * 3600 * 1000) as i64;
    let mut stmt = conn.prepare("SELECT track_id FROM trash WHERE deleted_ms <= ?1")?;
    let ids = stmt
        .query_map([limit], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(ids)
}

pub fn forget_trashed(conn: &Connection, track_id: &str) -> Result<()> {
    conn.execute("DELETE FROM trash WHERE track_id = ?1", [track_id])?;
    Ok(())
}

pub fn add_payload(
    playlist_id: &str,
    file_name: &str,
    sha256: &str,
    title: Option<&str>,
    artist: Option<&str>,
    order_key: &str,
) -> Value {
    json!({
        "playlist_id": playlist_id,
        "file_name": file_name,
        "sha256": sha256,
        "title": title,
        "artist": artist,
        "order_key": order_key,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::open_in_memory;

    fn add(conn: &Connection, clock: &mut Clock, dev: &str, now: u64, track: &str, pl: &str) -> Op {
        // в простых тестах ключом порядка служит сам id трека
        record_local(
            conn,
            clock,
            now,
            dev,
            Kind::Add,
            track,
            add_payload(pl, "song.flac", "abc", Some("Song"), None, track),
        )
        .unwrap()
    }

    /// Добавляет трек в конец плейлиста, как это делает приложение.
    fn add_appended(
        conn: &Connection,
        clock: &mut Clock,
        dev: &str,
        now: u64,
        track: &str,
        pl: &str,
    ) -> Op {
        let key = append_key(conn, pl).unwrap();
        record_local(
            conn,
            clock,
            now,
            dev,
            Kind::Add,
            track,
            add_payload(pl, "song.flac", "abc", Some(track), None, &key),
        )
        .unwrap()
    }

    fn ids(conn: &Connection, pl: &str) -> Vec<String> {
        playlist_tracks(conn, pl)
            .unwrap()
            .into_iter()
            .map(|t| t.track_id)
            .collect()
    }

    #[test]
    fn add_then_move_then_delete() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        add(&conn, &mut c, "A", 1000, "t1", "rock");
        record_local(
            &conn,
            &mut c,
            2000,
            "A",
            Kind::Move,
            "t1",
            json!({"to_playlist_id": "jazz"}),
        )
        .unwrap();
        assert_eq!(get_track(&conn, "t1").unwrap().unwrap().playlist_id, "jazz");

        record_local(&conn, &mut c, 3000, "A", Kind::Delete, "t1", json!({})).unwrap();
        assert!(get_track(&conn, "t1").unwrap().unwrap().deleted);
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM trash", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "удалённый трек должен попасть в корзину");
    }

    #[test]
    fn duplicate_delivery_is_idempotent() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        let op = add(&conn, &mut c, "A", 1000, "t1", "rock");
        assert_eq!(apply(&conn, &op, 1000).unwrap(), Applied::Duplicate);
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM ops", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }

    #[test]
    fn out_of_order_delivery_converges() {
        // Устройство A: add -> move. Устройство B получает сначала move, потом add.
        let a = open_in_memory().unwrap();
        let mut ca = Clock::new("A");
        let add_op = add(&a, &mut ca, "A", 1000, "t1", "rock");
        let move_op = record_local(
            &a,
            &mut ca,
            2000,
            "A",
            Kind::Move,
            "t1",
            json!({"to_playlist_id": "jazz"}),
        )
        .unwrap();

        let b = open_in_memory().unwrap();
        let mut cb = Clock::new("B");
        apply_remote(&b, &mut cb, &move_op, 5000).unwrap();
        assert!(
            get_track(&b, "t1").unwrap().is_none(),
            "без add состояния ещё нет"
        );
        apply_remote(&b, &mut cb, &add_op, 5000).unwrap();
        assert_eq!(get_track(&a, "t1").unwrap(), get_track(&b, "t1").unwrap());
        assert_eq!(get_track(&b, "t1").unwrap().unwrap().playlist_id, "jazz");
    }

    #[test]
    fn concurrent_moves_latest_hlc_wins_on_both_devices() {
        let a = open_in_memory().unwrap();
        let b = open_in_memory().unwrap();
        let mut ca = Clock::new("A");
        let mut cb = Clock::new("B");

        let add_op = add(&a, &mut ca, "A", 1000, "t1", "rock");
        apply_remote(&b, &mut cb, &add_op, 1100).unwrap();

        // Оба устройства независимо перемещают трек
        let move_a = record_local(
            &a,
            &mut ca,
            2000,
            "A",
            Kind::Move,
            "t1",
            json!({"to_playlist_id": "jazz"}),
        )
        .unwrap();
        let move_b = record_local(
            &b,
            &mut cb,
            2500,
            "B",
            Kind::Move,
            "t1",
            json!({"to_playlist_id": "pop"}),
        )
        .unwrap();

        // Обмен операциями
        apply_remote(&a, &mut ca, &move_b, 3000).unwrap();
        apply_remote(&b, &mut cb, &move_a, 3000).unwrap();

        let ta = get_track(&a, "t1").unwrap().unwrap();
        let tb = get_track(&b, "t1").unwrap().unwrap();
        assert_eq!(ta, tb, "устройства должны сойтись к одному состоянию");
        assert_eq!(ta.playlist_id, "pop", "побеждает более поздняя операция");
    }

    #[test]
    fn clock_skew_does_not_break_ordering() {
        // Часы B отстают на час, но после получения операций от A его правка идёт ПОСЛЕ.
        let a = open_in_memory().unwrap();
        let b = open_in_memory().unwrap();
        let mut ca = Clock::new("A");
        let mut cb = Clock::new("B");
        let add_op = add(&a, &mut ca, "A", 10_000_000, "t1", "rock");
        apply_remote(&b, &mut cb, &add_op, 6_400_000).unwrap(); // у B «сейчас» на час раньше
        let edit_b = record_local(
            &b,
            &mut cb,
            6_400_001,
            "B",
            Kind::Edit,
            "t1",
            json!({"title": "New"}),
        )
        .unwrap();
        assert!(edit_b.hlc > add_op.hlc);
        apply_remote(&a, &mut ca, &edit_b, 10_000_100).unwrap();
        assert_eq!(
            get_track(&a, "t1").unwrap().unwrap().title.as_deref(),
            Some("New")
        );
    }

    #[test]
    fn later_edit_restores_deleted_track_from_trash() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        add(&conn, &mut c, "A", 1000, "t1", "rock");
        record_local(&conn, &mut c, 2000, "A", Kind::Delete, "t1", json!({})).unwrap();
        record_local(
            &conn,
            &mut c,
            3000,
            "A",
            Kind::Edit,
            "t1",
            json!({"title": "Back"}),
        )
        .unwrap();
        let t = get_track(&conn, "t1").unwrap().unwrap();
        assert!(!t.deleted);
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM trash", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn delete_after_edit_wins() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        add(&conn, &mut c, "A", 1000, "t1", "rock");
        record_local(
            &conn,
            &mut c,
            2000,
            "A",
            Kind::Edit,
            "t1",
            json!({"title": "X"}),
        )
        .unwrap();
        record_local(&conn, &mut c, 3000, "A", Kind::Delete, "t1", json!({})).unwrap();
        assert!(get_track(&conn, "t1").unwrap().unwrap().deleted);
    }

    #[test]
    fn ops_since_returns_only_newer() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        let first = add(&conn, &mut c, "A", 1000, "t1", "rock");
        add(&conn, &mut c, "A", 2000, "t2", "rock");
        let all = ops_since(&conn, None).unwrap();
        assert_eq!(all.len(), 2);
        let newer = ops_since(&conn, Some(&first.hlc)).unwrap();
        assert_eq!(newer.len(), 1);
        assert_eq!(newer[0].track_id, "t2");
    }

    #[test]
    fn trash_expires_after_30_days() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        add(&conn, &mut c, "A", 1000, "t1", "rock");
        record_local(&conn, &mut c, 2000, "A", Kind::Delete, "t1", json!({})).unwrap();
        let day = 24 * 3600 * 1000u64;
        assert!(expired_trash(&conn, 2000 + 29 * day).unwrap().is_empty());
        assert_eq!(
            expired_trash(&conn, 2000 + 31 * day).unwrap(),
            vec!["t1".to_string()]
        );
        forget_trashed(&conn, "t1").unwrap();
        assert!(expired_trash(&conn, 2000 + 31 * day).unwrap().is_empty());
    }

    #[test]
    fn move_can_rename_the_file() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        add(&conn, &mut c, "A", 1000, "t1", "rock");
        record_local(
            &conn,
            &mut c,
            2000,
            "A",
            Kind::Move,
            "t1",
            json!({"to_playlist_id": "jazz", "file_name": "song (2).flac"}),
        )
        .unwrap();
        let t = get_track(&conn, "t1").unwrap().unwrap();
        assert_eq!(t.playlist_id, "jazz");
        assert_eq!(t.file_name, "song (2).flac");
        assert_eq!(live_tracks(&conn).unwrap().len(), 1);
    }

    #[test]
    fn tracks_are_appended_in_order() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        for (i, t) in ["a", "b", "c"].iter().enumerate() {
            add_appended(&conn, &mut c, "A", 1000 + i as u64, t, "rock");
        }
        assert_eq!(ids(&conn, "rock"), ["a", "b", "c"]);
    }

    #[test]
    fn reorder_within_playlist() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        for (i, t) in ["a", "b", "c"].iter().enumerate() {
            add_appended(&conn, &mut c, "A", 1000 + i as u64, t, "rock");
        }
        let ops = reorder_within(&conn, &mut c, 2000, "A", "c", 0).unwrap();
        assert_eq!(ops.len(), 1, "обычная перестановка - одна операция");
        assert_eq!(ids(&conn, "rock"), ["c", "a", "b"]);

        reorder_within(&conn, &mut c, 2001, "A", "a", 2).unwrap();
        assert_eq!(ids(&conn, "rock"), ["c", "b", "a"]);

        // индекс за пределами = в конец; то же место = без операций
        reorder_within(&conn, &mut c, 2002, "A", "c", 99).unwrap();
        assert_eq!(ids(&conn, "rock"), ["b", "a", "c"]);
        assert!(reorder_within(&conn, &mut c, 2003, "A", "c", 2)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn reorder_syncs_to_other_device() {
        let a = open_in_memory().unwrap();
        let b = open_in_memory().unwrap();
        let mut ca = Clock::new("A");
        let mut cb = Clock::new("B");
        let mut sent = Vec::new();
        for (i, t) in ["a", "b", "c"].iter().enumerate() {
            sent.push(add_appended(&a, &mut ca, "A", 1000 + i as u64, t, "rock"));
        }
        sent.extend(reorder_within(&a, &mut ca, 2000, "A", "c", 0).unwrap());
        // доставка в произвольном (обратном) порядке
        for op in sent.iter().rev() {
            apply_remote(&b, &mut cb, op, 3000).unwrap();
        }
        assert_eq!(ids(&b, "rock"), ["c", "a", "b"]);
        assert_eq!(ids(&a, "rock"), ids(&b, "rock"));
    }

    #[test]
    fn concurrent_reorders_converge() {
        let a = open_in_memory().unwrap();
        let b = open_in_memory().unwrap();
        let mut ca = Clock::new("A");
        let mut cb = Clock::new("B");
        for (i, t) in ["a", "b", "c"].iter().enumerate() {
            let op = add_appended(&a, &mut ca, "A", 1000 + i as u64, t, "rock");
            apply_remote(&b, &mut cb, &op, 1500).unwrap();
        }
        // каждое устройство независимо переставляет разные треки
        let ops_a = reorder_within(&a, &mut ca, 2000, "A", "c", 0).unwrap();
        let ops_b = reorder_within(&b, &mut cb, 2100, "B", "a", 99).unwrap();
        for op in &ops_b {
            apply_remote(&a, &mut ca, op, 3000).unwrap();
        }
        for op in &ops_a {
            apply_remote(&b, &mut cb, op, 3000).unwrap();
        }
        assert_eq!(
            ids(&a, "rock"),
            ids(&b, "rock"),
            "порядок должен совпасть на обоих устройствах"
        );
        assert_eq!(ids(&a, "rock").len(), 3);
    }

    #[test]
    fn concurrent_same_key_adds_are_ordered_by_track_id_and_rebalance_fixes_it() {
        let a = open_in_memory().unwrap();
        let b = open_in_memory().unwrap();
        let mut ca = Clock::new("A");
        let mut cb = Clock::new("B");
        // оба устройства одновременно добавляют в пустой плейлист -> одинаковый ключ
        let op_x = add_appended(&a, &mut ca, "A", 1000, "x", "rock");
        let op_y = add_appended(&b, &mut cb, "B", 1000, "y", "rock");
        assert_eq!(
            get_track(&a, "x").unwrap().unwrap().order_key,
            get_track(&b, "y").unwrap().unwrap().order_key
        );
        apply_remote(&a, &mut ca, &op_y, 2000).unwrap();
        apply_remote(&b, &mut cb, &op_x, 2000).unwrap();
        assert_eq!(ids(&a, "rock"), ["x", "y"]);
        assert_eq!(ids(&b, "rock"), ["x", "y"]);

        // вставка между треками с одинаковыми ключами требует перебалансировки
        let op_w = add_appended(&a, &mut ca, "A", 3000, "w", "rock");
        let ops = reorder_within(&a, &mut ca, 3001, "A", "w", 1).unwrap();
        assert!(ops.len() >= 2, "перебалансировка трогает несколько треков");
        assert_eq!(ids(&a, "rock"), ["x", "w", "y"]);

        apply_remote(&b, &mut cb, &op_w, 4000).unwrap();
        for op in &ops {
            apply_remote(&b, &mut cb, op, 4000).unwrap();
        }
        assert_eq!(ids(&b, "rock"), ["x", "w", "y"]);
    }

    #[test]
    fn reorder_does_not_restore_deleted_track() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        add_appended(&conn, &mut c, "A", 1000, "a", "rock");
        record_local(&conn, &mut c, 2000, "A", Kind::Delete, "a", json!({})).unwrap();
        record_local(
            &conn,
            &mut c,
            3000,
            "A",
            Kind::Reorder,
            "a",
            json!({"order_key": "z"}),
        )
        .unwrap();
        assert!(get_track(&conn, "a").unwrap().unwrap().deleted);
        assert!(ids(&conn, "rock").is_empty());
    }

    #[test]
    fn deleted_tracks_leave_the_order_and_move_goes_to_target_playlist() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        for (i, t) in ["a", "b", "c"].iter().enumerate() {
            add_appended(&conn, &mut c, "A", 1000 + i as u64, t, "rock");
        }
        record_local(&conn, &mut c, 2000, "A", Kind::Delete, "b", json!({})).unwrap();
        assert_eq!(ids(&conn, "rock"), ["a", "c"]);

        // перемещение «a» в конец плейлиста jazz с указанной позицией
        let key = append_key(&conn, "jazz").unwrap();
        record_local(
            &conn,
            &mut c,
            3000,
            "A",
            Kind::Move,
            "a",
            json!({"to_playlist_id": "jazz", "order_key": key}),
        )
        .unwrap();
        assert_eq!(ids(&conn, "rock"), ["c"]);
        assert_eq!(ids(&conn, "jazz"), ["a"]);
    }

    #[test]
    fn manifest_lists_track_ids_in_play_order() {
        let conn = open_in_memory().unwrap();
        let mut c = Clock::new("A");
        for (i, t) in ["a", "b"].iter().enumerate() {
            add_appended(&conn, &mut c, "A", 1000 + i as u64, t, "rock");
        }
        reorder_within(&conn, &mut c, 2000, "A", "b", 0).unwrap();
        let v: Value = serde_json::from_str(&manifest_json(&conn, "rock").unwrap()).unwrap();
        assert_eq!(v["order"], json!(["b", "a"]));
        assert_eq!(v["playlist_id"], "rock");
    }
}
