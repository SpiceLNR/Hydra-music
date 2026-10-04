//! Hydra Music core.
//!
//! Слои: clock (гибридные логические часы) -> journal (операции) -> db (SQLite)
//! + naming (безопасные имена папок и файлов). Сеть (iroh) подключается позже.

pub mod clock;
pub mod db;
pub mod error;
pub mod journal;
pub mod library;
pub mod naming;
pub mod order;

pub use error::{Error, Result};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
