// 迅雷云盘代理（移植自移动端 providers/thunder_provider.dart）。
//
// 关键行为对齐点：
// - 安卓端 UA（ANDROID-com.xunlei.downloadprovider/8.31.0.9726 ...）+
//   Referer(https://pan.xunlei.com/) + Bearer + JSON CT；accessToken 为空
//   才走 refresh（xluser-ssl.xunlei.com/xluser.core.auth.token/v1/auth/token，
//   client_id=Xq00jqW5m1PrHnV8）；刷新失败统一抛「登录已过期，请重新绑定」。
// - 刷新得到的新 accessToken 经 rotated_cred 回传，cred 键名对齐 Dart
//   loginWithFields 存储键（accessToken/refreshToken/userId）。
// - 列表 filters 为 jsonEncode({phase:{in:[PHASE_TYPE_COMPLETE]},trashed:{in:false}})
//   的整串编码（常量逐字符对齐 Dart jsonEncode 输出）；share/detail 不带
//   client_id（与 PikPak 的差异点）。
// - share 解析：resp.json['share'] 为 Map 时取之，否则把整个响应视作 share
//   （Dart data = share is Map ? resp.json : {'share': resp.json}）。
// - 直链：web_content_link 优先，medias[].link.url 兜底；直链头带 Referer，
//   TTL 30 分钟。分享 directPlayable=false → share_direct_link 走基类
//   UnsupportedError（'该盘分享不支持免转存直链'）。
// - Dart 源中签名相关：登录密码 md5Hex 与登录体 deviceid: uuidV4()；登录
//   留在客户端，两个纯函数按 Dart 逻辑移植并附单测。

use serde_json::{json, Value};

use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::http;
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC Oauth2Client/0.9";
const CLIENT_ID: &str = "Xq00jqW5m1PrHnV8";
/// Dart jsonEncode({'phase': {'in': ['PHASE_TYPE_COMPLETE']}, 'trashed': {'in': false}})。
const LIST_FILTERS: &str = r#"{"phase":{"in":["PHASE_TYPE_COMPLETE"]},"trashed":{"in":false}}"#;
/// 搜索 filters（设计稿形态）：仅回收站过滤，与列表 LIST_FILTERS 不同
/// （与 PikPak 搜索同构）。
const SEARCH_FILTERS: &str = r#"{"trashed":{"match":"exact","value":"false"}}"#;

const EXPIRED: &str = "登录已过期，请重新绑定";

/// 对齐 Dart md5Hex（http_login_support.dart）：utf8 → md5 → 小写 hex。
/// 登录密码传参用（登录留在客户端）。
#[allow(dead_code)]
fn md5_hex(input: &str) -> String {
    format!("{:x}", md5::compute(input.as_bytes()))
}

/// 对齐 Dart uuidV4：随机 UUID v4（小写、带连字符；登录体 deviceid 用）。
#[allow(dead_code)]
fn uuid_v4() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// API 请求头（Dart _h）：UA + Referer + Bearer（token 非空时）+ JSON CT。
fn api_headers(access_token: &str) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Referer".to_string(), "https://pan.xunlei.com/".to_string()),
    ];
    if !access_token.is_empty() {
        h.push(("Authorization".to_string(), format!("Bearer {access_token}")));
    }
    h.push(("Content-Type".to_string(), "application/json".to_string()));
    h
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

fn files_list_url(parent_id: &str, page_token: &str) -> String {
    format!(
        "https://api-pan.xunlei.com/drive/v1/files?parent_id={}&limit=100&page_token={}&filters={}",
        http::url_encode(parent_id),
        http::url_encode(page_token),
        http::url_encode(LIST_FILTERS)
    )
}

/// 文件搜索 URL（纯函数，单测断言）：parent_id=* 全盘检索 + search 关键词，
/// cursor 为响应 next_page_token（与 PikPak 搜索同构）。
fn search_url(keyword: &str, page_token: &str) -> String {
    format!(
        "https://api-pan.xunlei.com/drive/v1/files?parent_id=*&search={}&filters={}&page_token={}",
        http::url_encode(keyword),
        http::url_encode(SEARCH_FILTERS),
        http::url_encode(page_token)
    )
}

/// 迅雷 share/detail 不带 client_id（与 PikPak 差异点）。
fn share_detail_url(share_id: &str, pass_code: &str) -> String {
    format!(
        "https://api-pan.xunlei.com/drive/v1/share/detail?share_id={}&pass_code={}",
        http::url_encode(share_id),
        http::url_encode(pass_code)
    )
}

fn file_meta_url(file_id: &str) -> String {
    format!(
        "https://api-pan.xunlei.com/drive/v1/files/{}",
        http::url_encode(file_id)
    )
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

// ── 鉴权（带凭据轮换）──────────────────────────────────

/// 刷新 access_token。Dart _refreshToken 任何失败 → null → _auth 抛过期；
/// 这里所有失败路径统一映射同一文案。
async fn refresh_access_token(cred: &Value) -> Result<String, (i32, String)> {
    let refresh_token = cred.get("refreshToken").and_then(Value::as_str).unwrap_or("");
    if refresh_token.is_empty() {
        return Err(biz_err(EXPIRED));
    }
    let resp = http::post_json(
        "https://xluser-ssl.xunlei.com/xluser.core.auth.token/v1/auth/token",
        // Dart 刷新头仅 UA + CT（CT 由 post_json 按 body 形态注入）。
        &[("User-Agent".to_string(), UA.to_string())],
        &json!({
            "refresh_token": refresh_token,
            "client_id": CLIENT_ID,
            "grant_type": "refresh_token",
        }),
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
    Ok(at.to_string())
}

/// 取可用 access_token：缓存优先（无轮换）；否则刷新并产出新凭据集
/// （键名对齐 Dart cred：accessToken/refreshToken/userId）。
async fn auth(cred: &Value) -> Result<(String, Option<Value>), (i32, String)> {
    let cached = cred.get("accessToken").and_then(Value::as_str).unwrap_or("");
    if !cached.is_empty() {
        return Ok((cached.to_string(), None));
    }
    let at = refresh_access_token(cred).await?;
    let s = |k: &str| cred.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let new_cred = json!({
        "accessToken": at,
        "refreshToken": s("refreshToken"),
        "userId": s("userId"),
    });
    Ok((at, Some(new_cred)))
}

// ── op 实现 ──────────────────────────────────────────────

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = auth(&req.cred).await?;
    let valid = match http::get("https://api-pan.xunlei.com/drive/v1/about", &api_headers(&at)).await
    {
        Ok(resp) => resp.is_ok(),
        Err(_) => false,
    };
    Ok(CloudOut {
        result: json!({ "valid": valid }),
        rotated_cred: rotated,
    })
}

/// 目录列表主体（list_dir 与转存回查共用；Dart listDir 同体）。
async fn list_dir_at(at: &str, path: &str, cursor: &str) -> Result<Value, (i32, String)> {
    let resp = http::get(&files_list_url(path, cursor), &api_headers(at))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let mut files = Vec::new();
    if let Some(items) = j.get("files").and_then(Value::as_array) {
        for e in items {
            let id = js_str(e.get("id"), "");
            let name = js_str(e.get("name"), "");
            let is_dir = e.get("kind").and_then(Value::as_str) == Some("drive#folder");
            let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
            files.push(file_json(&id, &name, is_dir, size, Some(path), None, None));
        }
    }
    let next = js_str(j.get("next_page_token"), "");
    let next_cursor = if next.is_empty() { None } else { Some(next) };
    Ok(list_result_json(files, next_cursor))
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = auth(&req.cred).await?;
    let path = req.param_str("path");
    let cursor = req.param_str("cursor");
    let result = list_dir_at(&at, &path, &cursor).await?;
    Ok(CloudOut {
        result,
        rotated_cred: rotated,
    })
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
    let (at, rotated) = auth(&req.cred).await?;
    let cursor = req.param_str("cursor");
    let resp = http::get(&search_url(&keyword, &cursor), &api_headers(&at))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("搜索请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
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
    // 分享解析不需要登录态（Dart 头仅 UA + CT）。
    let headers = vec![
        ("User-Agent".to_string(), UA.to_string()),
        ("Content-Type".to_string(), "application/json".to_string()),
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
    let (at, rotated) = auth(&req.cred).await?;
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
    let resp = http::post_json(
        "https://api-pan.xunlei.com/drive/v1/share/restore",
        &api_headers(&at),
        &json!({
            "share_id": share.get("shareId").and_then(Value::as_str).unwrap_or(""),
            "pass_code_token": token,
            "file_list": file_list,
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("转存失败"));
    }
    // 转存后 id 变化：按文件名回查根目录。
    let listed = list_dir_at(&at, "", "").await?;
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
    let (at, rotated) = auth(&req.cred).await?;
    let file = req.param_obj("file");
    let file_id = file.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    let resp = http::get(&file_meta_url(&file_id), &api_headers(&at))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
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
                            json!({ "User-Agent": UA, "Referer": "https://pan.xunlei.com/" }),
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
            json!({ "User-Agent": UA, "Referer": "https://pan.xunlei.com/" }),
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
        // 对齐 Dart md5Hex：小写 hex（登录密码传 md5）。
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
    }

    #[test]
    fn uuid_v4_format() {
        // 对齐 Dart uuidV4：小写、连字符分段 8-4-4-4-12，版本 4、变体 8/9/a/b。
        let u = uuid_v4();
        let parts: Vec<&str> = u.split('-').collect();
        assert_eq!(parts.len(), 5);
        assert_eq!(
            parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12]
        );
        assert!(u.chars().all(|c| c.is_ascii_hexdigit() || c == '-'));
        assert!(u.chars().all(|c| !c.is_ascii_uppercase()));
        assert_eq!(parts[2].chars().next(), Some('4'));
        assert!(['8', '9', 'a', 'b'].contains(&parts[3].chars().next().unwrap()));
    }

    #[test]
    fn api_headers_shape() {
        let h = api_headers("at1");
        assert_eq!(h[0].1, UA);
        assert_eq!(h[1].1, "https://pan.xunlei.com/");
        assert_eq!(h[2].1, "Bearer at1");
        assert_eq!(h[3], ("Content-Type".to_string(), "application/json".to_string()));
        // 空 token 不带 Authorization（对齐 Dart if (accessToken.isNotEmpty)）。
        let h0 = api_headers("");
        assert_eq!(h0.len(), 3);
        assert!(!h0.iter().any(|(k, _)| k == "Authorization"));
    }

    #[test]
    fn files_list_url_filters_encoded() {
        assert_eq!(
            files_list_url("", "pt1"),
            "https://api-pan.xunlei.com/drive/v1/files?parent_id=&limit=100&page_token=pt1&filters=%7B%22phase%22%3A%7B%22in%22%3A%5B%22PHASE_TYPE_COMPLETE%22%5D%7D%2C%22trashed%22%3A%7B%22in%22%3Afalse%7D%7D"
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
