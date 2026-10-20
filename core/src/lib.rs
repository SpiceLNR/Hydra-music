//! Hydra Music core.
//!
//! Слои: clock (гибридные логические часы) -> journal (операции) -> db (SQLite)
//! + naming (безопасные имена папок и файлов). Сеть: net (LAN, Noise); интернет (iroh) подключается позже.

pub mod clock;
pub mod db;
pub mod error;
pub mod journal;
pub mod library;
pub mod naming;
pub mod net;
pub mod order;
pub mod tags;

pub use error::{Error, Result};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
