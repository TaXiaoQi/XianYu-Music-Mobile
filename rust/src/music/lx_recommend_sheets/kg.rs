//! 酷狗（kg）推荐歌单：getSpecial 标签目录与分页 + 每日推荐合并。

use super::*;

use crate::music::lx_search::{build_kugou_cover_url, http_post_json};

const PAGE_SIZE: usize = 20;

/// 档位标签（t 参数直取的固定排序位），与插件 pinned 顺序一致
const KG_PINNED: [(&str, &str); 5] = [("推荐", "5"), ("最热", "6"), ("最新", "7"), ("热藏", "3"), ("飙升", "8")];

fn kg_sheets_url(sort_id: &str, category_id: &str, page: u32) -> String {
    format!(
        "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t={}&c={}&p={}&pagesize={}",
        sort_id, category_id, page, PAGE_SIZE
    )
}

pub(crate) async fn kg_tags() -> Result<LxRecommendTagsResult, String> {
    let data = tokio::time::timeout(
        Duration::from_secs(6),
        http_get_json("http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1", &[]),
    )
    .await
    .map_err(|_| "KG recommend tags timeout".to_string())??;

    let pinned = KG_PINNED
        .iter()
        .map(|(title, id)| LxRecommendTag {
            id: (*id).into(),
            title: (*title).into(),
            digest: None,
            source: "kg".into(),
        })
        .collect();

    // data.tagids 为 {组名: {data: [{id, name}]}} 对象映射
    let tagids = data.pointer("/data/tagids");
    let mut groups = Vec::new();
    if let Some(map) = tagids.and_then(|v| v.as_object()) {
        for (title, group) in map {
            let empty = Vec::new();
            let items = group.get("data").and_then(|v| v.as_array()).unwrap_or(&empty);
            let tags: Vec<LxRecommendTag> = items
                .iter()
                .filter_map(|tag| {
                    let id = tag.get("id")?;
                    let name = tag
                        .get("name")
                        .and_then(|v| v.as_str())
                        .map(str::trim)
                        .filter(|s| !s.is_empty())?;
                    Some(LxRecommendTag {
                        id: value_to_id(id),
                        title: decode_name(name),
                        digest: None,
                        source: "kg".into(),
                    })
                })
                .collect();
            if !tags.is_empty() {
                groups.push(LxRecommendTagGroup { title: decode_name(title), data: tags });
            }
        }
    }
    Ok(LxRecommendTagsResult { pinned, data: groups })
}

pub(crate) async fn kg_sheets_by_tag(
    tag_id: &str,
    page: u32,
) -> Result<LxRecommendSheetsResult, String> {
    // 档位 tagId（3/5/6/7/8）走 sortId，其余为具体标签 categoryId；空串 = 默认推荐
    let (sort_id, category_id) = if ["3", "5", "6", "7", "8"].contains(&tag_id) {
        (tag_id, "")
    } else {
        ("5", tag_id)
    };

    // page1 默认推荐：并发每日推荐合并在前（官方固定参数，失败跳过），与插件一致
    let list = if sort_id == "5" && category_id.is_empty() && page == 1 {
        let (rec, normal) = tokio::join!(
            kg_everyday_rec(),
            kg_fetch_special(sort_id, category_id, page)
        );
        let mut list = rec.unwrap_or_default();
        list.extend(normal?);
        list
    } else {
        kg_fetch_special(sort_id, category_id, page).await?
    };

    Ok(LxRecommendSheetsResult { is_end: list.len() < PAGE_SIZE, data: list })
}

async fn kg_fetch_special(
    sort_id: &str,
    category_id: &str,
    page: u32,
) -> Result<Vec<LxRecommendSheet>, String> {
    let url = kg_sheets_url(sort_id, category_id, page);
    let data = tokio::time::timeout(Duration::from_secs(8), http_get_json(&url, &[]))
        .await
        .map_err(|_| "KG recommend sheets timeout".to_string())??;
    let list = data
        .get("special_db")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(list.iter().map(kg_sheet_from_value).collect())
}

/// getSpecial special_db 与每日推荐 special_list 同构条目映射
fn kg_sheet_from_value(s: &serde_json::Value) -> LxRecommendSheet {
    LxRecommendSheet {
        id: s.get("specialid").map(value_to_id).unwrap_or_default(),
        title: decode_name(s.get("specialname").and_then(|v| v.as_str()).unwrap_or("")),
        artist: decode_name(s.get("nickname").and_then(|v| v.as_str()).unwrap_or("")),
        // img 含 {size} 占位符，必须替换为具体尺寸才能访问
        artwork: s
            .get("img")
            .and_then(|v| v.as_str())
            .and_then(|u| build_kugou_cover_url(u, 480)),
        play_count: s.get("play_count").map(value_to_u64).unwrap_or(0),
        works_num: s.get("song_count").map(value_to_u64).unwrap_or(0),
        description: decode_name(s.get("intro").and_then(|v| v.as_str()).unwrap_or("")),
        source: "kg".into(),
    }
}

/// 每日推荐歌单：官方 pc 客户端固定参数（与 Baka 插件一致）；接口校验失败时
/// 返回空列表（error_code），仅作 page1 默认推荐的增量合并，失败不影响主列表。
async fn kg_everyday_rec() -> Result<Vec<LxRecommendSheet>, String> {
    let body = serde_json::json!({
        "appid": 1001,
        "clienttime": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
        "clientver": 8275,
        "key": "f1f93580115bb106680d2375f8032d96",
        "mid": "21511157a05844bd085308bc76ef3343",
        "platform": "pc",
        "userid": "262643156",
        "return_min": 6,
        "return_max": 15,
    });
    let headers: &[(&str, &str)] = &[("User-Agent", "KuGou2012-8275-web_browser_event_handler")];
    let data = tokio::time::timeout(
        Duration::from_secs(6),
        http_post_json(
            "http://everydayrec.service.kugou.com/guess_special_recommend",
            &body.to_string(),
            headers,
        ),
    )
    .await
    .map_err(|_| "KG everydayrec timeout".to_string())??;

    let list = data
        .pointer("/data/special_list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(list.iter().map(kg_sheet_from_value).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kg_sheets_url_params() {
        // 档位走 sortId（t），具体标签走 categoryId（c）
        let url = kg_sheets_url("6", "", 2);
        assert!(url.contains("t=6&c=&p=2&pagesize=20"));
        let url = kg_sheets_url("5", "1084", 1);
        assert!(url.contains("t=5&c=1084&p=1&pagesize=20"));
    }
}
