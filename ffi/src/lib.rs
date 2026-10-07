//! Тонкий мост между Flutter (dart:ffi) и ядром.
//!
//! Весь интерфейс - две C-функции:
//!   * `hydra_call(json) -> json`: запрос `{"method": "...", "args": {...}}`,
//!     ответ `{"ok": true, "result": ...}` или `{"ok": false, "error": "..."}`;
//!   * `hydra_free(ptr)`: освобождает строку, возвращённую `hydra_call`.
//!
//! Состояние (открытая библиотека) хранится в процессе, поэтому вызовы можно
//! делать из любого потока или изолята Dart; доступ сериализуется мьютексом.
//! Паника внутри ядра превращается в ответ с ошибкой и не роняет приложение.

use hydra_core::library::Library;
use serde::Serialize;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

struct State {
    lib: Library,
    cache_dir: PathBuf,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn es<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn to_json<T: Serialize>(r: hydra_core::Result<T>) -> Result<Value, String> {
    let v = r.map_err(es)?;
    serde_json::to_value(v).map_err(es)
}

/// Быстрый некриптографический хэш (FNV-1a) для имени файла в кэше обложек.
fn fnv1a(data: &[u8]) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    for b in data {
        h ^= *b as u32;
        h = h.wrapping_mul(0x0100_0193);
    }
    h
}

fn arg_str(args: &Value, key: &str) -> Result<String, String> {
    args[key]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| format!("missing argument: {key}"))
}

fn arg_usize(args: &Value, key: &str) -> Result<usize, String> {
    args[key]
        .as_u64()
        .map(|n| n as usize)
        .ok_or_else(|| format!("missing argument: {key}"))
}

/// Постоянный идентификатор устройства. Пока это случайный UUID в файле;
/// на этапе сети заменяется парой ключей Ed25519 из защищённого хранилища.
fn load_or_create_device_id(data_dir: &std::path::Path) -> Result<String, String> {
    let path = data_dir.join("device_id");
    if let Ok(s) = fs::read_to_string(&path) {
        let s = s.trim().to_string();
        if !s.is_empty() {
            return Ok(s);
        }
    }
    let id = uuid::Uuid::new_v4().to_string();
    fs::write(&path, &id).map_err(es)?;
    Ok(id)
}

fn open(args: &Value) -> Result<Value, String> {
    let root = PathBuf::from(arg_str(args, "root")?);
    let data_dir = PathBuf::from(arg_str(args, "data_dir")?);
    let cache_dir = PathBuf::from(arg_str(args, "cache_dir")?);
    fs::create_dir_all(&data_dir).map_err(es)?;
    fs::create_dir_all(&cache_dir).map_err(es)?;
    let device_id = load_or_create_device_id(&data_dir)?;
    let lib =
        Library::open(&root, &data_dir.join("hydra.db"), &device_id, now_ms()).map_err(es)?;
    let mut guard = STATE.lock().unwrap_or_else(|p| p.into_inner());
    *guard = Some(State { lib, cache_dir });
    Ok(json!({ "device_id": device_id, "root": root.to_string_lossy() }))
}

fn with_state<T>(f: impl FnOnce(&mut State) -> Result<T, String>) -> Result<T, String> {
    let mut guard = STATE.lock().unwrap_or_else(|p| p.into_inner());
    let st = guard.as_mut().ok_or("library is not open: call `open` first")?;
    f(st)
}

fn call(st: &mut State, method: &str, args: &Value) -> Result<Value, String> {
    match method {
        "scan" => to_json(st.lib.scan(now_ms())),
        "playlists" => to_json(st.lib.playlists()),
        "tracks" => to_json(st.lib.tracks(&arg_str(args, "playlist_id")?)),
        "trash_items" => to_json(st.lib.trash_items()),
        "create_playlist" => to_json(st.lib.create_playlist(&arg_str(args, "name")?, now_ms())),
        "move_track" => to_json(st.lib.move_track(
            &arg_str(args, "track_id")?,
            &arg_str(args, "to_playlist_id")?,
            now_ms(),
        )),
        "delete_track" => to_json(st.lib.delete_track(&arg_str(args, "track_id")?, now_ms())),
        "restore_track" => to_json(st.lib.restore_track(&arg_str(args, "track_id")?, now_ms())),
        "reorder" => to_json(st.lib.reorder(
            &arg_str(args, "track_id")?,
            arg_usize(args, "index")?,
            now_ms(),
        )),
        "purge_track" => to_json(st.lib.purge_track(&arg_str(args, "track_id")?)),
        "purge_trash" => to_json(st.lib.purge_expired_trash(now_ms())),
        "empty_trash" => to_json(st.lib.empty_trash()),
        "rename_playlist" => to_json(
            st.lib.rename_playlist(&arg_str(args, "playlist_id")?, &arg_str(args, "name")?),
        ),
        "delete_playlist" => to_json(st.lib.delete_playlist(&arg_str(args, "playlist_id")?)),
        "reorder_playlist" => to_json(st.lib.reorder_playlist(
            &arg_str(args, "playlist_id")?,
            arg_usize(args, "index")?,
        )),
        "rename_track" => {
            let written = st
                .lib
                .rename_track(&arg_str(args, "track_id")?, &arg_str(args, "title")?, now_ms())
                .map_err(es)?;
            Ok(json!({ "tag_written": written }))
        }
        "set_cover" => {
            let id = arg_str(args, "track_id")?;
            st.lib
                .set_cover(&id, std::path::Path::new(&arg_str(args, "image_path")?), now_ms())
                .map_err(es)?;
            Ok(Value::Null)
        }
        "cover" => {
            let id = arg_str(args, "track_id")?;
            match st.lib.cover(&id).map_err(es)? {
                None => Ok(Value::Null),
                Some((mime, bytes)) => {
                    let ext = if mime.contains("png") { "png" } else { "jpg" };
                    let dir = st.cache_dir.join("covers");
                    fs::create_dir_all(&dir).map_err(es)?;
                    // В имени есть отпечаток содержимого: после замены обложки путь другой,
                    // и Flutter не показывает старую картинку из своего кэша.
                    let name = format!("{id}-{:08x}.{ext}", fnv1a(&bytes));
                    let path = dir.join(&name);
                    if !path.exists() {
                        fs::write(&path, &bytes).map_err(es)?;
                    }
                    // прежние версии обложки этого трека больше не нужны
                    if let Ok(rd) = fs::read_dir(&dir) {
                        for e in rd.flatten() {
                            let n = e.file_name().to_string_lossy().to_string();
                            if n.starts_with(&format!("{id}-")) && n != name {
                                let _ = fs::remove_file(e.path());
                            }
                        }
                    }
                    Ok(json!({ "path": path.to_string_lossy() }))
                }
            }
        }
        other => Err(format!("unknown method: {other}")),
    }
}

fn dispatch(request: &str) -> Result<Value, String> {
    let req: Value = serde_json::from_str(request).map_err(|e| format!("bad request: {e}"))?;
    let method = req["method"].as_str().ok_or("missing method")?.to_string();
    let args = &req["args"];
    match method.as_str() {
        "version" => Ok(json!({
            "core": hydra_core::VERSION,
            "ffi": env!("CARGO_PKG_VERSION"),
        })),
        "open" => open(args),
        _ => with_state(|st| call(st, &method, args)),
    }
}

/// Обрабатывает один запрос. Вынесено из C-обёртки, чтобы тестироваться без FFI.
pub fn handle(request: &str) -> String {
    let result = match std::panic::catch_unwind(|| dispatch(request)) {
        Ok(r) => r,
        Err(_) => Err("internal error (panic in core)".to_string()),
    };
    match result {
        Ok(v) => json!({ "ok": true, "result": v }).to_string(),
        Err(e) => json!({ "ok": false, "error": e }).to_string(),
    }
}

/// # Safety
/// `request` должен быть нулевым указателем или указывать на C-строку с завершающим нулём.
#[no_mangle]
pub unsafe extern "C" fn hydra_call(request: *const c_char) -> *mut c_char {
    let req = if request.is_null() {
        String::new()
    } else {
        CStr::from_ptr(request).to_string_lossy().into_owned()
    };
    let response = handle(&req);
    CString::new(response)
        .unwrap_or_else(|_| CString::new(r#"{"ok":false,"error":"invalid response"}"#).unwrap())
        .into_raw()
}

/// # Safety
/// `ptr` должен быть значением, ранее возвращённым `hydra_call`, и не освобождаться дважды.
#[no_mangle]
pub unsafe extern "C" fn hydra_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn call_json(method: &str, args: Value) -> Value {
        let out = handle(&json!({ "method": method, "args": args }).to_string());
        serde_json::from_str(&out).unwrap()
    }

    fn ok(method: &str, args: Value) -> Value {
        let v = call_json(method, args);
        assert_eq!(v["ok"], true, "{method} failed: {v}");
        v["result"].clone()
    }

    #[test]
    fn version_and_bad_requests() {
        assert_eq!(ok("version", json!({}))["ffi"], env!("CARGO_PKG_VERSION"));
        let bad = serde_json::from_str::<Value>(&handle("not json")).unwrap();
        assert_eq!(bad["ok"], false);
        let unknown = call_json("no_such_method", json!({}));
        assert_eq!(unknown["ok"], false);
    }

    #[test]
    fn c_abi_roundtrip() {
        let req = CString::new(r#"{"method":"version","args":{}}"#).unwrap();
        unsafe {
            let ptr = hydra_call(req.as_ptr());
            let text = CStr::from_ptr(ptr).to_str().unwrap().to_string();
            hydra_free(ptr);
            assert!(text.contains("\"ok\":true"), "{text}");
            // нулевой указатель не должен падать
            let ptr = hydra_call(std::ptr::null());
            hydra_free(ptr);
        }
    }

    /// Единственный тест, который трогает глобальное состояние (порядок шагов важен).
    #[test]
    fn full_flow_through_json() {
        // до open всё, кроме version, отклоняется
        let early = call_json("playlists", json!({}));
        assert_eq!(early["ok"], false);

        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("Hydra");
        let opened = ok(
            "open",
            json!({
                "root": root.to_string_lossy(),
                "data_dir": tmp.path().join("data").to_string_lossy(),
                "cache_dir": tmp.path().join("cache").to_string_lossy(),
            }),
        );
        let device_id = opened["device_id"].as_str().unwrap().to_string();
        assert!(!device_id.is_empty());

        fs::create_dir_all(root.join("Rock")).unwrap();
        fs::write(root.join("Rock").join("a.mp3"), "aaa").unwrap();
        fs::write(root.join("Rock").join("b.flac"), "bbb").unwrap();

        let report = ok("scan", json!({}));
        assert_eq!(report["added"], 2);
        assert_eq!(report["playlists_created"], 1);

        let pls = ok("playlists", json!({}));
        let rock = pls[0]["playlist_id"].as_str().unwrap().to_string();
        assert_eq!(pls[0]["name"], "Rock");
        assert_eq!(pls[0]["track_count"], 2);

        let jazz = ok("create_playlist", json!({ "name": "Jazz" }));
        let jazz_id = jazz["playlist_id"].as_str().unwrap().to_string();

        let tracks = ok("tracks", json!({ "playlist_id": rock }));
        assert_eq!(tracks[0]["title"], "a");
        let a = tracks[0]["track_id"].as_str().unwrap().to_string();
        let b = tracks[1]["track_id"].as_str().unwrap().to_string();

        ok("reorder", json!({ "track_id": b, "index": 0 }));
        let tracks = ok("tracks", json!({ "playlist_id": rock }));
        assert_eq!(tracks[0]["file_name"], "b.flac");

        ok("move_track", json!({ "track_id": a, "to_playlist_id": jazz_id }));
        assert!(root.join("Jazz").join("a.mp3").exists());

        ok("delete_track", json!({ "track_id": b }));
        let trash = ok("trash_items", json!({}));
        assert_eq!(trash.as_array().unwrap().len(), 1);
        ok("restore_track", json!({ "track_id": b }));
        assert!(root.join("Rock").join("b.flac").exists());

        // у файла без обложки cover = null
        assert_eq!(ok("cover", json!({ "track_id": b })), Value::Null);

        // окончательное удаление из корзины
        ok("delete_track", json!({ "track_id": a }));
        ok("purge_track", json!({ "track_id": a }));
        assert!(ok("trash_items", json!({})).as_array().unwrap().is_empty());

        // ошибки ядра доходят текстом, а не падением
        let err = call_json("move_track", json!({ "track_id": "nope", "to_playlist_id": rock }));
        assert_eq!(err["ok"], false);
        assert!(err["error"].as_str().unwrap().contains("not found"));
        let missing = call_json("tracks", json!({}));
        assert_eq!(missing["ok"], false);

        // идентификатор устройства сохраняется между открытиями
        let reopened = ok(
            "open",
            json!({
                "root": root.to_string_lossy(),
                "data_dir": tmp.path().join("data").to_string_lossy(),
                "cache_dir": tmp.path().join("cache").to_string_lossy(),
            }),
        );
        assert_eq!(reopened["device_id"], device_id);
        assert_eq!(ok("playlists", json!({})).as_array().unwrap().len(), 2);

        // переименование и порядок плейлистов
        let renamed = ok("rename_playlist", json!({ "playlist_id": jazz_id, "name": "Blues" }));
        assert_eq!(renamed["name"], "Blues");
        assert!(root.join("Blues").is_dir() && !root.join("Jazz").exists());
        ok("reorder_playlist", json!({ "playlist_id": jazz_id, "index": 0 }));
        assert_eq!(ok("playlists", json!({}))[0]["name"], "Blues");

        // название трека: в файле-пустышке теги не пишутся, название хранится в приложении
        let renamed = ok("rename_track", json!({ "track_id": b, "title": "Новое" }));
        assert_eq!(renamed["tag_written"], false);
        assert_eq!(ok("tracks", json!({ "playlist_id": rock }))[0]["title"], "Новое");
        let bad = call_json("set_cover", json!({ "track_id": b, "image_path": "/no/such.png" }));
        assert_eq!(bad["ok"], false);

        // удаление плейлиста: с треками нельзя, пустой можно
        let refuse = call_json("delete_playlist", json!({ "playlist_id": rock }));
        assert_eq!(refuse["ok"], false);
        ok("delete_playlist", json!({ "playlist_id": jazz_id }));
        assert_eq!(ok("playlists", json!({})).as_array().unwrap().len(), 1);

        // очистка корзины
        ok("delete_track", json!({ "track_id": b }));
        assert_eq!(ok("empty_trash", json!({})), 1);
        assert!(ok("trash_items", json!({})).as_array().unwrap().is_empty());
    }
}
