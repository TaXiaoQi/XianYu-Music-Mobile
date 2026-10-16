// 迅雷云盘代理（网页版 pan.xunlei.com 通道）。
//
// 2026-10-16 迁移：X App 通道（thunderx 参数 + BuildCustomUserAgent 定制串）
// 与用户表按 client 维度隔离（X 参数对网页版账号报 not_found(5)），且 API
// 直调 auth/signin 有 IP/账号维度风控（review 4002，6h 不冷却），全量切换
// 网页版形态：
// - 业务 https://api-pan.xunlei.com/drive/v1；账号 https://xluser-ssl.xunlei.com/v1
//   （登录在 Dart/TS 端 WebView 内完成，此处只做 refresh）。
// - 请求头五件套：浏览器 UA（登录端存 cred.ua）+ Accept + x-device-id +
//   x-client-id + x-client-version；鉴权再加 Bearer + X-Captcha-Token。
// - 验证码 token：业务必带 X-Captcha-Token；error_code=9 过期 → captcha/init
//   重取（captcha_sign = 网页版 9 盐 md5 链）重试一次；4121/4122/10/16
//   → 刷 access token 重试一次；刷新失败统一抛「登录已过期，请重新绑定」。
// - refresh：POST /v1/auth/token，form 编码 client_id + grant_type +
//   refresh_token（不带 client_secret，带则 403）；refresh_token 单次轮换。
// - cred 键名对齐 Dart WebView 捕获：accessToken/refreshToken/userId/
//   deviceId（32hex）/ua（旧版凭据缺键 → 按过期处理，重新绑定即可）。
// - share/detail、share/restore 沿用同域路径（未验证，失败会显式报错）。

use serde_json::{json, Value};

use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::http;
use super::{biz_err, pre_parse_share, require_cred};

const API: &str = "https://api-pan.xunlei.com/drive/v1";
const XLUSER: &str = "https://xluser-ssl.xunlei.com/v1";
// client 参数用网页版（pan.xunlei.com）：实测用户表按 client 维度
// 隔离——X App 参数（ZQL_zwA4qhHcoe_2）对网页版注册的账号报
// not_found(5)，网页版参数报 invalid_account_or_password(4022)。
const CLIENT_ID: &str = "Xqp0kJBXWhwaTpB6";
const CLIENT_VERSION: &str = "1.93.10";
const PACKAGE_NAME: &str = "pan.xunlei.com";
/// 业务/分享/下载 UA（网页版浏览器串；与 Dart 端 cred.ua 保持同一串，
/// CDN 直链对签发 UA 敏感时保持一致最稳）。
const BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
/// captcha 签名盐表（网页版 utils-async chunk 实测 9 盐，顺序敏感；
/// 初串 = clientId + clientVersion + packageName + deviceId + timestampMs）。
const ALGORITHMS: [&str; 9] = [
    "DVM8BRQfJWDsIE0JbH5GCUM0z0jU1yGymBTj4Eyloazv1F+w0G7ig",
    "T",
    "a1fUxfjOO1/dW++DpGupRgw9P93L",
    "aktKbp+/lQc3MvlMHIupt65LjAgJOL6ttMFvTKK+7+WKubSf9rT",
    "SB/ne9FQUnQmWz4Wuv9KqKfGOBOCUubpHpECxOHfD4hNoMclYA2Yq",
    "sOZFBQ8IMFy3OFjAIf/eA65iqFvS9TIKzLyrhiT6",
    "ZhJdLgL7MGh2GanboB0yk",
    "Osf",
    "v",
];
/// 列表 filters（thunderx getFiles：eq 形态）。
const LIST_FILTERS: &str = r#"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#;
/// 搜索 filters（设计稿形态）：仅回收站过滤，与列表 LIST_FILTERS 不同
/// （与 PikPak 搜索同构）。
const SEARCH_FILTERS: &str = r#"{"trashed":{"match":"exact","value":"false"}}"#;

const EXPIRED: &str = "登录已过期，请重新绑定";

/// 对齐 Dart md5Hex（http_login_support.dart）：utf8 → md5 → 小写 hex。
/// captcha_sign 链式摘要用。
fn md5_hex(input: &str) -> String {
    format!("{:x}", md5::compute(input.as_bytes()))
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

// ── URL 拼接（纯函数，单测对齐参考实现）─────────────────────

fn files_list_url(parent_id: &str, page_token: &str) -> String {
    format!(
        "{API}/files?space=&__type=drive&refresh=true&__sync=true&parent_id={}&page_token={}&with_audit=true&limit=100&filters={}",
        http::url_encode(parent_id),
        http::url_encode(page_token),
        http::url_encode(LIST_FILTERS)
    )
}

/// 文件搜索 URL（纯函数，单测断言）：parent_id=* 全盘检索 + search 关键词，
/// cursor 为响应 next_page_token（与 PikPak 搜索同构）。
fn search_url(keyword: &str, page_token: &str) -> String {
    format!(
        "{API}/files?parent_id=*&search={}&filters={}&page_token={}",
        http::url_encode(keyword),
        http::url_encode(SEARCH_FILTERS),
        http::url_encode(page_token)
    )
}

/// 迅雷 share/detail（不带 client_id，与 PikPak 差异点）。
fn share_detail_url(share_id: &str, pass_code: &str) -> String {
    format!(
        "{API}/share/detail?share_id={}&pass_code={}",
        http::url_encode(share_id),
        http::url_encode(pass_code)
    )
}

fn file_meta_url(file_id: &str) -> String {
    format!("{API}/files/{}", http::url_encode(file_id))
}

fn about_url() -> String {
    format!("{API}/about")
}

/// share 对象提取：顶层 'share' 为对象取之，否则整个响应即 share
/// （对齐 Dart：data = resp.json['share'] is Map ? resp.json : {'share': resp.json}）。
fn pick_share_object(j: &Value) -> Value {
    if j.get("share").map(Value::is_object).unwrap_or(false) {
        j.get("share").cloned().unwrap_or(json!({}))
    } else {
        j.clone()
    }
}

/// OpenList GetAction：method + ":/路径段"（去 query/hash）。
fn action_of(method: &str, url: &str) -> String {
    let rest = url.split("://").nth(1).unwrap_or("");
    let path: String = {
        let no_query = rest.split(['?', '#']).next().unwrap_or("");
        let segs: Vec<&str> = no_query.split('/').skip(1).collect();
        format!("/{}", segs.join("/"))
    };
    format!("{method}:{path}")
}

// ── 请求头 ───────────────────────────────────────────────

/// 基础请求头（Common.Request 五件套；缺 ua/deviceId 的旧凭据按过期处理）。
fn base_headers(cred: &Value) -> Result<Vec<(String, String)>, (i32, String)> {
    let ua = cred.get("ua").and_then(Value::as_str).unwrap_or("");
    if ua.is_empty() {
        return Err(biz_err(EXPIRED));
    }
    let device_id = cred.get("deviceId").and_then(Value::as_str).unwrap_or("");
    Ok(vec![
        ("User-Agent".to_string(), ua.to_string()),
        (
            "Accept".to_string(),
            "application/json;charset=UTF-8".to_string(),
        ),
        ("x-device-id".to_string(), device_id.to_string()),
        ("x-client-id".to_string(), CLIENT_ID.to_string()),
        ("x-client-version".to_string(), CLIENT_VERSION.to_string()),
    ])
}

/// 鉴权请求头：基础五件套 + Bearer + X-Captcha-Token。
fn auth_headers(
    cred: &Value,
    access_token: &str,
    captcha_token: &str,
) -> Result<Vec<(String, String)>, (i32, String)> {
    let mut h = base_headers(cred)?;
    if !access_token.is_empty() {
        h.push(("Authorization".to_string(), format!("Bearer {access_token}")));
    }
    if !captcha_token.is_empty() {
        h.push(("X-Captcha-Token".to_string(), captcha_token.to_string()));
    }
    Ok(h)
}

// ── 验证码 token（缓存 + 签名）───────────────────────────

struct CaptchaEntry {
    user_id: String,
    token: String,
    expires_at: i64,
}

static CAPTCHA: std::sync::Mutex<Option<CaptchaEntry>> = std::sync::Mutex::new(None);

/// captcha_sign（GetCaptchaSign）："1." + md5 链（初串 = 五段拼接，逐盐摘要）。
fn captcha_sign(device_id: &str, timestamp_ms: i64) -> String {
    let mut s = format!("{CLIENT_ID}{CLIENT_VERSION}{PACKAGE_NAME}{device_id}{timestamp_ms}");
    for alg in ALGORITHMS {
        s = md5_hex(&format!("{s}{alg}"));
    }
    format!("1.{s}")
}

/// captcha/init 重取验证码 token（RefreshCaptchaTokenAtLogin 形态：meta 带
/// user_id + 签名）。
async fn fetch_captcha_token(cred: &Value, action: &str) -> Result<String, (i32, String)> {
    let headers = base_headers(cred)?;
    let device_id = cred.get("deviceId").and_then(Value::as_str).unwrap_or("");
    let user_id = cred.get("userId").and_then(Value::as_str).unwrap_or("");
    let ts = now_ms();
    let resp = http::post_json(
        &format!("{XLUSER}/shield/captcha/init"),
        &headers,
        &json!({
            "action": action,
            "captcha_token": "",
            "client_id": CLIENT_ID,
            "device_id": device_id,
            "meta": {
                "client_version": CLIENT_VERSION,
                "package_name": PACKAGE_NAME,
                "user_id": user_id,
                "timestamp": ts.to_string(),
                "captcha_sign": captcha_sign(device_id, ts),
            },
        }),
    )
    .await
    .map_err(biz_err)?;
    let j = resp.json().map_err(biz_err)?;
    if !js_str(j.get("url"), "").is_empty() {
        return Err(biz_err("需要人机验证，请稍后再试"));
    }
    let token = js_str(j.get("captcha_token"), "");
    if token.is_empty() {
        return Err(biz_err("人机验证获取失败"));
    }
    Ok(token)
}

/// 取验证码 token：进程级缓存（按 userId 复用，5 分钟），失效即重取。
async fn captcha_token(cred: &Value, action: &str) -> Result<String, (i32, String)> {
    let user_id = cred
        .get("userId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if let Ok(g) = CAPTCHA.lock() {
        if let Some(e) = g.as_ref() {
            if e.user_id == user_id && e.expires_at > now_ms() && !e.token.is_empty() {
                return Ok(e.token.clone());
            }
        }
    }
    let token = fetch_captcha_token(cred, action).await?;
    if let Ok(mut g) = CAPTCHA.lock() {
        *g = Some(CaptchaEntry {
            user_id,
            token: token.clone(),
            expires_at: now_ms() + 5 * 60 * 1000,
        });
    }
    Ok(token)
}

// ── 鉴权（带凭据轮换）──────────────────────────────────

/// 刷新 access_token，返回 (access_token, refresh_token)（响应缺 refresh_token
/// 时沿用旧值）。所有失败路径统一映射「登录已过期，请重新绑定」。
async fn refresh_access_token(cred: &Value) -> Result<(String, String), (i32, String)> {
    let refresh_token = cred.get("refreshToken").and_then(Value::as_str).unwrap_or("");
    if refresh_token.is_empty() {
        return Err(biz_err(EXPIRED));
    }
    let headers = base_headers(cred)?;
    // 网页版形态：form 编码，不带 client_secret（带则 403 permission_denied）。
    let resp = http::post_form(
        &format!("{XLUSER}/auth/token"),
        &headers,
        vec![
            ("client_id".to_string(), CLIENT_ID.to_string()),
            ("grant_type".to_string(), "refresh_token".to_string()),
            ("refresh_token".to_string(), refresh_token.to_string()),
        ],
    )
    .await
    .map_err(|_| biz_err(EXPIRED))?;
    if !resp.is_ok() {
        return Err(biz_err(EXPIRED));
    }
    let j = resp.json().map_err(|_| biz_err(EXPIRED))?;
    let at = j.get("access_token").and_then(Value::as_str).unwrap_or("");
    if at.is_empty() {
        return Err(biz_err(EXPIRED));
    }
    let rt = j.get("refresh_token").and_then(Value::as_str).unwrap_or("");
    Ok((
        at.to_string(),
        if rt.is_empty() {
            refresh_token.to_string()
        } else {
            rt.to_string()
        },
    ))
}

/// 轮换后的新凭据集（键名对齐 Dart cred）。
fn rotated_cred(cred: &Value, access_token: &str, refresh_token: &str) -> Value {
    let s =
        |k: &str| cred.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    json!({
        "accessToken": access_token,
        "refreshToken": refresh_token,
        "userId": s("userId"),
        "deviceId": s("deviceId"),
        "ua": s("ua"),
    })
}

/// 取可用 access_token：缓存优先（无轮换）；否则刷新并产出新凭据集。
async fn auth(cred: &Value) -> Result<(String, Option<Value>), (i32, String)> {
    let cached = cred.get("accessToken").and_then(Value::as_str).unwrap_or("");
    if !cached.is_empty() {
        return Ok((cached.to_string(), None));
    }
    let (at, rt) = refresh_access_token(cred).await?;
    Ok((at.clone(), Some(rotated_cred(cred, &at, &rt))))
}

/// 业务请求单发（GET 或 POST JSON）。
async fn biz_send(
    cred: &Value,
    access_token: &str,
    captcha_token: &str,
    url: &str,
    body: Option<&Value>,
) -> Result<Value, (i32, String)> {
    let headers = auth_headers(cred, access_token, captcha_token)?;
    let resp = match body {
        Some(b) => http::post_json(url, &headers, b).await,
        None => http::get(url, &headers).await,
    }
    .map_err(biz_err)?;
    resp.json().map_err(biz_err)
}

fn err_code(j: &Value) -> i64 {
    j.get("error_code").and_then(Value::as_i64).unwrap_or(0)
}

/// 业务请求（OpenList XunLeiXCommon.Request 对齐）：
/// error_code=9 → 重取验证码 token 重试；4121/4122/10/16 → 刷 access token
/// 重试；仍失败按 error_description 报错。
async fn biz_json(
    cred: &Value,
    method: &str,
    url: &str,
    body: Option<&Value>,
) -> Result<(Value, Option<Value>), (i32, String)> {
    let action = action_of(method, url);
    let mut ct = captcha_token(cred, &action).await?;
    let (mut at, mut rotated) = auth(cred).await?;
    let mut j = biz_send(cred, &at, &ct, url, body).await?;
    let mut code = err_code(&j);
    if code == 9 {
        ct = fetch_captcha_token(cred, &action).await?;
        j = biz_send(cred, &at, &ct, url, body).await?;
        code = err_code(&j);
    }
    if matches!(code, 4121 | 4122 | 10 | 16) {
        let (nat, nrt) = refresh_access_token(cred).await?;
        rotated = Some(rotated_cred(cred, &nat, &nrt));
        at = nat;
        j = biz_send(cred, &at, &ct, url, body).await?;
        code = err_code(&j);
    }
    if code != 0 {
        let msg = j
            .get("error_description")
            .and_then(Value::as_str)
            .or_else(|| j.get("error").and_then(Value::as_str))
            .unwrap_or("");
        return Err(biz_err(if msg.is_empty() { "请求失败" } else { msg }));
    }
    Ok((j, rotated))
}

// ── op 实现 ──────────────────────────────────────────────

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (_, rotated) = biz_json(&req.cred, "GET", &about_url(), None).await?;
    Ok(CloudOut {
        result: json!({ "valid": true }),
        rotated_cred: rotated,
    })
}

/// 目录列表主体（list_dir 与转存回查共用）。
async fn list_files(
    cred: &Value,
    parent_id: &str,
    page_token: &str,
) -> Result<(Value, Option<Value>), (i32, String)> {
    biz_json(cred, "GET", &files_list_url(parent_id, page_token), None).await
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let path = req.param_str("path");
    let cursor = req.param_str("cursor");
    let (j, rotated) = list_files(&req.cred, &path, &cursor).await?;
    Ok(CloudOut {
        result: list_from_json(&j),
        rotated_cred: rotated,
    })
}

/// files 列表响应 → list_result_json（list_dir / 转存回查共用映射）。
fn list_from_json(j: &Value) -> Value {
    let mut files = Vec::new();
    if let Some(items) = j.get("files").and_then(Value::as_array) {
        for e in items {
            let id = js_str(e.get("id"), "");
            let name = js_str(e.get("name"), "");
            let is_dir = e.get("kind").and_then(Value::as_str) == Some("drive#folder");
            let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
            files.push(file_json(&id, &name, is_dir, size, None, None, None));
        }
    }
    let next = js_str(j.get("next_page_token"), "");
    let next_cursor = if next.is_empty() { None } else { Some(next) };
    list_result_json(files, next_cursor)
}

/// 搜索结果条目 → CloudFile（映射纯函数，单测断言）。
/// 播放（files/{id} 元信息）只需 id；parentId 一并带回（搜索无目录上下文，
/// 缺省回空串）。
fn file_from_search_item(e: &Value) -> Value {
    let id = js_str(e.get("id"), "");
    let name = js_str(e.get("name"), "");
    let is_dir = e.get("kind").and_then(Value::as_str) == Some("drive#folder");
    let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
    let parent = js_str(e.get("parent_id"), "");
    file_json(&id, &name, is_dir, size, Some(&parent), None, None)
}

/// 文件搜索：keyword 必填，cursor 为响应 next_page_token（与 list_dir 同
/// 风格），返回结构与 list_dir 同构（list_result_json）。
async fn search_files(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let keyword = req.param_str("keyword");
    if keyword.is_empty() {
        return Err(biz_err("缺少搜索关键词"));
    }
    let cursor = req.param_str("cursor");
    let (j, rotated) = biz_json(&req.cred, "GET", &search_url(&keyword, &cursor), None).await?;
    let mut files = Vec::new();
    if let Some(items) = j.get("files").and_then(Value::as_array) {
        for e in items {
            files.push(file_from_search_item(e));
        }
    }
    let next = js_str(j.get("next_page_token"), "");
    let next_cursor = if next.is_empty() { None } else { Some(next) };
    Ok(CloudOut {
        result: list_result_json(files, next_cursor),
        rotated_cred: rotated,
    })
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "thunder")?;
    // Dart：shareId = info?.shareId ?? url。
    let share_id = if info.share_id.is_empty() {
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
    // 分享解析不需要登录态（Dalvik 下载 UA）。
    let headers = vec![
        ("User-Agent".to_string(), BROWSER_UA.to_string()),
        (
            "Accept".to_string(),
            "application/json;charset=UTF-8".to_string(),
        ),
    ];
    let resp = http::get(&share_detail_url(&share_id, &pass_code), &headers)
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("分享链接解析失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let share = pick_share_object(&j);
    let pass_code_token = js_str(share.get("pass_code_token"), "");
    if pass_code_token.is_empty() && !pass_code.is_empty() {
        return Err(biz_err("提取码错误"));
    }
    // Dart：(resp.json['list'] ?? resp.json['files']) as List?。
    let list = j
        .get("list")
        .filter(|v| v.is_array())
        .or_else(|| j.get("files").filter(|v| v.is_array()))
        .cloned()
        .unwrap_or(Value::Null);
    let mut files = Vec::new();
    if let Some(items) = list.as_array() {
        for e in items {
            let id = js_str(e.get("file_id").filter(|v| !v.is_null()).or_else(|| e.get("id")), "");
            let name = js_str(e.get("name"), "");
            let is_dir = e.get("kind").and_then(Value::as_str) == Some("drive#folder");
            let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
            files.push(file_json(&id, &name, is_dir, size, None, None, None));
        }
    }
    let pwd_opt = if pass_code.is_empty() { None } else { Some(pass_code) };
    Ok(CloudOut::plain(share_parse_json(
        "thunder",
        files,
        Some(&share_id),
        Some(&pass_code_token),
        pwd_opt.as_deref(),
        false,
    )))
}

async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let share = req.param_obj("share");
    let token = share
        .get("shareToken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if token.is_empty() {
        return Err(biz_err("请先填写提取码"));
    }
    let files_in = share
        .get("files")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let file_list: Vec<Value> = files_in
        .iter()
        .map(|f| {
            json!({
                "file_id": f.get("id").and_then(Value::as_str).unwrap_or(""),
                "name": f.get("name").and_then(Value::as_str).unwrap_or(""),
            })
        })
        .collect();
    let body = json!({
        "share_id": share.get("shareId").and_then(Value::as_str).unwrap_or(""),
        "pass_code_token": token,
        "file_list": file_list,
    });
    let (_, rotated) = biz_json(&req.cred, "POST", &format!("{API}/share/restore"), Some(&body)).await?;
    // 转存后 id 变化：按文件名回查根目录。
    let (listed, rotated2) = list_files(&req.cred, "", "").await?;
    let rotated = rotated2.or(rotated);
    let mut by_name: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    if let Some(items) = listed.get("files").and_then(Value::as_array) {
        for f in items {
            if let Some(n) = f.get("name").and_then(Value::as_str) {
                by_name.insert(n.to_string(), f.clone());
            }
        }
    }
    let out: Vec<Value> = files_in
        .iter()
        .filter_map(|f| {
            let n = f.get("name").and_then(Value::as_str)?;
            by_name.get(n).cloned()
        })
        .collect();
    if out.is_empty() {
        return Err(biz_err("转存失败"));
    }
    Ok(CloudOut {
        result: json!({ "files": out }),
        rotated_cred: rotated,
    })
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let file = req.param_obj("file");
    let file_id = file.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    let (j, rotated) = biz_json(&req.cred, "GET", &file_meta_url(&file_id), None).await?;
    let dl_url = js_str(j.get("web_content_link"), "");
    if dl_url.is_empty() {
        // 部分文件在 medias[].link.url 兜底。
        if let Some(medias) = j.get("medias").and_then(Value::as_array) {
            for m in medias {
                let alt = m
                    .get("link")
                    .and_then(|l| l.get("url"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if !alt.is_empty() {
                    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
                    let size = file.get("size").and_then(Value::as_i64);
                    return Ok(CloudOut {
                        result: direct_link_json(
                            alt,
                            json!({ "User-Agent": BROWSER_UA }),
                            Some(name),
                            size,
                            Some(now_ms() + 30 * 60 * 1000),
                        ),
                        rotated_cred: rotated,
                    });
                }
            }
        }
        return Err(biz_err("直链获取失败"));
    }
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    Ok(CloudOut {
        result: direct_link_json(
            &dl_url,
            json!({ "User-Agent": BROWSER_UA }),
            Some(name),
            size,
            Some(now_ms() + 30 * 60 * 1000),
        ),
        rotated_cred: rotated,
    })
}

pub async fn dispatch(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    match req.op.as_str() {
        "validate" => validate(req).await,
        "list_dir" => list_dir(req).await,
        "search_files" => search_files(req).await,
        "parse_share" => parse_share(req).await,
        "transfer_share" => transfer_share(req).await,
        "direct_link" => direct_link(req).await,
        // Dart 未覆写 getShareDirectLink → 基类 UnsupportedError。
        "share_direct_link" => Err(biz_err("该盘分享不支持免转存直链")),
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_hex_vectors() {
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
    }

    #[test]
    fn captcha_sign_shape() {
        // "1." + 32 位小写 hex；9 盐逐条摘要（确定性可复算）。
        let s = captcha_sign("dev1", 1729000000000);
        assert!(s.starts_with("1."));
        let hex = &s[2..];
        assert_eq!(hex.len(), 32);
        assert!(hex.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        // 同输入恒同输出。
        assert_eq!(s, captcha_sign("dev1", 1729000000000));
        assert_eq!(ALGORITHMS.len(), 9);
    }

    #[test]
    fn captcha_sign_official_vector() {
        // 网页版官方页面实测向量：deviceID + timestamp 逐字复现官方 sign。
        assert_eq!(
            captcha_sign("9d0bc3fe3e945a12a3d6b5882ea31cd4", 1792128233219),
            "1.a213bb292c99017161615f707158e150"
        );
    }

    #[test]
    fn action_of_paths() {
        assert_eq!(action_of("GET", &files_list_url("", "")), "GET:/drive/v1/files");
        assert_eq!(
            action_of("POST", &format!("{API}/share/restore")),
            "POST:/drive/v1/share/restore"
        );
        assert_eq!(
            action_of("POST", &format!("{XLUSER}/auth/signin")),
            "POST:/v1/auth/signin"
        );
    }

    #[test]
    fn headers_shape() {
        let cred = json!({ "ua": "UA1", "deviceId": "dev1" });
        let h = base_headers(&cred).unwrap();
        assert_eq!(
            h,
            vec![
                ("User-Agent".to_string(), "UA1".to_string()),
                ("Accept".to_string(), "application/json;charset=UTF-8".to_string()),
                ("x-device-id".to_string(), "dev1".to_string()),
                ("x-client-id".to_string(), CLIENT_ID.to_string()),
                ("x-client-version".to_string(), CLIENT_VERSION.to_string()),
            ]
        );
        // 旧凭据无 ua → 过期。
        assert!(base_headers(&json!({ "accessToken": "a" })).is_err());
        // 鉴权头追加 Bearer + X-Captcha-Token。
        let ah = auth_headers(&cred, "at1", "ct1").unwrap();
        assert!(ah.iter().any(|(k, v)| k == "Authorization" && v == "Bearer at1"));
        assert!(ah.iter().any(|(k, v)| k == "X-Captcha-Token" && v == "ct1"));
    }

    #[test]
    fn rotated_cred_keys() {
        let cred = json!({ "userId": "u1", "deviceId": "d1", "ua": "UA1" });
        let r = rotated_cred(&cred, "at2", "rt2");
        assert_eq!(r["accessToken"], "at2");
        assert_eq!(r["refreshToken"], "rt2");
        assert_eq!(r["userId"], "u1");
        assert_eq!(r["deviceId"], "d1");
        assert_eq!(r["ua"], "UA1");
    }

    #[test]
    fn files_list_url_filters_encoded() {
        assert_eq!(
            files_list_url("", "pt1"),
            "https://api-pan.xunlei.com/drive/v1/files?space=&__type=drive&refresh=true&__sync=true&parent_id=&page_token=pt1&with_audit=true&limit=100&filters=%7B%22phase%22%3A%7B%22eq%22%3A%22PHASE_TYPE_COMPLETE%22%7D%2C%22trashed%22%3A%7B%22eq%22%3Afalse%7D%7D"
        );
    }

    #[test]
    fn share_detail_url_no_client_id() {
        assert_eq!(
            share_detail_url("sid1", ""),
            "https://api-pan.xunlei.com/drive/v1/share/detail?share_id=sid1&pass_code="
        );
        assert_eq!(
            file_meta_url("f1"),
            "https://api-pan.xunlei.com/drive/v1/files/f1"
        );
    }

    #[test]
    fn share_object_wrap_semantics() {
        // 顶层 share 为对象 → 直接取。
        let nested = json!({ "share": { "pass_code_token": "t1" }, "list": [] });
        assert_eq!(pick_share_object(&nested)["pass_code_token"], "t1");
        // 无顶层 share → 整个响应视作 share。
        let flat = json!({ "pass_code_token": "t2" });
        assert_eq!(pick_share_object(&flat)["pass_code_token"], "t2");
        // 顶层 share 非对象 → 整个响应视作 share（Dart is Map 判断）。
        let weird = json!({ "share": "str", "pass_code_token": "t3" });
        assert_eq!(pick_share_object(&weird)["pass_code_token"], "t3");
    }

    #[test]
    fn search_url_filters_encoded() {
        // 与 PikPak 搜索同构：filters 整串逐字符对齐设计稿再 encodeQueryComponent。
        assert_eq!(
            search_url("lofi beats", "pt1"),
            "https://api-pan.xunlei.com/drive/v1/files?parent_id=*&search=lofi+beats&filters=%7B%22trashed%22%3A%7B%22match%22%3A%22exact%22%2C%22value%22%3A%22false%22%7D%7D&page_token=pt1"
        );
    }

    #[test]
    fn file_from_search_item_maps_fields() {
        let e = json!({
            "id": "f1",
            "name": "a.flac",
            "kind": "drive#folder",
            "size": 123,
            "parent_id": "p0",
        });
        let f = file_from_search_item(&e);
        assert_eq!(f["id"], "f1");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], true);
        assert_eq!(f["size"], 123);
        assert_eq!(f["parentId"], "p0");
        // 缺字段：isDir 回 false、parentId 回空串；播放只需 id，path 留空。
        let f2 = file_from_search_item(&json!({ "id": "f2", "name": "b.mp3" }));
        assert_eq!(f2["isDir"], false);
        assert_eq!(f2["parentId"], "");
        assert!(f.get("path").is_none());
    }
}
