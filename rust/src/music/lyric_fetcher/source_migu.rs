//! MG (咪咕) 歌词抓取，移植桌面端 lyric_fetcher/migu.rs。

use super::*;

const MG_CLIENT_HEADERS: [(&str, &str); 3] = [
    ("Referer", "https://app.c.nf.migu.cn/"),
    (
        "User-Agent",
        "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
    ),
    ("channel", "0146921"),
];

fn mg_extract_lyric_urls(
    json: &serde_json::Value,
) -> (Option<String>, Option<String>, Option<String>) {
    let node = json.get("content").unwrap_or(json);
    let pick = |key: &str| -> Option<String> {
        node.get(key)
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    };
    (pick("lrcUrl"), pick("mrcUrl"), pick("trcUrl"))
}

pub(crate) async fn fetch_mg_lyric(
    song_info: &LyricSongInfo,
) -> Result<Option<LyricResult>, String> {
    let copyright_id = match song_info.copyright_id.as_deref() {
        Some(id) if !id.is_empty() => id.to_string(),
        _ => return Ok(None),
    };

    let mut result = LyricResult::default();
    let mut lyric_fetched = false;

    let resource_url =
        "https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2";
    let payload = format!(
        r#"{{"resourceId":"{}","copyrightId":"{}"}}"#,
        copyright_id, copyright_id
    );
    let headers: [(&str, &str); 2] = [
        ("Content-Type", "application/json;charset=UTF-8"),
        ("channel", "0146921"),
    ];
    if let Ok(resp) = http_fetch_text(resource_url, "POST", &headers, Some(&payload)).await {
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&resp.body) {
            let (lrc_url, _mrc_url, trc_url) = mg_extract_lyric_urls(&json);

            if let Some(url) = lrc_url {
                if let Ok(r) = http_fetch_text(&url, "GET", &MG_CLIENT_HEADERS, None).await {
                    let text = r.body.trim().to_string();
                    if !text.is_empty() {
                        result.lyric = text;
                        lyric_fetched = true;
                    }
                }
            }

            if let Some(url) = trc_url {
                if let Ok(r) = http_fetch_text(&url, "GET", &MG_CLIENT_HEADERS, None).await {
                    let text = r.body.trim().to_string();
                    if !text.is_empty() {
                        result.tlyric = text;
                    }
                }
            }
        }
    }

    if !lyric_fetched {
        for endpoint in [
            format!(
                "https://music.migu.cn/v3/api/music/audio-player/get_lyric?copyrightId={}&isPlay=1&responseType=json",
                copyright_id
            ),
            format!(
                "https://music.migu.cn/v3/api/music/audioPlayer/getLyric?copyrightId={}",
                copyright_id
            ),
        ] {
            if let Ok(r) = http_fetch_text(&endpoint, "GET", &MG_CLIENT_HEADERS, None).await {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&r.body) {
                    if let Some(lyric) = json["lyric"].as_str() {
                        let lyric = lyric.trim().to_string();
                        if !lyric.is_empty() {
                            result.lyric = lyric;
                            lyric_fetched = true;
                            break;
                        }
                    }
                }
            }
        }
    }

    if !lyric_fetched {
        return Ok(None);
    }

    Ok(Some(result))
}
