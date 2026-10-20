//! Схема SQLite и открытие базы.

use crate::Result;
use rusqlite::Connection;
use std::path::Path;

pub const SCHEMA_VERSION: i32 = 4;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Семья устройств: подписанный список (подпись добавится на этапе сети).
CREATE TABLE IF NOT EXISTS devices (
    device_id  TEXT PRIMARY KEY,      -- публичный ключ устройства
    name       TEXT NOT NULL,
    status     TEXT NOT NULL CHECK (status IN ('active','revoked')),
    added_hlc  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlists (
    playlist_id TEXT PRIMARY KEY,     -- UUID
    dir_name    TEXT NOT NULL,        -- имя папки на диске
    deleted     INTEGER NOT NULL DEFAULT 0,
    hlc         TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tracks (
    track_id    TEXT PRIMARY KEY,     -- UUID, присваивается при первом добавлении
    playlist_id TEXT NOT NULL,
    file_name   TEXT NOT NULL,
    sha256      TEXT NOT NULL,        -- только проверка целостности, не идентификатор
    title       TEXT,
    artist      TEXT,
    order_key   TEXT NOT NULL DEFAULT '', -- позиция в плейлисте (дробный ключ), синхронизируется
    deleted     INTEGER NOT NULL DEFAULT 0,
    hlc         TEXT NOT NULL         -- метка последнего изменения (победитель конфликта)
);
CREATE INDEX IF NOT EXISTS idx_tracks_playlist ON tracks(playlist_id);

-- Журнал плейлистов (создание, имя, удаление, порядок списка). Состояние плейлиста =
-- последние значения по меткам HLC. playlist_id = '' означает порядок всего списка.
CREATE TABLE IF NOT EXISTS pl_ops (
    op_id       TEXT PRIMARY KEY,
    hlc         TEXT NOT NULL,
    device_id   TEXT NOT NULL,
    playlist_id TEXT NOT NULL,
    payload     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pl_ops_hlc ON pl_ops(hlc);
CREATE INDEX IF NOT EXISTS idx_pl_ops_playlist ON pl_ops(playlist_id);

-- Журнал операций: add / move / delete / edit. Это «история».
CREATE TABLE IF NOT EXISTS ops (
    op_id     TEXT PRIMARY KEY,       -- UUID
    hlc       TEXT NOT NULL,
    device_id TEXT NOT NULL,
    kind      TEXT NOT NULL CHECK (kind IN ('add','move','delete','edit','reorder')),
    track_id  TEXT NOT NULL,
    payload   TEXT NOT NULL           -- JSON
);
CREATE INDEX IF NOT EXISTS idx_ops_hlc ON ops(hlc);

-- Корзина: удалённое хранится 30 дней.
CREATE TABLE IF NOT EXISTS trash (
    track_id   TEXT PRIMARY KEY,
    file_name  TEXT NOT NULL,
    playlist_id TEXT NOT NULL,
    deleted_ms INTEGER NOT NULL,
    reason     TEXT NOT NULL          -- 'user' | 'sync' | 'conflict'
);
"#;

pub fn open(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)?;
    init(&conn)?;
    Ok(conn)
}

pub fn open_in_memory() -> Result<Connection> {
    let conn = Connection::open_in_memory()?;
    init(&conn)?;
    Ok(conn)
}

fn init(conn: &Connection) -> Result<()> {
    conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
    conn.execute_batch(SCHEMA)?;
    migrate(conn)?;
    conn.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?1)",
        [SCHEMA_VERSION.to_string()],
    )?;
    Ok(())
}

/// Обновление старых баз. Версия 2: порядок плейлистов (`playlists.sort_order`).
fn migrate(conn: &Connection) -> Result<()> {
    let has_sort: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('playlists') WHERE name = 'sort_order'",
        [],
        |r| r.get(0),
    )?;
    if has_sort == 0 {
        conn.execute_batch("ALTER TABLE playlists ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;")?;
    }
    // Версия 3: файл трека ещё не получен от другого устройства (`pending`).
    let has_pending: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('tracks') WHERE name = 'pending'",
        [],
        |r| r.get(0),
    )?;
    if has_pending == 0 {
        conn.execute_batch("ALTER TABLE tracks ADD COLUMN pending INTEGER NOT NULL DEFAULT 0;")?;
    }
    // Версия 4: правило порядка треков плейлиста: manual | artist | title.
    let has_sort_mode: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('playlists') WHERE name = 'sort_mode'",
        [],
        |r| r.get(0),
    )?;
    if has_sort_mode == 0 {
        conn.execute_batch("ALTER TABLE playlists ADD COLUMN sort_mode TEXT NOT NULL DEFAULT 'manual';")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_creates_and_is_idempotent() {
        let conn = open_in_memory().unwrap();
        init(&conn).unwrap(); // повторная инициализация не ломает базу
        let v: String = conn
            .query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION.to_string());
    }
}
