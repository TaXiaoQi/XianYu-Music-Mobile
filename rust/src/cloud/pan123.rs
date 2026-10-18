// 123 云盘代理（对齐 OpenList/AList 2026-07 驱动：web API 已整体迁至
// yun.123pan.com，全接口追加 CRC-32 路径签名）。
//
// 关键行为对齐点：
// - 业务/分享接口 base = https://yun.123pan.com/b/api，URL 统一经
//   sign_url() 追加 {timeSign}={ts}-{rand}-{dataSign}（对齐 AList
//   signPath(path,"web","3")：k = crc32(yyyyMMddHHmm 逐位表映射，CST)，
//   v = {ts}-{rand}-{crc32("{ts}|{rand}|{path}|web|3|{k}")}）。
// - 请求头：UA / Referer+Origin(yun.123pan.com) / Platform: web /
//   App-Version: 3，token 非空追加 Bearer；分享类不带登录态但头同全套。
// - 列表/搜索统一走 file/list/new（搜索 SearchData=关键词），query 与
//   响应对齐 AList（driveId/next/Page/event/operateType…；code==0 成功，
//   InfoList/Next(-1 末页)，字段大小写双兜底）。
// - DownloadUrl 字段实测可能是纯 URL / JSON 串 / 嵌套 data，统一防御解析
//   （_extractDownloadUrl 逐行对齐，含 backup_download_url 兜底）。
// - 分享 directPlayable=true：share_direct_link 直连 share/download/info，
//   fileIds 传 jsonEncode([{FileId: id}])；提取码 PassCode/SharePwd 双写。
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

/// 带登录态请求头（对齐 AList Request）。
fn auth_headers(token: &str) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Referer".to_string(), "https://yun.123pan.com/".to_string()),
        ("Origin".to_string(), "https://yun.123pan.com".to_string()),
        ("Platform".to_string(), "web".to_string()),
        ("App-Version".to_string(), "3".to_string()),
    ];
    if !token.is_empty() {
        h.push(("Authorization".to_string(), format!("Bearer {token}")));
    }
    h
}

/// 分享类请求头（无登录态，头同全套）。
fn share_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Referer".to_string(), "https://yun.123pan.com/".to_string()),
        ("Origin".to_string(), "https://yun.123pan.com".to_string()),
        ("Platform".to_string(), "web".to_string()),
        ("App-Version".to_string(), "3".to_string()),
    ]
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

// ── CRC-32 路径签名（对齐 AList signPath，2024-09 起全接口强制）──────

/// CRC-32（IEEE，反射 poly 0xEDB88320），对齐 Go crc32.ChecksumIEEE。
fn crc32_ieee(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xEDB88320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

/// 数字 0-9 → 签名表字符（AList signPath 的 table）。
const SIGN_TABLE: &[u8] = b"adefghlmyijnopkqrstubcvsz";

/// Unix 秒 → CST(UTC+8) 年月日时分（civil_from_days 算法，免时区库）。
fn cst_ymdhm(unix_secs: i64) -> (i64, u32, u32, u32, u32) {
    let secs = unix_secs + 8 * 3600;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (
        y,
        m,
        d,
        (rem / 3600) as u32,
        ((rem % 3600) / 60) as u32,
    )
}

/// 签名键值对（k=timeSign，v={ts}-{rand}-{dataSign}）。随机数取系统纳秒
/// 模 1e7+1（AList 为 round(1e7*rand)，同为 0..1e7 整数）。
fn sign_path(path: &str) -> (String, String) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let ts = now.as_secs() as i64;
    let (y, mo, d, h, mi) = cst_ymdhm(ts);
    let digits = format!("{y:04}{mo:02}{d:02}{h:02}{mi:02}");
    let mapped: Vec<u8> = digits
        .bytes()
        .map(|c| SIGN_TABLE[(c - b'0') as usize])
        .collect();
    let time_sign = crc32_ieee(&mapped);
    let random = (now.subsec_nanos() as i64) % 10_000_001;
    let data = format!("{ts}|{random}|{path}|web|3|{time_sign}");
    let data_sign = crc32_ieee(data.as_bytes());
    (time_sign.to_string(), format!("{ts}-{random}-{data_sign}"))
}

/// base + query 追加签名段（签名的 path 为不含 query 的裸路径）。
fn sign_url(path: &str, query: &str, sign: &(String, String)) -> String {
    if query.is_empty() {
        format!("https://yun.123pan.com{path}?{}={}", sign.0, sign.1)
    } else {
        format!("https://yun.123pan.com{path}?{query}&{}={}", sign.0, sign.1)
    }
}

// ── URL 拼接（纯函数，单测以固定 sign 对齐 AList 模板）───────────────

fn list_url(path: &str, page: i64) -> String {
    sign_url(
        "/b/api/file/list/new",
        &format!(
            "driveId=0&limit=100&next=0&orderBy=file_id&orderDirection=desc&parentFileId={}&trashed=false&SearchData=&Page={page}&OnlyLookAbnormalFile=0&event=homeListFile&operateType=4&inDirectSpace=false",
            http::url_encode(path)
        ),
        &sign_path("/b/api/file/list/new"),
    )
}

/// 文件搜索复用 file/list/new（SearchData=关键词，AList 同参形态）。
fn search_url(keyword: &str, page: i64) -> String {
    sign_url(
        "/b/api/file/list/new",
        &format!(
            "driveId=0&limit=100&next=0&orderBy=file_id&orderDirection=desc&parentFileId=0&trashed=false&SearchData={}&Page={page}&OnlyLookAbnormalFile=0&event=homeListFile&operateType=4&inDirectSpace=false",
            http::url_encode(keyword)
        ),
        &sign_path("/b/api/file/list/new"),
    )
}

fn share_get_url(share_key: &str, pass_code: &str) -> String {
    sign_url(
        "/b/api/share/get",
        &format!(
            "limit=100&next=0&orderBy=file_id&orderDirection=desc&parentFileId=0&Page=1&shareKey={}&PassCode={}&SharePwd={}",
            http::url_encode(share_key),
            http::url_encode(pass_code),
            http::url_encode(pass_code)
        ),
        &sign_path("/b/api/share/get"),
    )
}

fn share_download_info_url(share_key: &str, pass_code: &str, file_ids_json: &str) -> String {
    sign_url(
        "/b/api/share/download/info",
        &format!(
            "shareKey={}&PassCode={}&SharePwd={}&fileIds={}",
            http::url_encode(share_key),
            http::url_encode(pass_code),
            http::url_encode(pass_code),
            http::url_encode(file_ids_json)
        ),
        &sign_path("/b/api/share/download/info"),
    )
}

fn download_info_url(file_id: &str) -> String {
    sign_url(
        "/b/api/file/download_info",
        &format!("driveId=0&fileId={}", http::url_encode(file_id)),
        &sign_path("/b/api/file/download_info"),
    )
}

/// 新网关成功 code==0（旧 200 兼容）；非成功取 message。
fn check_code(j: &Value, fallback_msg: &str) -> Result<(), (i32, String)> {
    let code = j.get("code").and_then(Value::as_i64).unwrap_or(0);
    if code != 0 && code != 200 {
        let msg = j
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or(fallback_msg);
        return Err(biz_err(msg));
    }
    Ok(())
}

/// Type/Size 大小写双兜底（新网关 PascalCase，旧接口 camelCase）。
fn item_type(e: &Value) -> Option<i64> {
    e.get("Type")
        .and_then(Value::as_i64)
        .or_else(|| e.get("type").and_then(Value::as_i64))
}

fn item_size(e: &Value) -> i64 {
    e.get("Size")
        .and_then(Value::as_i64)
        .or_else(|| e.get("size").and_then(Value::as_i64))
        .unwrap_or(0)
}

fn item_id(e: &Value) -> String {
    js_str(
        e.get("FileId").filter(|v| !v.is_null()).or_else(|| e.get("fileId")),
        "",
    )
}

fn item_name(e: &Value) -> String {
    js_str(
        e.get("FileName").filter(|v| !v.is_null()).or_else(|| e.get("filename")),
        "",
    )
}

// ── op 实现 ──────────────────────────────────────────────

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let token = req.cred_str("token");
    let url = sign_url("/b/api/user/info", "", &sign_path("/b/api/user/info"));
    if let Ok(resp) = http::get(&url, &auth_headers(&token)).await {
        if resp.is_ok() {
            if let Ok(j) = resp.json() {
                if check_code(&j, "").is_ok() {
                    return Ok(CloudOut::plain(json!({ "valid": true })));
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
        return Err(biz_err(format!("目录列表请求失败 (HTTP {})", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    check_code(&j, "目录列表请求失败")?;
    let data = j.get("data").cloned().unwrap_or(Value::Null);
    let items = data
        .get("InfoList")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &items {
        let parent = js_str(e.get("parentFileId").filter(|v| !v.is_null()), &path);
        files.push(file_json(
            &item_id(e),
            &item_name(e),
            item_type(e) == Some(1),
            item_size(e),
            Some(&parent),
            None,
            None,
        ));
    }
    // 翻页：Next=="-1" 或空页即末页（AList 同语义）；cursor 仍为页码。
    let next = js_str(data.get("Next").filter(|v| !v.is_null()), "-1");
    let next_cursor = if !items.is_empty() && next != "-1" {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

/// file/list/new 的 data.InfoList 条目 → CloudFile（映射纯函数，单测断言）。
/// 播放（download_info）只需 fileId；parentFileId 一并带回（搜索无目录上下文，
/// 缺省回空串）。
fn file_from_search_item(e: &Value) -> Value {
    let parent = js_str(e.get("parentFileId").filter(|v| !v.is_null()), "");
    file_json(
        &item_id(e),
        &item_name(e),
        item_type(e) == Some(1),
        item_size(e),
        Some(&parent),
        None,
        None,
    )
}

/// 文件搜索：keyword 必填，cursor 为页码（与 list_dir 同风格），
/// 返回结构与 list_dir 同构（list_result_json）。
async fn search_files(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let keyword = req.param_str("keyword");
    if keyword.is_empty() {
        return Err(biz_err("缺少搜索关键词"));
    }
    let token = req.cred_str("token");
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let resp = http::get(&search_url(&keyword, page), &auth_headers(&token))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("搜索请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    check_code(&j, "搜索请求失败")?;
    let data = j.get("data").cloned().unwrap_or(Value::Null);
    let items = data
        .get("InfoList")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &items {
        files.push(file_from_search_item(e));
    }
    let next = js_str(data.get("Next").filter(|v| !v.is_null()), "-1");
    let next_cursor = if !items.is_empty() && next != "-1" {
        Some((page + 1).to_string())
    } else {
        None
    };
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
            let is_dir = item_type(e) == Some(1);
            let size = item_size(e);
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
        return Err(biz_err(format!("直链获取失败 (HTTP {})", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    check_code(&j, "直链获取失败")?;
    let dl_url = extract_download_url(j.get("data").unwrap_or(&Value::Null));
    if dl_url.is_empty() {
        return Err(biz_err(format!(
            "直链获取失败（未返回下载地址，code={})",
            j.get("code").and_then(Value::as_i64).unwrap_or(-1)
        )));
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
        "search_files" => search_files(req).await,
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
    fn crc32_ieee_vectors() {
        // 标准向量（与 Go crc32.ChecksumIEEE 同为 IEEE 实现）。
        assert_eq!(crc32_ieee(b""), 0);
        assert_eq!(crc32_ieee(b"123456789"), 0xCBF4_3926);
        assert_eq!(
            crc32_ieee(b"The quick brown fox jumps over the lazy dog"),
            0x414F_A339
        );
    }

    #[test]
    fn auth_headers_shape() {
        let h = auth_headers("tok123");
        assert_eq!(h[0].0, "User-Agent");
        assert_eq!(h[1].1, "https://yun.123pan.com/");
        assert_eq!(h[2], ("Origin".to_string(), "https://yun.123pan.com".to_string()));
        assert_eq!(h[3], ("Platform".to_string(), "web".to_string()));
        assert_eq!(h[4], ("App-Version".to_string(), "3".to_string()));
        assert_eq!(h[5].1, "Bearer tok123");
        // 空 token 不带 Authorization。
        let h0 = auth_headers("");
        assert_eq!(h0.len(), 5);
        assert!(!h0.iter().any(|(k, _)| k == "Authorization"));
    }

    #[test]
    fn sign_url_shape() {
        // 签名段 {timeSign}={ts}-{rand}-{dataSign} 追加在 query 之后。
        assert_eq!(
            sign_url(
                "/b/api/user/info",
                "",
                &("123".to_string(), "1790000000-42-456".to_string()),
            ),
            "https://yun.123pan.com/b/api/user/info?123=1790000000-42-456"
        );
        assert_eq!(
            sign_url(
                "/b/api/file/list/new",
                "driveId=0&Page=1",
                &("9".to_string(), "1-2-3".to_string()),
            ),
            "https://yun.123pan.com/b/api/file/list/new?driveId=0&Page=1&9=1-2-3"
        );
    }

    #[test]
    fn url_builders_yun_host_and_signed() {
        // 全部 URL 迁 yun.123pan.com 且以 {timeSign}={ts}-{rand}-{sign} 结尾。
        let u = list_url("0", 1);
        assert!(u.starts_with(
            "https://yun.123pan.com/b/api/file/list/new?driveId=0&limit=100&next=0&orderBy=file_id&orderDirection=desc&parentFileId=0&trashed=false&SearchData=&Page=1&OnlyLookAbnormalFile=0&event=homeListFile&operateType=4&inDirectSpace=false&"
        ));
        let s = search_url("lo fi", 2);
        assert!(s.contains("SearchData=lo+fi"));
        assert!(s.contains("&Page=2&"));
        assert!(s.starts_with("https://yun.123pan.com/b/api/file/list/new?"));
        let g = share_get_url("abc123", "pwd9");
        assert!(g.starts_with(
            "https://yun.123pan.com/b/api/share/get?limit=100&next=0&orderBy=file_id&orderDirection=desc&parentFileId=0&Page=1&shareKey=abc123&PassCode=pwd9&SharePwd=pwd9&"
        ));
        let file_ids = serde_json::to_string(&json!([{ "FileId": "42" }])).unwrap();
        assert_eq!(file_ids, r#"[{"FileId":"42"}]"#);
        let d = share_download_info_url("s1", "", &file_ids);
        assert!(d.starts_with(
            "https://yun.123pan.com/b/api/share/download/info?shareKey=s1&PassCode=&SharePwd=&fileIds=%5B%7B%22FileId%22%3A%2242%22%7D%5D&"
        ));
        let dl = download_info_url("42");
        assert!(dl.starts_with("https://yun.123pan.com/b/api/file/download_info?driveId=0&fileId=42&"));
        // 尾段签名值形如 {ts}-{rand}-{sign}（两个 -），键为 timeSign 数值串。
        let kv = dl.rsplit('&').next().unwrap();
        let (k, v) = kv.split_once('=').unwrap();
        assert!(!k.is_empty());
        assert_eq!(v.matches('-').count(), 2);
    }

    #[test]
    fn file_from_search_item_maps_fields() {
        // 新网关 PascalCase。
        let e = json!({
            "FileId": "f1",
            "FileName": "a.flac",
            "Type": 0,
            "Size": 123,
            "parentFileId": "p0",
        });
        let f = file_from_search_item(&e);
        assert_eq!(f["id"], "f1");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], false);
        assert_eq!(f["size"], 123);
        assert_eq!(f["parentId"], "p0");
        // type==1 判目录；parentFileId 缺失回空串（搜索无目录上下文）；
        // 旧接口 camelCase 字段兜底。
        let d = file_from_search_item(&json!({ "fileId": 9, "filename": "dir", "type": 1 }));
        assert_eq!(d["isDir"], true);
        assert_eq!(d["id"], "9");
        assert_eq!(d["parentId"], "");
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
