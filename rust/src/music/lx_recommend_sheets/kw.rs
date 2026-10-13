//! 酷我（kw）推荐歌单：getTagList 标签 + 三分支分页（标签推荐/专区展平/热门推荐）。

use super::*;

const PAGE_SIZE: u64 = 20;
const KW_AUTH: &str = "loginUid=0&loginSid=0&appUid=76039576";

fn kw_tag_list_url() -> &'static str {
    "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagList?cmd=rcm_keyword_playlist&user=0&prod=kwplayer_pc_9.0.5.0&vipver=9.0.5.0&source=kwplayer_pc_9.0.5.0&loginUid=0&loginSid=0&appUid=76039576"
}

pub(crate) async fn kw_tags() -> Result<LxRecommendTagsResult, String> {
    let data = tokio::time::timeout(Duration::from_secs(6), http_get_json(kw_tag_list_url(), &[]))
        .await
        .map_err(|_| "KW recommend tags timeout".to_string())??;

    let groups_in = data
        .get("data")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let groups: Vec<LxRecommendTagGroup> = groups_in
        .iter()
        .filter_map(|g| {
            let title = g
                .get("name")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty())?;
            let items = g.get("data").and_then(|v| v.as_array())?;
            let tags: Vec<LxRecommendTag> = items
                .iter()
                .filter_map(|t| {
                    let id = t.get("id").map(value_to_id).filter(|s| !s.is_empty())?;
                    let name = t
                        .get("name")
                        .and_then(|v| v.as_str())
                        .map(str::trim)
                        .filter(|s| !s.is_empty())?;
                    let digest = t.get("digest").map(value_to_id).filter(|s| !s.is_empty());
                    Some(LxRecommendTag {
                        id,
                        title: decode_name(name),
                        digest,
                        source: "kw".into(),
                    })
                })
                .collect();
            // 末组固定为空，剔除
            (!tags.is_empty()).then(|| LxRecommendTagGroup { title: decode_name(title), data: tags })
        })
        .collect();

    // pinned 固定四个热门标签（digest=10000 走标签推荐分支），与插件一致
    let pinned = [("翻唱", "1848"), ("网络", "621"), ("伤感", "146"), ("欧美", "35")]
        .iter()
        .map(|(title, id)| LxRecommendTag {
            id: (*id).into(),
            title: (*title).into(),
            digest: Some("10000".into()),
            source: "kw".into(),
        })
        .collect();
    Ok(LxRecommendTagsResult { pinned, data: groups })
}

pub(crate) async fn kw_sheets_by_tag(
    tag_id: &str,
    digest: &str,
    page: u32,
) -> Result<LxRecommendSheetsResult, String> {
    let pn = page.saturating_sub(1);
    // digest=10000 → 标签推荐；其他 digest → 运营专区（单请求展平）；
    // 无 id → 热门推荐。与插件三分支一致，pn 均从 0 计。
    let (url, flatten) = if !tag_id.is_empty() {
        if digest == "10000" {
            (
                format!(
                    "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList?{KW_AUTH}&pn={pn}&id={tag_id}&rn={PAGE_SIZE}"
                ),
                false,
            )
        } else {
            (
                format!("http://mobileinterfaces.kuwo.cn/er.s?type=get_pc_qz_data&f=web&id={tag_id}&prod=pc"),
                true,
            )
        }
    } else {
        (
            format!(
                "https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?{KW_AUTH}&pn={pn}&rn={PAGE_SIZE}&order=hot"
            ),
            false,
        )
    };

    let data = tokio::time::timeout(Duration::from_secs(8), http_get_json(&url, &[]))
        .await
        .map_err(|_| "KW recommend sheets timeout".to_string())??;

    if flatten {
        // 运营专区：响应为数组，各分组 list 展平；total = 展平长度
        let arr = data.as_array().cloned().unwrap_or_default();
        let mut sheets = Vec::new();
        for group in &arr {
            let Some(list) = group.get("list").and_then(|v| v.as_array()) else { continue };
            for item in list {
                sheets.push(kw_sheet_from_value(item));
            }
        }
        let total = sheets.len() as u64;
        Ok(LxRecommendSheetsResult { is_end: page as u64 * PAGE_SIZE >= total, data: sheets })
    } else {
        let total = data.pointer("/data/total").map(value_to_u64).unwrap_or(0);
        let list = data
            .pointer("/data/data")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(LxRecommendSheetsResult {
            is_end: page as u64 * PAGE_SIZE >= total,
            data: list.iter().map(kw_sheet_from_value).collect(),
        })
    }
}

fn kw_sheet_from_value(s: &serde_json::Value) -> LxRecommendSheet {
    LxRecommendSheet {
        id: s.get("id").map(value_to_id).unwrap_or_default(),
        title: decode_name(s.get("name").and_then(|v| v.as_str()).unwrap_or("")),
        artist: decode_name(s.get("uname").and_then(|v| v.as_str()).unwrap_or("")),
        artwork: s
            .get("img")
            .and_then(|v| v.as_str())
            .map(|u| u.to_string())
            .filter(|u| !u.is_empty()),
        play_count: s.get("listencnt").map(value_to_u64).unwrap_or(0),
        // 插件未映射歌曲数与简介，保持一致
        works_num: 0,
        description: String::new(),
        source: "kw".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kw_is_end_page_arithmetic() {
        // isEnd = page * 20 >= total（total 为字符串数字）
        let total = value_to_u64(&serde_json::json!("196383"));
        assert!(!(1 * PAGE_SIZE >= total));
        assert!(9820 * PAGE_SIZE >= total);
    }

    #[test]
    fn test_kw_urls_page_zero_based() {
        let url = format!(
            "https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?{KW_AUTH}&pn={}&rn={PAGE_SIZE}&order=hot",
            1
        );
        assert!(url.contains("pn=1&rn=20&order=hot"));
        let url = format!(
            "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList?{KW_AUTH}&pn={}&id=146&rn={PAGE_SIZE}",
            0
        );
        assert!(url.contains("pn=0&id=146&rn=20"));
    }
}
