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
// - share_direct_link / direct_link 免登录：Dart 不使用凭据（分享页匿名可取），
//   空 cred 可解析，不做 require_cred；
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
    json!({ "User-Agent": UA })
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

/// Uri.tryParse(url).host 最小实现：scheme:// 与 /?# 之间，去 userinfo/端口。
fn host_of(url: &str) -> String {
    let rest = match url.split_once("://") {
        Some((_, r)) => r,
        None => return String::new(),
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let mut host = &rest[..end];
    if let Some(i) = host.rfind('@') {
        host = &host[i + 1..];
    }
    if !host.starts_with('[') {
        if let Some(i) = host.find(':') {
            host = &host[..i];
        }
    }
    host.to_string()
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

/// 隐含 input（name/value 顺序可反，双向匹配；name 空跳过；同名后写覆盖）。
fn extract_hidden_inputs(page: &str) -> Vec<(String, String)> {
    let re = Regex::new(
        r#"(?i)<input[^>]+(?:name="([^"]*)"[^>]+value="([^"]*)"|value="([^"]*)"[^>]+name="([^"]*)")"#,
    )
    .unwrap();
    let mut out: Vec<(String, String)> = Vec::new();
    for c in re.captures_iter(page) {
        let name = c
            .get(1)
            .or_else(|| c.get(4))
            .map(|m| m.as_str().trim())
            .unwrap_or("");
        if name.is_empty() {
            continue;
        }
        let value_raw = c
            .get(2)
            .or_else(|| c.get(3))
            .map(|m| m.as_str().trim())
            .unwrap_or("");
        let value = html_unescape(value_raw);
        if let Some(slot) = out.iter_mut().find(|(k, _)| k == name) {
            slot.1 = value;
        } else {
            out.push((name.to_string(), value));
        }
    }
    out
}

/// /ajaxm.php 响应 → 直链：zt==1 且 url 为绝对地址取 url，否则 dom+url。
fn ajaxm_direct_url(j: &Value) -> Option<String> {
    let zt = j.get("zt").and_then(Value::as_i64).unwrap_or(0);
    if zt != 1 {
        return None; // 分享已失效等。
    }
    let dom = jstr(j.get("dom"));
    let url = jstr(j.get("url"));
    if url.starts_with("http") {
        return Some(url);
    }
    if !dom.is_empty() && !url.is_empty() {
        return Some(format!("{dom}{url}"));
    }
    None
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

/// Dart _get：GET 分享页，失败/非 2xx 返回空串。
async fn get_page(url: &str) -> String {
    match get_follow(url, &[("User-Agent".to_string(), UA.to_string())]).await {
        Ok(r) if r.is_ok() => r.body,
        _ => String::new(),
    }
}

/// 分享页 → 子页（iframe）→ 隐含表单 → /ajaxm.php → 直链。
async fn resolve_share_page_files(share_url: &str) -> Result<Vec<Value>, (i32, String)> {
    let page = get_page(share_url).await;
    if page.is_empty() {
        return Err(biz_err("分享已失效"));
    }
    // 顶层可能是多文件页（iframe 列表）或单文件页。
    let sub_links = iframe_sub_links(&page);
    if sub_links.is_empty() {
        // 单文件页：直接解析出直链。
        let direct = direct_from_page(&page, &host_of(share_url)).await;
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
        let direct = direct_from_page(&sub_page, &host_of(sub)).await;
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

/// 子页隐含表单参数 → POST /ajaxm.php → dom+url 直链。
async fn direct_from_page(page: &str, host: &str) -> Option<String> {
    let pairs = extract_hidden_inputs(page);
    if pairs.is_empty() {
        return None;
    }
    let url = format!("https://{host}/ajaxm.php");
    let headers = vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Referer".to_string(), format!("https://{host}/")),
    ];
    let resp = post_form_follow(&url, &headers, pairs).await.ok()?;
    if !resp.is_ok() {
        return None;
    }
    ajaxm_direct_url(&resp.json().ok()?)
}

/// 分享页直链：单文件页直接出直链；多文件页先找首个 iframe（不过滤 file）。
async fn direct_from_share_page(url: &str, name: &str, size: i64) -> Result<Value, (i32, String)> {
    let page = get_page(url).await;
    if page.is_empty() {
        return Err(biz_err("分享已失效"));
    }
    let mut host = host_of(url);
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
        host = host_of(&sub);
    }
    let direct = direct_from_page(&target, &host)
        .await
        .ok_or_else(|| biz_err("分享已失效"))?;
    Ok(direct_link_json(
        &direct,
        direct_link_headers(),
        Some(name),
        Some(size),
        Some(now_ms() + 20 * 60 * 1000),
    ))
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

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let path = req.param_str("path");
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let mut url = "https://pc.woozooo.com/mydisk.php?item=files&action=index".to_string();
    if !path.is_empty() {
        url.push_str("&f_id=");
        url.push_str(&http::url_encode(&path));
    }
    url.push_str(&format!("&page={page}"));
    let resp = get_follow(&url, &h_headers(&req.cred_str("cookie")))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let body = resp.body;
    let mut files = Vec::new();
    for (id, name) in extract_folder_rows(&body) {
        files.push(file_json(&id, &name, true, 0, Some(&path), None, None));
    }
    // 文件行：文件页链接作为 token（后续直链复用）；与名称按文档序就近配对。
    let names = extract_names(&body);
    let links = extract_file_links(&body);
    let mut i = 0usize;
    for link in &links {
        if i >= names.len() {
            break;
        }
        let n = html_unescape(&names[i]).trim().to_string();
        i += 1;
        // 只收音频扩展名；名称判后缀。
        if !audio_ext_ok(&n) {
            continue;
        }
        files.push(file_json(link, &n, false, 0, Some(&path), None, Some(link)));
    }
    let has_next = files.len() as i64 >= 30;
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
    let files = resolve_share_page_files(&share_url).await?;
    if files.is_empty() {
        return Err(biz_err("分享已失效"));
    }
    let share_id = if info.share_id.is_empty() {
        share_url.clone()
    } else {
        info.share_id.clone()
    };
    let pwd = req.param_str("pwd");
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

/// 我的网盘文件：file.token 为分享页地址（浏览页入口解析时写入）。
/// Dart getDirectLink 只读 file.token，凭据不参与请求 → 不做 require_cred。
async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let file = req.param_obj("file");
    let name = jstr(file.get("name"));
    let size = file.get("size").and_then(Value::as_i64).unwrap_or(0);
    let token = jstr(file.get("token"));
    if token.starts_with("http") {
        return Ok(CloudOut::plain(
            direct_from_share_page(&token, &name, size).await?,
        ));
    }
    Err(biz_err("直链获取失败"))
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
        return Ok(CloudOut::plain(direct_link_json(
            &token,
            direct_link_headers(),
            Some(&name),
            Some(size),
            Some(expire),
        )));
    }
    // token 是分享页地址 → 重新解析。
    let url = if !token.is_empty() {
        token
    } else {
        jstr(share.get("shareId"))
    };
    let files = resolve_share_page_files(&url).await?;
    for f in &files {
        let f_token = jstr(f.get("token"));
        if f.get("name").and_then(Value::as_str) == Some(name.as_str())
            && f_token.starts_with("http")
        {
            return Ok(CloudOut::plain(direct_link_json(
                &f_token,
                direct_link_headers(),
                Some(&name),
                Some(size),
                Some(expire),
            )));
        }
    }
    Err(biz_err("分享已失效"))
}

pub async fn dispatch(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    match req.op.as_str() {
        "validate" => validate(req).await,
        "list_dir" => list_dir(req).await,
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
    fn headers_with_and_without_cookie() {
        let h = h_headers("ylogin=abc");
        assert_eq!(h[0].0, "User-Agent");
        assert_eq!(h[1].1, "https://pc.woozooo.com/");
        assert_eq!(h[2], ("Cookie".to_string(), "ylogin=abc".to_string()));
        assert_eq!(h_headers("").len(), 2);
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
    fn hidden_inputs_both_orders() {
        let page = concat!(
            "<form>",
            "<input type=\"hidden\" name=\"lx\" value=\"2\">",
            "<input type=\"hidden\" value=\"abc123\" name=\"fid\">",
            "<input type=\"text\" value=\"keep\" name=\"\">",
            "</form>",
        );
        assert_eq!(
            extract_hidden_inputs(page),
            vec![
                ("lx".to_string(), "2".to_string()),
                ("fid".to_string(), "abc123".to_string()),
            ]
        );
        assert!(extract_hidden_inputs("<p>no inputs</p>").is_empty());
    }

    #[test]
    fn ajaxm_json_extracts_direct() {
        assert_eq!(
            ajaxm_direct_url(&json!({"zt": 1, "dom": "https://d.cn", "url": "/f/x.mp3"})),
            Some("https://d.cn/f/x.mp3".to_string())
        );
        assert_eq!(
            ajaxm_direct_url(&json!({"zt": 1, "dom": "https://d.cn", "url": "http://full/x"})),
            Some("http://full/x".to_string())
        );
        assert_eq!(ajaxm_direct_url(&json!({"zt": 0, "dom": "a", "url": "b"})), None);
        assert_eq!(ajaxm_direct_url(&json!({"zt": 1, "dom": "a", "url": ""})), None);
        assert_eq!(ajaxm_direct_url(&json!({})), None);
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
        assert_eq!(host_of("https://sub.lanzouw.com/file.html?a=1"), "sub.lanzouw.com");
        assert_eq!(host_of("/relative.html"), "");
    }
}
