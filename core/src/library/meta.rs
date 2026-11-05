//! Правки названия и исполнителя, которые не удаётся записать в сам файл (формат без тегов
//! или файл не принимает запись). Они живут в журнале, а журнал лежит в базе приложения и
//! стирается при переустановке. Поэтому такие правки дублируются в `.hydra/meta.json`
//! рядом с музыкой: ключ - хэш файла, значение - название и/или исполнитель. При добавлении
//! файла (сканирование после переустановки) запись по хэшу применяется вместо тегов.
//! Между устройствами правки и так ездят в журнале: `meta.json` нужен только для
//! восстановления.
//!
//! Так же устроена обложка для файлов, в которые её не встроить: картинка (jpeg) лежит в
//! `.hydra/covers/<хэш картинки>.jpg`, в журнал уходит правка `{"cover": "<хэш>"}`, а сама
//! картинка ездит между устройствами тем же каналом, что и файлы (как «файл» `cover:<хэш>`).

use super::*;
use crate::i18n::tr;
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
    /// Хэш картинки в `.hydra/covers`; пусто: обложка внутри файла.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
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

    pub(super) fn covers_dir(&self) -> PathBuf {
        self.root.join(INTERNAL_DIR).join("covers")
    }

    /// Файл картинки по её хэшу. Хэш обязан быть 64 шестнадцатеричными знаками: он попадает
    /// в путь, а приходит и с других устройств.
    pub(super) fn cover_file(&self, sha: &str) -> Option<PathBuf> {
        if sha.len() == 64 && sha.bytes().all(|b| b.is_ascii_hexdigit()) {
            Some(
                self.covers_dir()
                    .join(format!("{}.jpg", sha.to_ascii_lowercase())),
            )
        } else {
            None
        }
    }

    /// Кладёт картинку в `.hydra/covers` и возвращает её хэш.
    pub(super) fn store_cover(&self, jpeg: &[u8]) -> Result<String> {
        let sha: String = Sha256::digest(jpeg)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let path = self
            .cover_file(&sha)
            .ok_or_else(|| Error::Invalid(tr("хэш картинки").into()))?;
        fs::create_dir_all(self.covers_dir())?;
        if !path.is_file() {
            fs::write(&path, jpeg)?;
        }
        Ok(sha)
    }

    /// Хэш картинки-обложки трека из последней правки с полем `cover` (пусто: обложка в файле).
    pub(super) fn track_cover(&self, track_id: &str) -> Result<Option<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT payload FROM ops WHERE kind = 'edit' AND track_id = ?1 ORDER BY hlc DESC",
        )?;
        let rows = stmt
            .query_map([track_id], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        for payload in rows {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) else {
                continue;
            };
            if let Some(c) = v.get("cover").and_then(|x| x.as_str()) {
                return Ok(Some(c.to_string()).filter(|c| !c.is_empty()));
            }
        }
        Ok(None)
    }

    /// Удаляет из `.hydra/covers` картинки, которые больше не нужны: на них не ссылается ни
    /// живой трек, ни трек в корзине, ни запись `meta.json`. Так уходят прежние обложки после
    /// замены и обложки треков, удалённых насовсем. Трогаются только файлы вида `<хэш>.jpg`
    /// не моложе [min_age] (картинка, которая как раз приходит с другого устройства, цела).
    /// Если удалённый трек вернётся правкой с другого устройства, его обложка скачается заново.
    pub(super) fn purge_unused_covers(&self, min_age: std::time::Duration) -> Result<usize> {
        let Ok(rd) = fs::read_dir(self.covers_dir()) else {
            return Ok(0);
        };
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT o.track_id FROM ops o JOIN tracks t ON t.track_id = o.track_id
             WHERE o.kind = 'edit' AND o.payload LIKE '%\"cover\"%'
               AND (t.deleted = 0 OR t.track_id IN (SELECT track_id FROM trash))",
        )?;
        let ids = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        let mut used: HashSet<String> = HashSet::new();
        for id in ids {
            if let Some(c) = self.track_cover(&id)? {
                used.insert(c.to_ascii_lowercase());
            }
        }
        for o in self.load_overrides().values() {
            if let Some(c) = o.cover.as_ref().filter(|c| !c.is_empty()) {
                used.insert(c.to_ascii_lowercase());
            }
        }
        let now = std::time::SystemTime::now();
        let mut removed = 0;
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let Some(sha) = name.strip_suffix(".jpg") else {
                continue;
            };
            if self.cover_file(sha).is_none() || used.contains(&sha.to_ascii_lowercase()) {
                continue; // не наш файл или картинка нужна
            }
            let old_enough = e
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|m| now.duration_since(m).ok())
                .is_some_and(|age| age >= min_age);
            if old_enough && fs::remove_file(e.path()).is_ok() {
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// Картинки, которых не хватает на этом устройстве (хэш картинки), для живых треков.
    pub(super) fn missing_covers(&self) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT o.track_id FROM ops o JOIN tracks t ON t.track_id = o.track_id
             WHERE o.kind = 'edit' AND t.deleted = 0 AND o.payload LIKE '%\"cover\"%'
             ORDER BY o.track_id",
        )?;
        let ids = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        let mut out: Vec<String> = Vec::new();
        for id in ids {
            let Some(c) = self.track_cover(&id)? else {
                continue;
            };
            let Some(path) = self.cover_file(&c) else {
                continue;
            };
            if !path.is_file() && !out.contains(&c) {
                out.push(c);
            }
        }
        Ok(out)
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
        // какие поля трека правились хоть раз: (название, исполнитель, обложка)
        let mut flags: BTreeMap<String, (bool, bool, bool)> = BTreeMap::new();
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
            if v.get("cover").and_then(|x| x.as_str()).is_some() {
                e.2 = true;
            }
        }
        let mut out = BTreeMap::new();
        for (id, (title_edited, artist_edited, cover_edited)) in flags {
            if !title_edited && !artist_edited && !cover_edited {
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
                    cover: if cover_edited {
                        Some(self.track_cover(&id)?.unwrap_or_default())
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
            if fresh.cover.is_some() {
                e.cover = fresh.cover;
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
    use std::time::Duration;

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

    fn png(dir: &Path, name: &str, shade: u8) -> PathBuf {
        let p = dir.join(name);
        image::RgbImage::from_pixel(8, 8, image::Rgb([shade, 30, 30]))
            .save(&p)
            .unwrap();
        p
    }

    fn covers_on_disk(tmp: &tempfile::TempDir) -> usize {
        fs::read_dir(tmp.path().join("Hydra/.hydra/covers"))
            .map(|rd| rd.count())
            .unwrap_or(0)
    }

    /// Прежние обложки и обложки треков, удалённых насовсем, убираются; текущие и обложки
    /// треков в корзине остаются; чужие файлы и свежие картинки не трогаются.
    #[test]
    fn unused_covers_are_purged_and_needed_ones_kept() {
        let tmp = tempfile::tempdir().unwrap();
        let mut lib = open(&tmp, "a.db", T0);
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        lib.scan(T0 + 1).unwrap();
        let a = find(&lib, "a.mp3").track_id;
        let b = find(&lib, "b.mp3").track_id;
        lib.set_cover(&a, &png(tmp.path(), "1.png", 10), T0 + 2)
            .unwrap();
        lib.set_cover(&a, &png(tmp.path(), "2.png", 20), T0 + 3)
            .unwrap();
        lib.set_cover(&b, &png(tmp.path(), "3.png", 30), T0 + 4)
            .unwrap();
        let foreign = tmp.path().join("Hydra/.hydra/covers/readme.txt");
        fs::write(&foreign, "не наше").unwrap();
        assert_eq!(covers_on_disk(&tmp), 4);

        // свежие картинки не трогаются
        assert_eq!(
            lib.purge_unused_covers(Duration::from_secs(3600)).unwrap(),
            0
        );
        // прежняя обложка трека a больше не нужна
        assert_eq!(lib.purge_unused_covers(Duration::ZERO).unwrap(), 1);
        let a_cover = lib.cover(&a).unwrap().expect("текущая обложка на месте").1;
        assert!(!a_cover.is_empty());

        // трек в корзине: обложка нужна для восстановления
        lib.delete_track(&b, T0 + 5).unwrap();
        lib.write_overrides(true).unwrap();
        assert_eq!(lib.purge_unused_covers(Duration::ZERO).unwrap(), 0);
        lib.restore_track(&b, T0 + 6).unwrap();
        assert!(
            lib.cover(&b).unwrap().is_some(),
            "восстановленный трек с обложкой"
        );

        // удалён насовсем: обложка уходит
        lib.delete_track(&b, T0 + 7).unwrap();
        lib.purge_track(&b).unwrap();
        lib.write_overrides(true).unwrap();
        assert_eq!(lib.purge_unused_covers(Duration::ZERO).unwrap(), 1);
        assert!(foreign.exists(), "чужой файл не тронут");
        assert_eq!(covers_on_disk(&tmp), 2, "обложка трека a и чужой файл");
    }

    #[test]
    fn cover_for_a_tagless_file_lives_beside_the_music_and_survives_reinstall() {
        let tmp = tempfile::tempdir().unwrap();
        let mut lib = open(&tmp, "a.db", T0);
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let id = find(&lib, "a.mp3").track_id;
        assert!(lib.cover(&id).unwrap().is_none());
        let pic = png(tmp.path(), "c.png", 200);
        lib.set_cover(&id, &pic, T0 + 2).unwrap();
        let (_, bytes) = lib.cover(&id).unwrap().expect("обложка есть");
        assert!(!bytes.is_empty());
        let files = fs::read_dir(tmp.path().join("Hydra/.hydra/covers"))
            .unwrap()
            .count();
        assert_eq!(files, 1);
        // заменили: новая картинка главнее старой
        let pic2 = png(tmp.path(), "c2.png", 10);
        lib.set_cover(&id, &pic2, T0 + 3).unwrap();
        let (_, bytes2) = lib.cover(&id).unwrap().unwrap();
        assert_ne!(bytes, bytes2);
        drop(lib);

        // «переустановка»
        let mut lib2 = open(&tmp, "fresh.db", T0 + 100);
        lib2.scan(T0 + 101).unwrap();
        let id2 = find(&lib2, "a.mp3").track_id;
        let (_, back) = lib2.cover(&id2).unwrap().expect("обложка вернулась");
        assert_eq!(back, bytes2);
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
