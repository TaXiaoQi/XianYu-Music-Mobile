//! 网易云（wy）推荐歌单：catalogue 标签目录 + playlist/list 明文分页（免 weapi 加密）。

use super::*;

use crate::music::lx_toplist::wy::WY_HEADERS;

const PAGE_SIZE: u64 = 20;

pub(crate) async fn wy_tags() -> Result<LxRecommendTagsResult, String> {
    let data = tokio::time::timeout(
        Duration::from_secs(6),
        http_get_json("https://music.163.com/api/playlist/catalogue", WY_HEADERS),
    )
    .await
    .map_err(|_| "WY recommend tags timeout".to_string())??;

    let sub = data
        .get("sub")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    // categories 为 {分类号: 分组名} 映射；缺失则全部归入单组"推荐标签"
    let categories = data.get("categories").filter(|v| v.is_object());

    let mut pinned = Vec::new();
    let mut groups: Vec<LxRecommendTagGroup> = Vec::new();
    for tag in &sub {
        let name = tag
            .get("name")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let Some(name) = name else { continue };
        let item = LxRecommendTag {
            // 插件协议 tag.id 即标签名（作 list 接口 cat 参数）
            id: name.to_string(),
            title: name.to_string(),
            digest: None,
            source: "wy".into(),
        };
        if tag.get("hot").and_then(|v| v.as_bool()).unwrap_or(false) {
            pinned.push(item.clone());
        }
        let title = match categories
            .and_then(|c| c.get(tag.get("category").map(value_to_id).unwrap_or_default()))
        {
            Some(v) => v.as_str().unwrap_or("其他").to_string(),
            None => "推荐标签".to_string(),
        };
        if let Some(g) = groups.iter_mut().find(|g| g.title == title) {
            g.data.push(item);
        } else {
            groups.push(LxRecommendTagGroup { title, data: vec![item] });
        }
    }
    Ok(LxRecommendTagsResult { pinned, data: groups })
}

pub(crate) async fn wy_sheets_by_tag(
    tag_id: &str,
    page: u32,
) -> Result<LxRecommendSheetsResult, String> {
    // 空标签走默认"全部"；cat 为中文标签名需 URL 编码
    let cat = if tag_id.is_empty() { "全部" } else { tag_id };
    let url = format!(
        "https://music.163.com/api/playlist/list?cat={}&limit=20&offset={}&order=hot&total=true",
        urlencoding::encode(cat),
        page.saturating_sub(1) * PAGE_SIZE as u32
    );
    let data = tokio::time::timeout(
        Duration::from_secs(8),
        http_get_json(&url, WY_HEADERS),
    )
    .await
    .map_err(|_| "WY recommend sheets timeout".to_string())??;

    let playlists = data
        .get("playlists")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(LxRecommendSheetsResult {
        is_end: !data.get("more").and_then(|v| v.as_bool()).unwrap_or(false),
        data: playlists
            .iter()
            .map(|p| LxRecommendSheet {
                // id 必须 string，数字会导致 Dart 层 isSameMedia 分页异常
                id: p.get("id").map(value_to_id).unwrap_or_default(),
                title: decode_name(p.get("name").and_then(|v| v.as_str()).unwrap_or("")),
                artist: decode_name(
                    p.pointer("/creator/nickname")
                        .and_then(|v| v.as_str())
                        .unwrap_or(""),
                ),
                artwork: p
                    .get("coverImgUrl")
                    .and_then(|v| v.as_str())
                    .map(|s| s.replace("http://", "https://")),
                play_count: p.get("playCount").map(value_to_u64).unwrap_or(0),
                works_num: p.get("trackCount").map(value_to_u64).unwrap_or(0),
                description: decode_name(p.get("description").and_then(|v| v.as_str()).unwrap_or("")),
                source: "wy".into(),
            })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wy_list_url_encodes_cat_and_page() {
        let cat = "全部";
        let url = format!(
            "https://music.163.com/api/playlist/list?cat={}&limit=20&offset={}&order=hot&total=true",
            urlencoding::encode(cat),
            2 * PAGE_SIZE as u32
        );
        assert!(url.contains("cat=%E5%85%A8%E9%83%A8&"));
        assert!(url.contains("offset=40"));
        assert!(url.ends_with("total=true"));
    }
}
