// 移动云盘（139）provider（webviewCookie：登录页 Cookie 全收）。
//
// 移植自移动端 providers/mobile139_provider.dart（六个代理 op 逐行对齐）。
// http_login_support.dart 被本盘使用的 md5Hex 仅服务登录装配时的账号指纹、
// cookieHeader 仅服务 completeLogin 凭据拼装——登录留在 Dart 侧，六个
// op 不涉及，无需移植。
//
// 关键行为对齐点：
// - validate/list_dir/direct_link 走个人盘接口（Cookie + Referer，
//   orchestration/hcy JSON 形态）；list_dir 以 startNumber/endNumber=
//   start..start+100 翻页，files.length >= 100 判定有下一页；
// - parse_share/share_direct_link 走 share-kd-njs 匿名 outLink 接口（仅 UA，
//   无 Referer/Cookie）——outLink 免转存直链，空 cred 可解析；
// - transfer_share best-effort：转存请求失败静默忽略，原样回分享文件；
// - 直链 TTL 30 分钟，随 expireAt 毫秒时间戳回传；
// - Dart appRequest 的手动重定向跟随（上限 5 跳、303/302 非 GET 降级）由
//   request_follow/resolve_url 复刻。

use serde_json::{json, Value};

use super::http::{self, Body, Outbound};
use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 个人盘请求头（UA + Referer；cookie 非空才带；Content-Type 由 post_json 注入）。
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

// ── JSON 条目映射（纯函数，便于单测） ───────────────────

/// contentList 条目 → CloudFile（isCatalog==1 判目录；parentId 缺省回请求路径）。
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

// ── op 实现 ─────────────────────────────────────────────

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let resp = post_json_follow(
        "https://personal-kd-njs.yun.139.com/hcy/file/list",
        &h_headers(&req.cred_str("cookie")),
        &json!({
            "parentCatalogId": "root",
            "catalogType": 3,
            "pageBean": { "pageNum": 1, "pageSize": 1 },
        }),
    )
    .await;
    // Dart try/catch：任何异常按未登录处理。
    let valid = match resp {
        Ok(r) if r.is_ok() => match r.json() {
            Ok(j) => {
                j.get("status").and_then(Value::as_i64) == Some(0)
                    || j.get("success") == Some(&json!(true))
            }
            Err(_) => false,
        },
        _ => false,
    };
    Ok(CloudOut::plain(json!({ "valid": valid })))
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let path = req.param_str("path");
    let start: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let resp = post_json_follow(
        "https://yun.139.com/orchestration/personalCloud/catalog/listContents",
        &h_headers(&req.cred_str("cookie")),
        &json!({
            "parentCatalogId": path,
            "catalogType": 3,
            "contentListType": 1,
            "sortDirection": 1,
            "startNumber": start,
            "endNumber": start + 100,
            "filter": 0,
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
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
        files.push(file_from_content(e, &path));
    }
    let has_next = files.len() as i64 >= 100;
    let next_cursor = if has_next {
        Some((start + 100).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

/// 搜索请求体（纯函数，单测断言）：body 照 hcy/file/list 风格装配，
/// searchValue 关键词 + pageNum 页码游标，pageSize 100 对齐列表每页条数。
fn search_body(keyword: &str, page: i64) -> Value {
    json!({
        "searchValue": keyword,
        "catalogType": 3,
        "pageBean": { "pageNum": page, "pageSize": 100 },
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
    let resp = post_json_follow(
        "https://personal-kd-njs.yun.139.com/hcy/file/search",
        &h_headers(&req.cred_str("cookie")),
        &search_body(&keyword, page),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("搜索请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
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
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
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
        Some(now_ms() + 30 * 60 * 1000),
    )))
}

/// best-effort 转存（139 分享本可直链，转存作为留档兜底）：失败静默忽略。
async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let share = req.param_obj("share");
    let file_ids: Vec<String> = share
        .get("files")
        .and_then(Value::as_array)
        .map(|l| l.iter().map(|f| jstr(f.get("id"))).collect())
        .unwrap_or_default();
    let _ = post_json_follow(
        "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IBatchOprTask/createOuterLinkBatchOprTask",
        &h_headers(&req.cred_str("cookie")),
        &json!({
            "outLinkGUID": jstr(share.get("shareId")),
            "passcode": jstr(share.get("passcode")),
            "taskType": 2,
            "fileIds": file_ids,
        }),
    )
    .await;
    Ok(CloudOut::plain(json!(
        { "files": share.get("files").cloned().unwrap_or_else(|| json!([])) }
    )))
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let file = req.param_obj("file");
    let resp = post_json_follow(
        "https://personal-kd-njs.yun.139.com/hcy/file/getDownloadUrl",
        &h_headers(&req.cred_str("cookie")),
        &json!({
            "contentId": jstr(file.get("id")),
            "catalogType": 3,
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let url = j
        .get("data")
        .filter(|d| d.is_object())
        .and_then(|d| d.get("downloadUrl"))
        .map(|v| jstr(Some(v)))
        .unwrap_or_default();
    if url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let name = jstr(file.get("name"));
    let size = file.get("size").and_then(Value::as_i64).unwrap_or(0);
    Ok(CloudOut::plain(direct_link_json(
        &url,
        json!({ "User-Agent": UA }),
        Some(&name),
        Some(size),
        Some(now_ms() + 30 * 60 * 1000),
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
        "share_direct_link" => share_direct_link(req).await,
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_shape() {
        let h = h_headers("a=1; b=2");
        assert_eq!(h.len(), 3);
        assert_eq!(h[0].0, "User-Agent");
        assert_eq!(h[1].1, "https://yun.139.com/");
        assert_eq!(h[2], ("Cookie".to_string(), "a=1; b=2".to_string()));
        assert_eq!(h_headers("").len(), 2);
        // 分享 outLink 接口仅 UA（Content-Type 由 post_json 注入）。
        assert_eq!(share_headers().len(), 1);
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
        // 缺字段：parentId 回请求路径，isCatalog==1 判目录。
        let e2 = json!({ "contentId": null, "isCatalog": 1 });
        let f2 = file_from_content(&e2, "root");
        assert_eq!(f2["id"], "");
        assert_eq!(f2["parentId"], "root");
        assert_eq!(f2["isDir"], true);
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
        assert!(f.get("token").is_none());
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
    fn search_body_shape() {
        let b = search_body("周深", 2);
        assert_eq!(b["searchValue"], "周深");
        assert_eq!(b["catalogType"], json!(3));
        assert_eq!(b["pageBean"]["pageNum"], json!(2));
        assert_eq!(b["pageBean"]["pageSize"], json!(100));
    }

    #[test]
    fn search_item_mapping_without_context() {
        // 搜索复用 file_from_content：parentId 缺省回空串（无目录上下文）。
        let e = json!({
            "contentId": "c1",
            "contentName": "a.flac",
            "isCatalog": 0,
            "contentSize": 123,
        });
        let f = file_from_content(&e, "");
        assert_eq!(f["id"], "c1");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], false);
        assert_eq!(f["size"], 123);
        assert_eq!(f["parentId"], "");
        assert!(f.get("path").is_none());
        // 条目带 parentCatalogId 时原样带回。
        let f2 = file_from_content(
            &json!({ "contentId": "c2", "contentName": "b", "isCatalog": 1, "parentCatalogId": "p9" }),
            "",
        );
        assert_eq!(f2["parentId"], "p9");
        assert_eq!(f2["isDir"], true);
    }
}
