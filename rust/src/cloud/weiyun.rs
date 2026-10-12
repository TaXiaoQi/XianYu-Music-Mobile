// 腾讯微云 provider（webviewToken 混合：openid 走 pollScript，会话走 Cookie）。
//
// 移植自移动端 providers/weiyun_provider.dart。关键行为对齐点：
// - goapi 统一 req_header（cmd 12001 / appid 30013 / version 3.9.9），字段
//   防御式解析（接口形状不确定度高），失败文案简短；
// - goapi 请求头 UA + Referer www.weiyun.com + Cookie（仅 cred['cookie']
//   非空时携带；Content-Type 由 http::post_json 统一注入）；
// - cred 存整串 cookie（'cookie' 键）+ openid，与 Dart completeLogin 键名一致；
// - parse_share 匿名：分享页兜底抓 "share_key" 后走 WeiyunShareQuery；
// - 转存接口不保证回新 id，返回原 files（防御式兜底）；
// - 直链下载头需带登录 Cookie（Dart 即便空串也带 Cookie 键）；
// - 日志不打 cred/cookie 内容。

use serde_json::{json, Value};

use super::http;
use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn jstr(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn num_i64(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))
}

/// `a ?? b ?? ''` 的字符串版（仅跳过 null，空串不跳）。
fn coalesce_jstr(a: Option<&Value>, b: Option<&Value>) -> String {
    match a.filter(|v| !v.is_null()) {
        Some(v) => jstr(Some(v)),
        None => jstr(b),
    }
}

/// goapi 统一请求头（Content-Type 由 post_json 注入，Cookie 非空才带）。
fn goapi_headers(cred: &Value) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".into(), UA.into()),
        ("Referer".into(), "https://www.weiyun.com/".into()),
    ];
    let cookie = cred.get("cookie").and_then(Value::as_str).unwrap_or("");
    if !cookie.is_empty() {
        h.push(("Cookie".into(), cookie.to_string()));
    }
    h
}

fn req_header() -> Value {
    json!({
        "cmd": 12001,
        "appid": "30013",
        "version": "3.9.9",
        "major_version": "3",
        "minor_version": "9",
        "fix_version": "9",
    })
}

/// validate 判定：retcode == 0 或 resp_body 存在（对齐 Dart `||` 短路）。
fn validate_ok(j: &Value) -> bool {
    let retcode = j.pointer("/resp_header/retcode").and_then(|v| num_i64(Some(v)));
    retcode == Some(0) || j.get("resp_body").map(|v| !v.is_null()).unwrap_or(false)
}

/// 分享页提取 shareKey（页面 JS 变量，脆弱；仅作兜底）。
fn extract_share_key(body: &str) -> Option<String> {
    let re = regex::Regex::new(r#""share_key"\s*:\s*"([^"]+)""#).ok()?;
    re.captures(body).map(|c| c[1].to_string())
}

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let body = json!({
        "req_header": req_header(),
        "req_body": {
            "dir_key": "",
            "page_index": 0,
            "sort_field": "create_time",
            "reverse_order": true,
            "filter": 0,
            "get_abstract_url": true,
        },
    });
    // Dart 侧 try/catch 全吞：网络失败/JSON 异常一律 valid=false。
    let ok = match http::post_json(
        "https://weiyun.com/webapp/json/weiyunShareNetdisk/WeiyunNetdiskDirList",
        &goapi_headers(&req.cred),
        &body,
    )
    .await
    {
        Ok(resp) => resp.is_ok() && resp.json().map(|j| validate_ok(&j)).unwrap_or(false),
        Err(_) => false,
    };
    Ok(CloudOut::plain(json!({ "valid": ok })))
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let page: i64 = req.param_str("cursor").parse().unwrap_or(0);
    let path = req.param_str("path");
    let body = json!({
        "req_header": req_header(),
        "req_body": {
            "dir_key": path,
            "page_index": page,
            "sort_field": "create_time",
            "reverse_order": true,
            "filter": 0,
            "get_abstract_url": true,
        },
    });
    let resp = http::post_json(
        "https://weiyun.com/webapp/json/weiyunShareNetdisk/WeiyunNetdiskDirList",
        &goapi_headers(&req.cred),
        &body,
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let body = j.get("resp_body").cloned().unwrap_or(Value::Null);
    let dir_list = body
        .get("dir_list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let file_list = body
        .get("file_list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &dir_list {
        // 目录 id：dir_key 优先，file_id 兜底。
        files.push(file_json(
            &coalesce_jstr(e.get("dir_key"), e.get("file_id")),
            &coalesce_jstr(e.get("file_name"), e.get("dir_name")),
            true,
            0,
            Some(&path),
            None,
            None,
        ));
    }
    for e in &file_list {
        files.push(file_json(
            &jstr(e.get("file_id")),
            &jstr(e.get("file_name")),
            false,
            num_i64(e.get("file_size")).unwrap_or(0),
            Some(&path),
            None,
            None,
        ));
    }
    let next_cursor = if dir_list.len() + file_list.len() >= 60 {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "weiyun")?;
    let share_key = if info.share_id.is_empty() {
        info.url.clone()
    } else {
        info.share_id.clone()
    };
    let pwd_param = req.param_str("pwd");
    let pwd = if pwd_param.is_empty() {
        info.passcode.clone().unwrap_or_default()
    } else {
        pwd_param
    };
    // 分享页提取 shareKey 兜底（页面 JS 变量，脆弱）：任何失败都保持原 key。
    let mut key = share_key.clone();
    if let Ok(page) = http::get(
        &format!(
            "https://share.weiyun.com/{}",
            http::url_encode(&share_key)
        ),
        &[("User-Agent".into(), UA.into())],
    )
    .await
    {
        if page.is_ok() {
            if let Some(k) = extract_share_key(&page.body) {
                key = k;
            }
        }
    }
    let resp = http::post_json(
        "https://weiyun.com/webapp/json/weiyunShare/WeiyunShareQuery",
        &[("User-Agent".into(), UA.into())],
        &json!({
            "req_header": req_header(),
            "req_body": { "share_key": key, "pwd": pwd },
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("微云分享解析失败，请转存后播放"));
    }
    let j = resp.json().map_err(biz_err)?;
    let body = j.get("resp_body").cloned().unwrap_or(Value::Null);
    let list = body
        .get("list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &list {
        // Dart `e['is_dir'] == true`：严格布尔。
        let is_dir = e.get("is_dir") == Some(&Value::Bool(true));
        files.push(file_json(
            &jstr(e.get("file_id")),
            &jstr(e.get("file_name")),
            is_dir,
            num_i64(e.get("file_size")).unwrap_or(0),
            None,
            None,
            None,
        ));
    }
    Ok(CloudOut::plain(share_parse_json(
        "weiyun",
        files,
        Some(&key),
        None,
        if pwd.is_empty() { None } else { Some(&pwd) },
        false,
    )))
}

async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let share = req.param_obj("share");
    let files_in = share
        .get("files")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let file_list: Vec<Value> = files_in
        .iter()
        .map(|f| {
            json!({
                "file_id": jstr(f.get("id")),
                "file_name": jstr(f.get("name")),
                "is_dir": f.get("isDir").and_then(Value::as_bool).unwrap_or(false),
            })
        })
        .collect();
    let body = json!({
        "req_header": req_header(),
        "req_body": {
            "share_key": share.get("shareId").and_then(Value::as_str).unwrap_or(""),
            "pwd": share.get("passcode").and_then(Value::as_str).unwrap_or(""),
            "file_list": file_list,
        },
    });
    let resp = http::post_json(
        "https://weiyun.com/webapp/json/weiyunNetdiskClient/CopySaveFile",
        &goapi_headers(&req.cred),
        &body,
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("转存失败"));
    }
    // 接口不保证回新 id；返回原 files（防御式兜底）。
    Ok(CloudOut::plain(json!({ "files": files_in })))
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let file = req.param_obj("file");
    let body = json!({
        "req_header": req_header(),
        "req_body": { "file_id": jstr(file.get("id")) },
    });
    let resp = http::post_json(
        "https://weiyun.com/webapp/json/weiyunNetdiskClient/WebdiskDownloadRedirect",
        &goapi_headers(&req.cred),
        &body,
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let url = jstr(j.pointer("/resp_body/download_url"));
    if url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let name = jstr(file.get("name"));
    let size = num_i64(file.get("size")).unwrap_or(0);
    // Dart 侧即便 cookie 为空串也带 Cookie 键。
    Ok(CloudOut::plain(direct_link_json(
        &url,
        json!({
            "User-Agent": UA,
            "Cookie": req.cred.get("cookie").and_then(Value::as_str).unwrap_or(""),
        }),
        Some(&name),
        Some(size),
        Some(now_ms() + 30 * 60 * 1000),
    )))
}

pub async fn dispatch(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    match req.op.as_str() {
        "validate" => validate(req).await,
        "list_dir" => list_dir(req).await,
        // goapi 未暴露检索接口。
        "search_files" => Err(biz_err("该盘不支持文件搜索")),
        "parse_share" => parse_share(req).await,
        "transfer_share" => transfer_share(req).await,
        "direct_link" => direct_link(req).await,
        "share_direct_link" => Err(biz_err("该盘分享不支持免转存直链")),
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn goapi_headers_cookie_conditional() {
        let h = goapi_headers(&json!({ "cookie": "a=1; b=2", "openid": "o" }));
        assert_eq!(h[0].1, UA);
        assert_eq!(h[1].1, "https://www.weiyun.com/");
        assert_eq!(h[2].0, "Cookie");
        assert_eq!(h[2].1, "a=1; b=2");
        // cookie 缺失/为空时不带 Cookie 头。
        assert_eq!(goapi_headers(&json!({ "openid": "o" })).len(), 2);
        assert_eq!(goapi_headers(&json!({ "cookie": "" })).len(), 2);
    }

    #[test]
    fn req_header_shape() {
        let h = req_header();
        assert_eq!(h["cmd"], json!(12001));
        assert_eq!(h["appid"], "30013");
        assert_eq!(h["version"], "3.9.9");
        assert_eq!(h["major_version"], "3");
        assert_eq!(h["fix_version"], "9");
    }

    #[test]
    fn validate_logic() {
        assert!(validate_ok(&json!({ "resp_header": { "retcode": 0 } })));
        // retcode 非 0 但 resp_body 存在 → 有效（|| 短路第二支）。
        assert!(validate_ok(&json!({ "resp_header": { "retcode": -1 }, "resp_body": {} })));
        assert!(!validate_ok(&json!({ "resp_header": { "retcode": -1 } })));
        assert!(!validate_ok(&json!({})));
        assert!(!validate_ok(&json!({ "resp_body": null })));
    }

    #[test]
    fn share_key_extraction() {
        let body = r#"var cfg = {"share_key" : "abc123XYZ", "x": 1};"#;
        assert_eq!(extract_share_key(body).as_deref(), Some("abc123XYZ"));
        assert_eq!(extract_share_key("no match here"), None);
    }

    #[test]
    fn dir_entry_fallbacks() {
        let e = json!({ "dir_key": "dk1", "file_name": "目录", "file_id": "fid" });
        assert_eq!(coalesce_jstr(e.get("dir_key"), e.get("file_id")), "dk1");
        assert_eq!(coalesce_jstr(e.get("file_name"), e.get("dir_name")), "目录");
        let e2 = json!({ "file_id": "fid2", "dir_name": "fallback" });
        assert_eq!(coalesce_jstr(e2.get("dir_key"), e2.get("file_id")), "fid2");
        assert_eq!(coalesce_jstr(e2.get("file_name"), e2.get("dir_name")), "fallback");
    }

    #[test]
    fn is_dir_strict_bool() {
        // Dart `e['is_dir'] == true`：数字 1 不算。
        assert_eq!(json!({ "is_dir": true }).get("is_dir"), Some(&Value::Bool(true)));
        assert_ne!(json!({ "is_dir": 1 }).get("is_dir"), Some(&Value::Bool(true)));
        assert_ne!(json!({}).get("is_dir"), Some(&Value::Bool(true)));
    }

    #[test]
    fn file_size_parsing() {
        assert_eq!(num_i64(json!({ "file_size": 1024 }).get("file_size")), Some(1024));
        assert_eq!(num_i64(json!({}).get("file_size")), None);
    }
}
