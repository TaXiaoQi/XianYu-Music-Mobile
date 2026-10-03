// 歌单导入域模块入口：内置实现自前端 playlistImport*.ts 下沉而来（对齐 lyric_fetcher 范式）。
// 平台文件只暴露 get_list_detail_*；命令入口 fetch_playlist_from_source 见 orchestrator。

mod common;
mod kg;
mod kw;
mod orchestrator;
mod qishui;
mod tx;
mod wy;

pub use orchestrator::fetch_playlist_from_source;
