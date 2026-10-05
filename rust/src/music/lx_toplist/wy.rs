//! 网易云（wy）榜单：榜单列表 + 榜单即歌单的详情分页。

use super::*;

const WY_HEADERS: &[(&str, &str)] = &[
    ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36"),
    ("Referer", "https://music.163.com/"),
    ("Cookie", "MUSIC_A=1"),
];

pub(crate) async fn wy_boards() -> Result<Vec<LxToplistBoard>, String> {
    let data = tokio::time::timeout(
        Duration::from_secs(6),
        http_get_json("https://music.163.com/api/toplist", WY_HEADERS),
    )
    .await
    .map_err(|_| "WY toplist timeout".to_string())??;

    let list = data
        .get("list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(list
        .iter()
        .filter_map(|b| {
            let id = b.get("id")?;
            let title = b
                .get("name")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())?;
            Some(LxToplistBoard {
                id: value_to_id(id),
                title,
                cover_img: b
                    .get("coverImgUrl")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .filter(|s| !s.is_empty()),
                description: b
                    .get("updateFrequency")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                source: "wy".into(),
            })
        })
        .collect())
}

pub(crate) async fn wy_board_songs(
    board_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    // 榜单即歌单：一次拉 n = min(1000, max(limit, page*limit)) 条全量，再本地切片分页
    let n = ((page as u64 * limit as u64).max(limit as u64)).min(1000) as u32;
    let url = format!(
        "https://music.163.com/api/v6/playlist/detail?id={}&n={}&s=0",
        board_id, n
    );
    let data = tokio::time::timeout(
        Duration::from_secs(8),
        http_get_json(&url, WY_HEADERS),
    )
    .await
    .map_err(|_| "WY toplist detail timeout".to_string())??;

    let tracks = data
        .pointer("/playlist/tracks")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let start = ((page - 1) * limit) as usize;
    let slice: Vec<serde_json::Value> = tracks
        .into_iter()
        .skip(start)
        .take(limit as usize)
        .collect();

    let (types, lx_types) = super::declared_types("wy", None);
    Ok(slice
        .iter()
        .map(|song| {
            let al = song.get("album").or_else(|| song.get("al"));
            let ar = song
                .get("artists")
                .or_else(|| song.get("ar"))
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let singer = ar
                .iter()
                .filter_map(|s| s.get("name").and_then(|n| n.as_str()))
                .collect::<Vec<&str>>()
                .join("、");
            let duration = song
                .get("duration")
                .or_else(|| song.get("dt"))
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0)
                / 1000.0;
            LxSearchItem {
                name: decode_name(song.get("name").and_then(|v| v.as_str()).unwrap_or("")),
                singer: decode_name(&singer),
                album_name: al
                    .and_then(|a| a.get("name"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                album_id: al
                    .and_then(|a| a.get("id"))
                    .cloned()
                    .unwrap_or(serde_json::Value::Null),
                songmid: song.get("id").map(value_to_id).unwrap_or_default(),
                source: "wy".into(),
                interval: format_play_time(duration),
                img: al
                    .and_then(|a| a.get("picUrl"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.replace("http://", "https://")),
                hash: None,
                str_media_mid: None,
                song_id: None,
                album_mid: None,
                copyright_id: None,
                types: types.clone(),
                lx_types: Some(lx_types.clone()),
            }
        })
        .collect())
}

