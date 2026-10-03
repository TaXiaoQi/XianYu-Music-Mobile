//! 咪咕（mg）音源搜索。

use super::*;
use std::collections::HashMap;

pub(crate) fn mg_filter_data(raw_data: &serde_json::Value) -> Vec<LxSearchItem> {
    let mut list = Vec::new();
    let mut ids = std::collections::HashSet::new();

    // raw_data 可能是 [[{...}, {...}], [{...}]] 的嵌套结构
    let flat: Vec<&serde_json::Value> = if let Some(outer) = raw_data.as_array() {
        let mut items = Vec::new();
        for inner in outer {
            if let Some(arr) = inner.as_array() {
                for item in arr {
                    items.push(item);
                }
            } else {
                items.push(inner);
            }
        }
        items
    } else {
        vec![]
    };

    for data in flat {
        let song_id = data
            .get("songId")
            .and_then(|v| v.as_str())
            .or_else(|| data.get("songId").and_then(|v| v.as_i64()).map(|_| ""))
            .unwrap_or("");
        let copyright_id = data
            .get("copyrightId")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if song_id.is_empty() || copyright_id.is_empty() || ids.contains(copyright_id) {
            continue;
        }
        ids.insert(copyright_id.to_string());

        let mut types = Vec::new();
        let mut lx_types = HashMap::new();

        if let Some(audio_formats) = data.get("audioFormats").and_then(|v| v.as_array()) {
            for fmt in audio_formats {
                let format_type = fmt.get("formatType").and_then(|v| v.as_str()).unwrap_or("");
                let asize = fmt.get("asize").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let isize = fmt.get("isize").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let size_val = if asize > 0.0 { asize } else { isize };
                let size_str = size_formate(size_val);

                match format_type {
                    "PQ" => {
                        types.push(LxTypeTuple {
                            quality_type: "128k".into(),
                            size: Some(size_str.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "128k".into(),
                            LxTypeEntry {
                                size: Some(size_str),
                                hash: None,
                            },
                        );
                    }
                    "HQ" => {
                        types.push(LxTypeTuple {
                            quality_type: "320k".into(),
                            size: Some(size_str.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "320k".into(),
                            LxTypeEntry {
                                size: Some(size_str),
                                hash: None,
                            },
                        );
                    }
                    "SQ" => {
                        types.push(LxTypeTuple {
                            quality_type: "flac".into(),
                            size: Some(size_str.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "flac".into(),
                            LxTypeEntry {
                                size: Some(size_str),
                                hash: None,
                            },
                        );
                    }
                    "ZQ24" => {
                        types.push(LxTypeTuple {
                            quality_type: "flac24bit".into(),
                            size: Some(size_str.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "flac24bit".into(),
                            LxTypeEntry {
                                size: Some(size_str),
                                hash: None,
                            },
                        );
                    }
                    _ => {}
                }
            }
        }

        let mut img = data
            .get("img3")
            .and_then(|v| v.as_str())
            .or_else(|| data.get("img2").and_then(|v| v.as_str()))
            .or_else(|| data.get("img1").and_then(|v| v.as_str()))
            .map(|s| s.to_string());
        if let Some(ref img_url) = img {
            if !img_url.starts_with("http") {
                img = Some(format!("http://d.musicapp.migu.cn{}", img_url));
            }
        }

        let duration = data.get("duration").and_then(|v| v.as_f64()).unwrap_or(0.0);

        list.push(LxSearchItem {
            singer: format_singer_name(
                data.get("singerList")
                    .or_else(|| data.get("singers"))
                    .unwrap_or(&serde_json::Value::Null),
                "name",
            ),
            name: data
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            album_name: data
                .get("album")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            album_id: data
                .get("albumId")
                .cloned()
                .unwrap_or(serde_json::Value::Null),
            songmid: song_id.to_string(),
            source: "mg".into(),
            interval: format_play_time(duration),
            img,
            hash: None,
            str_media_mid: None,
            song_id: None,
            album_mid: None,
            copyright_id: Some(copyright_id.to_string()),
            types,
            lx_types: Some(lx_types),
        });
    }

    list
}

pub(crate) async fn search_mg(keyword: &str, limit: u32) -> Result<Vec<LxSearchItem>, String> {
    let time = std::time::SystemTime::now();
    let timestamp = time
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string();
    let (sign, device_id) = mg_create_signature(&timestamp, keyword);

    let search_switch = urlencoding::encode(
        r#"{"song":1,"album":0,"singer":0,"tagSong":1,"mvSong":0,"bestShow":1,"songlist":0,"lyricSong":0}"#,
    );
    let url = format!(
        "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch={}&pageSize={}&text={}&pageNo=1&sort=0&sid=USS",
        search_switch,
        limit,
        urlencoding::encode(keyword)
    );

    let result = http_get_json(
        &url,
        &[
            ("uiVersion", "A_music_3.6.1"),
            ("deviceId", &device_id),
            ("timestamp", &timestamp),
            ("sign", &sign),
            ("channel", "0146921"),
            ("User-Agent", "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"),
        ],
    )
    .await?;

    if result.get("code").and_then(|v| v.as_str()) != Some("000000") {
        return Err("MG search: code != 000000".to_string());
    }

    let song_result_data = result
        .get("songResultData")
        .unwrap_or(&serde_json::Value::Null);
    let result_list = song_result_data
        .get("resultList")
        .unwrap_or(&serde_json::Value::Null);
    Ok(mg_filter_data(result_list))
}
