// 123 云盘代理（移植自移动端 providers/pan123_provider.dart）。
//
// 关键行为对齐点：
// - 请求头 _h：UA / Referer(https://www.123pan.com/) / Platform: web，
//   token 非空时追加 Bearer；分享类接口仅带 UA（对齐 Dart 各调用点）。
// - 123 盘无 platform 签名计算，Dart 源中签名相关仅 md5Hex（登录/账号 id
//   路径使用；登录留在客户端，此处按纯函数移植并附单测）。
// - DownloadUrl 字段实测可能是纯 URL / JSON 串 / 嵌套 data，统一防御解析
//   （_extractDownloadUrl 逐行对齐，含 backup_download_url 兜底）。
// - 分享 directPlayable=true：share_direct_link 直连 share/download/info，
//   fileIds 传 jsonEncode([{FileId: id}])；提取码复用 share.passcode
//   ?? share.shareToken。
// - transfer_share 在 Dart 中抛 UnsupportedError('该盘分享不支持转存')。
// - 无 refresh_token 机制，无凭据轮换（rotated_cred 恒为 None）。

use serde_json::{json, Value};

use super::http;
use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 对齐 Dart md5Hex（http_login_support.dart）：utf8 → md5 → 小写 hex。
#[allow(dead_code)]
fn md5_hex(input: &str) -> String {
    format!("{:x}", md5::compute(input.as_bytes()))
}

/// 带登录态请求头（Dart _h）。
fn auth_headers(token: &str) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Referer".to_string(), "https://www.123pan.com/".to_string()),
        ("Platform".to_string(), "web".to_string()),
    ];
    if !token.is_empty() {
        h.push(("Authorization".to_string(), format!("Bearer {token}")));
    }
    h
}

/// 分享类请求头（Dart 分享接口仅带 UA）。
fn share_headers() -> Vec<(String, String)> {
    vec![("User-Agent".to_string(), UA.to_string())]
}

/// Dart `(v ?? fallback).toString()` 语义：字符串原样、数值转十进制，其余取 fallback。
fn js_str(v: Option<&Value>, fallback: &str) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => fallback.to_string(),
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ── URL 拼接（纯函数，单测对齐 Dart 模板串）─────────────────

fn list_url(path: &str, page: i64) -> String {
    format!(
        "https://www.123pan.com/b/api/file/list/new?parentFileId={}&page={}&limit=100&orderBy=file_id&orderDirection=asc&trashed=false&OnlyAbnormal=false&SearchData=false",
        http::url_encode(path),
        page
    )
}

fn share_get_url(share_key: &str, pass_code: &str) -> String {
    format!(
        "https://www.123pan.com/b/api/share/get?shareKey={}&PassCode={}&orderBy=file_id&orderDirection=asc",
        http::url_encode(share_key),
        http::url_encode(pass_code)
    )
}

fn share_download_info_url(share_key: &str, pass_code: &str, file_ids_json: &str) -> String {
    format!(
        "https://www.123pan.com/b/api/share/download/info?shareKey={}&PassCode={}&fileIds={}",
        http::url_encode(share_key),
        http::url_encode(pass_code),
        http::url_encode(file_ids_json)
    )
}

fn download_info_url(file_id: &str) -> String {
    format!(
        "https://www.123pan.com/b/api/file/download_info?driveId=0&fileId={}&Referer=",
        http::url_encode(file_id)
    )
}

// ── op 实现 ──────────────────────────────────────────────

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let token = req.cred_str("token");
    for host in ["https://www.123pan.com", "https://123pan.com"] {
        let url = format!("{host}/b/api/user/info");
        // Dart 逐 host try/catch：任何异常继续下一 host。
        if let Ok(resp) = http::get(&url, &auth_headers(&token)).await {
            if resp.is_ok() {
                if let Ok(j) = resp.json() {
                    if j.get("code").and_then(Value::as_i64) == Some(200) {
                        return Ok(CloudOut::plain(json!({ "valid": true })));
                    }
                }
            }
        }
    }
    Ok(CloudOut::plain(json!({ "valid": false })))
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let token = req.cred_str("token");
    let path = req.param_str("path");
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let resp = http::get(&list_url(&path, page), &auth_headers(&token))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let list = j
        .get("data")
        .and_then(|d| d.get("InfoList"))
        .cloned()
        .unwrap_or(Value::Null);
    let mut files = Vec::new();
    if let Some(items) = list.as_array() {
        for e in items {
            let id = js_str(e.get("fileId"), "");
            let name = js_str(e.get("filename"), "");
            let is_dir = e.get("type").and_then(Value::as_i64) == Some(1);
            let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
            let parent = js_str(e.get("parentFileId").filter(|v| !v.is_null()), &path);
            files.push(file_json(&id, &name, is_dir, size, Some(&parent), None, None));
        }
    }
    let has_next = files.len() >= 100;
    let next_cursor = if has_next { Some((page + 1).to_string()) } else { None };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "pan123")?;
    // Dart：shareKey = info?.shareId ?? url。
    let share_key = if info.share_id.is_empty() {
        info.url.clone()
    } else {
        info.share_id.clone()
    };
    let pwd = req.param_str("pwd");
    let pass_code = if pwd.is_empty() {
        info.passcode.clone().unwrap_or_default()
    } else {
        pwd
    };
    let resp = http::get(&share_get_url(&share_key, &pass_code), &share_headers())
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("分享链接解析失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    if j.get("code").and_then(Value::as_i64) != Some(0) {
        let default_msg = if !pass_code.is_empty() {
            "提取码错误"
        } else {
            "分享已失效"
        };
        let msg = j.get("message").and_then(Value::as_str).unwrap_or(default_msg);
        return Err(biz_err(msg));
    }
    let list = j
        .get("data")
        .and_then(|d| d.get("InfoList"))
        .cloned()
        .unwrap_or(Value::Null);
    let mut files = Vec::new();
    if let Some(items) = list.as_array() {
        for e in items {
            let id = js_str(e.get("FileId").filter(|v| !v.is_null()).or_else(|| e.get("fileId")), "");
            let name = js_str(
                e.get("FileName").filter(|v| !v.is_null()).or_else(|| e.get("filename")),
                "",
            );
            let is_dir = e.get("Type").and_then(Value::as_i64) == Some(1);
            let size = e.get("Size").and_then(Value::as_i64).unwrap_or(0);
            files.push(file_json(&id, &name, is_dir, size, None, None, None));
        }
    }
    // 123 分享直链需复用提取码，shareToken 暂存 pwd（Dart：shareToken: pwd, passcode: pwd）。
    let pwd_opt = if pass_code.is_empty() { None } else { Some(pass_code) };
    Ok(CloudOut::plain(share_parse_json(
        "pan123",
        files,
        Some(&share_key),
        pwd_opt.as_deref(),
        pwd_opt.as_deref(),
        true,
    )))
}

/// 分享免转存直链（download/info 批量接口取单个文件；Dart 不使用 cred）。
async fn share_direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let share = req.param_obj("share");
    let file = req.param_obj("file");
    let pass_code = share
        .get("passcode")
        .and_then(Value::as_str)
        .or_else(|| share.get("shareToken").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    let share_key = share
        .get("shareId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let file_id = file.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    // Dart：jsonEncode([{'FileId': file.id}])。
    let file_ids_json = serde_json::to_string(&json!([{ "FileId": file_id }])).unwrap_or_default();
    let resp = http::get(
        &share_download_info_url(&share_key, &pass_code, &file_ids_json),
        &share_headers(),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("分享直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    if j.get("code").and_then(Value::as_i64) != Some(0) {
        return Err(biz_err("分享直链获取失败"));
    }
    let dl_url = extract_download_url(j.get("data").unwrap_or(&Value::Null));
    if dl_url.is_empty() {
        return Err(biz_err("分享直链获取失败"));
    }
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    Ok(CloudOut::plain(direct_link_json(
        &dl_url,
        json!({ "User-Agent": UA }),
        Some(name),
        size,
        Some(now_ms() + 3600 * 1000),
    )))
}

// ── 直链 ──────────────────────────────────────────────

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let token = req.cred_str("token");
    let file = req.param_obj("file");
    let file_id = file.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    let resp = http::get(&download_info_url(&file_id), &auth_headers(&token))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    if j.get("code").and_then(Value::as_i64) != Some(0) {
        return Err(biz_err("直链获取失败"));
    }
    let dl_url = extract_download_url(j.get("data").unwrap_or(&Value::Null));
    if dl_url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    Ok(CloudOut::plain(direct_link_json(
        &dl_url,
        json!({ "User-Agent": UA }),
        Some(name),
        size,
        Some(now_ms() + 3600 * 1000),
    )))
}

/// DownloadUrl 可能是纯 URL、JSON 串或嵌套 data，统一防御解析
/// （逐行对齐 Dart _extractDownloadUrl）。
fn extract_download_url(data: &Value) -> String {
    match data {
        Value::String(s) => {
            if s.starts_with("http") {
                return s.clone();
            }
            match serde_json::from_str::<Value>(s) {
                Ok(inner) => extract_download_url(&inner),
                Err(_) => String::new(),
            }
        }
        Value::Object(_) => {
            for key in ["DownloadUrl", "downloadUrl", "download_url"] {
                let v = data.get(key);
                if let Some(Value::String(s)) = v {
                    if s.starts_with("http") {
                        return s.clone();
                    }
                    if !s.is_empty() {
                        let inner = extract_download_url(v.unwrap());
                        if !inner.is_empty() {
                            return inner;
                        }
                    }
                }
            }
            let backup = data
                .get("backup_download_url")
                .filter(|v| !v.is_null())
                .or_else(|| data.get("BackupDownloadUrl").filter(|v| !v.is_null()));
            if let Some(Value::String(s)) = backup {
                if s.starts_with("http") {
                    return s.clone();
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}

pub async fn dispatch(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    match req.op.as_str() {
        "validate" => validate(req).await,
        "list_dir" => list_dir(req).await,
        "parse_share" => parse_share(req).await,
        // Dart 抛 UnsupportedError('该盘分享不支持转存')。
        "transfer_share" => Err(biz_err("该盘分享不支持转存")),
        "direct_link" => direct_link(req).await,
        "share_direct_link" => share_direct_link(req).await,
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_hex_vectors() {
        // 对齐 Dart md5Hex：小写 hex。
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex("中文"), "a7bac2239fcdcb3a067903d8077c4a07");
    }

    #[test]
    fn auth_headers_shape() {
        let h = auth_headers("tok123");
        assert_eq!(h[0].0, "User-Agent");
        assert_eq!(h[1].1, "https://www.123pan.com/");
        assert_eq!(h[2], ("Platform".to_string(), "web".to_string()));
        assert_eq!(h[3].1, "Bearer tok123");
        // 空 token 不带 Authorization。
        let h0 = auth_headers("");
        assert_eq!(h0.len(), 3);
        assert!(!h0.iter().any(|(k, _)| k == "Authorization"));
    }

    #[test]
    fn list_url_shape() {
        assert_eq!(
            list_url("0", 1),
            "https://www.123pan.com/b/api/file/list/new?parentFileId=0&page=1&limit=100&orderBy=file_id&orderDirection=asc&trashed=false&OnlyAbnormal=false&SearchData=false"
        );
        assert_eq!(
            list_url("a b", 2),
            "https://www.123pan.com/b/api/file/list/new?parentFileId=a+b&page=2&limit=100&orderBy=file_id&orderDirection=asc&trashed=false&OnlyAbnormal=false&SearchData=false"
        );
    }

    #[test]
    fn share_urls_shape() {
        assert_eq!(
            share_get_url("abc123", "pwd9"),
            "https://www.123pan.com/b/api/share/get?shareKey=abc123&PassCode=pwd9&orderBy=file_id&orderDirection=asc"
        );
        // fileIds 为 jsonEncode([{FileId: id}]) 再编码。
        let file_ids = serde_json::to_string(&json!([{ "FileId": "42" }])).unwrap();
        assert_eq!(file_ids, r#"[{"FileId":"42"}]"#);
        assert_eq!(
            share_download_info_url("s1", "", &file_ids),
            "https://www.123pan.com/b/api/share/download/info?shareKey=s1&PassCode=&fileIds=%5B%7B%22FileId%22%3A%2242%22%7D%5D"
        );
        assert_eq!(
            download_info_url("42"),
            "https://www.123pan.com/b/api/file/download_info?driveId=0&fileId=42&Referer="
        );
    }

    #[test]
    fn extract_download_url_cases() {
        // 纯 URL 字符串。
        assert_eq!(extract_download_url(&json!("http://a/b")), "http://a/b");
        // JSON 串内嵌 DownloadUrl。
        assert_eq!(
            extract_download_url(&json!(r#"{"DownloadUrl":"http://x/1"}"#)),
            "http://x/1"
        );
        // JSON 串里再嵌 JSON 串（双层）。
        assert_eq!(
            extract_download_url(&json!(r#"{"DownloadUrl":"{\"download_url\":\"http://y/2\"}"}"#)),
            "http://y/2"
        );
        // 对象 + 小驼峰键。
        assert_eq!(
            extract_download_url(&json!({ "downloadUrl": "http://z/3" })),
            "http://z/3"
        );
        // backup 兜底。
        assert_eq!(
            extract_download_url(&json!({ "DownloadUrl": "no", "backup_download_url": "http://b/4" })),
            "http://b/4"
        );
        assert_eq!(
            extract_download_url(&json!({ "BackupDownloadUrl": "http://b/5" })),
            "http://b/5"
        );
        // 非法与缺失。
        assert_eq!(extract_download_url(&json!("not-json")), "");
        assert_eq!(extract_download_url(&json!({ "DownloadUrl": "" })), "");
        assert_eq!(extract_download_url(&Value::Null), "");
    }
}
