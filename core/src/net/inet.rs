//! Связь через интернет: iroh (QUIC). Устройства находят друг друга по ключу (endpoint id),
//! соединяются напрямую или через relay-сервер, если напрямую не получается.
//!
//! iroh даёт только «трубу» между устройствами. Поверх неё идёт тот же Noise-канал и тот же
//! обмен, что и в локальной сети, поэтому проверка ключей семьи и сопряжение не меняются.
//! Сеансы синхронизации работают в обычных потоках, а async-мир iroh прячется за [`IrohStream`].

use super::channel::Transport;
use crate::{Error, Result};
use iroh::endpoint::presets;
use iroh::{Endpoint, EndpointId, SecretKey};
use std::io::{self, Read, Write};
use std::sync::Arc;
use std::time::Duration;
use tokio::runtime::{Handle, Runtime};

/// Протокол поверх QUIC: другие приложения iroh к нам не подключатся.
pub const ALPN: &[u8] = b"hydra-music/sync/1";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(25);

fn err<E: std::fmt::Display>(e: E) -> Error {
    Error::Invalid(e.to_string())
}

/// Один двусторонний поток iroh как обычное блокирующее соединение.
pub struct IrohStream {
    rt: Handle,
    send: iroh::endpoint::SendStream,
    recv: iroh::endpoint::RecvStream,
    conn: iroh::endpoint::Connection,
    timeout: Duration,
}

impl Read for IrohStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let rt = self.rt.clone();
        let t = self.timeout;
        let recv = &mut self.recv;
        let r = rt.block_on(async { tokio::time::timeout(t, recv.read(buf)).await });
        match r {
            Err(_) => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "время ожидания вышло",
            )),
            Ok(Err(e)) => Err(io::Error::new(io::ErrorKind::Other, e.to_string())),
            Ok(Ok(None)) => Ok(0),
            Ok(Ok(Some(n))) => Ok(n),
        }
    }
}

impl Write for IrohStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let rt = self.rt.clone();
        let t = self.timeout;
        let send = &mut self.send;
        let r = rt.block_on(async { tokio::time::timeout(t, send.write_all(buf)).await });
        match r {
            Err(_) => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "время ожидания вышло",
            )),
            Ok(Err(e)) => Err(io::Error::new(io::ErrorKind::Other, e.to_string())),
            Ok(Ok(())) => Ok(buf.len()),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Transport for IrohStream {
    fn set_timeout(&mut self, secs: u64) {
        self.timeout = Duration::from_secs(secs);
    }
}

impl Drop for IrohStream {
    fn drop(&mut self) {
        // Сначала закрываем свою сторону, потом ждём, пока собеседник дочитает и закроет
        // свою: иначе последние байты могли бы пропасть вместе с соединением.
        let _ = self.send.finish();
        let rt = self.rt.clone();
        let recv = &mut self.recv;
        let _ = rt.block_on(async {
            tokio::time::timeout(Duration::from_secs(2), async {
                let mut b = [0u8; 256];
                while let Ok(Some(_)) = recv.read(&mut b).await {}
            })
            .await
        });
        self.conn.close(0u32.into(), b"done");
    }
}

/// Узел iroh этого устройства: принимает и устанавливает соединения.
pub struct Inet {
    rt: Runtime,
    ep: Endpoint,
    id: String,
}

impl Inet {
    /// Поднимает узел. `secret` - постоянный ключ устройства для iroh (по нему устройство
    /// узнают из других сетей). Каждое входящее соединение отдаётся в `on_stream`
    /// в отдельном потоке.
    pub fn start(
        secret: [u8; 32],
        on_stream: Arc<dyn Fn(IrohStream) + Send + Sync + 'static>,
    ) -> Result<Arc<Inet>> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("hydra-iroh")
            .enable_all()
            .build()
            .map_err(err)?;
        let ep = rt
            .block_on(async {
                Endpoint::builder(presets::N0)
                    .secret_key(SecretKey::from_bytes(&secret))
                    .alpns(vec![ALPN.to_vec()])
                    .bind()
                    .await
            })
            .map_err(err)?;
        let id = ep.id().to_string();

        let handle = rt.handle().clone();
        let accept_ep = ep.clone();
        rt.spawn(async move {
            while let Some(incoming) = accept_ep.accept().await {
                let cb = Arc::clone(&on_stream);
                let h = handle.clone();
                tokio::spawn(async move {
                    let Ok(conn) = incoming.await else { return };
                    let Ok((send, recv)) = conn.accept_bi().await else {
                        return;
                    };
                    let stream = IrohStream {
                        rt: h,
                        send,
                        recv,
                        conn,
                        timeout: Duration::from_secs(20),
                    };
                    std::thread::spawn(move || cb(stream));
                });
            }
        });
        Ok(Arc::new(Inet { rt, ep, id }))
    }

    /// Адрес этого устройства для других (строка, её можно положить в QR и в приветствие).
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Соединяется с устройством по его адресу iroh.
    pub fn connect(&self, id: &str) -> Result<IrohStream> {
        let target: EndpointId = id
            .trim()
            .parse()
            .map_err(|e| err(format!("адрес устройства повреждён: {e}")))?;
        let ep = self.ep.clone();
        let handle = self.rt.handle().clone();
        let res = self.rt.block_on(async move {
            tokio::time::timeout(CONNECT_TIMEOUT, async move {
                let conn = ep.connect(target, ALPN).await.map_err(|e| e.to_string())?;
                let (send, recv) = conn.open_bi().await.map_err(|e| e.to_string())?;
                Ok::<IrohStream, String>(IrohStream {
                    rt: handle,
                    send,
                    recv,
                    conn,
                    timeout: Duration::from_secs(20),
                })
            })
            .await
        });
        match res {
            Err(_) => Err(err("устройство не отвечает")),
            Ok(Err(e)) => Err(err(e)),
            Ok(Ok(stream)) => Ok(stream),
        }
    }
}
