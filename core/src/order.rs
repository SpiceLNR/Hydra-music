//! Дробные ключи порядка (fractional indexing).
//!
//! Позиция трека в плейлисте = строковый ключ. Чтобы вставить трек между двумя
//! соседями, генерируется ключ строго между их ключами, и остальные треки не
//! трогаются. Поэтому перестановка - это одна маленькая операция, которая
//! безопасно синхронизируется между устройствами.
//!
//! Ключи состоят из символов `0-9a-z`, не бывают пустыми и не заканчиваются на `0`.

use crate::{Error, Result};

const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
const BASE: usize = DIGITS.len();

fn digit_val(c: u8) -> Option<usize> {
    DIGITS.iter().position(|&d| d == c)
}

/// Допустимый ключ порядка.
pub fn is_valid_key(k: &str) -> bool {
    !k.is_empty() && k.bytes().all(|c| digit_val(c).is_some()) && !k.ends_with('0')
}

/// Ключ строго между `a` и `b`. `None` слева означает «в самое начало»,
/// `None` справа - «в самый конец».
pub fn key_between(a: Option<&str>, b: Option<&str>) -> Result<String> {
    if let Some(a) = a {
        if !is_valid_key(a) {
            return Err(Error::Invalid(format!("order key {a:?}")));
        }
    }
    if let Some(b) = b {
        if !is_valid_key(b) {
            return Err(Error::Invalid(format!("order key {b:?}")));
        }
    }
    if let (Some(a), Some(b)) = (a, b) {
        if a >= b {
            return Err(Error::Invalid(format!("order keys not ascending: {a:?} >= {b:?}")));
        }
    }
    Ok(midpoint(a.unwrap_or("").as_bytes(), b.map(|s| s.as_bytes())))
}

fn midpoint(a: &[u8], b: Option<&[u8]>) -> String {
    if let Some(b) = b {
        // общий префикс (a дополняется нулями справа)
        let mut n = 0;
        while n < b.len() && a.get(n).copied().unwrap_or(b'0') == b[n] {
            n += 1;
        }
        if n > 0 {
            let a_rest: &[u8] = if n < a.len() { &a[n..] } else { &[] };
            let mut s = String::from_utf8(b[..n].to_vec()).expect("ascii");
            s.push_str(&midpoint(a_rest, Some(&b[n..])));
            return s;
        }
    }
    let da = a.first().and_then(|&c| digit_val(c)).unwrap_or(0);
    let db = b.and_then(|b| digit_val(b[0])).unwrap_or(BASE);
    if db - da > 1 {
        let mid = (da + db) / 2;
        (DIGITS[mid] as char).to_string()
    } else if let Some(b) = b.filter(|b| b.len() > 1) {
        // первые цифры соседние, у b есть продолжение: хватит первой цифры b
        (b[0] as char).to_string()
    } else {
        let mut s = String::new();
        s.push(DIGITS[da] as char);
        let a_rest: &[u8] = if a.len() > 1 { &a[1..] } else { &[] };
        s.push_str(&midpoint(a_rest, None));
        s
    }
}

/// `n` равномерно распределённых ключей для полной перебалансировки плейлиста.
pub fn spread_keys(n: usize) -> Result<Vec<String>> {
    const WIDTH_MAX: usize = 36 * 36 * 36; // 3 цифры
    let mut out = Vec::with_capacity(n);
    if n == 0 {
        return Ok(out);
    }
    if n <= 10_000 {
        let step = WIDTH_MAX / (n + 1);
        for i in 0..n {
            let mut v = (i + 1) * step;
            if v % BASE == 0 {
                v += 1; // ключ не должен заканчиваться на '0'; step >= 4, соседей не заденет
            }
            let d2 = v / (BASE * BASE);
            let d1 = (v / BASE) % BASE;
            let d0 = v % BASE;
            out.push(
                [DIGITS[d2], DIGITS[d1], DIGITS[d0]].iter().map(|&c| c as char).collect(),
            );
        }
    } else {
        // очень большие плейлисты: последовательно дописываем в конец
        let mut prev: Option<String> = None;
        for _ in 0..n {
            let k = key_between(prev.as_deref(), None)?;
            prev = Some(k.clone());
            out.push(k);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn between_is_strictly_ordered() {
        let k = key_between(None, None).unwrap();
        let after = key_between(Some(&k), None).unwrap();
        let before = key_between(None, Some(&k)).unwrap();
        assert!(before < k && k < after);
        let mid = key_between(Some(&before), Some(&k)).unwrap();
        assert!(before < mid && mid < k);
    }

    #[test]
    fn repeated_insert_at_front_and_back() {
        let mut first = key_between(None, None).unwrap();
        let mut last = first.clone();
        for _ in 0..200 {
            let f = key_between(None, Some(&first)).unwrap();
            assert!(f < first);
            assert!(is_valid_key(&f));
            first = f;
            let l = key_between(Some(&last), None).unwrap();
            assert!(l > last);
            assert!(is_valid_key(&l));
            last = l;
        }
    }

    #[test]
    fn random_insertions_keep_strict_order() {
        let mut keys: Vec<String> = vec![key_between(None, None).unwrap()];
        let mut seed: u64 = 12345;
        for _ in 0..500 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let pos = (seed >> 33) as usize % (keys.len() + 1);
            let a = if pos == 0 { None } else { Some(keys[pos - 1].as_str()) };
            let b = keys.get(pos).map(|s| s.as_str());
            let k = key_between(a, b).unwrap();
            assert!(is_valid_key(&k));
            keys.insert(pos, k);
        }
        assert!(keys.windows(2).all(|w| w[0] < w[1]), "ключи должны остаться строго по возрастанию");
    }

    #[test]
    fn consecutive_digits_get_a_longer_key() {
        let k = key_between(Some("a"), Some("b")).unwrap();
        assert!("a" < k.as_str() && k.as_str() < "b");
    }

    #[test]
    fn rejects_invalid_input() {
        assert!(key_between(Some("b"), Some("a")).is_err());
        assert!(key_between(Some("a"), Some("a")).is_err());
        assert!(key_between(Some("a0"), None).is_err()); // хвостовой ноль
        assert!(key_between(Some("A"), None).is_err()); // заглавные не допускаются
        assert!(key_between(Some(""), None).is_err());
    }

    #[test]
    fn spread_keys_are_sorted_unique_and_valid() {
        for n in [0usize, 1, 2, 7, 100, 5000] {
            let keys = spread_keys(n).unwrap();
            assert_eq!(keys.len(), n);
            assert!(keys.iter().all(|k| is_valid_key(k)));
            assert!(keys.windows(2).all(|w| w[0] < w[1]), "n={n}");
        }
    }
}
