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
}

pub struct Identity {
    pub keys: Keys,
    pub device_id: String,
    pub name: String,
}

impl Identity {
    /// Читает ключ из `identity.json` в папке данных или создаёт новый.
    pub fn load_or_create(dir: &Path, device_id: &str, name: &str) -> Result<Identity> {
        let path = dir.join("identity.json");
        if let Ok(text) = fs::read_to_string(&path) {
            if let Ok(f) = serde_json::from_str::<KeyFile>(&text) {
                if let (Some(private), Some(public)) = (unhex(&f.private), unhex(&f.public)) {
                    return Ok(Identity {
                        keys: Keys { private, public },
                        device_id: device_id.to_string(),
                        name: name.to_string(),
                    });
                }
            }
        }
        let keys = generate_keys()?;
        let f = KeyFile {
            private: hex(&keys.private),
            public: hex(&keys.public),
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
}

/// Доверенные устройства. Хранятся в `family.json`.
pub struct Family {
    path: PathBuf,
    pub peers: Vec<Peer>,
}

impl Family {
    pub fn load(dir: &Path) -> Family {
        let path = dir.join("family.json");
        let peers = fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str::<Vec<Peer>>(&t).ok())
            .unwrap_or_default();
        Family { path, peers }
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
            });
        }
        self.save()
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
