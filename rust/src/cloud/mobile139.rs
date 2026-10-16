// 移动云盘（139）业务代理（hcy 新版签名协议）。
//
// 2026-10-16 v2：老 orchestration 编排接口（personalCloud/catalog/
// listContents 等）已服务端下线（匿名/带 cookie 均回 200 + XML
// BaseResult「资源不存在」，非 JSON → 业务报「接口返回格式异常」）。网页版
// SPA 现走 personal-kd-njs /hcy 签名协议，逐项对齐 OpenList
// drivers/139（personal_new）：
// - 鉴权：Authorization: Basic base64("pc:账号:token")，不再依赖 cookie；
//   token 形如 xxx|1|yyy|过期ms|...，<15 天自动经 aas.caiyun 令牌刷新接口
//   续期（XML 报文），新 authorization 经 rotated_cred 带回回写。
// - 签名：mcloud-sign = "ts,rand,sign"；sign = calSign(body, ts, rand) =
//   大写 md5( md5(b64(sort(encodeURIComponent(body)))) + md5("ts:rand") )。
//   Go 版 encodeURIComponent（QueryEscape + 还原 !'()*、+→%20）与 JS
//   encodeURIComponent 语义完全一致，Rust 手写同语义实现。
// - 客户端身份头：2026-10 起服务端强制校验 X-Yun-* 头（Api-Version /
//   App-Channel / Channel-Source / Client-Info / Module-Type / Svc-Type），
//   缺任一项 hcy 网关即 404「认证失败」（PC 重放二分实锤），逐项对齐
//   OpenList 现役 newRequest()。
// - ts 为 "yyyy-MM-dd HH:mm:ss" 格式串（OpenList 同款；服务端仅用于参与
//   签名重算），rand 16 字符，两值随 mcloud-sign 原样上送。
// - cred 键：authorization（裸 base64，无 "Basic " 前缀）；旧 cookie-only
//   凭据按「登录已过期」处理，重新绑定即可。cookie 可选保留（旧转存接口）。
// - 登录在 Dart 端 WebView 内完成：页面内轮询 localStorage 缓存的
//   "Basic " 串 / MCloudVM auth 状态，由 completeLogin 组装 cred。
// - parse_share/share_direct_link（outLink V6 匿名接口）与 transfer_share
//   （best-effort 转存，带 cookie）本版不动。

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde_json::{json, Value};

use super::http::{self, Body, Outbound};
use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
/// hcy 个人盘网关（file/list、file/getDownloadUrl）。
const HCYSVC: &str = "https://personal-kd-njs.yun.139.com/hcy";
/// 令牌刷新（XML 报文，返回 <token> 新令牌）。
const AAS: &str = "https://aas.caiyun.feixin.10086.cn/tellin/authTokenRefresh.do";
const EXPIRED: &str = "登录已过期，请重新绑定";
/// 15 天内自动续期（OpenList 同款阈值）。
const REFRESH_WINDOW_MS: i64 = 15 * 24 * 60 * 60 * 1000;
/// 直链 TTL 30 分钟。
const DIRECT_TTL_MS: i64 = 30 * 60 * 1000;

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 播放器取流 UA（分享直链响应头用）。
const STREAM_UA: &str = UA;

// ── 签名（calSign，纯函数，单测对齐参考实现） ─────────────

/// JS encodeURIComponent 语义：保留 A-Za-z0-9 - _ . ! ~ * ' ( )，其余
/// 按 UTF-8 字节大写十六进制转义（空格 → %20）。
fn js_encode_uri_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'!'
            | b'\'' | b'(' | b')' | b'*' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// calSign：encodeURIComponent → 字符升序 → base64 →
/// md5(b64) + md5("ts:rand") → 大写 md5。
fn cal_sign(body: &str, ts: &str, rand_str: &str) -> String {
    let mut enc = js_encode_uri_component(body);
    let mut chars: Vec<char> = enc.chars().collect();
    chars.sort_unstable();
    enc = chars.into_iter().collect();
    let b64 = B64.encode(enc.as_bytes());
    let res = format!(
        "{}{}",
        md5_hex(&b64),
        md5_hex(&format!("{ts}:{rand_str}"))
    );
    md5_hex(&res).to_uppercase()
}

fn md5_hex(input: &str) -> String {
    format!("{:x}", md5::compute(input.as_bytes()))
}

// ── 鉴权（authorization 装配 / 过期判断 / 令牌刷新） ──────

struct AuthState {
    basic: String,
    account: String,
    token: String,
    /// token 第 4 段（unix 毫秒过期），解析失败按已过期。
    expiry_ms: i64,
}

/// 解析 cred.authorization（裸 base64，"pc:账号:token"）。
fn parse_authorization(auth_b64: &str) -> Result<AuthState, (i32, String)> {
    let decoded = B64
        .decode(auth_b64.as_bytes())
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .ok_or_else(|| biz_err(EXPIRED))?;
    let parts: Vec<&str> = decoded.splitn(3, ':').collect();
    if parts.len() < 3 || parts[0] != "pc" || parts[2].is_empty() {
        return Err(biz_err(EXPIRED));
    }
    let expiry_ms = parts[2]
        .split('|')
        .nth(3)
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);
    Ok(AuthState {
        basic: format!("Basic {auth_b64}"),
        account: parts[1].to_string(),
        token: parts[2].to_string(),
        expiry_ms,
    })
}

/// 取鉴权头；<15 天到期自动刷新令牌并返回新 authorization（rotated_cred 用）。
async fn prepare_auth(req: &CloudReq) -> Result<(String, Option<String>), (i32, String)> {
    let auth_b64 = req.cred_str("authorization");
    if auth_b64.is_empty() {
        return Err(biz_err(EXPIRED));
    }
    let st = parse_authorization(&auth_b64)?;
    let remain = st.expiry_ms - now_ms();
    if remain > REFRESH_WINDOW_MS {
        return Ok((st.basic, None));
    }
    if remain < 0 {
        return Err(biz_err(EXPIRED));
    }
    // XML 报文刷新（clienttype 656 = PC 端）。
    let body = format!(
        "<root><token>{}</token><account>{}</account><clienttype>656</clienttype></root>",
        st.token, st.account
    );
    let resp = http::request(
        "POST",
        AAS,
        &[
            ("Content-Type".to_string(), "application/xml".to_string()),
            ("User-Agent".to_string(), STREAM_UA.to_string()),
        ],
        Some(&Body::Raw(body)),
    )
    .await
    .map_err(|_| biz_err(EXPIRED))?;
    let text = &resp.body;
    let ret = xml_tag(text, "return").unwrap_or_default();
    let new_token = xml_tag(text, "token").unwrap_or_default();
    if !resp.is_ok() || ret != "0" || new_token.is_empty() {
        return Err(biz_err(EXPIRED));
    }
    let new_b64 = B64.encode(format!("pc:{}:{}", st.account, new_token).as_bytes());
    Ok((format!("Basic {new_b64}"), Some(new_b64)))
}

/// 极简 XML 标签取值（刷新报文是扁平 <root><k>v</k>… 结构）。
fn xml_tag(text: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(text[start..end].trim().to_string())
}

/// hcy 请求头全家桶（对齐 OpenList 现役 newRequest()，含 2026-10 起服务端
/// 强制校验的 X-Yun-* 客户端身份头，缺任一项即 404「认证失败」）：mcloud-sign
/// 用 "ts,rand,sign"，ts 为 "yyyy-MM-dd HH:mm:ss" 格式串。
fn hcy_headers(basic: &str, body: &str) -> Vec<(String, String)> {
    let ts = now_ms();
    let rand = format!("{:016x}", ts);
    let ts_str = format_unix_ts(ts / 1000);
    let sign = cal_sign(body, &ts_str, &rand);
    vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Accept".to_string(), "application/json, text/plain, */*".to_string()),
        ("Authorization".to_string(), basic.to_string()),
        ("Caller".to_string(), "web".to_string()),
        ("CMS-DEVICE".to_string(), "default".to_string()),
        ("mcloud-channel".to_string(), "1000101".to_string()),
        ("mcloud-client".to_string(), "10701".to_string()),
        ("mcloud-route".to_string(), "001".to_string()),
        ("mcloud-sign".to_string(), format!("{ts_str},{rand},{sign}")),
        ("mcloud-version".to_string(), "7.14.0".to_string()),
        ("Origin".to_string(), "https://yun.139.com".to_string()),
        ("Referer".to_string(), "https://yun.139.com/w/".to_string()),
        (
            "x-DeviceInfo".to_string(),
            "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||".to_string(),
        ),
        ("x-huawei-channelSrc".to_string(), "10000034".to_string()),
        ("x-inner-ntwk".to_string(), "2".to_string()),
        ("x-m4c-caller".to_string(), "PC".to_string()),
        ("x-m4c-src".to_string(), "10002".to_string()),
        ("x-SvcType".to_string(), "1".to_string()),
        ("X-Yun-Api-Version".to_string(), "v1".to_string()),
        ("X-Yun-App-Channel".to_string(), "10000034".to_string()),
        ("X-Yun-Channel-Source".to_string(), "10000034".to_string()),
        (
            "X-Yun-Client-Info".to_string(),
            "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||dW5kZWZpbmVk||".to_string(),
        ),
        ("X-Yun-Module-Type".to_string(), "100".to_string()),
        ("X-Yun-Svc-Type".to_string(), "1".to_string()),
        ("Inner-Hcy-Router-Https".to_string(), "1".to_string()),
    ]
}

/// unix 秒 → "yyyy-MM-dd HH:mm:ss"（UTC；服务端仅参与签名重算，不校验
/// 时钟，OpenList 本地时间的差异不影响）。
fn format_unix_ts(secs: i64) -> String {
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // civil_from_days（Howard Hinnant 算法）。
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02} {h:02}:{mi:02}:{s:02}")
}

/// 个人盘请求头（UA + Referer；cookie 非空才带；Content-Type 由 post_json
/// 注入）。仅旧转存接口继续使用。
fn h_headers(cookie: &str) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Referer".to_string(), "https://yun.139.com/".to_string()),
    ];
    if !cookie.is_empty() {
        h.push(("Cookie".to_string(), cookie.to_string()));
    }
    h
}

/// 分享 outLink 请求头（Dart 固定 {'User-Agent': _ua}，无 Referer/Cookie）。
fn share_headers() -> Vec<(String, String)> {
    vec![("User-Agent".to_string(), UA.to_string())]
}

/// Dart (x ?? '').toString() 语义：null/缺失 → ''，字符串原样，其余 JSON 序列化。
fn jstr(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

/// 最小化 Dart Uri.resolve：绝对地址原样；`//` 开头补 scheme；`/` 开头补
/// origin；其余按当前路径所在目录拼接。
fn resolve_url(base: &str, loc: &str) -> String {
    if loc.starts_with("http://") || loc.starts_with("https://") {
        return loc.to_string();
    }
    let Some((scheme, after)) = base.split_once("://") else {
        return loc.to_string();
    };
    if let Some(rest) = loc.strip_prefix("//") {
        return format!("{scheme}://{rest}");
    }
    let authority_end = after.find(['/', '?', '#']).unwrap_or(after.len());
    let origin = format!("{scheme}://{}", &after[..authority_end]);
    if loc.starts_with('/') {
        return format!("{origin}{loc}");
    }
    let path = &after[authority_end..];
    let path_only = path.split(['?', '#']).next().unwrap_or("");
    let dir = match path_only.rfind('/') {
        Some(i) => &path_only[..=i],
        None => "/",
    };
    format!("{origin}{dir}{loc}")
}

/// Dart appRequest 语义复刻：手动跟随重定向（上限 5 跳），303 / 302(非 GET)
/// 降级为 GET 并丢弃 body，逐跳携带同一组请求头。
async fn request_follow(
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: Option<Body>,
) -> Result<Outbound, String> {
    let mut current = url.to_string();
    let mut m = method.to_string();
    let mut b = body;
    let mut hops = 0usize;
    loop {
        let resp = http::request(&m, &current, headers, b.as_ref()).await?;
        if !(300..400).contains(&resp.status) {
            return Ok(resp);
        }
        let loc = resp.location().unwrap_or_default();
        if loc.is_empty() {
            return Err(format!("网络请求失败: 重定向缺少 Location: {current}"));
        }
        if hops >= 5 {
            return Err(format!("网络请求失败: 重定向次数超限: {current}"));
        }
        hops += 1;
        if resp.status == 303 || (resp.status == 302 && m != "GET") {
            m = "GET".to_string();
            b = None;
        }
        current = resolve_url(&current, &loc);
    }
}

async fn post_json_follow(
    url: &str,
    headers: &[(String, String)],
    body: &Value,
) -> Result<Outbound, String> {
    request_follow("POST", url, headers, Some(Body::Json(body.clone()))).await
}

/// hcy 带签 POST：body 字符串参与签名，Content-Type 由 post_json 注入；
/// 非 200 / 非 JSON / success==false 均透出中文错误（message 来自服务端）。
async fn hcy_post(basic: &str, url: &str, body: &Value) -> Result<Value, (i32, String)> {
    let body_str = body.to_string();
    let headers = hcy_headers(basic, &body_str);
    let resp = post_json_follow(url, &headers, body)
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("移动云盘接口请求失败"));
    }
    let j: Value = serde_json::from_str(&resp.body)
        .map_err(|_| biz_err("移动云盘接口返回格式异常"))?;
    if j.get("success") != Some(&json!(true)) {
        let msg = jstr(j.get("message"));
        return Err(biz_err(if msg.is_empty() {
            "移动云盘接口返回异常".to_string()
        } else {
            format!("移动云盘: {msg}")
        }));
    }
    Ok(j)
}

// ── JSON 条目映射（纯函数，便于单测） ───────────────────

/// hcy file/list items 条目 → CloudFile（type=="folder" 判目录）。
fn file_from_item(e: &Value) -> Value {
    let id = jstr(e.get("fileId"));
    let name = jstr(e.get("name"));
    let is_dir = jstr(e.get("type")) == "folder";
    let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
    let parent = match e.get("parentFileId") {
        Some(v) if !v.is_null() => jstr(Some(v)),
        _ => String::new(),
    };
    file_json(&id, &name, is_dir, size, Some(&parent), None, None)
}

/// contentList 条目 → CloudFile（isCatalog==1 判目录；parentId 缺省回请求路径）。
/// 搜索仍在用（hcy/file/search 设计稿形态）。
fn file_from_content(e: &Value, path: &str) -> Value {
    let id = jstr(e.get("contentId"));
    let name = jstr(e.get("contentName"));
    let is_dir = e.get("isCatalog").and_then(Value::as_i64) == Some(1);
    let size = e.get("contentSize").and_then(Value::as_i64).unwrap_or(0);
    let parent = match e.get("parentCatalogId") {
        Some(v) if !v.is_null() => jstr(Some(v)),
        _ => path.to_string(),
    };
    file_json(&id, &name, is_dir, size, Some(&parent), None, None)
}

/// outLinkInfo.fileList 条目 → CloudFile（分享解析场景，无 parentId）。
fn file_from_outlink(e: &Value) -> Value {
    let id = jstr(e.get("contentId"));
    let name = jstr(e.get("contentName"));
    let is_dir = e.get("isCatalog").and_then(Value::as_i64) == Some(1);
    let size = e.get("contentSize").and_then(Value::as_i64).unwrap_or(0);
    file_json(&id, &name, is_dir, size, None, None, None)
}

/// hcy file/list 请求体（纯函数，单测断言）：pageCursor 首页空串，翻页
/// 回传响应 nextPageCursor。根目录归一：hcy/SPA 根 catalogID 为 "/"
///（转存映射 `"/"===catalogID?0` 佐证；实测传 "root" 回 success+空列表），
/// 旧约定 "root"/"" 一并归一，兼容历史选录路径。
fn list_body(path: &str, cursor: &str) -> Value {
    let parent = match path {
        "" | "root" => "/",
        p => p,
    };
    json!({
        "imageThumbnailStyleList": ["Small", "Large"],
        "orderBy": "updated_at",
        "orderDirection": "DESC",
        "pageInfo": { "pageCursor": cursor, "pageSize": 100 },
        "parentFileId": parent,
    })
}

// ── op 实现 ─────────────────────────────────────────────

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (basic, rotated) = match prepare_auth(req).await {
        Ok(v) => v,
        Err(_) => return Ok(CloudOut::plain(json!({ "valid": false }))),
    };
    // Dart try/catch：任何异常按未登录处理。
    let valid = hcy_post(&basic, &format!("{HCYSVC}/file/list"), &list_body("root", ""))
        .await
        .is_ok();
    let out = json!({ "valid": valid });
    Ok(match rotated {
        Some(new_auth) => CloudOut::rotated(out, json!({ "authorization": new_auth })),
        None => {
            CloudOut::plain(out)
        }
    })
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let path = req.param_str("path");
    let cursor = req.param_str("cursor");
    let (basic, rotated) = prepare_auth(req).await?;
    let j = hcy_post(
        &basic,
        &format!("{HCYSVC}/file/list"),
        &list_body(&path, &cursor),
    )
    .await?;
    let list = j
        .get("data")
        .filter(|d| d.is_object())
        .and_then(|d| d.get("items"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let files: Vec<Value> = list.iter().filter(|e| e.is_object()).map(file_from_item).collect();
    let next_cursor = j
        .get("data")
        .filter(|d| d.is_object())
        .and_then(|d| d.get("nextPageCursor"))
        .map(|v| jstr(Some(v)))
        .unwrap_or_default();
    let next_cursor = if next_cursor.is_empty() { None } else { Some(next_cursor) };
    Ok(match rotated {
        Some(new_auth) => CloudOut::rotated(
            list_result_json(files, next_cursor),
            json!({ "authorization": new_auth }),
        ),
        None => CloudOut::plain(list_result_json(files, next_cursor)),
    })
}

/// 文件搜索：keyword 必填，cursor 为页码（与 list_dir 同风格），返回结构
/// 与 list_dir 同构（list_result_json）；条目映射复用 file_from_content
/// （搜索无目录上下文，parentId 缺省回空串）。
async fn search_files(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let keyword = req.param_str("keyword");
    if keyword.is_empty() {
        return Err(biz_err("缺少搜索关键词"));
    }
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let (basic, rotated) = prepare_auth(req).await?;
    let body = json!({
        "searchValue": keyword,
        "catalogType": 3,
        "pageBean": { "pageNum": page, "pageSize": 100 },
    });
    let j = hcy_post(&basic, &format!("{HCYSVC}/file/search"), &body).await?;
    let list = j
        .get("data")
        .filter(|d| d.is_object())
        .and_then(|d| d.get("contentList"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &list {
        if !e.is_object() {
            continue;
        }
        files.push(file_from_content(e, ""));
    }
    let has_next = files.len() as i64 >= 100;
    let next_cursor = if has_next {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(match rotated {
        Some(new_auth) => CloudOut::rotated(
            list_result_json(files, next_cursor),
            json!({ "authorization": new_auth }),
        ),
        None => CloudOut::plain(list_result_json(files, next_cursor)),
    })
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "mobile139")?;
    let guid = if info.share_id.is_empty() {
        info.url.clone()
    } else {
        info.share_id.clone()
    };
    let pwd = req.param_str("pwd");
    let resp = post_json_follow(
        "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6",
        &share_headers(),
        &json!({
            "outLinkGUID": guid,
            "passcode": pwd,
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("分享链接解析失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let list = j
        .get("data")
        .filter(|d| d.is_object())
        .and_then(|d| d.get("outLinkInfo"))
        .and_then(|o| o.get("fileList"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        return Err(biz_err("分享已失效"));
    }
    let files: Vec<Value> = list
        .iter()
        .filter(|e| e.is_object())
        .map(file_from_outlink)
        .collect();
    let passcode = if pwd.is_empty() { None } else { Some(pwd.as_str()) };
    Ok(CloudOut::plain(share_parse_json(
        "mobile139",
        files,
        Some(&guid),
        None,
        passcode,
        true,
    )))
}

/// 分享免转存直链（dlFromOutLinkV3）。Dart getShareDirectLink 不带凭据请求
/// （仅 UA），空 cred 可解析。
async fn share_direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let share = req.param_obj("share");
    let file = req.param_obj("file");
    let resp = post_json_follow(
        "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/dlFromOutLinkV3",
        &share_headers(),
        &json!({
            "outLinkGUID": jstr(share.get("shareId")),
            "passcode": jstr(share.get("passcode")),
            "fileIds": [file.get("id").cloned().unwrap_or(json!(""))],
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("分享直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let first = j
        .get("data")
        .filter(|d| d.is_object())
        .and_then(|d| d.get("fileList"))
        .and_then(Value::as_array)
        .and_then(|l| l.first())
        .cloned()
        .unwrap_or(Value::Null);
    let url = jstr(first.get("downloadUrl"));
    if url.is_empty() {
        return Err(biz_err("分享直链获取失败"));
    }
    let name = jstr(file.get("name"));
    let size = file.get("size").and_then(Value::as_i64).unwrap_or(0);
    Ok(CloudOut::plain(direct_link_json(
        &url,
        json!({ "User-Agent": UA }),
        Some(&name),
        Some(size),
        Some(now_ms() + DIRECT_TTL_MS),
    )))
}

/// best-effort 转存（139 分享本可直链，转存作为留档兜底）：失败静默忽略。
async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let share = req.param_obj("share");
    let ids: Vec<Value> = share
        .get("files")
        .and_then(Value::as_array)
        .map(|l| l.iter().map(|f| f.get("id").cloned().unwrap_or(json!(""))).collect())
        .unwrap_or_default();
    let _ = post_json_follow(
        "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IBatchOprTask/createOuterLinkBatchOprTask",
        &h_headers(&req.cred_str("cookie")),
        &json!({
            "outLinkGUID": jstr(share.get("shareId")),
            "passcode": jstr(share.get("passcode")),
            "taskType": 2,
            "fileIds": ids,
        }),
    )
    .await;
    Ok(CloudOut::plain(json!(
        { "files": share.get("files").cloned().unwrap_or_else(|| json!([])) }
    )))
}

/// 直链（hcy/file/getDownloadUrl，{fileId} 报文）：优先 cdnUrl（cdnSwitch），
/// 回落 url。
async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let file = req.param_obj("file");
    let (basic, rotated) = prepare_auth(req).await?;
    let j = hcy_post(
        &basic,
        &format!("{HCYSVC}/file/getDownloadUrl"),
        &json!({ "fileId": jstr(file.get("id")) }),
    )
    .await?;
    let data = j.get("data").filter(|d| d.is_object()).cloned().unwrap_or(json!({}));
    let cdn_switch = data.get("cdnSwitch").and_then(Value::as_i64) == Some(1);
    let url = if cdn_switch {
        jstr(data.get("cdnUrl"))
    } else {
        jstr(data.get("url"))
    };
    if url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let name = jstr(file.get("name"));
    let size = file.get("size").and_then(Value::as_i64).unwrap_or(0);
    let out = direct_link_json(
        &url,
        json!({ "User-Agent": STREAM_UA }),
        Some(&name),
        Some(size),
        Some(now_ms() + DIRECT_TTL_MS),
    );
    Ok(match rotated {
        Some(new_auth) => CloudOut::rotated(out, json!({ "authorization": new_auth })),
        None => CloudOut::plain(out),
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
        "share_direct_link" => share_direct_link(req).await,
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cal_sign_official_vector() {
        // 独立实现（PowerShell .NET md5/base64）生成的对照向量，算法逐行
        // 对齐 OpenList drivers/139 calSign。
        assert_eq!(
            cal_sign(r#"{"a":"周深歌单123"}"#, "1792128233219", "abcdefgh12345678"),
            "D6093DD9F20B51DD65ECBA49D16CA220"
        );
        // encodeURIComponent 保留字符语义：!'()* 原样、空格 %20。
        assert_eq!(
            js_encode_uri_component("a b!c*d'e(f)g~h-i_j.k"),
            "a%20b!c*d'e(f)g~h-i_j.k"
        );
        assert_eq!(js_encode_uri_component("周"), "%E5%91%A8");
    }

    #[test]
    fn authorization_roundtrip() {
        let st = parse_authorization(&B64.encode(b"pc:16608240512:1|a|b|9999999999999|c")).unwrap();
        assert_eq!(st.account, "16608240512");
        assert_eq!(st.token, "1|a|b|9999999999999|c");
        assert_eq!(st.expiry_ms, 9999999999999);
        assert_eq!(st.basic, format!("Basic {}", B64.encode(b"pc:16608240512:1|a|b|9999999999999|c")));
        // 非法 base64 / 非 pc 前缀 / 空 token → 过期。
        assert!(parse_authorization("%%%").is_err());
        assert!(parse_authorization(&B64.encode(b"xx:a:b")).is_err());
        assert!(parse_authorization(&B64.encode(b"pc:a:")).is_err());
        assert!(parse_authorization(&B64.encode(b"pc:a:short")).is_ok());
    }

    #[test]
    fn format_unix_ts_shape() {
        // 2026-10-16 06:03:53 UTC = 1792130633（PowerShell 独立核验）。
        assert_eq!(format_unix_ts(1792130633), "2026-10-16 06:03:53");
        assert_eq!(format_unix_ts(0), "1970-01-01 00:00:00");
    }

    #[test]
    fn hcy_headers_shape() {
        let h = hcy_headers("Basic eGc=", r#"{"a":1}"#);
        let keys: Vec<&str> = h.iter().map(|(k, _)| k.as_str()).collect();
        for need in [
            "User-Agent",
            "Accept",
            "Authorization",
            "Caller",
            "CMS-DEVICE",
            "mcloud-channel",
            "mcloud-client",
            "mcloud-route",
            "mcloud-sign",
            "mcloud-version",
            "Origin",
            "Referer",
            "x-DeviceInfo",
            "x-huawei-channelSrc",
            "x-inner-ntwk",
            "x-m4c-caller",
            "x-m4c-src",
            "x-SvcType",
            "X-Yun-Api-Version",
            "X-Yun-App-Channel",
            "X-Yun-Channel-Source",
            "X-Yun-Client-Info",
            "X-Yun-Module-Type",
            "X-Yun-Svc-Type",
            "Inner-Hcy-Router-Https",
        ] {
            assert!(keys.contains(&need), "missing {need}");
        }
        let sign = h.iter().find(|(k, _)| k == "mcloud-sign").unwrap();
        let parts: Vec<&str> = sign.1.split(',').collect();
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[2].len(), 32);
        assert_eq!(parts[2].to_uppercase(), parts[2]);
    }

    #[test]
    fn list_body_shape() {
        let b = list_body("/", "");
        assert_eq!(b["parentFileId"], "/");
        assert_eq!(b["orderBy"], "updated_at");
        assert_eq!(b["pageInfo"]["pageSize"], json!(100));
        assert_eq!(b["pageInfo"]["pageCursor"], "");
        let b2 = list_body("/", "CUR1");
        assert_eq!(b2["pageInfo"]["pageCursor"], "CUR1");
        // 旧约定 "root"/空 归一为 "/"（实测 hcy 对 "root" 回空列表）。
        assert_eq!(list_body("root", "")["parentFileId"], "/");
        assert_eq!(list_body("", "")["parentFileId"], "/");
        assert_eq!(list_body("abc", "")["parentFileId"], "abc");
    }

    #[test]
    fn item_mapping() {
        let e = json!({
            "fileId": "f1",
            "name": "song.flac",
            "type": "file",
            "size": 9,
            "parentFileId": "p9",
        });
        let f = file_from_item(&e);
        assert_eq!(f["id"], "f1");
        assert_eq!(f["name"], "song.flac");
        assert_eq!(f["isDir"], false);
        assert_eq!(f["size"], 9);
        assert_eq!(f["parentId"], "p9");
        let d = file_from_item(&json!({ "fileId": "d1", "name": "相册", "type": "folder" }));
        assert_eq!(d["isDir"], true);
        assert_eq!(d["parentId"], "");
    }

    #[test]
    fn jstr_semantics() {
        assert_eq!(jstr(Some(&json!("a"))), "a");
        assert_eq!(jstr(Some(&json!(5))), "5");
        assert_eq!(jstr(Some(&json!(null))), "");
        assert_eq!(jstr(None), "");
    }

    #[test]
    fn content_item_mapping() {
        let e = json!({
            "contentId": "c1",
            "contentName": "a.flac",
            "isCatalog": 0,
            "contentSize": 123,
            "parentCatalogId": "p9",
        });
        let f = file_from_content(&e, "root");
        assert_eq!(f["id"], "c1");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], false);
        assert_eq!(f["size"], 123);
        assert_eq!(f["parentId"], "p9");
    }

    #[test]
    fn outlink_item_mapping() {
        let e = json!({
            "contentId": "f1",
            "contentName": "song.mp3",
            "isCatalog": 0,
            "contentSize": 9,
        });
        let f = file_from_outlink(&e);
        assert_eq!(f["id"], "f1");
        assert_eq!(f["name"], "song.mp3");
        assert!(f.get("parentId").is_none());
    }

    #[test]
    fn redirect_resolution() {
        assert_eq!(
            resolve_url("https://a.com/x", "https://b.com/y"),
            "https://b.com/y"
        );
        assert_eq!(resolve_url("https://a.com/x", "//b.com/y"), "https://b.com/y");
        assert_eq!(resolve_url("https://a.com/x", "/y"), "https://a.com/y");
        assert_eq!(resolve_url("https://a.com/x/y", "z"), "https://a.com/x/z");
    }

    #[test]
    fn xml_tag_extract() {
        let xml = "<root><return>0</return><token>abc|1|d|1792|</token><desc>ok</desc></root>";
        assert_eq!(xml_tag(xml, "return").as_deref(), Some("0"));
        assert_eq!(xml_tag(xml, "token").as_deref(), Some("abc|1|d|1792|"));
        assert_eq!(xml_tag(xml, "missing"), None);
    }
}
