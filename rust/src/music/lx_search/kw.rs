//! 酷我（kw）音源搜索。

use super::*;
use regex::Regex;
use std::sync::OnceLock;
use std::collections::HashMap;

const KW_MINFO_REGEX: &str = r"level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)";

/// KW minfo 正则惰性编译一次，避免每次解析都重建
static KW_MINFO_RE: OnceLock<Regex> = OnceLock::new();

fn kw_handle_result(raw_data: &serde_json::Value) -> Option<Vec<LxSearchItem>> {
    let re = KW_MINFO_RE.get_or_init(|| Regex::new(KW_MINFO_REGEX).unwrap());
    let mut result = Vec::new();

    let arr = raw_data.as_array()?;
    for info in arr {
        let musicrid = info.get("MUSICRID").and_then(|v| v.as_str()).unwrap_or("");
        let song_id = musicrid.replace("MUSIC_", "");
        let n_minfo = match info.get("N_MINFO").and_then(|v| v.as_str()) {
            Some(v) => v,
            None => return None, // 与前端一致：N_MINFO 为空时返回 null 触发重试
        };

        let mut types = Vec::new();
        let mut lx_types = HashMap::new();

        for item_str in n_minfo.split(';') {
            if let Some(caps) = re.captures(item_str) {
                let bitrate = caps.get(2).map(|m| m.as_str()).unwrap_or("");
                let size = caps.get(4).map(|m| m.as_str()).unwrap_or("").to_uppercase();
                match bitrate {
                    "4000" => {
                        types.push(LxTypeTuple {
                            quality_type: "flac24bit".into(),
                            size: Some(size.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "flac24bit".into(),
                            LxTypeEntry {
                                size: Some(size),
                                hash: None,
                            },
                        );
                    }
                    "2000" => {
                        types.push(LxTypeTuple {
                            quality_type: "flac".into(),
                            size: Some(size.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "flac".into(),
                            LxTypeEntry {
                                size: Some(size),
                                hash: None,
                            },
                        );
                    }
                    "320" => {
                        types.push(LxTypeTuple {
                            quality_type: "320k".into(),
                            size: Some(size.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "320k".into(),
                            LxTypeEntry {
                                size: Some(size),
                                hash: None,
                            },
                        );
                    }
                    "128" => {
                        types.push(LxTypeTuple {
                            quality_type: "128k".into(),
                            size: Some(size.clone()),
                            hash: None,
                        });
                        lx_types.insert(
                            "128k".into(),
                            LxTypeEntry {
                                size: Some(size),
                                hash: None,
                            },
                        );
                    }
                    _ => {}
                }
            }
        }
        // 构建顺序为高→低（flac24bit→128k），反转为低→高（128k 在前），与前端展示一致
        types.reverse();

        let duration_str = info
            .get("DURATION")
            .and_then(|v| v.as_str())
            .or_else(|| info.get("DURATION").and_then(|v| v.as_i64()).map(|_| "0"))
            .unwrap_or("0");
        let interval = duration_str
            .parse::<i64>()
            .map(|d| format_play_time(d as f64))
            .unwrap_or_else(|_| "00:00".to_string());

        let songname = decode_name(info.get("SONGNAME").and_then(|v| v.as_str()).unwrap_or(""));
        let artist = decode_name(info.get("ARTIST").and_then(|v| v.as_str()).unwrap_or(""))
            .replace('&', "、");
        let album = info.get("ALBUM").and_then(|v| v.as_str()).unwrap_or("");
        let album_id = info
            .get("ALBUMID")
            .and_then(|v| v.as_str())
            .or_else(|| {
                info.get("ALBUMID")
                    .and_then(|v| v.as_i64().map(|_| ""))
                    .map(|_| "")
            })
            .unwrap_or("");

        let web_albumpic_short = info
            .get("web_albumpic_short")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let img = build_kuwo_cover_url(web_albumpic_short, 500);

        result.push(LxSearchItem {
            name: songname,
            singer: artist,
            album_name: decode_name(album),
            album_id: serde_json::Value::String(album_id.to_string()),
            songmid: song_id,
            source: "kw".into(),
            interval,
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
    Some(result)
}

pub(crate) async fn search_kw(keyword: &str, limit: u32) -> Result<Vec<LxSearchItem>, String> {
    let url = format!(
        "http://search.kuwo.cn/r.s?client=kt&all={}&pn=0&rn={}&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1",
        urlencoding::encode(keyword),
        limit
    );
    let result = http_get_json(&url, &[]).await?;

    // 检查是否需要重试（TOTAL !== '0' && SHOW === '0'）
    let total = result.get("TOTAL").and_then(|v| v.as_str()).unwrap_or("0");
    let show = result.get("SHOW").and_then(|v| v.as_str()).unwrap_or("1");
    if total != "0" && show == "0" {
        // 重试一次
        let retry = http_get_json(&url, &[]).await?;
        return kw_handle_result(retry.get("abslist").unwrap_or(&serde_json::Value::Null))
            .ok_or_else(|| "KW search: no valid results".to_string());
    }

    kw_handle_result(result.get("abslist").unwrap_or(&serde_json::Value::Null))
        .ok_or_else(|| "KW search: N_MINFO missing".to_string())
}
