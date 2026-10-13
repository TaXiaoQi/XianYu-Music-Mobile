//! QQ 音乐（tx）推荐歌单：fcg 标签目录与按标签分页（JSONP 剥壳兜底）。

use super::*;

const TX_HEADERS: &[(&str, &str)] = &[("Referer", "https://y.qq.com/")];
const PAGE_SIZE: u64 = 20;
/// 空标签默认分类（全部）
const TX_DEFAULT_CATEGORY: &str = "10000000";

fn tx_tags_url() -> &'static str {
    "https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_tag_conf.fcg?format=json&inCharset=utf8&outCharset=utf-8"
}

fn tx_by_tag_url(category_id: &str, page: u32) -> String {
    format!(
        "https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg?format=json&inCharset=utf8&outCharset=utf-8&sortId=5&categoryId={}&sin={}&ein={}",
        category_id,
        page.saturating_sub(1) * PAGE_SIZE as u32,
        page * PAGE_SIZE as u32 - 1
    )
}

/// 部分出口返回 JSONP（callback(...) 包装），剥壳后解析；纯 JSON 原样通过
fn strip_jsonp(body: &str) -> &str {
    let t = body.trim();
    if t.starts_with('{') || t.starts_with('[') {
        return t;
    }
    match (t.find('('), t.rfind(')')) {
        (Some(a), Some(b)) if b > a => t[a + 1..b].trim(),
        _ => t,
    }
}

async fn tx_get_json(url: &str, timeout_secs: u64, err: &str) -> Result<serde_json::Value, String> {
    let body = tokio::time::timeout(Duration::from_secs(timeout_secs), http_get_text(url, TX_HEADERS))
        .await
        .map_err(|_| format!("{} timeout", err))??;
    serde_json::from_str(strip_jsonp(&body)).map_err(|e| format!("{} invalid JSON: {}", err, e))
}

pub(crate) async fn tx_tags() -> Result<LxRecommendTagsResult, String> {
    let data = tx_get_json(tx_tags_url(), 6, "TX recommend tags").await?;

    // data.categories[1..]：首组"热门"仅含"全部"，默认标签由空 tag 覆盖，不进分组
    let categories = data
        .pointer("/data/categories")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let mut pinned = Vec::new();
    let mut groups = Vec::new();
    for cat in categories.iter().skip(1) {
        let items = cat
            .get("items")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let tags: Vec<LxRecommendTag> = items
            .iter()
            .filter_map(|t| {
                let id = t.get("categoryId")?;
                let name = t
                    .get("categoryName")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())?;
                Some(LxRecommendTag {
                    id: value_to_id(id),
                    title: decode_name(name),
                    digest: None,
                    source: "tx".into(),
                })
            })
            .collect();
        if tags.is_empty() {
            continue;
        }
        let title = decode_name(
            cat.get("categoryGroupName")
                .and_then(|v| v.as_str())
                .unwrap_or(""),
        );
        // pinned = 各组首项
        pinned.push(tags[0].clone());
        groups.push(LxRecommendTagGroup { title, data: tags });
    }
    if groups.is_empty() {
        return Err("TX recommend tags empty".into());
    }
    Ok(LxRecommendTagsResult { pinned, data: groups })
}

pub(crate) async fn tx_sheets_by_tag(
    tag_id: &str,
    page: u32,
) -> Result<LxRecommendSheetsResult, String> {
    let category_id = if tag_id.is_empty() { TX_DEFAULT_CATEGORY } else { tag_id };
    let data = tx_get_json(&tx_by_tag_url(category_id, page), 8, "TX recommend sheets").await?;

    let sum = data.pointer("/data/sum").map(value_to_u64).unwrap_or(0);
    let list = data
        .pointer("/data/list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(LxRecommendSheetsResult {
        is_end: sum <= page as u64 * PAGE_SIZE,
        data: list
            .iter()
            .map(|s| LxRecommendSheet {
                id: s.get("dissid").map(value_to_id).unwrap_or_default(),
                title: decode_name(s.get("dissname").and_then(|v| v.as_str()).unwrap_or("")),
                artist: decode_name(
                    s.pointer("/creator/name")
                        .and_then(|v| v.as_str())
                        .unwrap_or(""),
                ),
                artwork: s
                    .get("imgurl")
                    .and_then(|v| v.as_str())
                    .map(|u| u.to_string())
                    .filter(|u| !u.is_empty()),
                play_count: s.get("listennum").map(value_to_u64).unwrap_or(0),
                works_num: 0,
                description: decode_name(s.get("introduction").and_then(|v| v.as_str()).unwrap_or("")),
                source: "tx".into(),
            })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strip_jsonp_plain_and_wrapped() {
        assert_eq!(strip_jsonp(r#"{"a":1}"#), r#"{"a":1}"#);
        assert_eq!(
            strip_jsonp("callback({\"a\":1})"),
            r#"{"a":1}"#
        );
        assert_eq!(
            strip_jsonp("MusicJsonCallback({\"a\":1})\n"),
            r#"{"a":1}"#
        );
        // 无括号的异常响应原样返回
        assert_eq!(strip_jsonp("bad"), "bad");
    }

    #[test]
    fn test_tx_by_tag_url_paging() {
        let url = tx_by_tag_url(TX_DEFAULT_CATEGORY, 1);
        assert!(url.contains("sortId=5&categoryId=10000000&sin=0&ein=19"));
        let url = tx_by_tag_url("165", 3);
        assert!(url.contains("categoryId=165&sin=40&ein=59"));
    }
}
