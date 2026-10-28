//! Шифрованный канал: Noise поверх TCP.
//!
//! Перед рукопожатием инициатор отправляет три открытых байта: `H`, `Y` и режим
//! (0 - обычное XX для уже знакомых устройств, 1 - XXpsk3 с секретом из QR-кода).
//! После рукопожатия обе стороны знают статический ключ друг друга (`remote_static`),
//! а общий для двух сторон 6-значный код получается из хэша рукопожатия.

use crate::{Error, Result};
use snow::{params::NoiseParams, Builder, HandshakeState, TransportState};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

/// Счётчик «эпохи» сеансов одного узла: когда он растёт, идущие сеансы этого узла обрываются.
pub type CancelEpoch = Arc<AtomicU64>;

/// Любое двустороннее соединение, по которому идёт Noise: TCP в локальной сети
/// или поток iroh через интернет.
pub trait Transport: Read + Write + Send {
    /// Предельное время ожидания чтения и записи.
    fn set_timeout(&mut self, secs: u64);
}

impl Transport for Box<dyn Transport> {
    fn set_timeout(&mut self, secs: u64) {
        (**self).set_timeout(secs);
    }
}

impl Transport for TcpStream {
    fn set_timeout(&mut self, secs: u64) {
        let d = Some(std::time::Duration::from_secs(secs));
        let _ = self.set_read_timeout(d);
        let _ = self.set_write_timeout(d);
    }
}

const NOISE_XX: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
const NOISE_XXPSK3: &str = "Noise_XXpsk3_25519_ChaChaPoly_SHA256";
const MAX_FRAME: usize = 65535;
/// Открытый текст в одном кадре; вместе с тегом (16 байт) укладывается в 65535.
const CHUNK: usize = 60_000;
/// Верхняя граница одного сообщения (защита от мусора в заголовке).
const MAX_MESSAGE: u64 = 256 * 1024 * 1024;

fn noise<E: std::fmt::Display>(e: E) -> Error {
    Error::Invalid(format!("шифрованный канал: {e}"))
}

fn params(psk: bool) -> Result<NoiseParams> {
    let s = if psk { NOISE_XXPSK3 } else { NOISE_XX };
    s.parse().map_err(noise)
}

pub struct Keys {
    pub private: Vec<u8>,
    pub public: Vec<u8>,
}

pub fn generate_keys() -> Result<Keys> {
    let kp = Builder::new(params(false)?)
        .generate_keypair()
        .map_err(noise)?;
    Ok(Keys {
        private: kp.private,
        public: kp.public,
    })
}

fn write_frame<W: Write>(w: &mut W, data: &[u8]) -> Result<()> {
    w.write_all(&(data.len() as u16).to_be_bytes())?;
    w.write_all(data)?;
    w.flush()?;
    Ok(())
}

fn read_frame<R: Read>(r: &mut R) -> Result<Vec<u8>> {
    let mut h = [0u8; 2];
    r.read_exact(&mut h)?;
    let mut buf = vec![0u8; u16::from_be_bytes(h) as usize];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

/// Установленный защищённый канал.
pub struct Secure {
    stream: Box<dyn Transport>,
    transport: TransportState,
    /// Открытый ключ собеседника (проверен рукопожатием).
    pub remote_static: Vec<u8>,
    /// 6 цифр, одинаковые на обоих устройствах.
    pub code: String,
    epoch: u64,
    cancel: CancelEpoch,
}

fn builder_with<'a>(p: NoiseParams, keys: &'a Keys, psk: &'a Option<[u8; 32]>) -> Builder<'a> {
    let mut b = Builder::new(p).local_private_key(&keys.private);
    if let Some(k) = psk {
        b = b.psk(3, k);
    }
    b
}

fn finish(stream: Box<dyn Transport>, hs: HandshakeState) -> Result<Secure> {
    if !hs.is_handshake_finished() {
        return Err(noise("рукопожатие не завершено"));
    }
    let remote_static = hs
        .get_remote_static()
        .ok_or_else(|| noise("нет ключа собеседника"))?
        .to_vec();
    let h = hs.get_handshake_hash();
    let n = if h.len() >= 4 {
        u32::from_be_bytes([h[0], h[1], h[2], h[3]])
    } else {
        0
    };
    let code = format!("{:06}", n % 1_000_000);
    let transport = hs.into_transport_mode().map_err(noise)?;
    Ok(Secure {
        stream,
        transport,
        remote_static,
        code,
        epoch: 0,
        cancel: Arc::new(AtomicU64::new(0)),
    })
}

/// Сторона, которая подключилась. `psk` - секрет из QR при сопряжении.
pub fn handshake_initiator<S: Transport + 'static>(
    mut stream: S,
    keys: &Keys,
    psk: Option<[u8; 32]>,
) -> Result<Secure> {
    stream.write_all(&[b'H', b'Y', if psk.is_some() { 1 } else { 0 }])?;
    let mut hs = builder_with(params(psk.is_some())?, keys, &psk)
        .build_initiator()
        .map_err(noise)?;
    let mut buf = vec![0u8; MAX_FRAME];
    // -> e
    let n = hs.write_message(&[], &mut buf).map_err(noise)?;
    write_frame(&mut stream, &buf[..n])?;
    // <- e, ee, s, es
    let m = read_frame(&mut stream)?;
    hs.read_message(&m, &mut buf).map_err(noise)?;
    // -> s, se (и psk)
    let n = hs.write_message(&[], &mut buf).map_err(noise)?;
    write_frame(&mut stream, &buf[..n])?;
    finish(Box::new(stream), hs)
}

/// Сторона, которая приняла подключение. `psk` - секрет активного предложения сопряжения
/// (если оно есть). Возвращает канал и признак «это сопряжение».
pub fn handshake_responder<S: Transport + 'static>(
    mut stream: S,
    keys: &Keys,
    psk: Option<[u8; 32]>,
) -> Result<(Secure, bool)> {
    let mut head = [0u8; 3];
    stream.read_exact(&mut head)?;
    if head[0] != b'H' || head[1] != b'Y' || head[2] > 1 {
        return Err(noise("это не Hydra Music"));
    }
    let pairing = head[2] == 1;
    let key = if pairing {
        Some(psk.ok_or_else(|| noise("сопряжение сейчас не открыто на этом устройстве"))?)
    } else {
        None
    };
    let mut hs = builder_with(params(pairing)?, keys, &key)
        .build_responder()
        .map_err(noise)?;
    let mut buf = vec![0u8; MAX_FRAME];
    // <- e
    let m = read_frame(&mut stream)?;
    hs.read_message(&m, &mut buf).map_err(noise)?;
    // -> e, ee, s, es
    let n = hs.write_message(&[], &mut buf).map_err(noise)?;
    write_frame(&mut stream, &buf[..n])?;
    // <- s, se (и psk)
    let m = read_frame(&mut stream)?;
    hs.read_message(&m, &mut buf).map_err(noise)?;
    Ok((finish(Box::new(stream), hs)?, pairing))
}

impl Secure {
    fn send_frame(&mut self, plain: &[u8]) -> Result<()> {
        let mut out = vec![0u8; plain.len() + 16];
        let n = self
            .transport
            .write_message(plain, &mut out)
            .map_err(noise)?;
        write_frame(&mut self.stream, &out[..n])
    }

    fn recv_frame(&mut self) -> Result<Vec<u8>> {
        let enc = read_frame(&mut self.stream)?;
        let mut out = vec![0u8; enc.len()];
        let n = self.transport.read_message(&enc, &mut out).map_err(noise)?;
        out.truncate(n);
        Ok(out)
    }

    /// Отправляет сообщение любой длины (до 256 МБ).
    /// Привязывает сеанс к узлу: его `cancel` обрывает этот сеанс при следующей передаче данных.
    pub fn bind_cancel(&mut self, cancel: &CancelEpoch) {
        self.epoch = cancel.load(Ordering::SeqCst);
        self.cancel = Arc::clone(cancel);
    }

    fn check_cancel(&self) -> Result<()> {
        if self.epoch != self.cancel.load(Ordering::SeqCst) {
            return Err(noise("синхронизация остановлена"));
        }
        Ok(())
    }

    pub fn send(&mut self, data: &[u8]) -> Result<()> {
        self.check_cancel()?;
        self.send_frame(&(data.len() as u64).to_be_bytes())?;
        for chunk in data.chunks(CHUNK) {
            self.send_frame(chunk)?;
        }
        Ok(())
    }

    pub fn recv(&mut self) -> Result<Vec<u8>> {
        self.check_cancel()?;
        let head = self.recv_frame()?;
        let head: [u8; 8] = head
            .try_into()
            .map_err(|_| noise("повреждён заголовок сообщения"))?;
        let total = u64::from_be_bytes(head);
        if total > MAX_MESSAGE {
            return Err(noise("слишком большое сообщение"));
        }
        let total = total as usize;
        let mut v = Vec::with_capacity(total.min(1 << 20));
        while v.len() < total {
            let part = self.recv_frame()?;
            if part.is_empty() {
                return Err(noise("пустой кадр"));
            }
            v.extend_from_slice(&part);
        }
        if v.len() != total {
            return Err(noise("длина сообщения не сошлась"));
        }
        Ok(v)
    }

    pub fn set_timeout(&mut self, secs: u64) {
        self.stream.set_timeout(secs);
    }
}
