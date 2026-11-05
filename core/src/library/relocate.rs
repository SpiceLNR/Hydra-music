//! Смена папки библиотеки: все файлы (плейлисты, корзина, служебные папки) переезжают
//! на новое место. В базе пути не хранятся (они собираются из корня), поэтому после переноса
//! достаточно сменить корень.
//!
//! Сначала пробуем мгновенное переименование (тот же диск); если оно не вышло (другой диск),
//! папка копируется с проверкой хэша каждого файла. При любой ошибке сделанное откатывается,
//! старая папка остаётся нетронутой. Старые файлы удаляются только после полного успеха.

use super::*;

#[derive(Debug, Default, Clone, PartialEq, Serialize)]
pub struct MoveReport {
    /// Сколько верхнеуровневых папок и файлов перенесено.
    pub entries: usize,
    /// Сколько файлов во всех перенесённых папках.
    pub files: usize,
    /// Их суммарный размер.
    pub bytes: u64,
    /// `true`, если переносили копированием (другой диск), а не переименованием.
    pub copied: bool,
    /// Что не удалось убрать из старой папки после копирования (например, занято плеером).
    pub leftover: Vec<String>,
}

impl Library {
    /// Переносит библиотеку в `new_root` (папка должна быть пустой или не существовать).
    pub fn move_root(&mut self, new_root: &Path) -> Result<MoveReport> {
        if !new_root.is_absolute() {
            return Err(Error::Invalid(
                "путь к новой папке должен быть полным".into(),
            ));
        }
        let old = canonical(&self.root)?;
        let new = canonical(new_root)?;
        if new == old || new.starts_with(&old) || old.starts_with(&new) {
            return Err(Error::Invalid(
                "новая папка не может совпадать со старой или лежать внутри неё (и наоборот)"
                    .into(),
            ));
        }
        let created = if new_root.exists() {
            if !new_root.is_dir() {
                return Err(Error::Invalid("на месте новой папки лежит файл".into()));
            }
            if fs::read_dir(new_root)?.next().is_some() {
                return Err(Error::Invalid("новая папка должна быть пустой".into()));
            }
            false
        } else {
            fs::create_dir_all(new_root)?;
            true
        };

        let entries: Vec<PathBuf> = fs::read_dir(&self.root)?
            .collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|e| e.path())
            .collect();
        let mut done: Vec<(PathBuf, PathBuf, bool)> = Vec::new();
        let mut report = MoveReport::default();
        if let Err(e) = move_entries(&entries, new_root, &mut done, &mut report) {
            for (src, dst, copied) in done.iter().rev() {
                if *copied {
                    let _ = remove_tree(dst);
                } else {
                    let _ = fs::rename(dst, src);
                }
            }
            if created {
                let _ = fs::remove_dir(new_root);
            }
            return Err(e);
        }

        // всё на месте: чистим старое (только то, что копировали)
        for (src, _, copied) in &done {
            if *copied && remove_tree(src).is_err() {
                report.leftover.push(src.to_string_lossy().to_string());
            }
        }
        if report.leftover.is_empty() {
            let _ = fs::remove_dir(&self.root); // пустую старую папку убираем, если можно
        }
        self.root = new_root.to_path_buf();
        self.held.clear();
        hide(&self.root.join(INTERNAL_DIR));
        Ok(report)
    }
}

fn move_entries(
    entries: &[PathBuf],
    new_root: &Path,
    done: &mut Vec<(PathBuf, PathBuf, bool)>,
    report: &mut MoveReport,
) -> Result<()> {
    for src in entries {
        let Some(name) = src.file_name() else {
            continue;
        };
        let dst = new_root.join(name);
        if fs::rename(src, &dst).is_ok() {
            done.push((src.clone(), dst.clone(), false));
            let (mut f, mut b) = (0, 0);
            count_tree(&dst, &mut f, &mut b);
            report.files += f;
            report.bytes += b;
        } else {
            let (mut f, mut b) = (0, 0);
            if let Err(e) = copy_tree(src, &dst, &mut f, &mut b) {
                let _ = remove_tree(&dst);
                return Err(e);
            }
            done.push((src.clone(), dst, true));
            report.copied = true;
            report.files += f;
            report.bytes += b;
        }
        report.entries += 1;
    }
    Ok(())
}

/// Путь без «..» и ссылок; для несуществующей папки берётся существующий родитель.
fn canonical(p: &Path) -> Result<PathBuf> {
    if p.exists() {
        return Ok(fs::canonicalize(p)?);
    }
    let parent = p
        .parent()
        .ok_or_else(|| Error::Invalid("у новой папки нет родителя".into()))?;
    let name = p
        .file_name()
        .ok_or_else(|| Error::Invalid("у новой папки нет имени".into()))?;
    Ok(canonical(parent)?.join(name))
}

fn count_tree(p: &Path, files: &mut usize, bytes: &mut u64) {
    let Ok(md) = fs::symlink_metadata(p) else {
        return;
    };
    if md.is_dir() {
        if let Ok(rd) = fs::read_dir(p) {
            for e in rd.flatten() {
                count_tree(&e.path(), files, bytes);
            }
        }
    } else if md.is_file() {
        *files += 1;
        *bytes += md.len();
    }
}

/// Копирует файл или папку целиком и сверяет размер и хэш каждого файла.
fn copy_tree(src: &Path, dst: &Path, files: &mut usize, bytes: &mut u64) -> Result<()> {
    let md = fs::symlink_metadata(src)?;
    if md.is_dir() {
        fs::create_dir_all(dst)?;
        for e in fs::read_dir(src)? {
            let e = e?;
            copy_tree(&e.path(), &dst.join(e.file_name()), files, bytes)?;
        }
    } else if md.is_file() {
        fs::copy(src, dst)?;
        if fs::metadata(dst)?.len() != md.len() || sha256_file(src)? != sha256_file(dst)? {
            return Err(Error::Invalid(format!(
                "файл скопирован с ошибкой: {}",
                src.display()
            )));
        }
        *files += 1;
        *bytes += md.len();
    }
    Ok(())
}

fn remove_tree(p: &Path) -> std::io::Result<()> {
    if fs::symlink_metadata(p)?.is_dir() {
        fs::remove_dir_all(p)
    } else {
        fs::remove_file(p)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    const T0: u64 = 7_000_000;

    fn setup() -> (TempDir, Library) {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open(
            &tmp.path().join("Hydra"),
            &tmp.path().join("hydra.db"),
            "dev-a",
            T0,
        )
        .unwrap();
        (tmp, lib)
    }

    fn put(lib: &Library, playlist: &str, file: &str, content: &str) {
        let dir = lib.root().join(playlist);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(file), content).unwrap();
    }

    fn first_playlist(lib: &Library, name: &str) -> String {
        lib.playlists()
            .unwrap()
            .into_iter()
            .find(|p| p.name == name)
            .unwrap()
            .playlist_id
    }

    #[test]
    fn library_moves_with_trash_and_keeps_working() {
        let (tmp, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        put(&lib, "Rock", "b.mp3", "bbb");
        put(&lib, "Jazz", "j.mp3", "jjj");
        lib.scan(T0 + 1).unwrap();
        let rock = first_playlist(&lib, "Rock");
        let id = lib.tracks(&rock).unwrap()[0].track_id.clone();
        lib.delete_track(&id, T0 + 2).unwrap();

        let old = lib.root().to_path_buf();
        let new = tmp.path().join("Elsewhere").join("Music");
        let rep = lib.move_root(&new).unwrap();
        assert_eq!(lib.root(), new);
        assert!(rep.entries >= 3 && rep.files >= 3, "{rep:?}");
        assert!(!old.join("Jazz").exists());
        assert!(new.join("Jazz").join("j.mp3").is_file());
        assert!(trash_root(&new).join(&id).is_dir(), "корзина переехала");

        // ничего не потерялось и не удалилось: скан после переезда пустой
        assert_eq!(lib.scan(T0 + 3).unwrap(), ScanReport::default());
        assert_eq!(lib.trash_items().unwrap().len(), 1);
        lib.restore_track(&id, T0 + 4).unwrap();
        assert_eq!(lib.tracks(&rock).unwrap().len(), 2);
    }

    #[test]
    fn bad_targets_are_refused_and_nothing_changes() {
        let (tmp, mut lib) = setup();
        put(&lib, "Rock", "a.mp3", "aaa");
        lib.scan(T0 + 1).unwrap();
        let root = lib.root().to_path_buf();

        let full = tmp.path().join("Full");
        fs::create_dir_all(&full).unwrap();
        fs::write(full.join("x.txt"), "x").unwrap();
        assert!(lib.move_root(&full).is_err(), "непустая папка");
        assert!(lib.move_root(&root).is_err(), "та же папка");
        assert!(lib.move_root(&root.join("Rock")).is_err(), "внутри старой");
        assert!(lib.move_root(tmp.path()).is_err(), "старая внутри новой");
        assert!(lib.move_root(Path::new("relative/dir")).is_err());

        assert_eq!(lib.root(), root);
        assert!(root.join("Rock").join("a.mp3").is_file());
        assert_eq!(lib.scan(T0 + 2).unwrap(), ScanReport::default());
    }

    #[test]
    fn copy_tree_copies_everything_and_verifies() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("a.txt"), "aaa").unwrap();
        fs::write(src.join("sub").join("b.txt"), "bbbb").unwrap();
        let dst = tmp.path().join("dst");
        let (mut f, mut b) = (0, 0);
        copy_tree(&src, &dst, &mut f, &mut b).unwrap();
        assert_eq!((f, b), (2, 7));
        assert_eq!(
            fs::read_to_string(dst.join("sub").join("b.txt")).unwrap(),
            "bbbb"
        );
        remove_tree(&dst).unwrap();
        assert!(!dst.exists());
    }
}
