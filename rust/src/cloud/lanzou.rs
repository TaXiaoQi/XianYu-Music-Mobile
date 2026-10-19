// 蓝奏云 provider（httpPassword；分享免登录免转存直链 directPlayable=true）。
//
// 移植自移动端 providers/lanzou_provider.dart（六个代理 op 逐行对齐）。
// http_login_support.dart 被蓝奏使用的 HttpLoginGate 限频与 md5Hex 账号指纹
// 仅服务账密登录流程——登录留在 Dart 侧，六个 op 不涉及，无需移植。
//
// 关键行为对齐点：
// - 接口为 HTML 页面形态，靠正则解析（域名常变，页面结构自适应尽力而为）；
//   解析出的直链直接塞 file.token 跨页传递（list_dir 文件行 token=分享页地址）；
// - Dart cloudGet/cloudPostForm 底层 appRequest 为手动重定向跟随（上限 5 跳、
//   303/302 非 GET 降级 GET、逐跳携带同一组请求头），蓝奏多 route 域名降级
//   即依赖该语义——request_follow/resolve_url 在此复刻；
// - 我的网盘列表/直链 2026-10 改版走 AJAX（doupload.php task=47/5/22）：
//   框架页抽 uid+vei，文件夹/文件分离返回，文件 token='f:<id>' 直链时换
//   分享页链接；旧 HTML 解析函数保留兼容单测与旧数据；
// - transfer_share：Dart 抛 UnsupportedError('该盘分享不支持转存') → 502 同文案；
// - 直链 TTL 20 分钟，随 expireAt 毫秒时间戳回传。

use regex::Regex;
use serde_json::{json, Value};

use super::http::{self, Body, Outbound};
use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1";
/// 分享页 2026-10 改版仅 PC UA 下返回内联 sign + ajaxfile.php 结构。
const PC_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

/// 常见音频扩展名（对齐 CloudFile.audioExts）。
const AUDIO_EXTS: &[&str] = &[
    "mp3", "flac", "wav", "m4a", "aac", "ogg", "ape", "dsf", "dff", "wma", "opus", "aiff", "aif",
    "alac", "wv", "tak", "tta", "ac3", "dts",
];

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 我的网盘请求头（UA + Referer；cookie 非空才带，对齐 Dart _h）。
fn h_headers(cookie: &str) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Referer".to_string(), "https://pc.woozooo.com/".to_string()),
    ];
    if !cookie.is_empty() {
        h.push(("Cookie".to_string(), cookie.to_string()));
    }
    h
}

/// 直链播放请求头（Dart 固定 {'User-Agent': _ua}）。
fn direct_link_headers() -> Value {
    // 蓝奏直链与解析时的 UA 绑定：/file/ 链接须带解析会话同一 PC UA，
    // 否则返回 200 OK 的 ~4KB HTML 挑战页（封面/歌词/时长/播放全挂）。
    json!({ "User-Agent": PC_UA })
}

/// acw_sc__v2 位置重排表 + 异或 mask（直链域 lanrar.com 等套了阿里云
/// WAF：无 cookie 请求一律 200 + ~4.3KB 混淆 JS 挑战页；页面算法固定——
/// 40 位 hex arg1 按位置表重排后与固定 mask 逐字节异或即 cookie 值，
/// 2026-10 实测算出的 cookie 有效）。
const ACW_POS: [usize; 40] = [
    15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11, 39, 18, 20, 8,
    14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36,
];
const ACW_MASK: &str = "3000176000856006061501533003690027800375";

/// 挑战页 arg1 → acw_sc__v2 cookie 值（q[z]=arg1[m[z]-1] 重排后逐字节异或）。
fn acw_sc_v2(arg1: &str) -> Option<String> {
    let bytes = arg1.as_bytes();
    if bytes.len() != 40 {
        return None;
    }
    let mut reordered = [0u8; 40];
    for (z, &pos) in ACW_POS.iter().enumerate() {
        reordered[z] = bytes[pos - 1];
    }
    let mask = ACW_MASK.as_bytes();
    let mut out = String::with_capacity(40);
    for i in (0..40).step_by(2) {
        let a = u8::from_str_radix(std::str::from_utf8(&reordered[i..i + 2]).ok()?, 16).ok()?;
        let b = u8::from_str_radix(std::str::from_utf8(&mask[i..i + 2]).ok()?, 16).ok()?;
        out.push_str(&format!("{:02x}", a ^ b));
    }
    Some(out)
}

fn is_acw_challenge(body: &str) -> bool {
    body.len() > 256 && body.contains("var arg1='") && body.contains("acw_sc__v2")
}

/// 直链域 WAF 预过：探一次直链，遇挑战页算 cookie 并合并响应 Set-Cookie
/// 重试一次。返回（需随直链下发的 Cookie 头, 最后一轮响应体）——响应体
/// 供二次验证页解包（4766 字节「验证并下载」页带 file/sign 常量）。
/// 未遇挑战 cookie=None；两轮仍挑战 cookie=None 放弃。
async fn acw_probe(direct_url: &str) -> (Option<String>, String) {
    let mut cookies: Vec<(String, String)> = Vec::new();
    let pairs_str = |c: &[(String, String)]| {
        c.iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    };
    for _ in 0..2 {
        let mut h = vec![
            ("User-Agent".to_string(), PC_UA.to_string()),
            // 8KB：验证页 ~4.8KB 全量入 body，真音频也不会拉大。
            ("Range".to_string(), "bytes=0-8191".to_string()),
        ];
        if !cookies.is_empty() {
            h.push(("Cookie".to_string(), pairs_str(&cookies)));
        }
        let Ok(resp) = http::request("GET", direct_url, &h, None).await else {
            return (None, String::new());
        };
        if !is_acw_challenge(&resp.body) {
            for (k, val) in resp.set_cookie_pairs() {
                cookies.retain(|(k2, _)| k2 != &k);
                cookies.push((k, val));
            }
            // 验证会话与「无 Range 的完整 GET」绑定：浏览器点下载是不带
            // Range 的，Range 探测建立的会话在 ajax.php 校验时被拒（报
            // 「验证码错误」）。识别出验证页后按浏览器方式无 Range 重取
            // 一次——服务端在验证会话内仍回 ~4.8KB 页面，不会真拉文件流。
            if resp.body.contains("ajax.php") {
                let h2 = vec![
                    ("User-Agent".to_string(), PC_UA.to_string()),
                    ("Cookie".to_string(), pairs_str(&cookies)),
                ];
                if let Ok(resp2) = http::request("GET", direct_url, &h2, None).await {
                    for (k, val) in resp2.set_cookie_pairs() {
                        cookies.retain(|(k2, _)| k2 != &k);
                        cookies.push((k, val));
                    }
                    return (Some(pairs_str(&cookies)), resp2.body);
                }
            }
            return (
                if cookies.is_empty() { None } else { Some(pairs_str(&cookies)) },
                resp.body,
            );
        }
        let arg1 = match resp
            .body
            .split("var arg1='")
            .nth(1)
            .and_then(|s| s.split('\'').next())
        {
            Some(a) => a.to_string(),
            None => return (None, resp.body),
        };
        let v = match acw_sc_v2(&arg1) {
            Some(v) => v,
            None => return (None, resp.body),
        };
        cookies.retain(|(k, _)| k != "acw_sc__v2");
        cookies.push(("acw_sc__v2".to_string(), v));
        for (k, val) in resp.set_cookie_pairs() {
            cookies.retain(|(k2, _)| k2 != &k);
            cookies.push((k, val));
        }
    }
    (None, String::new())
}

/// 验证页 JS data 常量提取：'file':'...' 与 'sign':'...'（页面硬编码）。
fn extract_verify_file_sign(body: &str) -> Option<(String, String)> {
    let re = regex::Regex::new(r"'(file|sign)'\s*:\s*'([^']+)'").ok()?;
    let mut file = String::new();
    let mut sign = String::new();
    for c in re.captures_iter(body) {
        match c.get(1).map(|m| m.as_str()) {
            Some("file") => file = c[2].to_string(),
            Some("sign") => sign = c[2].to_string(),
            _ => {}
        }
    }
    (!file.is_empty() && !sign.is_empty()).then_some((file, sign))
}

/// 直链域二次验证页（「验证并下载」，4766 字节）：页面 JS down_r(el) 就是
/// POST 同目录 ajax.php（file/el/sign 表单，X-Requested-With），响应
/// {zt:'1', url} 即真地址——纯协议复刻。浏览器真实路径：用户点
/// down_r(1)，失败时页面 setTimeout(window.location.reload()) 刷新重拿
/// 新 sign 再点——sign 按页面轮次签发，旧 sign 即报「验证码错误」。这里
/// 复刻同流程：失败后无 Range 重取验证页（新 sign）再 POST，最多 3 轮。
async fn unpack_lanrar_verify(
    direct: &str,
    cookie: Option<&str>,
    body: &str,
) -> Result<Option<String>, String> {
    if !body.contains("ajax.php") {
        return Ok(None);
    }
    let ajax_url = resolve_url(direct, "ajax.php");
    let origin = direct.split_once("://").map(|(scheme, rest)| {
        let host = rest.split('/').next().unwrap_or("");
        format!("{scheme}://{host}")
    });
    let mut cur_body = body.to_string();
    // 会话 cookie 可在 reload 中持续累积（浏览器行为），从只读参数复制
    let mut cookie_pairs: Vec<(String, String)> = Vec::new();
    if let Some(c) = cookie {
        for kv in c.split("; ") {
            if let Some((k, v)) = kv.split_once('=') {
                cookie_pairs.push((k.to_string(), v.to_string()));
            }
        }
    }
    let cookie_str = |pairs: &[(String, String)]| {
        pairs
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    };
    let mut last = String::new();
    for _round in 0..3 {
        let (file, sign) = match extract_verify_file_sign(&cur_body) {
            Some(fs) => fs,
            None => return Err("验证页缺 file/sign 常量".to_string()),
        };
        for el in ["2"] {
            // 只走 el=2（box2「网络异常验证」档，2026-10 实测唯一放行档；
            // el=1/3 一律「验证码错误」，且 el=1 先发会污染 sign——同 sign
            // 再发 el=2 只回 '?SignError'，必须 reload 换新 sign）。
            let mut h = vec![
                ("User-Agent".to_string(), PC_UA.to_string()),
                ("Referer".to_string(), direct.to_string()),
                ("X-Requested-With".to_string(), "XMLHttpRequest".to_string()),
            ];
            if let Some(o) = &origin {
                h.push(("Origin".to_string(), o.clone()));
            }
            if !cookie_pairs.is_empty() {
                h.push(("Cookie".to_string(), cookie_str(&cookie_pairs)));
            }
            let resp = http::post_form(
                &ajax_url,
                &h,
                vec![
                    ("file".to_string(), file.clone()),
                    ("el".to_string(), el.to_string()),
                    ("sign".to_string(), sign.clone()),
                ],
            )
            .await
            .map_err(|e| format!("ajax 网络失败: {e}"))?;
            for (k, val) in resp.set_cookie_pairs() {
                cookie_pairs.retain(|(k2, _)| k2 != &k);
                cookie_pairs.push((k, val));
            }
            if let Ok(j) = resp.json() {
                let zt_ok = match j.get("zt") {
                    // ajax.php 实测回数字 1（页面 JS 用宽松相等 `== '1'` 兼容
                    // 两类型）；as_str 对数字永不匹配，会把已拿到的真地址
                    // 当失败处理
                    Some(Value::String(s)) => s == "1",
                    Some(Value::Number(n)) => n.as_i64() == Some(1),
                    _ => false,
                };
                if zt_ok {
                    let url = j.get("url").and_then(Value::as_str).unwrap_or("");
                    // 异常态（如 sign 被污染后回 '?SignError'）非真地址，
                    // 仅接受 http 绝对链接
                    if url.starts_with("http") {
                        return Ok(Some(url.replace("\\/", "/")));
                    }
                }
            }
            // 实测（2026-10）：服务端签发 sign 后 ~1-3s 才生效，立即 POST
            // 必回 '?SignError'（zt=1 但 url 非真地址）；同 sign 等待后重发
            // 即成功。此处等 2.5s 重发一次，仍失败才走 reload 换新 sign。
            tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
            let resp = http::post_form(
                &ajax_url,
                &h,
                vec![
                    ("file".to_string(), file.clone()),
                    ("el".to_string(), "2".to_string()),
                    ("sign".to_string(), sign.clone()),
                ],
            )
            .await
            .map_err(|e| format!("ajax 网络失败: {e}"))?;
            for (k, val) in resp.set_cookie_pairs() {
                cookie_pairs.retain(|(k2, _)| k2 != &k);
                cookie_pairs.push((k, val));
            }
            last = format!(
                "el=2(retry) status={} body={}",
                resp.status,
                &resp.body[..resp.body.len().min(200)]
            );
            if let Ok(j) = resp.json() {
                let zt_ok = match j.get("zt") {
                    // ajax.php 实测回数字 1（页面 JS 用宽松相等 `== '1'` 兼容
                    // 两类型）；as_str 对数字永不匹配，会把已拿到的真地址
                    // 当失败处理
                    Some(Value::String(s)) => s == "1",
                    Some(Value::Number(n)) => n.as_i64() == Some(1),
                    _ => false,
                };
                if zt_ok {
                    let url = j.get("url").and_then(Value::as_str).unwrap_or("");
                    if url.starts_with("http") {
                        return Ok(Some(url.replace("\\/", "/")));
                    }
                    last = format!("{last} (zt=1 但 url 非真地址: {url})");
                }
            }
        }
        // 页面失败分支：setTimeout(window.location.reload())——无 Range
        // 重取验证页（服务端按轮次签发新 sign），会话 cookie 持续累积。
        let mut h = vec![("User-Agent".to_string(), PC_UA.to_string())];
        if !cookie_pairs.is_empty() {
            h.push(("Cookie".to_string(), cookie_str(&cookie_pairs)));
        }
        let Ok(resp) = http::request("GET", direct, &h, None).await else {
            break;
        };
        for (k, val) in resp.set_cookie_pairs() {
            cookie_pairs.retain(|(k2, _)| k2 != &k);
            cookie_pairs.push((k, val));
        }
        cur_body = resp.body;
        if !cur_body.contains("ajax.php") {
            break; // 刷新后不再是验证页（可能已放行/变挑战页），停止
        }
    }
    Err(last)
}

/// 直链 json 统一组装：UA 头 + acw WAF cookie（预过挑战）+ 二次验证页
/// 解包（ajax.php 换真地址）。验证页解包失败直接报错（带 ajax 响应摘要
/// 透传到 Dart 预探日志），不回退验证页 URL——那对探针/播放器毫无用处。
async fn direct_link_json_with_waf(
    direct: &str,
    name: &str,
    size: i64,
    expire_ms: i64,
) -> Result<Value, (i32, String)> {
    let mut headers = direct_link_headers();
    let (cookie, probe_body) = acw_probe(direct).await;
    if let Some(c) = &cookie {
        headers["Cookie"] = json!(c);
    }
    match unpack_lanrar_verify(direct, cookie.as_deref(), &probe_body).await {
        Ok(Some(real)) => {
            Ok(direct_link_json(&real, headers, Some(name), Some(size), Some(expire_ms)))
        }
        Ok(None) => Ok(direct_link_json(direct, headers, Some(name), Some(size), Some(expire_ms))),
        Err(d) => Err(biz_err(format!("蓝奏验证页解包失败: {d}"))),
    }
}

/// Dart (x ?? '').toString() 语义：null/缺失 → ''，字符串原样，其余 JSON 序列化。
fn jstr(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn html_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
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

async fn get_follow(url: &str, headers: &[(String, String)]) -> Result<Outbound, String> {
    request_follow("GET", url, headers, None).await
}

async fn post_form_follow(
    url: &str,
    headers: &[(String, String)],
    form: Vec<(String, String)>,
) -> Result<Outbound, String> {
    request_follow("POST", url, headers, Some(Body::Form(form))).await
}

// ── HTML 正则提取（纯函数，便于单测） ────────────────────

/// 文件夹行：f_id=(\d+) 与名称就近配对（HTML 脆弱，尽力而为）。
fn extract_folder_rows(body: &str) -> Vec<(String, String)> {
    let re = Regex::new(r"f_id='?(\d+)'?[^>]*>[\s\S]{0,400}?class='t'>([^<]+)").unwrap();
    re.captures_iter(body)
        .map(|c| (c[1].to_string(), html_unescape(&c[2]).trim().to_string()))
        .collect()
}

/// class='t' 锚点名称列表（文件夹/文件名混排，顺序即文档序）。
fn extract_names(body: &str) -> Vec<String> {
    let re = Regex::new(r"class='t'[^>]*>([^<]{1,120})</a>").unwrap();
    re.captures_iter(body).map(|c| c[1].to_string()).collect()
}

/// 文件页链接（去重保序）：mydisk/u.php 排除，/fn? 相对链接补 pc.woozooo.com。
fn extract_file_links(body: &str) -> Vec<String> {
    let re =
        Regex::new(r"(?i)(?:https?://[a-z0-9]+\.lanzou[a-z]?\.com/|/fn\?)[A-Za-z0-9_.-]+").unwrap();
    let mut out: Vec<String> = Vec::new();
    for c in re.captures_iter(body) {
        let raw = c[0].to_string();
        if raw.contains("mydisk") || raw.contains("u.php") {
            continue;
        }
        let link = if raw.starts_with('/') {
            format!("https://pc.woozooo.com{raw}")
        } else {
            raw
        };
        if !out.contains(&link) {
            out.push(link);
        }
    }
    out
}

/// 多文件页 iframe 子页链接（src 含 file 才收；`//` 开头补 https:）。
fn iframe_sub_links(page: &str) -> Vec<String> {
    let re = Regex::new(r#"(?i)<iframe[^>]+src="([^"]+)""#).unwrap();
    let mut out = Vec::new();
    for c in re.captures_iter(page) {
        let src = c[1].to_string();
        if src.contains("file") {
            out.push(if src.starts_with("//") {
                format!("https:{src}")
            } else {
                src
            });
        }
    }
    out
}

/// 分享页 JS 内联 sign（`var isngis = ''` 空声明后再赋值，取非空那条）。
fn extract_share_sign(page: &str) -> Option<&str> {
    Regex::new(r"var isngis = '([^']{20,})'")
        .ok()?
        .captures(page)?
        .get(1)
        .map(|m| m.as_str())
}

/// 分享页 file id（ajaxfile.php?file=N）。
fn extract_share_file_id(page: &str) -> Option<&str> {
    Regex::new(r"ajaxfile\.php\?file=(\d+)")
        .ok()?
        .captures(page)?
        .get(1)
        .map(|m| m.as_str())
}

/// 页面标题；去常见尾缀「xxx - 蓝奏云」，空则 None。
fn page_title(page: &str) -> Option<String> {
    let re = Regex::new(r"(?i)<title>([^<]{1,120})</title>").unwrap();
    let m = re.captures(page)?;
    let mut t = html_unescape(&m[1]).trim().to_string();
    let tail = Regex::new(r"\s*[-–]\s*蓝奏云\s*$").unwrap();
    t = tail.replace(&t, "").to_string();
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

/// 只收音频扩展名；名称判后缀（对齐 Dart listDir 的内联判断）。
fn audio_ext_ok(name: &str) -> bool {
    match name.rfind('.') {
        Some(dot) => AUDIO_EXTS.contains(&name[dot + 1..].to_ascii_lowercase().as_str()),
        None => false,
    }
}

// ── 内部请求（对齐 Dart 私有方法） ──────────────────────

/// Dart _get：GET 分享页，失败/非 2xx 返回空串。2026-10 改版分享页仅
/// PC UA 下返回内联 sign + ajaxfile.php 结构，用 PC_UA。
async fn get_page(url: &str) -> String {
    match get_follow(url, &[("User-Agent".to_string(), PC_UA.to_string())]).await {
        Ok(r) if r.is_ok() => r.body,
        _ => String::new(),
    }
}

/// 分享页 → 子页（iframe）→ sign + ajaxfile.php → 直链。
async fn resolve_share_page_files(share_url: &str, pwd: &str) -> Result<Vec<Value>, (i32, String)> {
    let page = get_page(share_url).await;
    if page.is_empty() {
        return Err(biz_err("分享已失效"));
    }
    // 顶层可能是多文件页（iframe 列表）或单文件页。
    let sub_links = iframe_sub_links(&page);
    if sub_links.is_empty() {
        // 单文件页：直接解析出直链。
        let direct = direct_from_page(&page, pwd).await;
        let name = page_title(&page).unwrap_or_else(|| "蓝奏云文件".to_string());
        return Ok(vec![file_json(
            share_url,
            &name,
            false,
            0,
            None,
            None,
            Some(direct.as_deref().unwrap_or(share_url)),
        )]);
    }
    let mut files = Vec::new();
    for sub in sub_links.iter().take(30) {
        let sub_page = get_page(sub).await;
        if sub_page.is_empty() {
            continue;
        }
        let direct = direct_from_page(&sub_page, pwd).await;
        let name = page_title(&sub_page).unwrap_or_else(|| "蓝奏云文件".to_string());
        files.push(file_json(
            sub,
            &name,
            false,
            0,
            None,
            None,
            Some(direct.as_deref().unwrap_or(sub)),
        ));
    }
    Ok(files)
}

/// 页面 sign + file id → POST apifile.woozooo.com/ajaxfile.php
/// （action=downprocess）→ dom + /file/ + url 直链（2026-10 改版）。
async fn direct_from_page(page: &str, pwd: &str) -> Option<String> {
    let sign = extract_share_sign(page)?;
    let file_id = extract_share_file_id(page)?;
    let url = format!("https://apifile.woozooo.com/ajaxfile.php?file={file_id}");
    let headers = vec![
        ("User-Agent".to_string(), PC_UA.to_string()),
        ("Referer".to_string(), "https://wwi.lanzouo.com/".to_string()),
    ];
    let resp = post_form_follow(
        &url,
        &headers,
        vec![
            ("action".to_string(), "downprocess".to_string()),
            ("sign".to_string(), sign.to_string()),
            ("kd".to_string(), "1".to_string()),
            ("p".to_string(), pwd.to_string()),
        ],
    )
    .await
    .ok()?;
    if !resp.is_ok() {
        return None;
    }
    let j = resp.json().ok()?;
    if j.get("zt").and_then(Value::as_i64) != Some(1) {
        return None; // 密码错/分享失效等。
    }
    let dom = jstr(j.get("dom"));
    let url2 = jstr(j.get("url"));
    if !dom.starts_with("http") || url2.is_empty() {
        return None;
    }
    Some(format!("{}/file/{}", dom.trim_end_matches('/'), url2))
}

/// 分享页直链：单文件页直接出直链；多文件页先找首个 iframe（不过滤 file）。
async fn direct_from_share_page(
    url: &str,
    name: &str,
    size: i64,
    pwd: &str,
) -> Result<Value, (i32, String)> {
    let page = get_page(url).await;
    if page.is_empty() {
        return Err(biz_err("分享已失效"));
    }
    let mut target = page;
    let re = Regex::new(r#"(?i)<iframe[^>]+src="([^"]+)""#).unwrap();
    if let Some(m) = re.captures(&target) {
        let src = m[1].to_string();
        let sub = if src.starts_with("//") {
            format!("https:{src}")
        } else {
            src
        };
        target = get_page(&sub).await;
    }
    let direct = direct_from_page(&target, pwd)
        .await
        .ok_or_else(|| biz_err("分享已失效"))?;
    Ok(direct_link_json_with_waf(&direct, name, size, now_ms() + 20 * 60 * 1000).await?)
}

// ── op 实现 ─────────────────────────────────────────────

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let resp = get_follow(
        "https://pc.woozooo.com/mydisk.php?item=files&action=index",
        &h_headers(&req.cred_str("cookie")),
    )
    .await;
    // Dart try/catch：任何异常按未登录处理。
    let valid = match resp {
        Ok(r) => r.is_ok() && !r.body.contains("mlogin"),
        Err(_) => false,
    };
    Ok(CloudOut::plain(json!({ "valid": valid })))
}

// ── 我的网盘（2026-10 AJAX 接口）─────────────────────────

/// 框架页 → (uid, vei)：列表接口 POST /doupload.php?uid=N 需带页内联的
/// 加密串 vei（'vei':'xxx'）。
fn extract_uid_vei(body: &str) -> Option<(String, String)> {
    let uid = Regex::new(r"doupload\.php\?uid=(\d+)")
        .ok()?
        .captures(body)?
        .get(1)?
        .as_str()
        .to_string();
    let vei = Regex::new(r"'vei':'([^']+)'")
        .ok()?
        .captures(body)?
        .get(1)?
        .as_str()
        .to_string();
    Some((uid, vei))
}

/// "28.4 M" → 字节数（蓝奏列表 JSON 的 size 为格式化文本）。
fn parse_lanzou_size(s: &str) -> i64 {
    let t = s.trim();
    let num_end = t
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(t.len());
    let num: f64 = t[..num_end].trim().parse().unwrap_or(0.0);
    let mul: f64 = match t[num_end..].trim().to_uppercase().as_str() {
        "B" => 1.0,
        "K" | "KB" => 1024.0,
        "M" | "MB" => 1024.0 * 1024.0,
        "G" | "GB" => 1024.0 * 1024.0 * 1024.0,
        "T" | "TB" => 1024.0 * 1024.0 * 1024.0 * 1024.0,
        _ => 1.0,
    };
    (num * mul) as i64
}

/// POST doupload.php（task 语义见 comm.js：47 目录树 / 5 文件列表 /
/// 22 文件分享链接）。uid 为空时 URL 不带 ?uid=（对齐 comm.js 各处）。
async fn doupload(
    cookie: &str,
    uid: &str,
    form: Vec<(&str, String)>,
) -> Result<Value, (i32, String)> {
    let url = if uid.is_empty() {
        "https://pc.woozooo.com/doupload.php".to_string()
    } else {
        format!("https://pc.woozooo.com/doupload.php?uid={uid}")
    };
    let pairs: Vec<(String, String)> =
        form.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
    let resp = post_form_follow(&url, &h_headers(cookie), pairs).await.map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    resp.json().map_err(biz_err)
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let path = req.param_str("path");
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let cookie = req.cred_str("cookie");
    // 框架页抽 uid + vei（改版后文件列表全走 AJAX，HTML 不再有文件行）。
    let frame = get_follow(
        "https://pc.woozooo.com/mydisk.php?item=files&action=index",
        &h_headers(&cookie),
    )
    .await
    .map_err(biz_err)?;
    if !frame.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let Some((uid, vei)) = extract_uid_vei(&frame.body) else {
        return Err(biz_err("目录列表请求失败"));
    };
    let folder_id = if path.is_empty() { "-1" } else { path.as_str() };
    let mut files = Vec::new();
    // 文件夹（task=47，不分页）；翻页时跳过避免跨页重复。
    if page == 1 {
        let folders = doupload(
            &cookie,
            &uid,
            vec![
                ("task", "47".to_string()),
                ("folder_id", folder_id.to_string()),
                ("vei", vei.clone()),
            ],
        )
        .await?;
        if let Some(arr) = folders.get("text").and_then(Value::as_array) {
            for f in arr {
                let id = jstr(f.get("fol_id"));
                let name = html_unescape(&jstr(f.get("name"))).trim().to_string();
                if id.is_empty() || name.is_empty() {
                    continue;
                }
                files.push(file_json(&id, &name, true, 0, Some(&path), None, None));
            }
        }
    }
    // 文件（task=5，pg 翻页；info==0 表示还有下一页）。
    let list = doupload(
        &cookie,
        &uid,
        vec![
            ("task", "5".to_string()),
            ("folder_id", folder_id.to_string()),
            ("pg", page.to_string()),
            ("vei", vei),
        ],
    )
    .await?;
    if let Some(arr) = list.get("text").and_then(Value::as_array) {
        for f in arr {
            let id = jstr(f.get("id"));
            let name = html_unescape(&jstr(f.get("name_all"))).trim().to_string();
            if id.is_empty() {
                continue;
            }
            // 只收音频扩展名；名称判后缀。
            if !audio_ext_ok(&name) {
                continue;
            }
            let size = parse_lanzou_size(&jstr(f.get("size")));
            // token 存 'f:<id>'，直链时 task=22 换分享页链接（对齐
            // direct_link 的 token 语义）。
            let token = format!("f:{id}");
            files.push(file_json(&token, &name, false, size, Some(&path), None, Some(&token)));
        }
    }
    // 蓝奏云 task=5 语义（对齐 comm.js）：info==0 还有下一页，info==1
    // 已到最后一页——与直觉相反，判断不能写 != 0。
    // 实测（2026-10-18）：请求页码超出范围时蓝奏云仍返回 info==0 且
    // text 为空——此时必须停止，否则全盘遍历会无限翻页。空页判定用
    // 原始 text 条数（files 已按音频扩展名过滤，不能反映真实空页）。
    let raw_page_count = list
        .get("text")
        .and_then(Value::as_array)
        .map_or(0, |a| a.len());
    let has_next =
        list.get("info").and_then(Value::as_i64).unwrap_or(1) == 0 && raw_page_count > 0;
    let next_cursor = if has_next {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

/// 免登录免转存：每个文件解析出直链塞 token。
async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "lanzou")?;
    let share_url = if info.url.is_empty() {
        req.param_str("url")
    } else {
        info.url.clone()
    };
    let pwd = req.param_str("pwd");
    let files = resolve_share_page_files(&share_url, &pwd).await?;
    if files.is_empty() {
        return Err(biz_err("分享已失效"));
    }
    let share_id = if info.share_id.is_empty() {
        share_url.clone()
    } else {
        info.share_id.clone()
    };
    let passcode = if pwd.is_empty() { None } else { Some(pwd.as_str()) };
    Ok(CloudOut::plain(share_parse_json(
        "lanzou",
        files,
        Some(&share_id),
        None,
        passcode,
        true,
    )))
}

/// directPlayable=true，不支持转存（Dart 抛 UnsupportedError）。
fn transfer_share() -> (i32, String) {
    biz_err("该盘分享不支持转存")
}

/// 我的网盘文件：file.token 为 'f:<id>'（列表时写入，2026-10 改版 AJAX
/// 列表不含分享链接）或旧数据的分享页地址。'f:' 前缀走 task=22 换分享
/// 链接（需登录 cred）再解析直链；http 直通免登录。
async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let file = req.param_obj("file");
    let name = jstr(file.get("name"));
    let size = file.get("size").and_then(Value::as_i64).unwrap_or(0);
    let token = jstr(file.get("token"));
    if token.starts_with("http") {
        return Ok(CloudOut::plain(
            direct_from_share_page(&token, &name, size, "").await?,
        ));
    }
    let file_id = token.strip_prefix("f:").unwrap_or(&token);
    if file_id.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    require_cred(req)?;
    let j = doupload(
        &req.cred_str("cookie"),
        "",
        vec![("task", "22".to_string()), ("file_id", file_id.to_string())],
    )
    .await?;
    if j.get("zt").and_then(Value::as_i64) != Some(1) {
        return Err(biz_err("直链获取失败"));
    }
    let info = j.get("info").cloned().unwrap_or(Value::Null);
    let base = jstr(info.get("is_newd"));
    let fid = jstr(info.get("f_id"));
    if !base.starts_with("http") || fid.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let share_url = format!("{}/{}", base.trim_end_matches('/'), fid);
    Ok(CloudOut::plain(
        direct_from_share_page(&share_url, &name, size, &jstr(info.get("pwd"))).await?,
    ))
}

/// 分享免转存直链：parseShareLink 时直链已塞 file.token；否则按分享页重解析。
/// Dart getShareDirectLink 不使用凭据（免登录直链），空 cred 可解析。
async fn share_direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let file = req.param_obj("file");
    let share = req.param_obj("share");
    let name = jstr(file.get("name"));
    let size = file.get("size").and_then(Value::as_i64).unwrap_or(0);
    let expire = now_ms() + 20 * 60 * 1000;
    let token = jstr(file.get("token"));
    if token.starts_with("http") {
        return Ok(CloudOut::plain(
            direct_link_json_with_waf(&token, &name, size, expire).await?,
        ));
    }
    // token 是分享页地址 → 重新解析（分享密码回填）。
    let pwd = jstr(share.get("passcode"));
    let url = if !token.is_empty() {
        token
    } else {
        jstr(share.get("shareId"))
    };
    let files = resolve_share_page_files(&url, &pwd).await?;
    for f in &files {
        let f_token = jstr(f.get("token"));
        if f.get("name").and_then(Value::as_str) == Some(name.as_str())
            && f_token.starts_with("http")
        {
            return Ok(CloudOut::plain(
                direct_link_json_with_waf(&f_token, &name, size, expire).await?,
            ));
        }
    }
    Err(biz_err("分享已失效"))
}

pub async fn dispatch(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    match req.op.as_str() {
        "validate" => validate(req).await,
        "list_dir" => list_dir(req).await,
        // HTML 页面形态无检索接口。
        "search_files" => Err(biz_err("该盘不支持文件搜索")),
        "parse_share" => parse_share(req).await,
        "transfer_share" => Err(transfer_share()),
        "direct_link" => direct_link(req).await,
        "share_direct_link" => share_direct_link(req).await,
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_unescape_entities() {
        assert_eq!(
            html_unescape("a&amp;b&lt;c&gt;d&quot;e&#39;f&apos;g"),
            "a&b<c>d\"e'f'g"
        );
        // 与 Dart 逐段 replaceAll 一致：&amp; 先还原，&lt; 再还原。
        assert_eq!(html_unescape("&amp;lt;"), "<");
    }

    #[test]
    fn acw_sc_v2_algorithm() {
        // 浏览器执行挑战页 JS 的实测样本（2026-10）。
        assert_eq!(
            acw_sc_v2("388CB9CA1F823E5E9B1E5115A727DB455AA936A0").as_deref(),
            Some("6ad54956f1916217a58daab9d554e2ccbc07a05c")
        );
        let challenge = format!(
            "<html><script>var arg1='A';{}</script>",
            "x".repeat(300) + "acw_sc__v2"
        );
        assert!(is_acw_challenge(&challenge));
        assert!(!is_acw_challenge("short"));
    }

    #[test]
    fn extract_verify_file_sign_sample() {
        // 设备探针日志实拍验证页（2026-10，节选 data 行）。
        let page = r#"<script> $.ajax({ type : 'post', url : 'ajax.php',
            data : { 'file':'UDhWdV10U3cGIwZqB3xTfVN5A2JWb1NiASgGd11kVDdQN1Nh==','el':el,'sign':'AzIFZQ5qBWMFYFMzC2YCOwdvAjUHOQ==' },
            dataType : 'json' }); </script>"#;
        let (file, sign) = extract_verify_file_sign(page).unwrap();
        assert_eq!(file, "UDhWdV10U3cGIwZqB3xTfVN5A2JWb1NiASgGd11kVDdQN1Nh==");
        assert_eq!(sign, "AzIFZQ5qBWMFYFMzC2YCOwdvAjUHOQ==");
        // 非验证页返回 None。
        assert!(extract_verify_file_sign("<html>普通页</html>").is_none());
    }

    #[test]
    fn headers_with_and_without_cookie() {
        let h = h_headers("ylogin=abc");
        assert_eq!(h[0].0, "User-Agent");
        assert_eq!(h[1].1, "https://pc.woozooo.com/");
        assert_eq!(h[2], ("Cookie".to_string(), "ylogin=abc".to_string()));
        assert_eq!(h_headers("").len(), 2);
    }

    #[test]
    fn uid_vei_extracted_from_frame() {
        let body = "url : '/doupload.php?uid=5355434' data:{task:5, 'vei':'UFRRUwZUAQ0BA1NWAFo='}";
        let (uid, vei) = extract_uid_vei(body).unwrap();
        assert_eq!(uid, "5355434");
        assert_eq!(vei, "UFRRUwZUAQ0BA1NWAFo=");
        assert!(extract_uid_vei("no markers").is_none());
    }

    #[test]
    fn lanzou_size_parsed() {
        assert_eq!(parse_lanzou_size("28.4 M"), 29779558);
        assert_eq!(parse_lanzou_size("3 KB"), 3072);
        assert_eq!(parse_lanzou_size("512 B"), 512);
        assert_eq!(parse_lanzou_size("1 G"), 1073741824);
        assert_eq!(parse_lanzou_size("bad"), 0);
        assert_eq!(parse_lanzou_size(""), 0);
    }

    #[test]
    fn folder_rows_extracted() {
        let body = "<tr><a f_id='111' onclick=\"go()\"> junk </a><a class='t'>Song A</a></tr>\
                    <tr><a f_id=222 title=y>more</a><a class='t'>FLAC 集</a></tr>";
        let rows = extract_folder_rows(body);
        assert_eq!(
            rows,
            vec![
                ("111".to_string(), "Song A".to_string()),
                ("222".to_string(), "FLAC 集".to_string()),
            ]
        );
        assert!(extract_folder_rows("no match here").is_empty());
    }

    #[test]
    fn name_rows_extracted() {
        let body = "<a class='t' href=\"x\">song one.mp3</a> <a class='t' data-x>y</a>";
        assert_eq!(
            extract_names(body),
            vec!["song one.mp3".to_string(), "y".to_string()]
        );
    }

    #[test]
    fn file_links_extracted_and_deduped() {
        let body = concat!(
            "<a href=\"https://wwe.lanzouw.com/ikZ1abc\">song.mp3</a>",
            "<a href=\"/fn?iKz2def\">f2.flac</a>",
            "<a href=\"https://wwe.lanzouw.com/u.php?a=b\">skip</a>",
            "<a href=\"https://wwe.lanzouw.com/ikZ1abc\">dup</a>",
            "<a href=\"https://pc.woozooo.com/mydisk.php?a=1\">skip2</a>",
        );
        assert_eq!(
            extract_file_links(body),
            vec![
                "https://wwe.lanzouw.com/ikZ1abc".to_string(),
                "https://pc.woozooo.com/fn?iKz2def".to_string(),
            ]
        );
    }

    #[test]
    fn iframe_sub_links_filtered() {
        let page = concat!(
            "<iframe src=\"https://sub.lanzouw.com/file123.html\"></iframe>\n",
            "<iframe src=\"//other.lanzoue.com/file456.htm\"></iframe>\n",
            "<iframe src=\"https://ads.example.com/frame.htm\"></iframe>\n",
            "<iframe src='/single.html'></iframe>",
        );
        assert_eq!(
            iframe_sub_links(page),
            vec![
                "https://sub.lanzouw.com/file123.html".to_string(),
                "https://other.lanzoue.com/file456.htm".to_string(),
            ]
        );
    }

    #[test]
    fn share_sign_file_id_extracted() {
        let page = concat!(
            "var isngis = '';\n",
            "var isngis = 'CG5WaA08UmMIAQQ7BjYFOVQ9BDNQOwc2';\n",
            "url : 'https://apifile.woozooo.com/ajaxfile.php?file=324374513'",
        );
        assert_eq!(
            extract_share_sign(page),
            Some("CG5WaA08UmMIAQQ7BjYFOVQ9BDNQOwc2")
        );
        assert_eq!(extract_share_file_id(page), Some("324374513"));
        // 空声明不匹配（长度 <20）。
        assert!(extract_share_sign("var isngis = '';").is_none());
        assert!(extract_share_file_id("no marker").is_none());
    }

    #[test]
    fn page_title_strips_suffix() {
        assert_eq!(
            page_title("<html><title>Gray - 蓝奏云</title>"),
            Some("Gray".to_string())
        );
        assert_eq!(
            page_title("<TITLE>test&amp;demo</TITLE>"),
            Some("test&demo".to_string())
        );
        assert_eq!(page_title("<title>   </title>"), None);
        assert_eq!(page_title("no title"), None);
    }

    #[test]
    fn audio_ext_filter() {
        assert!(audio_ext_ok("a.MP3"));
        assert!(audio_ext_ok("b.flac"));
        assert!(!audio_ext_ok("c.txt"));
        assert!(!audio_ext_ok("nodot"));
        assert!(!audio_ext_ok("d."));
    }

    #[test]
    fn redirect_resolution_and_host() {
        assert_eq!(
            resolve_url("https://a.com/x/y", "https://b.com/z"),
            "https://b.com/z"
        );
        assert_eq!(resolve_url("https://a.com/x/y", "//b.com/z"), "https://b.com/z");
        assert_eq!(resolve_url("https://a.com/x/y", "/top"), "https://a.com/top");
        assert_eq!(
            resolve_url("https://a.com/x/y?k=1", "c.mp3"),
            "https://a.com/x/c.mp3"
        );
        assert_eq!(resolve_url("https://a.com", "c"), "https://a.com/c");
    }
}
