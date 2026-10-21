//! Правка тегов аудиофайла: название и обложка (обложка встраивается в сам файл,
//! отдельной папки с картинками нет).
//!
//! Безопасная схема: правим КОПИЮ во внутренней папке `.hydra/tmp`, перечитываем её
//! для проверки и только потом заменяем оригинал. При любой ошибке оригинал не тронут.

use crate::{Error, Result};
use lofty::config::WriteOptions;
use lofty::picture::{Picture, PictureType};
use lofty::prelude::*;
use lofty::tag::Tag;
use std::fs;
use std::io::Cursor;
use std::path::Path;
use uuid::Uuid;

/// Самая длинная сторона обложки в пикселях: больше в теги класть незачем.
const MAX_COVER_SIDE: u32 = 1000;

fn lerr<E: std::fmt::Display>(e: E) -> Error {
    Error::Invalid(format!("теги: {e}"))
}

/// Записывает название в теги файла.
pub fn write_title(path: &Path, title: &str, tmp_dir: &Path) -> Result<()> {
    let wanted = title.to_string();
    edit(path, tmp_dir, |tag| {
        tag.set_title(wanted.clone());
        Ok(())
    })?;
    Ok(())
}

/// Записывает название и/или исполнителя одной правкой файла.
/// Пустой исполнитель убирает тег.
pub fn write_text(
    path: &Path,
    title: Option<&str>,
    artist: Option<&str>,
    tmp_dir: &Path,
) -> Result<()> {
    let title = title.map(|s| s.to_string());
    let artist = artist.map(|s| s.to_string());
    edit(path, tmp_dir, move |tag| {
        if let Some(t) = &title {
            tag.set_title(t.clone());
        }
        if let Some(a) = &artist {
            if a.is_empty() {
                tag.remove_artist();
            } else {
                tag.set_artist(a.clone());
            }
        }
        Ok(())
    })
}

/// Встраивает обложку (jpeg-байты) в теги файла, заменяя прежнюю лицевую.
pub fn write_cover(path: &Path, jpeg: &[u8], tmp_dir: &Path) -> Result<()> {
    let jpeg = jpeg.to_vec();
    edit(path, tmp_dir, |tag| {
        let mut pic = Picture::from_reader(&mut Cursor::new(&jpeg)).map_err(lerr)?;
        pic.set_pic_type(PictureType::CoverFront);
        tag.remove_picture_type(PictureType::CoverFront);
        tag.push_picture(pic);
        Ok(())
    })
}

/// Читает картинку (png, jpeg, webp), уменьшает до [`MAX_COVER_SIDE`] и кодирует в jpeg.
pub fn prepare_cover(image_path: &Path) -> Result<Vec<u8>> {
    let img = image::open(image_path)
        .map_err(|e| Error::Invalid(format!("не удалось прочитать картинку: {e}")))?;
    let img = if img.width() > MAX_COVER_SIDE || img.height() > MAX_COVER_SIDE {
        img.thumbnail(MAX_COVER_SIDE, MAX_COVER_SIDE)
    } else {
        img
    };
    let rgb = image::DynamicImage::ImageRgb8(img.to_rgb8());
    let mut buf: Vec<u8> = Vec::new();
    rgb.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Jpeg)
        .map_err(|e| Error::Invalid(format!("не удалось сжать картинку: {e}")))?;
    Ok(buf)
}

fn edit(path: &Path, tmp_dir: &Path, change: impl FnOnce(&mut Tag) -> Result<()>) -> Result<()> {
    fs::create_dir_all(tmp_dir)?;
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_string())
        .unwrap_or_default();
    let tmp = tmp_dir.join(format!("edit-{}.{ext}", Uuid::new_v4()));
    fs::copy(path, &tmp)?;
    let result = edit_copy(&tmp, change);
    match result {
        Ok(()) => {
            if let Err(e) = fs::rename(&tmp, path) {
                let _ = fs::remove_file(&tmp);
                return Err(e.into());
            }
            Ok(())
        }
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(e)
        }
    }
}

fn edit_copy(tmp: &Path, change: impl FnOnce(&mut Tag) -> Result<()>) -> Result<()> {
    let mut tagged = lofty::read_from_path(tmp).map_err(lerr)?;
    if tagged.primary_tag().is_none() {
        let tag_type = tagged.primary_tag_type();
        tagged.insert_tag(Tag::new(tag_type));
    }
    let tag = tagged
        .primary_tag_mut()
        .ok_or_else(|| lerr("формат не поддерживает теги"))?;
    change(tag)?;
    tag.save_to_path(tmp, WriteOptions::default())
        .map_err(lerr)?;
    // Проверка: файл с новыми тегами должен читаться.
    lofty::read_from_path(tmp).map_err(lerr)?;
    Ok(())
}
