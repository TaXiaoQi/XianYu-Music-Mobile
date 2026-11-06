//! 弦予音乐移动端复用核心（xianyu_core）。
//!
//! 从桌面端 `XianYu-Music-Desktop/src-tauri` 抽取的纯逻辑模块，
//! 不依赖 Tauri / 桌面窗口，可被 Flutter（flutter_rust_bridge）或
//! 其他宿主跨平台复用。后续批次会逐步并入音效 DSP、歌词、URL 解析等模块。

pub mod audio_convert;
pub mod cloud;
pub mod custom_fonts;
pub mod database;
pub mod dlna;
pub mod error;
pub mod fallback_verify;
pub mod filename_meta;
mod frb_generated;
pub mod host_crypto;
pub mod music;
pub mod player;
pub mod plugin_host;
pub mod plugins;
pub mod recognize;
pub mod remote;
pub mod security;
pub mod statistics;
pub mod toolbox;

pub mod api;
