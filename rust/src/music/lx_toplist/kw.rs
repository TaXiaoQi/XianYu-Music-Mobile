//! 酷我（kw）榜单：wapi bang/list 全量榜单 + kbangserver pn 分页详情。

use super::*;

const KW_BANG_LIST_URL: &str = "http://wapi.kuwo.cn/api/pc/bang/list";

/// 详情页 pn 从 0 计；旧 p 参数被上游忽略（永远返回第一页），会导致榜单翻页失效
fn kw_bang_url(id: &str, page: u32, rn: u32) -> String {
    format!(
        "http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&type=bang&data=content&id={}&pn={}&rn={}&isbang=1",
        id,
        page.saturating_sub(1),
        rn
    )
}

pub(crate) async fn kw_boards() -> Vec<LxToplistBoard> {
    // 单请求 6s 超时：列表接口偶发不响应时整体置空
    let data = match tokio::time::timeout(Duration::from_secs(6), http_get_json(KW_BANG_LIST_URL, &[]))
        .await
    {
        Ok(Ok(data)) => data,
        _ => return Vec::new(),
    };
    let groups = data
        .get("child")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for group in &groups {
        let boards = group
            .get("child")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        for b in &boards {
            let id = b.get("sourceid").map(value_to_id).unwrap_or_default();
            let title = b
                .get("name")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            if id.is_empty() || title.is_empty() {
                continue;
            }
            // pic5/pic2 为 zimg 正方形封面；pic 兜底
            let cover = ["pic5", "pic2", "pic"]
                .iter()
                .find_map(|k| {
                    b.get(k)
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                        .filter(|s| !s.is_empty())
                });
            out.push(LxToplistBoard {
                id,
                title,
                cover_img: cover,
                description: b
                    .get("intro")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                source: "kw".into(),
            });
        }
    }
    out
}

/// ksong.s 不带封面字段，且酷我封面路径为哈希分段无法由 albumid 拼出；
/// 与 LX 插件 getPicByRid 同款按歌曲 rid 换取封面 URL（纯文本响应）
fn kw_pic_url(rid: &str) -> String {
    format!(
        "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid={rid}"
    )
}

/// 单首歌换封面：5s 超时，响应非 http 开头视为无封面
async fn kw_song_cover(songmid: String) -> Option<String> {
    let text = tokio::time::timeout(
        Duration::from_secs(5),
        http_get_text(&kw_pic_url(&songmid), &[]),
    )
    .await
    .ok()?
    .ok()?;
    let text = text.trim();
    text.starts_with("http").then(|| text.to_string())
}

pub(crate) async fn kw_board_songs(
    board_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let url = kw_bang_url(board_id, page, limit);
    let data = tokio::time::timeout(Duration::from_secs(8), http_get_json(&url, &[]))
        .await
        .map_err(|_| "KW toplist detail timeout".to_string())??;

    let musiclist = data
        .get("musiclist")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let mut items: Vec<LxSearchItem> = musiclist
        .iter()
        .map(|s| {
            let secs = s
                .get("song_duration")
                .and_then(kw_secs)
                .or_else(|| s.get("duration").and_then(kw_secs))
                .unwrap_or(0.0);
            let (types, lx_types) = super::declared_types("kw", None);
            LxSearchItem {
                name: decode_name(s.get("name").and_then(|v| v.as_str()).unwrap_or("")),
                singer: decode_name(s.get("artist").and_then(|v| v.as_str()).unwrap_or("")),
                album_name: decode_name(s.get("album").and_then(|v| v.as_str()).unwrap_or("")),
                album_id: serde_json::Value::Null,
                songmid: s.get("id").map(value_to_id).unwrap_or_default(),
                source: "kw".into(),
                interval: format_play_time(secs),
                img: None,
                hash: None,
                str_media_mid: None,
                song_id: None,
                album_mid: None,
                copyright_id: None,
                types,
                lx_types: Some(lx_types),
            }
        })
        .filter(|it| !it.songmid.is_empty() && !it.name.is_empty())
        .collect();

    // 并发换封面（rid → URL 一歌一请求）：单个失败留空不阻塞整页
    let handles: Vec<(usize, tokio::task::JoinHandle<Option<String>>)> = items
        .iter()
        .enumerate()
        .map(|(i, it)| (i, tokio::spawn(kw_song_cover(it.songmid.clone()))))
        .collect();
    for (i, handle) in handles {
        if let Ok(Some(pic)) = handle.await {
            items[i].img = Some(pic);
        }
    }
    Ok(items)
}

/// 时长字段兼容数字与字符串两种类型
fn kw_secs(v: &serde_json::Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kw_bang_url_page_one_based() {
        assert!(kw_bang_url("93", 1, 30).contains("pn=0&"));
        assert!(kw_bang_url("93", 2, 30).contains("pn=1&"));
        assert!(kw_bang_url("93", 1, 30).contains("isbang=1"));
    }

    #[test]
    fn test_kw_pic_url_rid() {
        let url = kw_pic_url("624683929");
        assert!(url.starts_with("http://artistpicserver.kuwo.cn/pic.web?"));
        assert!(url.contains("type=rid_pic"));
        assert!(url.ends_with("rid=624683929"));
    }
}
