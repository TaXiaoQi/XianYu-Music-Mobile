//! 酷狗（kg）音源搜索。

use super::*;
use std::collections::HashMap;

pub(crate) fn kg_filter_data(raw: &serde_json::Value) -> LxSearchItem {
    let mut types = Vec::new();
    let mut lx_types = HashMap::new();

    let file_size = raw.get("FileSize").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let hq_size = raw
        .get("HQFileSize")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let sq_size = raw
        .get("SQFileSize")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let res_size = raw
        .get("ResFileSize")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    let file_hash = raw
        .get("FileHash")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let hq_hash = raw
        .get("HQFileHash")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let sq_hash = raw
        .get("SQFileHash")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let res_hash = raw
        .get("ResFileHash")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    if file_size != 0.0 {
        let s = size_formate(file_size);
        types.push(LxTypeTuple {
            quality_type: "128k".into(),
            size: Some(s.clone()),
            hash: Some(file_hash.clone()),
        });
        lx_types.insert(
            "128k".into(),
            LxTypeEntry {
                size: Some(s),
                hash: Some(file_hash.clone()),
            },
        );
    }
    if hq_size != 0.0 {
        let s = size_formate(hq_size);
        types.push(LxTypeTuple {
            quality_type: "320k".into(),
            size: Some(s.clone()),
            hash: Some(hq_hash.clone()),
        });
        lx_types.insert(
            "320k".into(),
            LxTypeEntry {
                size: Some(s),
                hash: Some(hq_hash),
            },
        );
    }
    if sq_size != 0.0 {
        let s = size_formate(sq_size);
        types.push(LxTypeTuple {
            quality_type: "flac".into(),
            size: Some(s.clone()),
            hash: Some(sq_hash.clone()),
        });
        lx_types.insert(
            "flac".into(),
            LxTypeEntry {
                size: Some(s),
                hash: Some(sq_hash),
            },
        );
    }
    if res_size != 0.0 {
        let s = size_formate(res_size);
        types.push(LxTypeTuple {
            quality_type: "flac24bit".into(),
            size: Some(s.clone()),
            hash: Some(res_hash.clone()),
        });
        lx_types.insert(
            "flac24bit".into(),
            LxTypeEntry {
                size: Some(s),
                hash: Some(res_hash),
            },
        );
    }

    let image = raw
        .get("Image")
        .and_then(|v| v.as_str())
        .or_else(|| {
            raw.pointer("/trans_param/union_cover")
                .and_then(|v| v.as_str())
        })
        .unwrap_or("");
    let img = build_kugou_cover_url(image, 480);

    let duration = raw.get("Duration").and_then(|v| v.as_f64()).unwrap_or(0.0);

    LxSearchItem {
        singer: decode_name(&format_singer_name(
            raw.get("Singers").unwrap_or(&serde_json::Value::Null),
            "name",
        )),
        name: decode_name(raw.get("SongName").and_then(|v| v.as_str()).unwrap_or("")),
        album_name: decode_name(raw.get("AlbumName").and_then(|v| v.as_str()).unwrap_or("")),
        album_id: serde_json::Value::String(
            raw.get("AlbumID")
                .and_then(|v| v.as_str())
                .or_else(|| raw.get("AlbumID").and_then(|v| v.as_i64()).map(|_| ""))
                .unwrap_or("")
                .to_string(),
        ),
        songmid: raw
            .get("Audioid")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                raw.get("Audioid")
                    .and_then(|v| v.as_i64())
                    .map(|n| n.to_string())
            })
            .unwrap_or_default(),
        source: "kg".into(),
        interval: format_play_time(duration),
        img,
        hash: Some(file_hash),
        str_media_mid: None,
        song_id: None,
        album_mid: None,
        copyright_id: None,
        types,
        lx_types: Some(lx_types),
    }
}

fn kg_handle_result(raw_data: &serde_json::Value) -> Vec<LxSearchItem> {
    let mut ids = std::collections::HashSet::new();
    let mut list = Vec::new();

    if let Some(arr) = raw_data.as_array() {
        for item in arr {
            let audioid = item
                .get("Audioid")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .or_else(|| {
                    item.get("Audioid")
                        .and_then(|v| v.as_i64())
                        .map(|n| n.to_string())
                })
                .unwrap_or_default();
            let file_hash = item.get("FileHash").and_then(|v| v.as_str()).unwrap_or("");
            let key = format!("{}{}", audioid, file_hash);
            if ids.contains(&key) {
                continue;
            }
            ids.insert(key);
            list.push(kg_filter_data(item));

            // 处理 Grp 子项
            if let Some(grp) = item.get("Grp").and_then(|v| v.as_array()) {
                for child in grp {
                    let child_audioid = child
                        .get("Audioid")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                        .or_else(|| {
                            child
                                .get("Audioid")
                                .and_then(|v| v.as_i64())
                                .map(|n| n.to_string())
                        })
                        .unwrap_or_default();
                    let child_hash = child.get("FileHash").and_then(|v| v.as_str()).unwrap_or("");
                    let child_key = format!("{}{}", child_audioid, child_hash);
                    if ids.contains(&child_key) {
                        continue;
                    }
                    ids.insert(child_key);
                    list.push(kg_filter_data(child));
                }
            }
        }
    }
    list
}

pub(crate) async fn search_kg(keyword: &str, limit: u32) -> Result<Vec<LxSearchItem>, String> {
    let url = format!(
        "https://songsearch.kugou.com/song_search_v2?keyword={}&page=1&pagesize={}&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1",
        urlencoding::encode(keyword),
        limit
    );
    // 酷狗接口偶发 error_code != 0 / 无列表，最多重试 3 次（对齐桌面端 searchKg）
    for attempt in 1..=3 {
        if attempt > 1 {
            tokio::time::sleep(Duration::from_millis(300 * attempt as u64)).await;
        }
        let result = match http_get_json(&url, &[]).await {
            Ok(r) => r,
            Err(e) => {
                if attempt >= 3 {
                    return Err(e);
                }
                continue;
            }
        };
        if result.get("error_code").and_then(|v| v.as_i64()) != Some(0) {
            if attempt >= 3 {
                return Err("KG search: error_code != 0".to_string());
            }
            continue;
        }
        let Some(lists) = result.pointer("/data/lists") else {
            if attempt >= 3 {
                return Err("KG search: no lists".to_string());
            }
            continue;
        };
        return Ok(kg_handle_result(lists));
    }
    Err("KG search: unknown error".to_string())
}
