//! Безопасные имена папок плейлистов и файлов (Windows + Android).
//!
//! Правила: убираем запрещённые символы, хвостовые точки/пробелы, зарезервированные
//! имена Windows, нормализуем Unicode (NFC), сравниваем без учёта регистра.

use unicode_normalization::UnicodeNormalization;

const FORBIDDEN: &[char] = &['<', '>', ':', '"', '/', '\\', '|', '?', '*'];
const RESERVED: &[&str] = &[
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];
const MAX_LEN: usize = 100;

/// Очищает имя. Никогда не возвращает пустую строку.
pub fn sanitize(name: &str) -> String {
    let nfc: String = name.nfc().collect();
    let mut s: String = nfc
        .chars()
        .map(|c| if c.is_control() || FORBIDDEN.contains(&c) { '_' } else { c })
        .collect();
    s = s.trim().trim_end_matches(['.', ' ']).to_string();
    if s.chars().count() > MAX_LEN {
        s = s.chars().take(MAX_LEN).collect::<String>().trim_end_matches(['.', ' ']).to_string();
    }
    if s.is_empty() {
        s = "Untitled".to_string();
    }
    let stem = s.split('.').next().unwrap_or("").to_uppercase();
    if RESERVED.contains(&stem.as_str()) {
        s = format!("_{s}");
    }
    s
}

/// Ключ для сравнения имён без учёта регистра (Windows и Android не должны расходиться).
pub fn fold_key(name: &str) -> String {
    name.nfc().collect::<String>().to_lowercase()
}

/// Подбирает свободное имя среди существующих: "Rock", "Rock (2)", "Rock (3)"...
pub fn unique_name(wanted: &str, existing: &[String]) -> String {
    let base = sanitize(wanted);
    let taken: Vec<String> = existing.iter().map(|e| fold_key(e)).collect();
    if !taken.contains(&fold_key(&base)) {
        return base;
    }
    let mut n = 2;
    loop {
        let candidate = format!("{base} ({n})");
        if !taken.contains(&fold_key(&candidate)) {
            return candidate;
        }
        n += 1;
    }
}

/// Свободное имя файла среди существующих: "song.flac", "song (2).flac", ...
pub fn unique_file_name(wanted: &str, existing: &[String]) -> String {
    let taken: Vec<String> = existing.iter().map(|e| fold_key(e)).collect();
    if !taken.contains(&fold_key(wanted)) {
        return wanted.to_string();
    }
    let (stem, ext) = match wanted.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{e}")),
        _ => (wanted.to_string(), String::new()),
    };
    let mut n = 2;
    loop {
        let candidate = format!("{stem} ({n}){ext}");
        if !taken.contains(&fold_key(&candidate)) {
            return candidate;
        }
        n += 1;
    }
}

/// Имя скрытого JSON плейлиста: ".Rock.json" (точка = скрытый на Android;
/// на Windows дополнительно выставляется атрибут Hidden на стороне платформы).
pub fn playlist_manifest_name(playlist_dir: &str) -> String {
    format!(".{}.json", sanitize(playlist_dir))
}

/// Расширения, которые плеер считает аудио. mp4/m4a/mkv и т.п. играются только звуком.
pub fn is_supported_audio(file_name: &str) -> bool {
    const EXT: &[&str] = &[
        "mp3", "flac", "wav", "ogg", "oga", "opus", "m4a", "aac", "wma", "aiff", "aif", "ape",
        "wv", "mka", "mp4", "m4b",
    ];
    ext(file_name).map_or(false, |e| EXT.contains(&e.as_str()))
}

/// Видеоконтейнеры: показываем значок киноплёнки вместо обложки.
pub fn is_video_container(file_name: &str) -> bool {
    const EXT: &[&str] = &["mp4", "mkv", "webm", "avi", "mov", "m4v"];
    ext(file_name).map_or(false, |e| EXT.contains(&e.as_str()))
}

fn ext(file_name: &str) -> Option<String> {
    let (_, e) = file_name.rsplit_once('.')?;
    Some(e.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_forbidden_chars_and_trailing_dots() {
        assert_eq!(sanitize("AC/DC: Live?."), "AC_DC_ Live_");
        assert_eq!(sanitize("  name.  "), "name");
    }

    #[test]
    fn reserved_windows_names_are_prefixed() {
        assert_eq!(sanitize("con"), "_con");
        assert_eq!(sanitize("NUL.txt"), "_NUL.txt");
        assert_eq!(sanitize("Console"), "Console");
    }

    #[test]
    fn empty_becomes_untitled() {
        assert_eq!(sanitize("..."), "Untitled");
        assert_eq!(sanitize(""), "Untitled");
    }

    #[test]
    fn case_conflicts_get_suffix() {
        let existing = vec!["Rock".to_string()];
        assert_eq!(unique_name("rock", &existing), "rock (2)");
        let existing = vec!["Rock".to_string(), "rock (2)".to_string()];
        assert_eq!(unique_name("ROCK", &existing), "ROCK (3)");
        assert_eq!(unique_name("Jazz", &existing), "Jazz");
    }

    #[test]
    fn unique_file_name_keeps_extension() {
        let existing = vec!["Song.FLAC".to_string()];
        assert_eq!(unique_file_name("song.flac", &existing), "song (2).flac");
        assert_eq!(unique_file_name("other.mp3", &existing), "other.mp3");
        let existing = vec!["a".to_string()];
        assert_eq!(unique_file_name("a", &existing), "a (2)");
    }

    #[test]
    fn unicode_is_normalized() {
        // "é" как одна кодпоинта и как e + combining acute должны совпасть
        assert_eq!(fold_key("caf\u{e9}"), fold_key("cafe\u{301}"));
    }

    #[test]
    fn long_names_are_truncated() {
        let long = "a".repeat(300);
        assert_eq!(sanitize(&long).chars().count(), 100);
    }

    #[test]
    fn manifest_is_hidden_dotfile() {
        assert_eq!(playlist_manifest_name("Rock"), ".Rock.json");
    }

    #[test]
    fn audio_and_video_detection() {
        assert!(is_supported_audio("a.FLAC"));
        assert!(is_supported_audio("clip.mp4"));
        assert!(!is_supported_audio("cover.jpg"));
        assert!(is_video_container("clip.MP4"));
        assert!(!is_video_container("song.flac"));
    }
}
