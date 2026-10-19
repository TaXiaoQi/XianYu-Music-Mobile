// 百度网盘 provider（双轨凭据）。
//
// - OAuth 轨（cred 含 accessToken/refreshToken）：开放平台 xpan API，
//   access_token 鉴权——登录凭据不受网页风控降权影响（WebView 会话
//   签发的 BDUSS 被百度服务端系统性拒绝，任何 API 通道 errno=-6）。
//   access_token 30 天有效，过期用 refresh_token 续（百度刷新会轮换
//   refresh_token，新凭据经 rotated_cred 带回落盘）。
//   注意：xpan 无搜索/分享 API，且 filemetas 有应用沙箱（默认仅
//   /apps/<应用名> 目录）——OAuth 轨 search/parse_share/transfer_share
//   明确报错，direct_link 依赖全盘权限申请结果。
// - Cookie 轨（cred 含 BDUSS）：网页 API（手填 Cookie 的账号），
//   分享列表/转存/搜索全功能保留。
//
// 移植自移动端 providers/baidu_provider.dart。关键行为对齐点：
// - parse_share 先 share/verify 换 randsk（BDCLND），再以
//   `Cookie: <登录态>; BDCLND=<urlencoded>` 拉 share/list；
// - 分享文件 token 存 `<shareid>:<from>`，转存时拆出 from（split(':').last）；
// - 转存前 ensureDir 建 /apps/弦予音乐（errno 12/-8 = 目录已存在可继续），
//   转存 sekey 是 verify 换来的 randsk，不是提取码本身；
// - 直链 dlink 手动跟随重定向归一终态 URL，host 命中 d2-ant/speed-limited
//   判限速；播放下载 UA 用 netdisk;P2SP;2.2.91.136;android-android；
// - 日志不打 cred/cookie 内容。

use std::collections::HashMap;

use serde_json::{json, Value};

use super::http;
use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::{biz_err, pre_parse_share, require_cred};

const APP_ID: &str = "250528";
const SAVE_DIR: &str = "/apps/弦予音乐";
// OAuth 凭据（pan.baidu.com/union 注册，与 Dart 侧 baidu_provider 一致）。
const OAUTH_CLIENT_ID: &str = "__BAIDU_APPKEY__";
const OAUTH_CLIENT_SECRET: &str = "__BAIDU_APPSECRET__";
// 统一移动 UA：百度网页会话与创建环境 UA 绑定——移动端 WebView（安卓
// UA）种的 Cookie 用桌面 UA 请求会判定会话无效（/disk/main 302 循环、
// api/list errno=-6）；实测移动 UA 对 WebView 与电脑浏览器种的 Cookie
// 均兼容，网页通道统一走移动 UA。
const UA: &str =
    "Mozilla/5.0 (Linux; Android 13; M2102K1C) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
// xpan dlink 下载校验 UA 前缀（开放平台规则：下载请求 UA 须为 netdisk 系）。
const NETDISK_UA: &str = "netdisk;P2SP;2.2.91.136;android-android;";

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// OAuth 轨判定：cred 带 refreshToken / accessToken 即为 OAuth 凭据。
fn is_oauth(cred: &Value) -> bool {
    cred.get("refreshToken")
        .and_then(Value::as_str)
        .map(|s| !s.is_empty())
        .unwrap_or(false)
        || cred
            .get("accessToken")
            .and_then(Value::as_str)
            .map(|s| !s.is_empty())
            .unwrap_or(false)
}

/// xpan 业务请求头（UA + access_token 走 query，无需 Cookie）。
fn oauth_headers() -> Vec<(String, String)> {
    vec![("User-Agent".into(), UA.into())]
}

/// 换 access_token：缓存有效直接用；否则用 refresh_token 续新，
/// 新凭据集交由调用方放进 rotated_cred（百度刷新轮换 refresh_token）。
async fn access_token(cred: &Value) -> Result<(String, Option<Value>), (i32, String)> {
    let cached = cred
        .get("accessToken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let expire_ms: i64 = cred
        .get("accessExpireMs")
        .and_then(Value::as_str)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    if !cached.is_empty() && now_ms() < expire_ms {
        return Ok((cached, None));
    }
    let refresh_token = cred
        .get("refreshToken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if refresh_token.is_empty() {
        return Err(biz_err("登录凭据缺失，请重新绑定"));
    }
    let resp = http::post_form(
        "https://openapi.baidu.com/oauth/2.0/token",
        &[("User-Agent".into(), UA.into())],
        vec![
            ("grant_type".into(), "refresh_token".into()),
            ("refresh_token".into(), refresh_token.clone()),
            ("client_id".into(), OAUTH_CLIENT_ID.into()),
            ("client_secret".into(), OAUTH_CLIENT_SECRET.into()),
        ],
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err(format!("凭据续期失败(http={})", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    let access = j
        .get("access_token")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if access.is_empty() {
        // 百度错误响应：{"error":"expired_token","error_description":"..."}
        let desc = j
            .get("error_description")
            .and_then(Value::as_str)
            .unwrap_or("");
        return Err(biz_err(format!(
            "登录已过期，请重新绑定{}",
            if desc.is_empty() {
                String::new()
            } else {
                format!("（{desc}）")
            }
        )));
    }
    let new_refresh = j
        .get("refresh_token")
        .and_then(Value::as_str)
        .unwrap_or(&refresh_token)
        .to_string();
    let expires_in = j.get("expires_in").and_then(Value::as_i64).unwrap_or(2_592_000);
    let s = |k: &str| {
        cred.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let new_cred = json!({
        "refreshToken": new_refresh,
        "accountId": s("accountId"),
        "nickname": s("nickname"),
        "accessToken": access,
        "accessExpireMs": (now_ms() + expires_in * 1000).to_string(),
    });
    Ok((access, Some(new_cred)))
}

/// xpan 请求 URL 拼接（纯函数，单测断言）：access_token + 业务参数
/// （method 也走 query，如 xpan_url("file", at, &[("method","list"), ...])）。
fn xpan_url(path: &str, access: &str, extra: &[(&str, &str)]) -> String {
    let mut url = format!("https://pan.baidu.com/rest/2.0/xpan/{path}?access_token={access}");
    for (k, v) in extra {
        url.push_str(&format!("&{k}={}", http::url_encode(v)));
    }
    url
}

/// `(x ?? '').toString()`：字符串原样、数值/布尔取字面量、其余为空串。
fn jstr(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

/// Dart `as num?` 转 i64（兼容小数形态）。
fn num_i64(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))
}

/// 凭据失效 errno：-6 身份验证失败（BDUSS 被拒/缺失，bdstoken 拿不到也
/// 落在这里），111 登录态过期。统一映射为简短重绑提示。
fn cred_expired(errno: i64) -> bool {
    errno == -6 || errno == 111
}

/// `a ?? b ?? ''` 的字符串版（仅跳过 null，空串不跳）。
fn coalesce_jstr(a: Option<&Value>, b: Option<&Value>) -> String {
    match a.filter(|v| !v.is_null()) {
        Some(v) => jstr(Some(v)),
        None => jstr(b),
    }
}

fn cred_pairs(cred: &Value) -> Vec<(String, String)> {
    cred.as_object()
        .map(|m| {
            m.iter()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// 通用请求头（UA / Referer disk/main / Cookie）。
fn auth_headers(cred: &Value) -> Vec<(String, String)> {
    vec![
        ("User-Agent".into(), UA.into()),
        ("Referer".into(), "https://pan.baidu.com/disk/main".into()),
        ("Cookie".into(), http::cookie_header(&cred_pairs(cred))),
    ]
}

/// 分享接口请求头（Referer 为 pan.baidu.com 根路径）。
fn share_headers(cookie: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".into(), UA.into()),
        ("Referer".into(), "https://pan.baidu.com/".into()),
        ("Cookie".into(), cookie.to_string()),
    ]
}

/// 登录态 Cookie 拼 BDCLND（verify 换来的 randsk，URL 编码后追加）。
fn cookie_with_randsk(base: &str, randsk: &str) -> String {
    if randsk.is_empty() {
        base.to_string()
    } else {
        format!("{base}; BDCLND={}", http::url_encode(randsk))
    }
}

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    // OAuth 轨：uinfo 探活。
    if is_oauth(&req.cred) {
        let (at, rotated) = access_token(&req.cred).await?;
        let url = xpan_url("nas", &at, &[("method", "uinfo")]);
        let ok = match http::get(&url, &oauth_headers()).await {
            Ok(resp) => resp.is_ok(),
            Err(_) => false,
        };
        return Ok(CloudOut {
            result: json!({ "valid": ok }),
            rotated_cred: rotated,
        });
    }
    // Cookie 轨：quota 探活。Dart 侧 try/catch 全吞：网络失败/JSON
    // 异常一律 valid=false。
    let url = "https://pan.baidu.com/api/quota?checkfree=1&checkexpire=1&clienttype=0&app_id=250528&web=1";
    let ok = match http::get(url, &auth_headers(&req.cred)).await {
        Ok(resp) => {
            resp.is_ok()
                && resp
                    .json()
                    .map(|j| num_i64(j.get("errno")) == Some(0))
                    .unwrap_or(false)
        }
        Err(_) => false,
    };
    Ok(CloudOut::plain(json!({ "valid": ok })))
}

/// xpan file list 条目 → CloudFile（映射纯函数，单测断言）。响应字段
/// path 即文件全路径（无独立 parent 字段），parentId 一并带 path。
fn file_from_xpan_item(e: &Value) -> Value {
    let path = jstr(e.get("path"));
    file_json(
        &jstr(e.get("fs_id")),
        &jstr(e.get("server_filename")),
        num_i64(e.get("isdir")) == Some(1),
        num_i64(e.get("size")).unwrap_or(0),
        Some(&path),
        Some(&path),
        None,
    )
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let dir = {
        let p = req.param_str("path");
        if p.is_empty() {
            "/".to_string()
        } else {
            p
        }
    };
    // OAuth 轨：xpan file list，游标为 start 偏移。
    if is_oauth(&req.cred) {
        let (at, rotated) = access_token(&req.cred).await?;
        let start: i64 = req.param_str("cursor").parse().unwrap_or(0);
        let url = xpan_url(
            "file",
            &at,
            &[
                ("method", "list"),
                ("dir", &dir),
                ("order", "name"),
                ("desc", "0"),
                ("limit", "100"),
                ("start", &start.to_string()),
                ("web", "1"),
            ],
        );
        let resp = http::get(&url, &oauth_headers()).await.map_err(biz_err)?;
        if !resp.is_ok() {
            return Err(biz_err(format!("目录列表请求失败(http={})", resp.status)));
        }
        let j = resp.json().map_err(biz_err)?;
        let errno = num_i64(j.get("errno")).unwrap_or(-1);
        if errno != 0 {
            if cred_expired(errno) {
                return Err(biz_err("登录已过期，请重新绑定"));
            }
            let msg = if errno == -7 {
                "目录不存在"
            } else if errno == 2 {
                "参数错误（应用可能无全盘权限，文件需在应用沙箱目录内）"
            } else {
                "目录列表请求失败"
            };
            return Err(biz_err(format!("{msg}(errno={errno})")));
        }
        let list = j.get("list").and_then(Value::as_array).cloned().unwrap_or_default();
        let files: Vec<Value> = list.iter().map(file_from_xpan_item).collect();
        let next_cursor = if files.len() >= 100 {
            Some((start + 100).to_string())
        } else {
            None
        };
        return Ok(CloudOut {
            result: list_result_json(files, next_cursor),
            rotated_cred: rotated,
        });
    }
    // Cookie 轨：网页 /api/list，游标为页码。
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let url = format!(
        "https://pan.baidu.com/api/list?clienttype=0&app_id={APP_ID}&web=1&order=name&desc=0&dir={}&limit=100&page={page}",
        http::url_encode(&dir)
    );
    let resp = http::get(&url, &auth_headers(&req.cred))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err(format!("目录列表请求失败(http={})", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    let errno = num_i64(j.get("errno")).unwrap_or(-1);
    if errno != 0 {
        if cred_expired(errno) {
            return Err(biz_err("登录已过期，请重新绑定"));
        }
        return Err(biz_err(format!("目录列表请求失败(errno={errno})")));
    }
    let list = j.get("list").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut files = Vec::new();
    for e in &list {
        files.push(file_json(
            &jstr(e.get("fs_id")),
            &jstr(e.get("server_filename")),
            num_i64(e.get("isdir")) == Some(1),
            num_i64(e.get("size")).unwrap_or(0),
            Some(&jstr(e.get("parent_path"))),
            Some(&jstr(e.get("path"))),
            None,
        ));
    }
    let next_cursor = if files.len() >= 100 {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

/// 文件搜索 URL（纯函数，单测断言）。端点 filesearch 为设计稿形态：
/// 全盘检索（dir=/），app_id 照抄 list，响应 list 与 /api/list 同构。
fn search_url(keyword: &str) -> String {
    format!(
        "https://pan.baidu.com/api/filesearch?dir=/&key={}&web=1&clienttype=0&app_id={APP_ID}",
        http::url_encode(keyword)
    )
}

/// filesearch 条目 → CloudFile（映射纯函数，单测断言）。
/// 播放（filemetas dlink）只需 fs_id；path 一并带回，响应无 parent_path
/// （parentId 留空）。
fn file_from_search_item(e: &Value) -> Value {
    file_json(
        &jstr(e.get("fs_id")),
        &jstr(e.get("server_filename")),
        num_i64(e.get("isdir")) == Some(1),
        num_i64(e.get("size")).unwrap_or(0),
        None,
        Some(&jstr(e.get("path"))),
        None,
    )
}

/// 文件搜索：keyword 必填；filesearch 无翻页参数，结果一次返回
/// （nextCursor 恒空），返回结构与 list_dir 同构（list_result_json）。
async fn search_files(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    // xpan 无全盘搜索 API，OAuth 轨明确降级提示。
    if is_oauth(&req.cred) {
        return Err(biz_err("OAuth 账号暂不支持全盘搜索（百度开放平台未提供接口）"));
    }
    let keyword = req.param_str("keyword");
    if keyword.is_empty() {
        return Err(biz_err("缺少搜索关键词"));
    }
    let resp = http::get(&search_url(&keyword), &auth_headers(&req.cred))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("搜索请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    if num_i64(j.get("errno")) != Some(0) {
        return Err(biz_err("搜索请求失败"));
    }
    let list = j.get("list").and_then(Value::as_array).cloned().unwrap_or_default();
    let files: Vec<Value> = list.iter().map(file_from_search_item).collect();
    Ok(CloudOut::plain(list_result_json(files, None)))
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    // 分享接口仅网页 API（Cookie 登录态），OAuth 轨明确提示。
    if is_oauth(&req.cred) {
        return Err(biz_err("分享解析需 Cookie 登录态：请用「填 Cookie」绑定的账号，或转存到网盘后播放"));
    }
    let info = pre_parse_share(req, "baidu")?;
    // Dart：info?.shareId ?? url。
    let surl = if info.share_id.is_empty() {
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
    // verify 换 randsk（BDCLND）；无提取码的分享 verify 也走一遍拿空 sekey。
    let verify_url = format!(
        "https://pan.baidu.com/share/verify?surl={surl}&t={}&channel=chunlei&clienttype=0&web=1&app_id={APP_ID}",
        now_ms()
    );
    let vresp = http::post_form(
        &verify_url,
        &auth_headers(&req.cred),
        vec![("pwd".into(), pwd.clone())],
    )
    .await
    .map_err(biz_err)?;
    let mut randsk = String::new();
    if vresp.is_ok() {
        let vj = vresp.json().map_err(biz_err)?;
        if num_i64(vj.get("errno")) == Some(0) {
            randsk = jstr(vj.pointer("/data/randsk"));
        }
        for (k, v) in vresp.set_cookie_pairs() {
            if k == "BDCLND" && randsk.is_empty() && !v.is_empty() {
                randsk = http::url_decode(&v);
            }
        }
    }
    let cookie = cookie_with_randsk(&http::cookie_header(&cred_pairs(&req.cred)), &randsk);
    let list_url = format!(
        "https://pan.baidu.com/share/list?clienttype=0&app_id={APP_ID}&web=1&shorturl={}&root=1",
        http::url_encode(&surl)
    );
    let lresp = http::get(&list_url, &share_headers(&cookie))
        .await
        .map_err(biz_err)?;
    if !lresp.is_ok() {
        return Err(biz_err("分享文件列表获取失败"));
    }
    let lj = lresp.json().map_err(biz_err)?;
    let errno = num_i64(lj.get("errno"));
    if errno == Some(-9) || errno == Some(-105) {
        return Err(biz_err("需要提取码"));
    }
    if errno != Some(0) {
        return Err(biz_err("分享已失效"));
    }
    let list = lj.get("list").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut files = Vec::new();
    for e in &list {
        // token 存 `<shareid>:<from>`，转存时用。
        let token = format!("{}:{}", jstr(e.get("share_id")), jstr(e.get("from")));
        files.push(file_json(
            &jstr(e.get("fs_id")),
            &coalesce_jstr(e.get("server_filename"), e.get("filename")),
            num_i64(e.get("isdir")) == Some(1),
            num_i64(e.get("size")).unwrap_or(0),
            None,
            Some(&jstr(e.get("path"))),
            Some(&token),
        ));
    }
    Ok(CloudOut::plain(share_parse_json(
        "baidu",
        files,
        Some(&surl),
        Some(&randsk),
        if pwd.is_empty() { None } else { Some(&pwd) },
        false,
    )))
}

/// 拉取 bdstoken（CSRF token，网页 /api/download、转存等写接口必带，
/// 缺失时返回 errno=-6）。
async fn bdstoken(cred: &Value) -> String {
    let tpl_url = format!(
        "https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id={APP_ID}&web=1&fields=[\"bdstoken\"]"
    );
    match http::get(&tpl_url, &auth_headers(cred)).await {
        Ok(resp) if resp.is_ok() => match resp.json() {
            Ok(j) => jstr(j.pointer("/result/bdstoken")),
            Err(_) => String::new(),
        },
        _ => String::new(),
    }
}

/// 确保转存目标目录存在并返回 bdstoken（errno 12/-8 = 目录已存在可继续）。
async fn ensure_dir(cred: &Value) -> Result<String, (i32, String)> {
    let bdstoken = bdstoken(cred).await;
    let create_url =
        format!("https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1&app_id={APP_ID}&clienttype=0");
    let create_resp = http::post_form(
        &create_url,
        &auth_headers(cred),
        vec![
            ("path".into(), SAVE_DIR.into()),
            ("isdir".into(), "1".into()),
            ("block_list".into(), "[]".into()),
            ("bdstoken".into(), bdstoken.clone()),
        ],
    )
    .await
    .map_err(biz_err)?;
    let errno = if create_resp.is_ok() {
        let j = create_resp.json().map_err(biz_err)?;
        num_i64(j.get("errno"))
    } else {
        Some(-1)
    };
    if errno != Some(0) && errno != Some(12) && errno != Some(-8) {
        return Err(biz_err("创建转存目录失败"));
    }
    Ok(bdstoken)
}

async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    // 分享接口仅网页 API（Cookie 登录态），OAuth 轨明确提示。
    if is_oauth(&req.cred) {
        return Err(biz_err("分享转存需 Cookie 登录态：请用「填 Cookie」绑定的账号"));
    }
    let share = req.param_obj("share");
    let files_in = share
        .get("files")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // 先确保转存目录存在（目录已存在不报错）。
    ensure_dir(&req.cred).await?;
    // sekey 是 verify 换来的 randsk（BDCLND），不是提取码本身。
    let sekey = share
        .get("shareToken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if sekey.is_empty() {
        return Err(biz_err("请先填写提取码"));
    }
    // from 取自首个分享文件的 token（`<shareid>:<from>` 拆尾段）。
    let from = files_in
        .first()
        .and_then(|f| f.get("token"))
        .and_then(Value::as_str)
        .unwrap_or(":")
        .rsplit(':')
        .next()
        .unwrap_or("")
        .to_string();
    let ids: Vec<String> = files_in.iter().map(|f| jstr(f.get("id"))).collect();
    let url = format!(
        "https://pan.baidu.com/share/transfer?shareid=&from={}&sekey={}&ondup=new&async=1&channel=chunlei&clienttype=0&web=1&app_id={APP_ID}",
        http::url_encode(&from),
        http::url_encode(&sekey)
    );
    let transfer_resp = http::post_form(
        &url,
        &share_headers(&http::cookie_header(&cred_pairs(&req.cred))),
        vec![
            ("path".into(), SAVE_DIR.into()),
            ("filelist".into(), json!(ids).to_string()),
        ],
    )
    .await
    .map_err(biz_err)?;
    if !transfer_resp.is_ok() {
        return Err(biz_err("转存失败"));
    }
    let tj = transfer_resp.json().map_err(biz_err)?;
    if num_i64(tj.get("errno")) != Some(0) {
        return Err(biz_err("转存失败：文件可能已存在或超限"));
    }
    let infos = tj
        .get("info")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut by_fs_id: HashMap<String, Value> = HashMap::new();
    for f in &files_in {
        by_fs_id.insert(jstr(f.get("id")), f.clone());
    }
    let mut out = Vec::new();
    for e in &infos {
        let new_id = jstr(e.get("to_fs_id"));
        if new_id.is_empty() {
            continue;
        }
        let old_id = jstr(e.get("from_fs_id"));
        let src = by_fs_id.get(&old_id);
        let name = src
            .map(|s| jstr(s.get("name")))
            .unwrap_or_default();
        let is_dir = src
            .map(|s| s.get("isDir").and_then(Value::as_bool).unwrap_or(false))
            .unwrap_or(false);
        let size = src.map(|s| num_i64(s.get("size")).unwrap_or(0)).unwrap_or(0);
        out.push(file_json(
            &new_id,
            &name,
            is_dir,
            size,
            None,
            Some(&format!("{SAVE_DIR}/{name}")),
            None,
        ));
    }
    if out.is_empty() {
        return Err(biz_err("转存失败：文件可能已存在或超限"));
    }
    Ok(CloudOut::plain(json!({ "files": out })))
}

fn host_of(url: &str) -> String {
    let after_scheme = match url.find("://") {
        Some(i) => &url[i + 3..],
        None => url,
    };
    let authority = after_scheme.split(['/', '?', '#']).next().unwrap_or("");
    let host = match authority.rfind('@') {
        Some(i) => &authority[i + 1..],
        None => authority,
    };
    if let Some(rest) = host.strip_prefix('[') {
        return rest.split(']').next().unwrap_or(host).to_string();
    }
    host.split(':').next().unwrap_or(host).to_string()
}

fn is_rate_limited(host: &str) -> bool {
    host.contains("d2-ant") || host.contains("speed-limited")
}

/// 相对 Location → 绝对 URL（仅覆盖绝对/协议相对/根相对三种，足够直链跳转）。
fn absolute_url(base: &str, loc: &str) -> Option<String> {
    if loc.starts_with("http://") || loc.starts_with("https://") {
        return Some(loc.to_string());
    }
    if let Some(rest) = loc.strip_prefix("//") {
        let scheme = base.split("://").next()?;
        return Some(format!("{scheme}://{rest}"));
    }
    if loc.starts_with('/') {
        let idx = base.find("://")? + 3;
        let host_end = base[idx..].find('/').map(|i| idx + i).unwrap_or(base.len());
        return Some(format!("{}{loc}", &base[..host_end]));
    }
    None
}

/// 直链重定向归一：手动跟随 3xx（最多 5 跳），失败原样返回（对齐 Dart
/// resolveFinalUrl 的 catch(_) return url）。
async fn resolve_final_url(url: &str, headers: &[(String, String)]) -> String {
    let mut current = url.to_string();
    for _ in 0..=5 {
        let resp = match http::get(&current, headers).await {
            Ok(r) => r,
            Err(_) => return url.to_string(),
        };
        if !(300..400).contains(&resp.status) {
            return current;
        }
        let loc = match resp.location() {
            Some(l) if !l.is_empty() => l,
            _ => return url.to_string(),
        };
        match absolute_url(&current, &loc) {
            Some(next) => current = next,
            None => return url.to_string(),
        }
    }
    url.to_string()
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let file = req.param_obj("file");
    let id = jstr(file.get("id"));
    let name = jstr(file.get("name"));
    let size = num_i64(file.get("size")).unwrap_or(0);

    // OAuth 轨：xpan filemetas dlink（应用沙箱——文件不在应用可访问
    // 目录时接口报错，文案提示全盘权限）。
    if is_oauth(&req.cred) {
        let (at, rotated) = access_token(&req.cred).await?;
        let url = xpan_url(
            "file",
            &at,
            &[
                ("method", "filemetas"),
                ("dlink", "1"),
                ("fsids", &format!("[{id}]")),
            ],
        );
        let resp = http::get(&url, &oauth_headers()).await.map_err(biz_err)?;
        if !resp.is_ok() {
            return Err(biz_err(format!("直链获取失败(http={})", resp.status)));
        }
        let j = resp.json().map_err(biz_err)?;
        let errno = num_i64(j.get("errno")).unwrap_or(-1);
        if errno != 0 {
            if cred_expired(errno) {
                return Err(biz_err("登录已过期，请重新绑定"));
            }
            let msg = if errno == 12 || errno == 2 {
                "文件不在应用可访问范围内（开放平台沙箱限制，需申请全盘权限；可先转存到 /apps 目录）"
            } else {
                "直链获取失败"
            };
            return Err(biz_err(format!("{msg}(errno={errno})")));
        }
        let dlink = j
            .get("list")
            .and_then(Value::as_array)
            .and_then(|a| a.first())
            .and_then(|d| d.get("dlink"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if dlink.is_empty() {
            return Err(biz_err("直链获取失败"));
        }
        // dlink 下载校验 UA 为 netdisk 系；302 跟随同 UA。
        let nd_headers = vec![("User-Agent".to_string(), NETDISK_UA.to_string())];
        let dlink = resolve_final_url(&dlink, &nd_headers).await;
        if is_rate_limited(&host_of(&dlink)) {
            return Err(biz_err("该文件被限速，暂无法播放"));
        }
        return Ok(CloudOut {
            result: direct_link_json(
                &dlink,
                json!({ "User-Agent": NETDISK_UA }),
                Some(&name),
                Some(size),
                Some(now_ms() + 8 * 3600 * 1000),
            ),
            rotated_cred: rotated,
        });
    }

    // Cookie 轨：网页 filemetas dlink 接口（GET fsids 数组参数）——旧
    // POST api/download 已废（errno=2 params error，2026-10 实测）。
    // 不能带 origin=dlna：dlna 源直链被 PCS 风控（31329 hit illeage
    // dlna）。dlink 302 跟随需 netdisk UA + 全量 cookie（缺 cookie 报
    // 31045 user not exists）；终态 baidupcs URL 自带签名授权，免
    // cookie 直连（Range 206 实测），播放头仅 netdisk UA。
    let resp = http::get(
        &format!(
            "https://pan.baidu.com/api/filemetas?dlink=1&fsids={}&clienttype=0&app_id={APP_ID}&web=1",
            http::url_encode(&format!("[{id}]"))
        ),
        &auth_headers(&req.cred),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err(format!("直链获取失败(http={})", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    let errno = num_i64(j.get("errno")).unwrap_or(-1);
    if errno != 0 {
        if cred_expired(errno) {
            return Err(biz_err("登录已过期，请重新绑定"));
        }
        return Err(biz_err(format!("直链获取失败(errno={errno})")));
    }
    // 响应 info[0].dlink。
    let dlink = j
        .get("info")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .and_then(|d| d.get("dlink"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if dlink.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    // 302 跟随：netdisk UA + 全量 cookie（PCS 会话校验点）。
    let nd_headers = vec![
        ("User-Agent".to_string(), NETDISK_UA.to_string()),
        (
            "Cookie".to_string(),
            http::cookie_header(&cred_pairs(&req.cred)),
        ),
    ];
    let dlink = resolve_final_url(&dlink, &nd_headers).await;
    if is_rate_limited(&host_of(&dlink)) {
        return Err(biz_err("该文件被限速，暂无法播放"));
    }
    Ok(CloudOut::plain(direct_link_json(
        &dlink,
        // 播放头带全量 cookie：d.pcs dlink 302 → baidupcs 终态期间
        // PCS 校验会话（缺 cookie 报 31045 user not exists）；resolve
        // 失败回退原 URL 时，播放器的手动重定向跟随（同头 5 跳）可完成
        // 302——cookie 随头透传。
        json!({
            "User-Agent": NETDISK_UA,
            "Cookie": http::cookie_header(&cred_pairs(&req.cred)),
        }),
        Some(&name),
        Some(size),
        Some(now_ms() + 8 * 3600 * 1000),
    )))
}

pub async fn dispatch(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    match req.op.as_str() {
        "validate" => validate(req).await,
        "list_dir" => list_dir(req).await,
        "search_files" => search_files(req).await,
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
    fn auth_headers_shape() {
        let cred = json!({ "BDUSS": "abc", "STOKEN": "def" });
        let h = auth_headers(&cred);
        assert_eq!(h[0].0, "User-Agent");
        assert!(h[0].1.contains("Chrome/120.0.0.0"));
        assert_eq!(h[1].1, "https://pan.baidu.com/disk/main");
        assert_eq!(h[2].1, "BDUSS=abc; STOKEN=def");
    }

    #[test]
    fn oauth_track_detection() {
        assert!(is_oauth(&json!({ "refreshToken": "r", "accessToken": "a" })));
        assert!(is_oauth(&json!({ "accessToken": "a" })));
        assert!(!is_oauth(&json!({ "BDUSS": "b" })));
        assert!(!is_oauth(&json!({ "refreshToken": "" })));
        assert!(!is_oauth(&json!({})));
    }

    #[test]
    fn xpan_url_shape() {
        assert_eq!(
            xpan_url("file", "AT", &[("method", "list"), ("dir", "/")]),
            "https://pan.baidu.com/rest/2.0/xpan/file?access_token=AT&method=list&dir=%2F"
        );
        assert_eq!(
            xpan_url("nas", "AT", &[("method", "uinfo")]),
            "https://pan.baidu.com/rest/2.0/xpan/nas?access_token=AT&method=uinfo"
        );
    }

    #[test]
    fn xpan_item_maps_fields() {
        let e = json!({
            "fs_id": 123,
            "server_filename": "a.flac",
            "isdir": 0,
            "size": 4096,
            "path": "/music/a.flac",
        });
        let f = file_from_xpan_item(&e);
        assert_eq!(f["id"], "123");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["path"], "/music/a.flac");
        assert_eq!(f["parentId"], "/music/a.flac");
        assert_eq!(f["isDir"], false);
    }

    #[test]
    fn share_headers_referer_root() {
        let h = share_headers("BDUSS=a");
        assert_eq!(h[1].1, "https://pan.baidu.com/");
        assert_eq!(h[2].1, "BDUSS=a");
    }

    #[test]
    fn randsk_cookie_encoding() {
        assert_eq!(cookie_with_randsk("BDUSS=a", ""), "BDUSS=a");
        assert_eq!(
            cookie_with_randsk("BDUSS=a", "x/y+z"),
            "BDUSS=a; BDCLND=x%2Fy%2Bz"
        );
    }

    #[test]
    fn share_token_pair_from_entry() {
        let e = json!({ "share_id": 12345, "from": "/from/path" });
        let token = format!("{}:{}", jstr(e.get("share_id")), jstr(e.get("from")));
        assert_eq!(token, "12345:/from/path");
        // 转存时拆尾段（split(':').last）。
        assert_eq!(token.rsplit(':').next().unwrap(), "/from/path");
    }

    #[test]
    fn fs_id_to_string() {
        assert_eq!(jstr(Some(&json!(123456))), "123456");
        assert_eq!(jstr(Some(&json!("str-id"))), "str-id");
        assert_eq!(jstr(None), "");
    }

    #[test]
    fn name_fallback_skips_null_only() {
        let e = json!({ "server_filename": "", "filename": "fb.flac" });
        // Dart `??` 只跳 null：空串不回退。
        assert_eq!(coalesce_jstr(e.get("server_filename"), e.get("filename")), "");
        let e2 = json!({ "filename": "fb.flac" });
        assert_eq!(coalesce_jstr(e2.get("server_filename"), e2.get("filename")), "fb.flac");
    }

    #[test]
    fn errno_interpretation() {
        assert_eq!(num_i64(json!({ "errno": 0 }).get("errno")), Some(0));
        assert_eq!(num_i64(json!({}).get("errno")), None);
        assert_eq!(num_i64(Some(&json!(2.0))), Some(2));
        assert_eq!(num_i64(Some(&json!(-105))), Some(-105));
    }

    #[test]
    fn search_url_shape() {
        assert_eq!(
            search_url("lofi beats"),
            "https://pan.baidu.com/api/filesearch?dir=/&key=lofi+beats&web=1&clienttype=0&app_id=250528"
        );
        assert_eq!(
            search_url("周深"),
            "https://pan.baidu.com/api/filesearch?dir=/&key=%E5%91%A8%E6%B7%B1&web=1&clienttype=0&app_id=250528"
        );
    }

    #[test]
    fn file_from_search_item_maps_fields() {
        let e = json!({
            "fs_id": 123456,
            "server_filename": "a.flac",
            "isdir": 0,
            "size": 4096,
            "path": "/music/a.flac",
        });
        let f = file_from_search_item(&e);
        assert_eq!(f["id"], "123456");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], false);
        assert_eq!(f["size"], 4096);
        assert_eq!(f["path"], "/music/a.flac");
        // 响应无 parent_path：parentId 留空。
        assert!(f.get("parentId").is_none());
        // 目录条目 isdir==1。
        let d = file_from_search_item(&json!({ "fs_id": 9, "server_filename": "m", "isdir": 1 }));
        assert_eq!(d["isDir"], true);
    }

    #[test]
    fn rate_limited_host_check() {
        assert!(is_rate_limited(&host_of("https://data.d2-ant.baidu.com/x")));
        assert!(is_rate_limited(&host_of("https://speed-limited.xxx.com/y")));
        assert!(!is_rate_limited(&host_of("https://d.pcs.baidu.com/file?x=1")));
        assert_eq!(host_of("https://u:p@host.example:8443/a"), "host.example");
    }

    #[test]
    fn redirect_url_resolution() {
        assert_eq!(
            absolute_url("https://a.com/x", "https://b.com/y").as_deref(),
            Some("https://b.com/y")
        );
        assert_eq!(
            absolute_url("https://a.com/x", "//b.com/y").as_deref(),
            Some("https://b.com/y")
        );
        assert_eq!(
            absolute_url("https://a.com/x", "/y?z=1").as_deref(),
            Some("https://a.com/y?z=1")
        );
        assert_eq!(absolute_url("https://a.com/x", "y"), None);
    }
}
