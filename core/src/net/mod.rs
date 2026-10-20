//! Синхронизация между устройствами по локальной сети.
//!
//! Слои:
//!  * `channel` - шифрованный канал Noise поверх TCP (XX, а при сопряжении XXpsk3 с одноразовым
//!    секретом из QR-кода);
//!  * `identity` - ключ устройства и «семья» (список доверенных устройств);
//!  * `session` - сам обмен: опись, журнал, файлы (использует функции `Library::sync_*`);
//!  * `node` - фоновые потоки: приём подключений, обнаружение устройств, сопряжение.

pub mod channel;
pub mod identity;
pub mod node;
pub mod session;

pub use identity::{Family, Identity, Peer};
pub use node::{Node, Offer};
pub use session::{LibHandle, SessionReport};

pub(crate) fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() % 2 != 0 || !s.is_ascii() {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}
