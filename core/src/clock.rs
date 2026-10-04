//! Гибридные логические часы (HLC).
//!
//! Время = (физические миллисекунды, счётчик, id устройства). Порядок событий
//! остаётся корректным, даже если часы устройств расходятся: получив чужую
//! метку, мы никогда не откатываемся назад.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hlc {
    pub wall_ms: u64,
    pub counter: u32,
    pub device: String,
}

impl Hlc {
    pub fn new(wall_ms: u64, counter: u32, device: impl Into<String>) -> Self {
        Self { wall_ms, counter, device: device.into() }
    }

    /// Компактная строка, сортируемая лексикографически: 16 hex + 8 hex + id.
    pub fn encode(&self) -> String {
        format!("{:016x}-{:08x}-{}", self.wall_ms, self.counter, self.device)
    }

    pub fn decode(s: &str) -> Option<Self> {
        let mut parts = s.splitn(3, '-');
        let wall_ms = u64::from_str_radix(parts.next()?, 16).ok()?;
        let counter = u32::from_str_radix(parts.next()?, 16).ok()?;
        let device = parts.next()?.to_string();
        if device.is_empty() {
            return None;
        }
        Some(Self { wall_ms, counter, device })
    }
}

impl PartialOrd for Hlc {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Hlc {
    fn cmp(&self, other: &Self) -> Ordering {
        self.wall_ms
            .cmp(&other.wall_ms)
            .then(self.counter.cmp(&other.counter))
            .then_with(|| self.device.cmp(&other.device))
    }
}

/// Генератор меток для одного устройства.
#[derive(Debug, Clone)]
pub struct Clock {
    device: String,
    last_wall: u64,
    counter: u32,
}

impl Clock {
    pub fn new(device: impl Into<String>) -> Self {
        Self { device: device.into(), last_wall: 0, counter: 0 }
    }

    /// Метка для локального события. `now_ms` передаётся снаружи (тестируемость).
    pub fn tick(&mut self, now_ms: u64) -> Hlc {
        if now_ms > self.last_wall {
            self.last_wall = now_ms;
            self.counter = 0;
        } else {
            self.counter += 1;
        }
        Hlc::new(self.last_wall, self.counter, self.device.clone())
    }

    /// Учёт метки, полученной от другого устройства.
    pub fn observe(&mut self, remote: &Hlc, now_ms: u64) -> Hlc {
        let max_wall = now_ms.max(self.last_wall).max(remote.wall_ms);
        if max_wall == self.last_wall && max_wall == remote.wall_ms {
            self.counter = self.counter.max(remote.counter) + 1;
        } else if max_wall == self.last_wall {
            self.counter += 1;
        } else if max_wall == remote.wall_ms {
            self.counter = remote.counter + 1;
        } else {
            self.counter = 0;
        }
        self.last_wall = max_wall;
        Hlc::new(self.last_wall, self.counter, self.device.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tick_is_monotonic_even_if_wall_clock_goes_back() {
        let mut c = Clock::new("a");
        let t1 = c.tick(1000);
        let t2 = c.tick(900); // часы откатились
        let t3 = c.tick(900);
        assert!(t1 < t2 && t2 < t3);
    }

    #[test]
    fn observe_never_goes_behind_remote() {
        let mut a = Clock::new("a");
        let remote = Hlc::new(5000, 7, "b");
        let t = a.observe(&remote, 1000);
        assert!(t > remote);
        let next = a.tick(1000);
        assert!(next > t);
    }

    #[test]
    fn encode_decode_roundtrip_and_sorting() {
        let a = Hlc::new(10, 1, "dev-a");
        let b = Hlc::new(10, 2, "dev-a");
        assert_eq!(Hlc::decode(&a.encode()), Some(a.clone()));
        assert!(a.encode() < b.encode());
    }

    #[test]
    fn decode_rejects_garbage() {
        assert!(Hlc::decode("nonsense").is_none());
        assert!(Hlc::decode("0000000000000001-00000001-").is_none());
    }
}
