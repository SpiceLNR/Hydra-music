//! Ключ этого устройства и список доверенных устройств («семья»).

use super::channel::{generate_keys, Keys};
use super::{hex, now_ms, unhex};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize)]
struct KeyFile {
    private: String,
    public: String,
    /// Имя, выбранное пользователем в «Настройках». Нет поля (старые файлы) -
    /// используется имя по умолчанию, которое передаёт приложение.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

/// Самое длинное имя устройства (в символах).
pub const MAX_NAME_CHARS: usize = 40;

/// Приводит имя устройства в порядок: без управляющих символов и лишних пробелов,
/// не длиннее [`MAX_NAME_CHARS`]. `None`, если ничего не осталось.
pub fn clean_name(name: &str) -> Option<String> {
    let s: String = name
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let s: String = s.chars().take(MAX_NAME_CHARS).collect();
    let s = s.trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

pub struct Identity {
    pub keys: Keys,
    pub device_id: String,
    pub name: String,
}

impl Identity {
    /// Читает ключ из `identity.json` в папке данных или создаёт новый.
    /// [name] - имя по умолчанию; если пользователь выбрал своё, берётся оно.
    pub fn load_or_create(dir: &Path, device_id: &str, name: &str) -> Result<Identity> {
        let path = dir.join("identity.json");
        if let Ok(text) = fs::read_to_string(&path) {
            if let Ok(f) = serde_json::from_str::<KeyFile>(&text) {
                if let (Some(private), Some(public)) = (unhex(&f.private), unhex(&f.public)) {
                    let chosen = f.name.as_deref().and_then(clean_name);
                    return Ok(Identity {
                        keys: Keys { private, public },
                        device_id: device_id.to_string(),
                        name: chosen.unwrap_or_else(|| name.to_string()),
                    });
                }
            }
        }
        let keys = generate_keys()?;
        let f = KeyFile {
            private: hex(&keys.private),
            public: hex(&keys.public),
            name: None,
        };
        fs::create_dir_all(dir)?;
        fs::write(&path, serde_json::to_vec_pretty(&f)?)?;
        Ok(Identity {
            keys,
            device_id: device_id.to_string(),
            name: name.to_string(),
        })
    }

    pub fn public_hex(&self) -> String {
        hex(&self.keys.public)
    }

    /// Запоминает выбранное имя в `identity.json` (ключ не меняется).
    /// Возвращает очищенное имя.
    pub fn save_name(dir: &Path, name: &str) -> Result<String> {
        let name = clean_name(name)
            .ok_or_else(|| Error::Invalid("имя устройства не может быть пустым".into()))?;
        let path = dir.join("identity.json");
        let text = fs::read_to_string(&path)?;
        let mut f: KeyFile = serde_json::from_str(&text)?;
        f.name = Some(name.clone());
        let tmp = dir.join("identity.json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(&f)?)?;
        fs::rename(&tmp, &path)?;
        Ok(name)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Peer {
    pub device_id: String,
    pub name: String,
    /// Открытый ключ в hex.
    pub public_key: String,
    pub added_ms: u64,
    #[serde(default)]
    pub last_sync_ms: u64,
    /// Последний адрес `ip:порт`, по которому устройство отвечало.
    #[serde(default)]
    pub last_addr: String,
    /// Адрес для связи через интернет (id iroh); известен после первой синхронизации.
    #[serde(default)]
    pub endpoint: String,
    /// Имя, которое пользователь дал устройству у себя. Не затирается именем от самого устройства.
    #[serde(default)]
    pub alias: String,
}

/// Доверенные устройства. Хранятся в `family.json`.
pub struct Family {
    path: PathBuf,
    goodbye_path: PathBuf,
    pub peers: Vec<Peer>,
    /// Устройства, которые мы удалили, но ещё не сообщили им об этом (хранятся в `goodbye.json`).
    pub goodbyes: Vec<Peer>,
}

impl Family {
    pub fn load(dir: &Path) -> Family {
        let path = dir.join("family.json");
        let peers = fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str::<Vec<Peer>>(&t).ok())
            .unwrap_or_default();
        let goodbye_path = dir.join("goodbye.json");
        let goodbyes = fs::read_to_string(&goodbye_path)
            .ok()
            .and_then(|t| serde_json::from_str::<Vec<Peer>>(&t).ok())
            .unwrap_or_default();
        Family {
            path,
            goodbye_path,
            peers,
            goodbyes,
        }
    }

    fn save_goodbyes(&self) -> Result<()> {
        let tmp = self.goodbye_path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(&self.goodbyes)?)?;
        fs::rename(&tmp, &self.goodbye_path).map_err(Error::from)
    }

    /// Запоминает, что устройству надо сообщить об удалении (`added_ms` = когда удалили).
    pub fn queue_goodbye(&mut self, mut peer: Peer) -> Result<()> {
        peer.added_ms = now_ms();
        self.goodbyes.retain(|p| p.device_id != peer.device_id);
        self.goodbyes.push(peer);
        self.save_goodbyes()
    }

    pub fn done_goodbye(&mut self, device_id: &str) -> Result<()> {
        self.goodbyes.retain(|p| p.device_id != device_id);
        self.save_goodbyes()
    }

    /// Убирает записи старше `max_age_ms` (устройство так и не появилось).
    pub fn expire_goodbyes(&mut self, max_age_ms: u64) -> Result<()> {
        let now = now_ms();
        let before = self.goodbyes.len();
        self.goodbyes
            .retain(|p| now.saturating_sub(p.added_ms) < max_age_ms);
        if self.goodbyes.len() != before {
            self.save_goodbyes()?;
        }
        Ok(())
    }

    fn save(&self) -> Result<()> {
        let tmp = self.path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(&self.peers)?)?;
        fs::rename(&tmp, &self.path).map_err(Error::from)
    }

    pub fn by_key(&self, public: &[u8]) -> Option<&Peer> {
        let h = hex(public);
        self.peers.iter().find(|p| p.public_key == h)
    }

    pub fn by_id(&self, device_id: &str) -> Option<&Peer> {
        self.peers.iter().find(|p| p.device_id == device_id)
    }

    /// Добавляет устройство или обновляет запись с тем же id.
    pub fn upsert(&mut self, device_id: &str, name: &str, public: &[u8], addr: &str) -> Result<()> {
        let key = hex(public);
        if let Some(p) = self.peers.iter_mut().find(|p| p.device_id == device_id) {
            p.name = name.to_string();
            p.public_key = key;
            if !addr.is_empty() {
                p.last_addr = addr.to_string();
            }
        } else {
            self.peers.push(Peer {
                device_id: device_id.to_string(),
                name: name.to_string(),
                public_key: key,
                added_ms: now_ms(),
                last_sync_ms: 0,
                last_addr: addr.to_string(),
                endpoint: String::new(),
                alias: String::new(),
            });
        }
        self.save()
    }

    /// Своё имя для устройства; пустая строка возвращает имя, которое оно сообщает само.
    /// Возвращает `false`, если такого устройства нет.
    pub fn set_alias(&mut self, device_id: &str, alias: &str) -> Result<bool> {
        let alias: String = alias.trim().chars().take(40).collect();
        match self.peers.iter_mut().find(|p| p.device_id == device_id) {
            Some(p) => {
                p.alias = alias;
                self.save()?;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Запоминает адрес устройства для связи через интернет.
    pub fn set_endpoint(&mut self, device_id: &str, endpoint: &str) -> Result<()> {
        if let Some(p) = self.peers.iter_mut().find(|p| p.device_id == device_id) {
            if p.endpoint != endpoint {
                p.endpoint = endpoint.to_string();
                return self.save();
            }
        }
        Ok(())
    }

    pub fn touch(&mut self, device_id: &str, addr: &str) -> Result<()> {
        if let Some(p) = self.peers.iter_mut().find(|p| p.device_id == device_id) {
            p.last_sync_ms = now_ms();
            if !addr.is_empty() {
                p.last_addr = addr.to_string();
            }
        }
        self.save()
    }

    pub fn remove(&mut self, device_id: &str) -> Result<bool> {
        let before = self.peers.len();
        self.peers.retain(|p| p.device_id != device_id);
        self.save()?;
        Ok(self.peers.len() != before)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chosen_name_survives_restart_and_keeps_the_key() {
        let tmp = tempfile::tempdir().unwrap();
        let first = Identity::load_or_create(tmp.path(), "d1", "Телефон").unwrap();
        assert_eq!(first.name, "Телефон");
        assert_eq!(
            Identity::save_name(tmp.path(), "  Pixel   Даши\n ").unwrap(),
            "Pixel Даши"
        );
        let again = Identity::load_or_create(tmp.path(), "d1", "Телефон").unwrap();
        assert_eq!(
            again.name, "Pixel Даши",
            "выбранное имя важнее имени по умолчанию"
        );
        assert_eq!(again.keys.public, first.keys.public, "ключ не меняется");
        assert!(Identity::save_name(tmp.path(), " \t ").is_err());
        assert_eq!(
            Identity::load_or_create(tmp.path(), "d1", "Телефон")
                .unwrap()
                .name,
            "Pixel Даши"
        );
    }

    #[test]
    fn old_identity_file_without_name_still_loads() {
        let tmp = tempfile::tempdir().unwrap();
        let first = Identity::load_or_create(tmp.path(), "d1", "PC").unwrap();
        // файл старого формата: только ключи
        let old = serde_json::json!({
            "private": hex(&first.keys.private),
            "public": hex(&first.keys.public),
        });
        fs::write(tmp.path().join("identity.json"), old.to_string()).unwrap();
        let again = Identity::load_or_create(tmp.path(), "d1", "DESKTOP-1").unwrap();
        assert_eq!(again.name, "DESKTOP-1");
        assert_eq!(again.keys.public, first.keys.public);
    }

    #[test]
    fn clean_name_rules() {
        assert_eq!(clean_name("  a\u{0}b  c "), Some("a b c".to_string()));
        assert_eq!(clean_name(""), None);
        assert_eq!(clean_name("\n\t"), None);
        let long = "я".repeat(100);
        assert_eq!(clean_name(&long).unwrap().chars().count(), MAX_NAME_CHARS);
    }

    #[test]
    fn alias_survives_renames_by_the_device_and_restarts() {
        let tmp = tempfile::tempdir().unwrap();
        let mut f = Family::load(tmp.path());
        f.upsert("d1", "LAPTOP-1", &[1, 2, 3], "").unwrap();
        assert!(f.set_alias("d1", "  Ноутбук  ").unwrap());
        assert!(!f.set_alias("nope", "x").unwrap());
        // само устройство сообщило другое имя: своё мы не теряем
        f.upsert("d1", "LAPTOP-2", &[1, 2, 3], "").unwrap();
        let f = Family::load(tmp.path());
        let p = f.by_id("d1").unwrap();
        assert_eq!(p.alias, "Ноутбук");
        assert_eq!(p.name, "LAPTOP-2");
        // пустое имя возвращает исходное
        let mut f = f;
        f.set_alias("d1", "").unwrap();
        assert!(f.by_id("d1").unwrap().alias.is_empty());
    }
}
