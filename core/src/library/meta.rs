//! Правки названия и исполнителя, которые не удаётся записать в сам файл (формат без тегов
//! или файл не принимает запись). Они живут в журнале, а журнал лежит в базе приложения и
//! стирается при переустановке. Поэтому такие правки дублируются в `.hydra/meta.json`
//! рядом с музыкой: ключ - хэш файла, значение - название и/или исполнитель. При добавлении
//! файла (сканирование после переустановки) запись по хэшу применяется вместо тегов.
//! Между устройствами правки и так ездят в журнале: `meta.json` нужен только для
//! восстановления.

use super::*;
use serde::Deserialize;
use std::collections::BTreeMap;

const META_FILE: &str = "meta.json";

/// Правка по файлу. `artist == Some("")`: исполнитель убран.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TagOverride {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct MetaFile {
    version: u32,
    tracks: BTreeMap<String, TagOverride>,
}

impl Library {
    fn meta_path(&self) -> PathBuf {
        self.root.join(INTERNAL_DIR).join(META_FILE)
    }

    /// Сохранённые правки (хэш файла -> правка). Нет файла или он испорчен: пусто.
    pub(super) fn load_overrides(&self) -> BTreeMap<String, TagOverride> {
        fs::read_to_string(self.meta_path())
            .ok()
            .and_then(|s| serde_json::from_str::<MetaFile>(&s).ok())
            .map(|m| m.tracks)
            .unwrap_or_default()
    }

    /// Правки, которые журнал знает прямо сейчас (по операциям `edit`).
    fn edited_in_journal(&self) -> Result<BTreeMap<String, TagOverride>> {
        let mut stmt = self
            .conn
            .prepare("SELECT track_id, payload FROM ops WHERE kind = 'edit' ORDER BY hlc ASC")?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        // какие поля трека правились хоть раз: (название, исполнитель)
        let mut flags: BTreeMap<String, (bool, bool)> = BTreeMap::new();
        for (id, payload) in rows {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) else {
                continue;
            };
            let e = flags.entry(id).or_default();
            if v.get("title").and_then(|x| x.as_str()).is_some() {
                e.0 = true;
            }
            if v.get("artist").and_then(|x| x.as_str()).is_some() {
                e.1 = true;
            }
        }
        let mut out = BTreeMap::new();
        for (id, (title_edited, artist_edited)) in flags {
            if !title_edited && !artist_edited {
                continue;
            }
            let Some(st) = journal::get_track(&self.conn, &id)? else {
                continue;
            };
            if st.sha256.is_empty() {
                continue;
            }
            out.insert(
                st.sha256.clone(),
                TagOverride {
                    title: if title_edited {
                        st.title.clone().filter(|s| !s.trim().is_empty())
                    } else {
                        None
                    },
                    artist: if artist_edited {
                        Some(st.artist.clone().unwrap_or_default())
                    } else {
                        None
                    },
                },
            );
        }
        Ok(out)
    }

    /// Обновляет `.hydra/meta.json`: старые записи остаются, новые из журнала добавляются.
    /// С `prune` убираются записи файлов, которые журнал знает только удалёнными насовсем
    /// (записи о файлах, которых база не знает, не трогаем: после переустановки они ещё
    /// могут пригодиться). Запись только если содержимое изменилось.
    pub(super) fn write_overrides(&self, prune: bool) -> Result<()> {
        let mut map = self.load_overrides();
        for (sha, fresh) in self.edited_in_journal()? {
            let e = map.entry(sha).or_default();
            if fresh.title.is_some() {
                e.title = fresh.title;
            }
            if fresh.artist.is_some() {
                e.artist = fresh.artist;
            }
        }
        if prune {
            let live = self.sha_set("SELECT sha256 FROM tracks WHERE deleted = 0")?;
            let dead = self.sha_set(
                "SELECT sha256 FROM tracks WHERE deleted = 1
                 AND track_id NOT IN (SELECT track_id FROM trash)",
            )?;
            map.retain(|sha, _| live.contains(sha) || !dead.contains(sha));
        }
        let path = self.meta_path();
        if map.is_empty() && !path.exists() {
            return Ok(());
        }
        let content = serde_json::to_string_pretty(&MetaFile {
            version: 1,
            tracks: map,
        })?;
        if fs::read_to_string(&path).ok().as_deref() == Some(content.as_str()) {
            return Ok(());
        }
        fs::create_dir_all(self.root.join(INTERNAL_DIR))?;
        fs::write(&path, content)?;
        Ok(())
    }

    fn sha_set(&self, sql: &str) -> Result<HashSet<String>> {
        let mut stmt = self.conn.prepare(sql)?;
        let set = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<HashSet<_>, _>>()?;
        Ok(set)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: u64 = 9_000_000;

    fn put(lib: &Library, playlist: &str, file: &str, content: &str) {
        let dir = lib.root().join(playlist);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(file), content).unwrap();
    }

    fn open(tmp: &tempfile::TempDir, db: &str, now: u64) -> Library {
        Library::open(
            &tmp.path().join("Hydra"),
            &tmp.path().join(db),
            "dev-a",
            now,
        )
        .unwrap()
    }

    fn find(lib: &Library, file: &str) -> TrackInfo {
        let pid = lib.playlists().unwrap()[0].playlist_id.clone();
        lib.tracks(&pid)
            .unwrap()
            .into_iter()
            .find(|t| t.file_name == file)
            .unwrap()
    }

    #[test]
    fn edits_that_cannot_go_into_the_file_survive_reinstall() {
        let tmp = tempfile::tempdir().unwrap();
        let mut lib = open(&tmp, "a.db", T0);
        // «aaa» не настоящий mp3: теги в такой файл не записать
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        let id = find(&lib, "a.mp3").track_id;
        let written = lib
            .edit_track(&id, "Новое имя", "Исполнитель", T0 + 2)
            .unwrap();
        assert!(!written);
        assert!(tmp.path().join("Hydra/.hydra/meta.json").is_file());
        drop(lib);

        // «переустановка»: база новая, папка та же
        let mut lib2 = open(&tmp, "fresh.db", T0 + 100);
        lib2.scan(T0 + 101).unwrap();
        let a = find(&lib2, "a.mp3");
        assert_eq!(a.title, "Новое имя");
        assert_eq!(a.artist.as_deref(), Some("Исполнитель"));
        assert_eq!(
            find(&lib2, "b.mp3").title,
            "b",
            "остальные треки без правок"
        );

        // повторное сканирование и ещё одна переустановка ничего не теряют
        lib2.scan(T0 + 102).unwrap();
        drop(lib2);
        let mut lib3 = open(&tmp, "fresh2.db", T0 + 200);
        lib3.scan(T0 + 201).unwrap();
        let a = find(&lib3, "a.mp3");
        assert_eq!(a.title, "Новое имя");
        assert_eq!(a.artist.as_deref(), Some("Исполнитель"));
    }

    #[test]
    fn removed_artist_stays_removed_after_reinstall() {
        let tmp = tempfile::tempdir().unwrap();
        let mut lib = open(&tmp, "a.db", T0);
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let id = find(&lib, "a.mp3").track_id;
        lib.edit_track(&id, "x", "Кто-то", T0 + 2).unwrap();
        lib.edit_track(&id, "x", "", T0 + 3).unwrap();
        drop(lib);
        let mut lib2 = open(&tmp, "fresh.db", T0 + 100);
        lib2.scan(T0 + 101).unwrap();
        assert_eq!(find(&lib2, "a.mp3").artist, None);
        assert_eq!(find(&lib2, "a.mp3").title, "x");
    }

    #[test]
    fn deleted_for_good_tracks_drop_out_of_the_file() {
        let tmp = tempfile::tempdir().unwrap();
        let mut lib = open(&tmp, "a.db", T0);
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let id = find(&lib, "a.mp3").track_id;
        lib.edit_track(&id, "Имя", "", T0 + 2).unwrap();
        lib.delete_track(&id, T0 + 3).unwrap();
        lib.purge_track(&id).unwrap();
        lib.scan(T0 + 4).unwrap();
        assert!(lib.load_overrides().is_empty());
    }
}
