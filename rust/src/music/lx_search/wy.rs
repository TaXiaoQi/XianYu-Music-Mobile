//! 网易云（wy）音源搜索。

use super::*;
use std::collections::HashMap;

pub(crate) async fn search_wy(keyword: &str, limit: u32) -> Result<Vec<LxSearchItem>, String> {
    let url = format!(
        "https://music.163.com/api/search/get/web?s={}&type=1&offset=0&limit={}",
        urlencoding::encode(keyword),
        limit
    );

    // 网易云接口偶发 code != 200 / 网络抖动，最多重试 3 次（对齐桌面端 searchWy）
    let result = {
        let mut attempt = 0;
        loop {
            attempt += 1;
            match http_get_json(
                &url,
                &[
                    ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36"),
                    ("Referer", "https://music.163.com"),
                    ("Cookie", "MUSIC_A=1"),
                ],
            )
            .await
            {
                Ok(r) if r.get("code").and_then(|v| v.as_i64()) == Some(200) => break r,
                Ok(r) => {
                    let msg = format!("WY search: code != 200 ({:?})", r.get("code"));
                    if attempt >= 3 {
                        return Err(msg);
                    }
                }
                Err(e) => {
                    if attempt >= 3 {
                        return Err(e);
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(300 * attempt as u64)).await;
        }
    };

    let songs = result
        .pointer("/result/songs")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let mut list = Vec::new();

    for song in &songs {
        let mut types = Vec::new();
        let mut lx_types = HashMap::new();

        // 网易云搜索接口多数场景不返回 hq/sq 标志（旧版字段），若仅依赖它们，
        // types 会只剩 128k，导致可选音质与播放都只有最低档。网易云歌曲普遍提供
        // 320k 与 flac（无损），在 hq/sq 之外补充声明，由播放时的音质回退链实测
        // 过滤出真正可用的档位（对齐桌面端 searchWy）。
        let hq = song.get("hq").is_some();
        let sq = song.get("sq").is_some();
        let mut push_type = |quality_type: &str| {
            types.push(LxTypeTuple {
                quality_type: quality_type.into(),
                size: None,
                hash: None,
            });
            lx_types.insert(
                quality_type.into(),
                LxTypeEntry {
                    size: None,
                    hash: None,
                },
            );
        };
        if hq {
            push_type("320k");
        }
        if sq {
            push_type("flac");
        }
        push_type("128k");
        if !hq {
            push_type("320k");
        }
        if !sq {
            push_type("flac");
        }
        push_type("flac24bit");
        push_type("master");
        // 构建顺序为高→低，反转为低→高（128k 在前），与前端展示一致
        types.reverse();

        let ar = song
            .get("artists")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let al = song
            .get("album")
            .cloned()
            .unwrap_or(serde_json::Value::Null);

        // 搜索接口不返回 picUrl，改由 picId 推导（见 wy_cover_url）。
        let img = wy_cover_url(&al);

        let singer = ar
            .iter()
            .filter_map(|s| {
                s.get("name")
                    .and_then(|n| n.as_str())
                    .map(|n| n.to_string())
            })
            .collect::<Vec<_>>()
            .join("、");

        let duration = song.get("duration").and_then(|v| v.as_f64()).unwrap_or(0.0);

        list.push(LxSearchItem {
            singer,
            name: song
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            album_name: al
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            album_id: al.get("id").cloned().unwrap_or(serde_json::Value::Null),
            source: "wy".into(),
            interval: format_play_time(duration / 1000.0),
            songmid: song
                .get("id")
                .and_then(|v| v.as_i64())
                .map(|n| n.to_string())
                .unwrap_or_default(),
            img,
            hash: None,
            str_media_mid: None,
            song_id: None,
            album_mid: None,
            copyright_id: None,
            types,
            lx_types: Some(lx_types),
        });
    }

    Ok(list)
}
