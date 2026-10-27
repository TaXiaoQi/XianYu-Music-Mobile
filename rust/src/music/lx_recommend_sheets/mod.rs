// lx_recommend_sheets - LX 推荐歌单数据（推荐歌单元数据链路的固定原生实现）
//
// 与 MF 插件协议同名：getRecommendSheetTags / getRecommendSheetsByTag，聚合
// wy/kg/kw/tx 四平台推荐歌单；标签列表并发拉取（失败平台跳过、按入参顺序合并、
// 跨平台同名分组按 title 合并）。Dart 侧经 lxRecommendSheetTags/lxRecommendSheetsByTag
// 桥接；平台来源/开关由服务端下发的签名配置调整（见 fallback_modules/registry
// 与 plugin_host_fallback）。

mod kg;
mod kw;
mod tx;
mod wy;

use std::time::Duration;

use serde::Serialize;

use crate::music::lx_search::{decode_name, http_get_json, http_get_text};
use crate::music::lx_toplist::value_to_id;

/// 推荐歌单标签（camelCase 输出：id/title/digest/source；digest 仅 kw 使用）
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LxRecommendTag {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
    pub source: String,
}

/// 标签分组
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LxRecommendTagGroup {
    pub title: String,
    pub data: Vec<LxRecommendTag>,
}

/// getRecommendSheetTags 出参：{pinned:[tag], data:[{title, data:[tag]}]}
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LxRecommendTagsResult {
    pub pinned: Vec<LxRecommendTag>,
    pub data: Vec<LxRecommendTagGroup>,
}

/// 推荐歌单条目（camelCase 输出：id/title/artist/artwork/playCount/worksNum/description/source）
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LxRecommendSheet {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub artwork: Option<String>,
    pub play_count: u64,
    pub works_num: u64,
    pub description: String,
    pub source: String,
}

/// getRecommendSheetsByTag 出参：{isEnd, data:[sheet]}
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LxRecommendSheetsResult {
    pub is_end: bool,
    pub data: Vec<LxRecommendSheet>,
}

/// getRecommendSheetTags：四平台并发，失败平台跳过，按入参 sources 顺序合并。
pub async fn lx_recommend_sheet_tags(sources: &[String]) -> LxRecommendTagsResult {
    let mut seen = std::collections::HashSet::new();
    let keys: Vec<&str> = sources
        .iter()
        .map(|s| s.as_str())
        .filter(|s| seen.insert(*s))
        .collect();

    // 未入选平台跑空 future，避免动态 Future 组合的类型体操
    let wy_fut = async { if keys.contains(&"wy") { wy::wy_tags().await.ok() } else { None } };
    let kg_fut = async { if keys.contains(&"kg") { kg::kg_tags().await.ok() } else { None } };
    let kw_fut = async { if keys.contains(&"kw") { kw::kw_tags().await.ok() } else { None } };
    let tx_fut = async { if keys.contains(&"tx") { tx::tx_tags().await.ok() } else { None } };
    let (wy, kg, kw, tx) = tokio::join!(wy_fut, kg_fut, kw_fut, tx_fut);

    let mut results = [wy, kg, kw, tx];
    let mut merged = Vec::new();
    for key in keys {
        let idx = match key {
            "wy" => 0,
            "kg" => 1,
            "kw" => 2,
            "tx" => 3,
            _ => continue,
        };
        if let Some(res) = results[idx].take() {
            merged.push(res);
        }
    }
    merge_tags_results(merged)
}

/// getRecommendSheetsByTag：tag_id/digest 空串表示各平台默认标签。
pub async fn lx_recommend_sheets_by_tag(
    source: &str,
    tag_id: &str,
    digest: &str,
    page: u32,
) -> Result<LxRecommendSheetsResult, String> {
    match source {
        "wy" => wy::wy_sheets_by_tag(tag_id, page).await,
        "kg" => kg::kg_sheets_by_tag(tag_id, page).await,
        "kw" => kw::kw_sheets_by_tag(tag_id, digest, page).await,
        "tx" => tx::tx_sheets_by_tag(tag_id, page).await,
        _ => Err(format!("Unknown LX recommend source: {}", source)),
    }
}

/// 聚合各平台 tags 结果：pinned 顺序拼接；data 同名分组按 title 合并
/// （tag 自带 source 区分平台，跨平台同名分组合并后仍可区分来源）。
pub(crate) fn merge_tags_results(results: Vec<LxRecommendTagsResult>) -> LxRecommendTagsResult {
    let mut out = LxRecommendTagsResult { pinned: Vec::new(), data: Vec::new() };
    for res in results {
        out.pinned.extend(res.pinned);
        for group in res.data {
            if let Some(existing) = out.data.iter_mut().find(|g| g.title == group.title) {
                existing.data.extend(group.data);
            } else {
                out.data.push(group);
            }
        }
    }
    out
}

/// Value → u64（计数/体积字段常见字符串数字形态）
pub(crate) fn value_to_u64(v: &serde_json::Value) -> u64 {
    v.as_u64()
        .or_else(|| v.as_f64().map(|f| f as u64))
        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_value_to_u64_number_string_float() {
        assert_eq!(value_to_u64(&serde_json::json!(123)), 123);
        assert_eq!(value_to_u64(&serde_json::json!("456")), 456);
        assert_eq!(value_to_u64(&serde_json::json!(7.0)), 7);
        assert_eq!(value_to_u64(&serde_json::json!(null)), 0);
        assert_eq!(value_to_u64(&serde_json::json!("abc")), 0);
    }

    #[test]
    fn test_merge_tags_results_groups_and_pinned() {
        let mk = |id: &str, source: &str| LxRecommendTag {
            id: id.into(),
            title: id.into(),
            digest: None,
            source: source.into(),
        };
        let a = LxRecommendTagsResult {
            pinned: vec![mk("p1", "wy")],
            data: vec![
                LxRecommendTagGroup { title: "语种".into(), data: vec![mk("t1", "wy")] },
                LxRecommendTagGroup { title: "风格".into(), data: vec![mk("t2", "wy")] },
            ],
        };
        let b = LxRecommendTagsResult {
            pinned: vec![mk("p2", "kw")],
            data: vec![
                LxRecommendTagGroup { title: "语种".into(), data: vec![mk("t3", "kw")] },
                LxRecommendTagGroup { title: "场景".into(), data: vec![mk("t4", "kw")] },
            ],
        };
        let merged = merge_tags_results(vec![a, b]);
        assert_eq!(merged.pinned.len(), 2);
        assert_eq!(merged.pinned[0].source, "wy");
        assert_eq!(merged.data.len(), 3);
        let yz = merged.data.iter().find(|g| g.title == "语种").unwrap();
        assert_eq!(yz.data.len(), 2);
        assert_eq!(yz.data[0].source, "wy");
        assert_eq!(yz.data[1].source, "kw");
    }

    #[test]
    fn test_sheet_serialization_camel_case() {
        let sheet = LxRecommendSheet {
            id: "19723756".into(),
            title: "私人雷达".into(),
            artist: "网易云".into(),
            artwork: Some("https://example.com/a.jpg".into()),
            play_count: 70579,
            works_num: 98,
            description: "日推".into(),
            source: "wy".into(),
        };
        let json = serde_json::to_string(&sheet).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["id"], "19723756");
        assert_eq!(v["playCount"], 70579);
        assert_eq!(v["worksNum"], 98);
        assert_eq!(v["source"], "wy");

        let tags = LxRecommendTagsResult {
            pinned: vec![LxRecommendTag {
                id: "5".into(),
                title: "推荐".into(),
                digest: None,
                source: "kg".into(),
            }],
            data: Vec::new(),
        };
        let json = serde_json::to_string(&tags).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["pinned"][0]["id"], "5");
        // digest 缺省不序列化
        assert!(v["pinned"][0].get("digest").is_none());
    }
}
