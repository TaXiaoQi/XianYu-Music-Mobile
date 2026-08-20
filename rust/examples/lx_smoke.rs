//! LX 在线音源连通性验证。
//!
//! 用于确认纯 Rust 实现的搜索 / 封面 / 音源解析在当前网络下可用。
//! 运行：`cargo run --example lx_smoke`
//!
//! 注意：依赖真实外网接口，失败不代表代码缺陷，可能是网络或上游变更。
//!
//! # 已知回归点
//!
//! - `tx`（QQ音乐）：soso 接口不能带 `new_json=1`，否则列表恒空
//! - `wy`（网易云）：搜索接口不返回 picUrl，封面由 picId 本地推导
//! - `mg`（咪咕）：搜索/封面正常，但落雪音源不支持其直链解析

use xianyu_core::music::lx_search::lx_search;
use xianyu_core::music::url_resolver::{resolve_lx_music_url_inner, LxUrlSongInfo};

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    // 记录每个音源的搜索条数 / 有封面条数 / 直链是否成功，末尾汇总。
    let mut summary: Vec<(&str, usize, usize, bool)> = Vec::new();

    // 依次验证各音源，任一可用即说明链路通畅。
    for source in ["wy", "kw", "tx", "kg", "mg"] {
        print!("[{source}] 搜索 ... ");
        match lx_search(source, "周杰伦", 5).await {
            Ok(items) if items.is_empty() => {
                println!("返回 0 条");
                summary.push((source, 0, 0, false));
            }
            Ok(items) => {
                println!("{} 条", items.len());
                let with_cover = items
                    .iter()
                    .filter(|i| i.img.as_deref().is_some_and(|s| !s.is_empty()))
                    .count();
                for it in items.iter().take(2) {
                    println!(
                        "    {} - {} | 时长 {} | songmid {}",
                        it.name,
                        it.singer,
                        if it.interval.is_empty() { "无" } else { &it.interval },
                        it.songmid,
                    );
                    println!(
                        "      封面: {}",
                        it.img.as_deref().unwrap_or("<无>"),
                    );
                }
                // 用第一条尝试解析播放直链。
                let first = &items[0];
                let info = LxUrlSongInfo {
                    songmid: first.songmid.clone(),
                    source: first.source.clone(),
                    hash: first.hash.clone(),
                    name: Some(first.name.clone()),
                    singer: Some(first.singer.clone()),
                    album_name: Some(first.album_name.clone()),
                    album_id: Some(first.album_id.clone()),
                    album_mid: first.album_mid.clone(),
                    copyright_id: first.copyright_id.clone(),
                    str_media_mid: first.str_media_mid.clone(),
                    song_id: first.song_id.clone(),
                    types: first.lx_types.clone(),
                };
                let resolved = match resolve_lx_music_url_inner(&info, "320k").await {
                    Some(r) => {
                        println!("    直链解析成功: {}...", &r.url[..r.url.len().min(60)]);
                        true
                    }
                    None => {
                        println!("    直链解析失败");
                        false
                    }
                };
                summary.push((source, items.len(), with_cover, resolved));
            }
            Err(e) => {
                println!("失败: {e}");
                summary.push((source, 0, 0, false));
            }
        }
    }

    // ---- 汇总 ----
    println!("\n===== 汇总 =====");
    println!("{:<6} {:>6} {:>8} {:>8}", "音源", "条数", "有封面", "直链");
    for (source, count, with_cover, resolved) in &summary {
        println!(
            "{:<6} {:>6} {:>8} {:>8}",
            source,
            count,
            with_cover,
            if *resolved { "OK" } else { "FAIL" }
        );
    }

    // 已知预期：mg 直链不可用（落雪音源不支持），其余音源应全部可搜可播。
    let problems: Vec<&str> = summary
        .iter()
        .filter(|(source, count, _, resolved)| {
            *count == 0 || (!*resolved && *source != "mg")
        })
        .map(|(source, _, _, _)| *source)
        .collect();

    if problems.is_empty() {
        println!("\n结果符合预期（mg 直链不可用为已知限制）");
    } else {
        println!("\n异常音源: {problems:?}");
    }
}
