//! Язык сообщений ядра: ошибки и журнал сети показываются пользователю, поэтому их текст
//! переводится, как и интерфейс.
//!
//! Исходный язык - русский: в коде пишется вызов `tr` с русским текстом или `trf` с текстом,
//! где `{имя}` - подстановка, и списком пар (имя, значение). Английский и украинский берутся из таблицы
//! [`TABLE`] (файл `i18n_table.rs`, его генерирует `tools/i18n_core.py`). Нет перевода -
//! остаётся русский текст.
//!
//! Язык процесса задаёт приложение (метод моста `set_lang`). Тесты ядра его не меняют
//! (параллельные тесты живут в одном процессе): переводы проверяются функцией [`translate`].

use std::fmt::Display;
use std::sync::atomic::{AtomicU8, Ordering};

#[path = "i18n_table.rs"]
mod table;
pub use table::TABLE;

/// Язык сообщений.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    Ru = 0,
    En = 1,
    Uk = 2,
}

impl Lang {
    /// `ru`, `en`, `uk`; остальное - английский.
    pub fn from_code(code: &str) -> Lang {
        match code {
            "ru" => Lang::Ru,
            "uk" => Lang::Uk,
            _ => Lang::En,
        }
    }
}

static LANG: AtomicU8 = AtomicU8::new(Lang::Ru as u8);

/// Язык процесса (задаёт приложение при запуске и при смене языка).
pub fn set_lang(lang: Lang) {
    LANG.store(lang as u8, Ordering::Relaxed);
}

pub fn lang() -> Lang {
    match LANG.load(Ordering::Relaxed) {
        1 => Lang::En,
        2 => Lang::Uk,
        _ => Lang::Ru,
    }
}

/// Перевод на заданный язык (без подстановок). Нет в таблице - русский текст.
pub fn translate(lang: Lang, ru: &str) -> String {
    if lang == Lang::Ru {
        return ru.to_string();
    }
    match TABLE.iter().find(|(k, _, _)| *k == ru) {
        Some((_, en, uk)) => if lang == Lang::En { en } else { uk }.to_string(),
        None => ru.to_string(),
    }
}

/// Перевод на язык процесса.
pub fn tr(ru: &str) -> String {
    translate(lang(), ru)
}

/// Перевод с подстановками: `{имя}` в тексте заменяется значением.
pub fn trf(ru: &str, args: &[(&str, &dyn Display)]) -> String {
    fill(tr(ru), args)
}

fn fill(mut s: String, args: &[(&str, &dyn Display)]) -> String {
    for (name, value) in args {
        s = s.replace(&format!("{{{name}}}"), &value.to_string());
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn holes(s: &str) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        let mut rest = s;
        while let Some(i) = rest.find('{') {
            match rest[i..].find('}') {
                Some(j) => {
                    out.insert(rest[i..i + j + 1].to_string());
                    rest = &rest[i + j + 1..];
                }
                None => break,
            }
        }
        out
    }

    /// Все строки вызовов tr / trf из исходников ядра и моста.
    fn keys_in_sources() -> BTreeSet<String> {
        let mut keys = BTreeSet::new();
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut stack = vec![root.join("src"), root.join("../ffi/src")];
        while let Some(dir) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&dir) else {
                continue;
            };
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                    continue;
                }
                if p.extension().and_then(|x| x.to_str()) != Some("rs")
                    || p.file_name().and_then(|x| x.to_str()) == Some("i18n_table.rs")
                {
                    continue;
                }
                let src = std::fs::read_to_string(&p).unwrap();
                for call in ["tr(\"", "trf(\""] {
                    let mut rest = src.as_str();
                    while let Some(i) = rest.find(call) {
                        // не часть другого имени (например, `split("`)
                        let before = rest[..i].chars().last();
                        rest = &rest[i + call.len()..];
                        if before.is_some_and(|c| c.is_alphanumeric() || c == '_') {
                            continue;
                        }
                        if let Some(end) = rest.find('"') {
                            keys.insert(rest[..end].to_string());
                        }
                    }
                }
            }
        }
        keys
    }

    #[test]
    fn every_message_has_english_and_ukrainian() {
        let keys = keys_in_sources();
        assert!(keys.len() > 80, "нашлось мало строк: {}", keys.len());
        let missing: Vec<_> = keys
            .iter()
            .filter(|k| !TABLE.iter().any(|(r, _, _)| r == k))
            .collect();
        assert!(missing.is_empty(), "нет перевода: {missing:#?}");
    }

    #[test]
    fn placeholders_and_detail_marks_match() {
        for (ru, en, uk) in TABLE {
            assert_eq!(holes(ru), holes(en), "en: {ru}");
            assert_eq!(holes(ru), holes(uk), "uk: {ru}");
            // строки подробностей журнала начинаются с '#': ядро отделяет их по этому знаку
            assert_eq!(ru.starts_with('#'), en.starts_with('#'), "en #: {ru}");
            assert_eq!(ru.starts_with('#'), uk.starts_with('#'), "uk #: {ru}");
        }
    }

    #[test]
    fn translate_and_fill() {
        assert_eq!(translate(Lang::Ru, "Готово"), "Готово");
        assert_eq!(translate(Lang::En, "Готово"), "Done");
        assert_eq!(translate(Lang::Uk, "Готово"), "Готово");
        assert_eq!(translate(Lang::En, "нет такой строки"), "нет такой строки");
        let s = fill(
            translate(Lang::En, "Слушаю порт {port}"),
            &[("port", &47475)],
        );
        assert_eq!(s, "Listening on port 47475");
        assert_eq!(Lang::from_code("uk"), Lang::Uk);
        assert_eq!(Lang::from_code("de"), Lang::En);
    }
}
