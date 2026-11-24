//! 弦予音乐移动端薄壳 crate（FFI 桥接层）。
//!
//! 纯逻辑已抽至独立仓库 XianYu-Music-Core（submodule: `rust/core`），
//! 本 crate 只保留 flutter_rust_bridge 的 api 层与生成代码，
//! 产出 libxianyu_core.so / .a 供 Dart 侧加载。
//!
//! 修改核心逻辑请到 XianYu-Music-Core 仓库，双端（Mobile/Watch）自动共享。

pub mod api;
mod frb_generated;
