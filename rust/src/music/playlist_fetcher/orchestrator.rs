// 编排入口：按音源分发到对应平台实现（对齐前端 importPlaylist 的 switch）。
// source 取值 wy|tx|kw|kg|qishui，raw_id 为歌单 ID / 链接 / 短码原文。
// 桌面端为 Tauri 命令；移动端经 api/mod.rs 的 frb 门面暴露。

use super::common::PlaylistImportResult;

pub async fn fetch_playlist_from_source(
    source: String,
    raw_id: String,
) -> Result<PlaylistImportResult, String> {
    match source.as_str() {
        "wy" => super::wy::get_list_detail_wy(&raw_id).await,
        "tx" => super::tx::get_list_detail_tx(&raw_id).await,
        "kw" => super::kw::get_list_detail_kw(&raw_id).await,
        "kg" => super::kg::get_list_detail_kg(&raw_id).await,
        "qishui" => super::qishui::get_list_detail_qishui(&raw_id).await,
        _ => Err(format!("不支持的音源: {source}")),
    }
}
