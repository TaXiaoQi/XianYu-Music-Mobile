// PikPak 代理（移植自移动端 providers/pikpak_provider.dart）。
//
// 关键行为对齐点：
// - 安卓端 UA（ANDROID-com.pikcloud.pikpak/1.47.1）+ Bearer + JSON CT；
//   accessToken 为空才走 refresh（user.mypikpak.com/v1/auth/token，
//   client_id=YNxT9w7GMdWvEOKa）；刷新失败统一抛「登录已过期，请重新绑定」。
// - 刷新得到的新 accessToken 经 rotated_cred 回传，cred 键名对齐 Dart
//   loginWithFields 存储键（accessToken/refreshToken/userId）。
// - 列表 filters 为 jsonEncode({phase:{in:[PHASE_TYPE_COMPLETE]},trashed:{in:false}})
//   的整串编码（常量逐字符对齐 Dart jsonEncode 输出）。
// - 直链：web_content_link 优先，medias[].link.url 兜底，TTL 30 分钟。
// - 分享 directPlayable=false：share_direct_link 走基类 UnsupportedError
//   （'该盘分享不支持免转存直链'）。
// - Dart 源中签名相关：登录密码 md5Hex 与登录头 x-device-id: uuidV4()；
//   登录留在客户端，两个纯函数按 Dart 逻辑移植并附单测。

use serde_json::{json, Value};

use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::http;
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str = "ANDROID-com.pikcloud.pikpak/1.47.1";
const CLIENT_ID: &str = "YNxT9w7GMdWvEOKa";
/// Dart jsonEncode({'phase': {'in': ['PHASE_TYPE_COMPLETE']}, 'trashed': {'in': false}})。
const LIST_FILTERS: &str = r#"{"phase":{"in":["PHASE_TYPE_COMPLETE"]},"trashed":{"in":false}}"#;

const EXPIRED: &str = "登录已过期，请重新绑定";

/// 对齐 Dart md5Hex（http_login_support.dart）：utf8 → md5 → 小写 hex。
/// 登录密码传参用（登录留在客户端）。
#[allow(dead_code)]
fn md5_hex(input: &str) -> String {
    format!("{:x}", md5::compute(input.as_bytes()))
}

/// 对齐 Dart uuidV4：随机 UUID v4（小写、带连字符；登录头 x-device-id 用）。
#[allow(dead_code)]
fn uuid_v4() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// API 请求头（Dart _h）：UA + Bearer（token 非空时）+ JSON CT。
fn api_headers(access_token: &str) -> Vec<(String, String)> {
    let mut h = vec![("User-Agent".to_string(), UA.to_string())];
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
        "https://api-drive.mypikpak.com/drive/v1/files?parent_id={}&limit=100&page_token={}&filters={}",
        http::url_encode(parent_id),
        http::url_encode(page_token),
        http::url_encode(LIST_FILTERS)
    )
}

fn share_detail_url(share_id: &str, pass_code: &str) -> String {
    format!(
        "https://api-drive.mypikpak.com/drive/v1/share/detail?share_id={}&pass_code={}&client_id={}",
        http::url_encode(share_id),
        http::url_encode(pass_code),
        CLIENT_ID
    )
}

fn file_meta_url(file_id: &str) -> String {
    format!(
        "https://api-drive.mypikpak.com/drive/v1/files/{}",
        http::url_encode(file_id)
    )
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
        &format!("https://user.mypikpak.com/v1/auth/token?client_id={CLIENT_ID}"),
        // Dart 刷新头仅 UA + CT（CT 由 post_json 按 body 形态注入）。
        &[("User-Agent".to_string(), UA.to_string())],
        &json!({
            "refresh_token": refresh_token,
            "grant_type": "refresh_token",
            "client_id": CLIENT_ID,
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
    let valid = match http::get("https://api-drive.mypikpak.com/drive/v1/about", &api_headers(&at))
        .await
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

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "pikpak")?;
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
    // 分享解析不需要登录态（Dart 头仅 UA + CT；CT 由 GET 原样透传）。
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
    let share = j.get("share").cloned().filter(|v| v.is_object()).unwrap_or(json!({}));
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
        "pikpak",
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
        "https://api-drive.mypikpak.com/drive/v1/share/restore",
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
    let mut dl_url = js_str(j.get("web_content_link"), "");
    if dl_url.is_empty() {
        // medias[].link.url 兜底。
        if let Some(medias) = j.get("medias").and_then(Value::as_array) {
            for m in medias {
                let alt = m
                    .get("link")
                    .and_then(|l| l.get("url"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                if !alt.is_empty() {
                    dl_url = alt;
                    break;
                }
            }
        }
    }
    if dl_url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    Ok(CloudOut {
        result: direct_link_json(
            &dl_url,
            json!({ "User-Agent": UA }),
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
        assert_eq!(h[1].1, "Bearer at1");
        assert_eq!(h[2], ("Content-Type".to_string(), "application/json".to_string()));
        // 空 token 不带 Authorization（对齐 Dart if (accessToken.isNotEmpty)）。
        let h0 = api_headers("");
        assert_eq!(h0.len(), 2);
        assert!(!h0.iter().any(|(k, _)| k == "Authorization"));
    }

    #[test]
    fn files_list_url_filters_encoded() {
        // filters 整串逐字符对齐 Dart jsonEncode 输出再 encodeQueryComponent。
        assert_eq!(
            files_list_url("", ""),
            "https://api-drive.mypikpak.com/drive/v1/files?parent_id=&limit=100&page_token=&filters=%7B%22phase%22%3A%7B%22in%22%3A%5B%22PHASE_TYPE_COMPLETE%22%5D%7D%2C%22trashed%22%3A%7B%22in%22%3Afalse%7D%7D"
        );
        assert_eq!(
            files_list_url("ab cd", "tok"),
            "https://api-drive.mypikpak.com/drive/v1/files?parent_id=ab+cd&limit=100&page_token=tok&filters=%7B%22phase%22%3A%7B%22in%22%3A%5B%22PHASE_TYPE_COMPLETE%22%5D%7D%2C%22trashed%22%3A%7B%22in%22%3Afalse%7D%7D"
        );
    }

    #[test]
    fn share_detail_url_has_client_id() {
        assert_eq!(
            share_detail_url("sid1", "pwd 9"),
            "https://api-drive.mypikpak.com/drive/v1/share/detail?share_id=sid1&pass_code=pwd+9&client_id=YNxT9w7GMdWvEOKa"
        );
        assert_eq!(
            file_meta_url("f/1"),
            "https://api-drive.mypikpak.com/drive/v1/files/f%2F1"
        );
    }
}
