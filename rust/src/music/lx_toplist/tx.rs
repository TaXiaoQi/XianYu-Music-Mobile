//! QQ 音乐（tx）榜单：fcg_v8_toplist_cp 固定 ID 并发探测 + 详情分页。

use super::*;

use crate::music::lx_search::size_formate;

/// tx 榜单接口自带各档位体积（size128/size320/sizeflac），映射进声明供菜单在
/// 真实体积探测关闭时显示；flac24bit 无体积字段，档位仍乐观声明。
fn tx_declared_types(s: &serde_json::Value) -> (Vec<LxTypeTuple>, HashMap<String, LxTypeEntry>) {
    let size_of = |key: &str| -> Option<String> {
        let v = s.get(key);
        let bytes = v
            .and_then(|v| v.as_f64())
            .or_else(|| v.and_then(|v| v.as_str()).and_then(|t| t.parse().ok()))
            .unwrap_or(0.0);
        (bytes > 0.0).then(|| size_formate(bytes))
    };
    let sizes = [
        ("128k", size_of("size128")),
        ("320k", size_of("size320")),
        ("flac", size_of("sizeflac")),
        ("flac24bit", None),
    ];
    let mut types = Vec::new();
    let mut lx_types = HashMap::new();
    for (quality, size) in sizes {
        types.push(LxTypeTuple {
            quality_type: quality.into(),
            size: size.clone(),
            hash: None,
        });
        lx_types.insert(quality.into(), LxTypeEntry { size, hash: None });
    }
    (types, lx_types)
}

const TX_BOARD_IDS: [u32; 12] = [26, 4, 27, 62, 60, 63, 58, 65, 66, 6, 3, 17];

const TX_HEADERS: &[(&str, &str)] = &[("Referer", "https://y.qq.com/")];

fn tx_toplist_url(topid: &str, song_begin: u32, song_num: u32) -> String {
    format!(
        "https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg?topid={}&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq&needNewCode=0&song_begin={}&song_num={}",
        topid, song_begin, song_num
    )
}

async fn tx_probe_board(id: u32) -> Option<LxToplistBoard> {
    let url = tx_toplist_url(&id.to_string(), 0, 1);
    // 必须带 Referer: https://y.qq.com/，否则接口不返回数据
    let data = tokio::time::timeout(Duration::from_secs(6), http_get_json(&url, TX_HEADERS))
        .await
        .ok()?
        .ok()?;
    let topinfo = data.get("topinfo")?;
    let title = topinfo
        .get("ListName")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())?;
    // pic_v12 是榜单真实封面（photo_new T003 标准格式）；headPic_v12/MacListPicUrl
    // 是运营配置图，冷门榜单（国风/ACG/DJ/抖音）会配成纯色占位图。
    // gtimg 全站支持 https，统一升级避免明文 http 在部分网络下失败。
    let cover = ["pic_v12", "headPic_v12", "MacListPicUrl"]
        .iter()
        .find_map(|k| {
            topinfo
                .get(*k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .map(|s| s.replace("http://y.gtimg.cn", "https://y.gtimg.cn"));
    Some(LxToplistBoard {
        id: id.to_string(),
        title,
        cover_img: cover,
        description: "QQ音乐榜单".into(),
        source: "tx".into(),
    })
}

pub(crate) async fn tx_boards() -> Vec<LxToplistBoard> {
    let handles: Vec<_> = TX_BOARD_IDS
        .iter()
        .map(|id| tokio::spawn(tx_probe_board(*id)))
        .collect();
    let mut out = Vec::new();
    for h in handles {
        if let Ok(Some(b)) = h.await {
            out.push(b);
        }
    }
    out
}

pub(crate) async fn tx_board_songs(
    board_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let url = tx_toplist_url(board_id, (page - 1) * limit, limit);
    let data = tokio::time::timeout(Duration::from_secs(8), http_get_json(&url, TX_HEADERS))
        .await
        .map_err(|_| "TX toplist detail timeout".to_string())??;

    let songlist = data
        .get("songlist")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(songlist
        .iter()
        .filter_map(|entry| {
            let s = entry.get("data")?;
            let songmid = s.get("songmid").map(value_to_id)?;
            if songmid.is_empty() {
                return None;
            }
            let singer = s
                .get("singer")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
                .iter()
                .filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                .collect::<Vec<_>>()
                .join("/");
            let albummid = s
                .get("albummid")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let interval = s.get("interval").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let img = if albummid.is_empty() {
                None
            } else {
                Some(format!(
                    "https://y.gtimg.cn/music/photo_new/T002R300x300M000{}.jpg",
                    albummid
                ))
            };
            let (types, lx_types) = tx_declared_types(s);
            Some(LxSearchItem {
                name: decode_name(s.get("songname").and_then(|v| v.as_str()).unwrap_or("")),
                singer: decode_name(&singer),
                album_name: decode_name(s.get("albumname").and_then(|v| v.as_str()).unwrap_or("")),
                album_id: serde_json::Value::Null,
                songmid,
                source: "tx".into(),
                interval: format_play_time(interval),
                img,
                hash: None,
                str_media_mid: None,
                song_id: None,
                album_mid: if albummid.is_empty() {
                    None
                } else {
                    Some(albummid)
                },
                copyright_id: None,
                types,
                lx_types: Some(lx_types),
            })
        })
        .collect())
}
