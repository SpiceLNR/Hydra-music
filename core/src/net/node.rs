//! Фоновая работа сети: приём подключений, обнаружение устройств, сопряжение и сеансы.
//!
//! Одновременно идёт только один сеанс (два сеанса вперемешку портили бы друг другу
//! состояние библиотеки). Входящее подключение во время чужого сеанса просто отклоняется:
//! другое устройство повторит попытку позже.

use super::channel::{handshake_initiator, handshake_responder, Secure, Transport};
use super::identity::{Family, Identity};
use super::session::{run_session, Hello, LibHandle, Role, SessionReport};
use super::{hex, now_ms, unhex};
use crate::{Error, Result};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

pub const TCP_PORT: u16 = 47475;
pub const DISCOVERY_PORT: u16 = 47476;
const OFFER_TTL: Duration = Duration::from_secs(180);
const ONLINE_MS: u64 = 20_000;

/// Одноразовое предложение сопряжения (его секрет лежит в QR-коде).
pub struct Offer {
    secret: [u8; 32],
    created: Instant,
}

#[derive(Default)]
struct Status {
    port: u16,
    busy: bool,
    message: String,
    error: String,
    /// Растёт после каждого успешного сеанса: по нему интерфейс понимает, что пора обновить списки.
    generation: u64,
    /// Растёт, когда в семью добавлено устройство.
    family_generation: u64,
    log: VecDeque<String>,
    report: Option<Value>,
    /// device_id -> (адрес ip:порт, когда замечено)
    found: HashMap<String, (String, u64)>,
    /// Адрес этого устройства в интернете (iroh); пусто, пока связь через интернет не поднята.
    endpoint: String,
    /// Почему связь через интернет не заработала (пусто, если всё в порядке или не включалась).
    internet_error: String,
}

pub struct Node<H> {
    ident: Identity,
    family: Mutex<Family>,
    handle: Arc<H>,
    offer: Mutex<Option<Offer>>,
    session: Mutex<()>,
    st: Mutex<Status>,
    /// Когда в последний раз пытались сообщить удалённым устройствам об удалении.
    last_goodbye: AtomicU64,
    #[cfg(feature = "internet")]
    inet: Mutex<Option<Arc<super::inet::Inet>>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

fn bad<E: std::fmt::Display>(e: E) -> Error {
    Error::Invalid(e.to_string())
}

/// Каким путём установлено соединение (для сообщений об ошибках).
fn via_text(addr: &str) -> String {
    if addr.is_empty() {
        "через интернет".to_string()
    } else {
        format!("по сети, {addr}")
    }
}

/// Сбой на этапе рукопожатия: чаще всего собеседник сразу закрыл соединение.
fn explain(e: Error, via: &str) -> Error {
    let text = e.to_string();
    if text.contains("fill whole buffer") || text.contains("unexpected end") {
        bad(format!(
            "устройство ответило и закрыло соединение ({via}). Проверьте, что QR-код на втором \
             устройстве ещё действует (3 минуты) и что на нём не идёт другая синхронизация; \
             причина записана в журнале того устройства"
        ))
    } else {
        bad(format!("{text} ({via})"))
    }
}

fn key32(secret_hex: &str) -> Result<[u8; 32]> {
    let v = unhex(secret_hex).ok_or_else(|| bad("секрет сопряжения повреждён"))?;
    v.try_into().map_err(|_| bad("секрет сопряжения повреждён"))
}

impl<H: LibHandle + Send + Sync + 'static> Node<H> {
    pub fn new(ident: Identity, family: Family, handle: Arc<H>) -> Arc<Node<H>> {
        Arc::new(Node {
            ident,
            family: Mutex::new(family),
            handle,
            offer: Mutex::new(None),
            session: Mutex::new(()),
            st: Mutex::new(Status::default()),
            last_goodbye: AtomicU64::new(0),
            #[cfg(feature = "internet")]
            inet: Mutex::new(None),
        })
    }

    fn log(&self, text: &str) {
        let mut st = lock(&self.st);
        // время в мс UTC и текст через табуляцию; приложение покажет местное время
        st.log.push_back(format!("{}\t{}", super::now_ms(), text));
        while st.log.len() > 100 {
            st.log.pop_front();
        }
    }

    fn set_message(&self, text: &str) {
        // строки с «#» - подробности для журнала, а не статус
        if let Some(d) = text.strip_prefix('#') {
            self.log(d);
            return;
        }
        lock(&self.st).message = text.to_string();
    }

    fn try_session(&self) -> Option<MutexGuard<'_, ()>> {
        match self.session.try_lock() {
            Ok(g) => Some(g),
            Err(TryLockError::Poisoned(p)) => Some(p.into_inner()),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    fn hello(&self) -> Hello {
        let port = lock(&self.st).port;
        let endpoint = lock(&self.st).endpoint.clone();
        Hello::new(&self.ident.device_id, &self.ident.name, port).with_endpoint(endpoint)
    }

    // ---------- интернет (iroh) ----------

    /// Включает связь через интернет с постоянным ключом `secret`. Ошибка не мешает работе
    /// в локальной сети: причина видна в `status` (`internet_error`).
    #[cfg(feature = "internet")]
    pub fn enable_internet(self: &Arc<Self>, secret: [u8; 32]) -> Result<()> {
        if lock(&self.inet).is_some() {
            return Ok(());
        }
        let me = Arc::clone(self);
        let on_stream: Arc<dyn Fn(super::inet::IrohStream) + Send + Sync> =
            Arc::new(move |stream| Arc::clone(&me).incoming(Box::new(stream), String::new()));
        match super::inet::Inet::start(secret, on_stream) {
            Ok(inet) => {
                let id = inet.id().to_string();
                *lock(&self.inet) = Some(inet);
                let mut st = lock(&self.st);
                st.endpoint = id;
                st.internet_error.clear();
                drop(st);
                self.log("Связь через интернет включена");
                Ok(())
            }
            Err(e) => {
                lock(&self.st).internet_error = e.to_string();
                self.log(&format!("Связь через интернет не запустилась: {e}"));
                Err(e)
            }
        }
    }

    #[cfg(not(feature = "internet"))]
    pub fn enable_internet(self: &Arc<Self>, _secret: [u8; 32]) -> Result<()> {
        lock(&self.st).internet_error = "сборка без связи через интернет".to_string();
        Err(bad("сборка без связи через интернет"))
    }

    #[cfg(feature = "internet")]
    fn connect_inet(&self, endpoint: &str) -> Result<Box<dyn Transport>> {
        let inet = lock(&self.inet)
            .clone()
            .ok_or_else(|| bad("связь через интернет не включена"))?;
        Ok(Box::new(inet.connect(endpoint)?))
    }

    #[cfg(not(feature = "internet"))]
    fn connect_inet(&self, _endpoint: &str) -> Result<Box<dyn Transport>> {
        Err(bad("сборка без связи через интернет"))
    }

    /// Подключается и проходит рукопожатие: сначала по локальной сети, потом (если разрешено)
    /// через интернет. Если по сети соединение есть, но рукопожатие не прошло (например,
    /// VPN или чужое устройство на том же адресе), пробуется интернет.
    fn dial_secure(
        &self,
        addrs: &[String],
        endpoint: &str,
        internet: bool,
        psk: Option<[u8; 32]>,
    ) -> Result<(Secure, String)> {
        let mut notes: Vec<String> = Vec::new();
        if !addrs.is_empty() {
            match Self::connect(addrs) {
                Ok((mut s, a)) => {
                    // по своей сети ответ приходит быстро: долго ждать нечего
                    s.set_timeout(8);
                    match handshake_initiator(s, &self.ident.keys, psk) {
                        Ok(mut ch) => {
                            ch.set_timeout(20);
                            return Ok((ch, a));
                        }
                        Err(e) => notes.push(explain(e, &via_text(&a)).to_string()),
                    }
                }
                Err(e) => notes.push(e.to_string()),
            }
        }
        if internet && !endpoint.is_empty() {
            self.log("Подключаюсь через интернет");
            match self.connect_inet(endpoint) {
                Ok(s) => match handshake_initiator(s, &self.ident.keys, psk) {
                    Ok(ch) => return Ok((ch, String::new())),
                    Err(e) => notes.push(explain(e, &via_text("")).to_string()),
                },
                Err(e) => notes.push(format!("через интернет: {e}")),
            }
        }
        if notes.is_empty() {
            Err(bad("нет адреса устройства"))
        } else {
            Err(bad(notes.join("; ")))
        }
    }

    // ---------- запуск ----------

    /// Начинает слушать порт и искать устройства. Повторный вызов ничего не меняет.
    /// Возвращает порт.
    pub fn start(self: &Arc<Self>) -> Result<u16> {
        if lock(&self.st).port != 0 {
            return Ok(lock(&self.st).port);
        }
        let listener = TcpListener::bind(("0.0.0.0", TCP_PORT))
            .or_else(|_| TcpListener::bind(("0.0.0.0", 0)))?;
        let port = listener.local_addr()?.port();
        lock(&self.st).port = port;
        self.log(&format!("Слушаю порт {port}"));

        let me = Arc::clone(self);
        thread::spawn(move || {
            for conn in listener.incoming() {
                let Ok(stream) = conn else { continue };
                let node = Arc::clone(&me);
                let ip = stream
                    .peer_addr()
                    .map(|a| a.ip().to_string())
                    .unwrap_or_default();
                thread::spawn(move || node.incoming(Box::new(stream), ip));
            }
        });
        self.start_discovery(port);
        // сообщения об удалении, которые не дошли (устройство было далеко): повтор через интернет
        let me = Arc::clone(self);
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(300));
            me.send_goodbyes();
        });
        Ok(port)
    }

    fn start_discovery(self: &Arc<Self>, port: u16) {
        // объявляем себя
        let me = Arc::clone(self);
        thread::spawn(move || {
            let Ok(sock) = UdpSocket::bind("0.0.0.0:0") else {
                return;
            };
            let _ = sock.set_broadcast(true);
            let msg = format!("HYDRA1|{}|{}", me.ident.device_id, port);
            loop {
                let _ = sock.send_to(msg.as_bytes(), ("255.255.255.255", DISCOVERY_PORT));
                thread::sleep(Duration::from_secs(5));
            }
        });
        // слушаем остальных
        let me = Arc::clone(self);
        thread::spawn(move || {
            let sock = match UdpSocket::bind(("0.0.0.0", DISCOVERY_PORT)) {
                Ok(s) => s,
                Err(e) => {
                    me.log(&format!("Поиск устройств недоступен: {e}"));
                    return;
                }
            };
            let mut buf = [0u8; 256];
            loop {
                let Ok((n, src)) = sock.recv_from(&mut buf) else {
                    continue;
                };
                let Ok(text) = std::str::from_utf8(&buf[..n]) else {
                    continue;
                };
                let parts: Vec<&str> = text.split('|').collect();
                if parts.len() != 3 || parts[0] != "HYDRA1" || parts[1] == me.ident.device_id {
                    continue;
                }
                let Ok(p) = parts[2].parse::<u16>() else {
                    continue;
                };
                // запоминаем только своих: чужие устройства нас не интересуют
                let (member, waiting) = {
                    let fam = lock(&me.family);
                    (
                        fam.by_id(parts[1]).is_some(),
                        fam.goodbyes.iter().any(|g| g.device_id == parts[1]),
                    )
                };
                if member || waiting {
                    let addr = format!("{}:{}", src.ip(), p);
                    lock(&me.st)
                        .found
                        .insert(parts[1].to_string(), (addr, now_ms()));
                }
                if waiting {
                    me.send_goodbyes();
                }
            }
        });
    }

    // ---------- сопряжение ----------

    /// Новое предложение сопряжения: секрет живёт 3 минуты и работает один раз.
    pub fn pair_offer(&self) -> Value {
        let mut secret = [0u8; 32];
        secret[..16].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
        secret[16..].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
        *lock(&self.offer) = Some(Offer {
            secret,
            created: Instant::now(),
        });
        json!({
            "device_id": self.ident.device_id,
            "name": self.ident.name,
            "public_key": self.ident.public_hex(),
            "secret": hex(&secret),
            "port": lock(&self.st).port,
            "endpoint": lock(&self.st).endpoint,
            "ttl_secs": OFFER_TTL.as_secs(),
        })
    }

    pub fn pair_cancel(&self) {
        *lock(&self.offer) = None;
    }

    fn current_psk(&self) -> Option<[u8; 32]> {
        let mut o = lock(&self.offer);
        let secret = o
            .as_ref()
            .filter(|x| x.created.elapsed() <= OFFER_TTL)
            .map(|x| x.secret);
        if secret.is_none() {
            *o = None;
        }
        secret
    }

    // ---------- входящие ----------

    /// Входящее соединение: из локальной сети (`ip` - адрес собеседника) или из интернета (`ip` пусто).
    fn incoming(self: Arc<Self>, mut stream: Box<dyn Transport>, ip: String) {
        stream.set_timeout(20);
        let Some(_guard) = self.try_session() else {
            self.log("Входящее подключение отклонено: уже идёт другая синхронизация");
            return; // занято: собеседник повторит попытку
        };
        lock(&self.st).busy = true;
        lock(&self.st).error.clear();
        let res = self.incoming_session(stream, &ip);
        match &res {
            Ok(_) => {}
            // чужие/случайные подключения (сканеры портов и т. п.) не показываем как сбой
            Err(e) => {
                let from = if ip.is_empty() {
                    "из интернета".to_string()
                } else {
                    ip.clone()
                };
                self.log(&format!("Входящее подключение ({from}): {e}"))
            }
        }
        self.finish(res, true);
    }

    fn incoming_session(&self, stream: Box<dyn Transport>, ip: &str) -> Result<SessionReport> {
        let (mut ch, pairing) = handshake_responder(stream, &self.ident.keys, self.current_psk())?;
        let key = ch.remote_static.clone();
        let known = lock(&self.family).by_key(&key).cloned();
        if !pairing && known.is_none() {
            return Err(bad("устройство не входит в семью"));
        }
        self.set_message(if pairing {
            "Сопряжение"
        } else {
            "Синхронизация"
        });
        let verify = |hello: &Hello| -> Result<()> {
            let addr = if hello.port == 0 || ip.is_empty() {
                String::new()
            } else {
                format!("{ip}:{}", hello.port)
            };
            self.verify(
                hello,
                &key,
                pairing,
                known.as_ref().map(|p| p.device_id.as_str()),
                &addr,
            )
        };
        run_session(
            &mut ch,
            &*self.handle,
            Role::Responder,
            &self.hello(),
            &verify,
            &|m| self.set_message(m),
        )
    }

    /// Проверка собеседника после приветствия.
    fn verify(
        &self,
        hello: &Hello,
        key: &[u8],
        pairing: bool,
        expected_id: Option<&str>,
        addr: &str,
    ) -> Result<()> {
        if hello.device_id == self.ident.device_id {
            return Err(bad("нельзя синхронизироваться с самим собой"));
        }
        if pairing {
            lock(&self.family).upsert(&hello.device_id, &hello.name, key, addr)?;
            lock(&self.family).set_endpoint(&hello.device_id, &hello.endpoint)?;
            *lock(&self.offer) = None;
            lock(&self.st).family_generation += 1;
            self.log(&format!("Добавлено устройство «{}»", hello.name));
            Ok(())
        } else if expected_id == Some(hello.device_id.as_str()) && hello.goodbye {
            // собеседник убрал нас из своего списка: убираем и его
            let name = lock(&self.family)
                .by_id(&hello.device_id)
                .map(|p| p.name.clone())
                .unwrap_or_else(|| hello.name.clone());
            lock(&self.family).remove(&hello.device_id)?;
            lock(&self.st).family_generation += 1;
            self.log(&format!(
                "«{name}» удалило это устройство из своего списка: оно убрано и у нас"
            ));
            Ok(())
        } else if expected_id == Some(hello.device_id.as_str()) {
            // обновляем последний известный адрес (он мог смениться)
            lock(&self.family).upsert(&hello.device_id, &hello.name, key, addr)?;
            lock(&self.family).set_endpoint(&hello.device_id, &hello.endpoint)?;
            Ok(())
        } else {
            Err(bad("устройство представилось чужим именем"))
        }
    }

    // ---------- исходящие ----------

    fn connect(addrs: &[String]) -> Result<(TcpStream, String)> {
        let mut errors: Vec<String> = Vec::new();
        for a in addrs {
            let Ok(sa) = a.parse::<SocketAddr>() else {
                continue;
            };
            match TcpStream::connect_timeout(&sa, Duration::from_secs(4)) {
                Ok(s) => {
                    let _ = s.set_read_timeout(Some(Duration::from_secs(20)));
                    let _ = s.set_write_timeout(Some(Duration::from_secs(20)));
                    return Ok((s, a.clone()));
                }
                Err(e) => errors.push(format!("{a}: {e}")),
            }
        }
        if errors.is_empty() {
            return Err(bad("нет адреса устройства"));
        }
        Err(bad(format!(
            "не удалось подключиться ({})",
            errors.join("; ")
        )))
    }

    /// Запускает задачу в фоне. Состояние смотрите через `status`.
    fn spawn_job(
        self: &Arc<Self>,
        title: &str,
        job: impl FnOnce(&Arc<Self>) -> Result<SessionReport> + Send + 'static,
    ) {
        let me = Arc::clone(self);
        let title = title.to_string();
        thread::spawn(move || {
            let Some(_guard) = me.try_session() else {
                me.fail("Уже идёт другая синхронизация, подождите");
                return;
            };
            {
                let mut st = lock(&me.st);
                st.busy = true;
                st.error.clear();
                st.message = title;
            }
            let res = job(&me);
            me.finish(res, false);
        });
    }

    fn fail(&self, text: &str) {
        let mut st = lock(&self.st);
        st.error = text.to_string();
        st.message.clear();
        st.busy = false;
        drop(st);
        self.log(text);
    }

    fn finish(&self, res: Result<SessionReport>, incoming: bool) {
        match res {
            Ok(rep) if rep.goodbye => {
                let mut st = lock(&self.st);
                st.busy = false;
                st.message.clear();
            }
            Ok(rep) => {
                let _ = lock(&self.family).touch(&rep.peer_device_id, "");
                let mut st = lock(&self.st);
                st.busy = false;
                st.generation += 1;
                st.message = "Готово".to_string();
                st.report = serde_json::to_value(&rep).ok();
                drop(st);
                self.log(&format!(
                    "Синхронизация с «{}»: получено файлов {}, отправлено {}",
                    rep.peer_name, rep.files_received, rep.files_sent
                ));
            }
            Err(e) => {
                let mut st = lock(&self.st);
                st.busy = false;
                st.message.clear();
                // входящие сбои (чужие подключения) в «ошибку» не выносим
                if !incoming {
                    st.error = e.to_string();
                }
                drop(st);
                if !incoming {
                    self.log(&format!("Ошибка: {e}"));
                }
            }
        }
    }

    /// Подключиться к устройству по данным из QR-кода и добавить его в семью.
    pub fn pair_with(
        self: &Arc<Self>,
        addrs: Vec<String>,
        public_hex: &str,
        secret_hex: &str,
    ) -> Result<()> {
        self.pair_with_ex(addrs, String::new(), true, public_hex, secret_hex)
    }

    /// То же, но с адресом устройства в интернете. `internet = false` запрещает идти через интернет.
    pub fn pair_with_ex(
        self: &Arc<Self>,
        addrs: Vec<String>,
        endpoint: String,
        internet: bool,
        public_hex: &str,
        secret_hex: &str,
    ) -> Result<()> {
        let psk = key32(secret_hex)?;
        let expected = unhex(public_hex).ok_or_else(|| bad("ключ устройства повреждён"))?;
        self.spawn_job("Сопряжение", move |me| {
            let (mut ch, addr) = me.dial_secure(&addrs, &endpoint, internet, Some(psk))?;
            if ch.remote_static != expected {
                return Err(bad("ключ устройства не совпал с QR-кодом"));
            }
            let key = ch.remote_static.clone();
            let verify = |hello: &Hello| me.verify(hello, &key, true, None, &addr);
            run_session(
                &mut ch,
                &*me.handle,
                Role::Initiator,
                &me.hello(),
                &verify,
                &|m| me.set_message(m),
            )
        });
        Ok(())
    }

    /// Синхронизация с устройством из семьи.
    pub fn sync_peer(self: &Arc<Self>, device_id: &str) -> Result<()> {
        self.sync_peer_ex(device_id, true)
    }

    /// `internet = false` запрещает идти через интернет (например, на мобильной сети).
    pub fn sync_peer_ex(self: &Arc<Self>, device_id: &str, internet: bool) -> Result<()> {
        let peer = lock(&self.family)
            .by_id(device_id)
            .cloned()
            .ok_or_else(|| bad("такого устройства нет в семье"))?;
        let found = lock(&self.st).found.get(device_id).cloned();
        let mut addrs = Vec::new();
        if let Some((a, seen)) = found {
            if now_ms().saturating_sub(seen) < ONLINE_MS * 3 {
                addrs.push(a);
            }
        }
        let by_internet = internet && !peer.endpoint.is_empty();
        // старый адрес из прошлой синхронизации пробуем, только если интернет не вариант:
        // вдали от дома это лишние секунды ожидания
        if !by_internet && !peer.last_addr.is_empty() && !addrs.contains(&peer.last_addr) {
            addrs.push(peer.last_addr.clone());
        }
        if addrs.is_empty() && !by_internet {
            return Err(bad(format!("«{}» сейчас не видно в сети", peer.name)));
        }
        let endpoint = peer.endpoint.clone();
        let title = format!("Синхронизация с «{}»", peer.name);
        self.spawn_job(&title, move |me| {
            let (mut ch, addr) = me.dial_secure(&addrs, &endpoint, internet, None)?;
            if hex(&ch.remote_static) != peer.public_key {
                return Err(bad(
                    "ключ устройства изменился: отзовите его и добавьте заново",
                ));
            }
            let key = ch.remote_static.clone();
            let id = peer.device_id.clone();
            let verify = |hello: &Hello| me.verify(hello, &key, false, Some(&id), &addr);
            let rep = run_session(
                &mut ch,
                &*me.handle,
                Role::Initiator,
                &me.hello(),
                &verify,
                &|m| me.set_message(m),
            )?;
            let _ = lock(&me.family).touch(&id, &addr);
            Ok(rep)
        });
        Ok(())
    }

    // ---------- состояние для интерфейса ----------

    /// Убирает устройство из семьи и сообщает ему об этом, чтобы оно убрало и нас.
    /// Если устройство сейчас недоступно, сообщение уйдёт, как только оно появится.
    pub fn forget(self: &Arc<Self>, device_id: &str) -> Result<bool> {
        // удаляя устройство, обрываем и идущую синхронизацию
        super::channel::cancel_sessions();
        let found = lock(&self.st).found.remove(device_id);
        let peer = lock(&self.family).by_id(device_id).cloned();
        let removed = lock(&self.family).remove(device_id)?;
        if let Some(mut p) = peer {
            if let Some((addr, _)) = found {
                p.last_addr = addr;
            }
            lock(&self.family).queue_goodbye(p)?;
            self.last_goodbye.store(0, Ordering::SeqCst);
            self.send_goodbyes();
        }
        Ok(removed)
    }

    /// Сообщает удалённым устройствам, что мы их убрали (в фоне). Пока устройство не
    /// отозвалось, сообщение хранится до 14 дней.
    pub fn send_goodbyes(self: &Arc<Self>) {
        const MAX_AGE_MS: u64 = 14 * 24 * 3600 * 1000;
        {
            let mut fam = lock(&self.family);
            let _ = fam.expire_goodbyes(MAX_AGE_MS);
            if fam.goodbyes.is_empty() {
                return;
            }
        }
        // не чаще раза в 20 секунд, чтобы не стучаться на каждый сигнал поиска
        let now = now_ms();
        let last = self.last_goodbye.swap(now, Ordering::SeqCst);
        if now.saturating_sub(last) < 20_000 {
            return;
        }
        let me = Arc::clone(self);
        thread::spawn(move || {
            let pending = lock(&me.family).goodbyes.clone();
            for peer in pending {
                // только что оборванный сеанс освобождает замок не мгновенно
                let mut guard = me.try_session();
                for _ in 0..10 {
                    if guard.is_some() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(300));
                    guard = me.try_session();
                }
                let Some(_guard) = guard else {
                    return; // занято: попробуем позже
                };
                let found = lock(&me.st).found.get(&peer.device_id).cloned();
                let mut addrs = Vec::new();
                if let Some((a, seen)) = found {
                    if now_ms().saturating_sub(seen) < ONLINE_MS * 3 {
                        addrs.push(a);
                    }
                }
                if !peer.last_addr.is_empty() && !addrs.contains(&peer.last_addr) {
                    addrs.push(peer.last_addr.clone());
                }
                let res =
                    me.dial_secure(&addrs, &peer.endpoint, true, None)
                        .and_then(|(mut ch, _)| {
                            if hex(&ch.remote_static) != peer.public_key {
                                return Err(bad("ключ устройства изменился"));
                            }
                            let id = peer.device_id.clone();
                            let verify = |h: &Hello| {
                                if h.device_id == id {
                                    Ok(())
                                } else {
                                    Err(bad("устройство представилось чужим именем"))
                                }
                            };
                            run_session(
                                &mut ch,
                                &*me.handle,
                                Role::Initiator,
                                &me.hello().with_goodbye(),
                                &verify,
                                &|_| {},
                            )
                        });
                match res {
                    Ok(_) => {
                        let _ = lock(&me.family).done_goodbye(&peer.device_id);
                        me.log(&format!("«{}» уведомлено об удалении", peer.name));
                    }
                    Err(e) => me.log(&format!(
                        "«{}» пока не уведомлено об удалении: {e}",
                        peer.name
                    )),
                }
            }
        });
    }

    /// Переименовывает устройство только у нас (пустое имя возвращает исходное).
    pub fn rename_peer(&self, device_id: &str, name: &str) -> Result<bool> {
        lock(&self.family).set_alias(device_id, name)
    }

    pub fn family_json(&self) -> Value {
        let found = lock(&self.st).found.clone();
        let now = now_ms();
        let peers: Vec<Value> = lock(&self.family)
            .peers
            .iter()
            .map(|p| {
                let online = found
                    .get(&p.device_id)
                    .map(|f| now.saturating_sub(f.1) < ONLINE_MS)
                    .unwrap_or(false);
                json!({
                    "device_id": p.device_id,
                    "name": if p.alias.is_empty() { &p.name } else { &p.alias },
                    "original_name": p.name,
                    "alias": p.alias,
                    "last_sync_ms": p.last_sync_ms,
                    "online": online,
                    "internet": !p.endpoint.is_empty(),
                })
            })
            .collect();
        Value::Array(peers)
    }

    pub fn status_json(&self) -> Value {
        let st = lock(&self.st);
        json!({
            "device_id": self.ident.device_id,
            "name": self.ident.name,
            "port": st.port,
            "busy": st.busy,
            "message": st.message,
            "error": st.error,
            "generation": st.generation,
            "family_generation": st.family_generation,
            "endpoint": st.endpoint,
            "internet_error": st.internet_error,
            "log": st.log.iter().collect::<Vec<_>>(),
            "report": st.report,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::Library;
    use std::fs;
    use std::path::Path;

    type TestNode = Arc<Node<Mutex<Library>>>;

    fn make(tmp: &Path, name: &str) -> (TestNode, Arc<Mutex<Library>>) {
        let base = tmp.join(name);
        fs::create_dir_all(&base).unwrap();
        let lib = Library::open(&base.join("Hydra"), &base.join("hydra.db"), name, 1_000).unwrap();
        let lib = Arc::new(Mutex::new(lib));
        let ident = Identity::load_or_create(&base, name, name).unwrap();
        (Node::new(ident, Family::load(&base), lib.clone()), lib)
    }

    fn put(lib: &Arc<Mutex<Library>>, playlist: &str, file: &str, content: &str) {
        let mut l = lock(lib);
        let dir = l.root().join(playlist);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(file), content).unwrap();
        l.scan(2_000).unwrap();
    }

    /// Ждёт завершения очередной задачи: успех (generation вырос) или ошибка.
    fn wait_done(n: &TestNode, generation_before: u64) -> Value {
        for _ in 0..400 {
            let st = n.status_json();
            let done = st["generation"].as_u64().unwrap() > generation_before
                || !st["error"].as_str().unwrap().is_empty();
            if done && !st["busy"].as_bool().unwrap() {
                return st;
            }
            thread::sleep(Duration::from_millis(50));
        }
        panic!("синхронизация не завершилась: {}", n.status_json());
    }

    fn wait_idle(n: &TestNode) {
        for _ in 0..400 {
            if !n.status_json()["busy"].as_bool().unwrap() {
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
        panic!("узел всё ещё занят");
    }

    fn generation(n: &TestNode) -> u64 {
        n.status_json()["generation"].as_u64().unwrap()
    }

    #[test]
    fn pairing_then_sync_over_loopback() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, lib_a) = make(tmp.path(), "phone");
        let (b, lib_b) = make(tmp.path(), "pc");
        let (c, _lib_c) = make(tmp.path(), "stranger");
        put(&lib_a, "Rock", "a.mp3", "a-bytes");
        let port = a.start().unwrap();
        b.start().unwrap();
        let addr = vec![format!("127.0.0.1:{port}")];

        // чужой секрет не подходит
        let offer = a.pair_offer();
        let wrong = hex(&[7u8; 32]);
        c.pair_with(addr.clone(), offer["public_key"].as_str().unwrap(), &wrong)
            .unwrap();
        let st = wait_done(&c, 0);
        assert!(
            !st["error"].as_str().unwrap().is_empty(),
            "с чужим секретом пускать нельзя"
        );
        assert!(a.family_json().as_array().unwrap().is_empty());

        // настоящий секрет: устройства узнают друг друга и сразу синхронизируются
        let before = generation(&b);
        b.pair_with(
            addr.clone(),
            offer["public_key"].as_str().unwrap(),
            offer["secret"].as_str().unwrap(),
        )
        .unwrap();
        wait_done(&b, before);
        assert_eq!(a.family_json().as_array().unwrap().len(), 1);
        assert_eq!(b.family_json().as_array().unwrap().len(), 1);
        let got = lock(&lib_b).root().join("Rock").join("a.mp3");
        assert_eq!(fs::read_to_string(got).unwrap(), "a-bytes");

        // одноразовый секрет второй раз не работает
        let (d, _lib_d) = make(tmp.path(), "late");
        d.pair_with(
            addr,
            offer["public_key"].as_str().unwrap(),
            offer["secret"].as_str().unwrap(),
        )
        .unwrap();
        assert!(!wait_done(&d, 0)["error"].as_str().unwrap().is_empty());

        // новая песня на телефоне доезжает по обычной синхронизации
        wait_idle(&a);
        put(&lib_a, "Rock", "b.mp3", "b-bytes");
        let before = generation(&b);
        let a_id = a.status_json()["device_id"].as_str().unwrap().to_string();
        b.sync_peer(&a_id).unwrap();
        wait_done(&b, before);
        let got = lock(&lib_b).root().join("Rock").join("b.mp3");
        assert_eq!(fs::read_to_string(got).unwrap(), "b-bytes");

        // посторонний без пары синхронизироваться не может
        assert!(c.sync_peer(&a_id).is_err());
    }

    #[test]
    fn forgetting_a_device_removes_us_from_its_list_too() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, _lib_a) = make(tmp.path(), "phone");
        let (b, _lib_b) = make(tmp.path(), "pc");
        let port = a.start().unwrap();
        b.start().unwrap();
        let offer = a.pair_offer();
        let before = generation(&b);
        b.pair_with(
            vec![format!("127.0.0.1:{port}")],
            offer["public_key"].as_str().unwrap(),
            offer["secret"].as_str().unwrap(),
        )
        .unwrap();
        wait_done(&b, before);
        assert_eq!(a.family_json().as_array().unwrap().len(), 1);
        wait_idle(&a);
        wait_idle(&b);

        let a_id = a.status_json()["device_id"].as_str().unwrap().to_string();
        assert!(b.forget(&a_id).unwrap());
        assert!(b.family_json().as_array().unwrap().is_empty());
        // телефон узнаёт об удалении и убирает ПК у себя
        let mut gone = false;
        for _ in 0..100 {
            if a.family_json().as_array().unwrap().is_empty() {
                gone = true;
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        assert!(gone, "второе устройство осталось в списке");
        assert!(
            lock(&b.family).goodbyes.is_empty(),
            "сообщение об удалении не снято с очереди"
        );
    }
}
