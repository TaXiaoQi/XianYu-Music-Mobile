// 阿里云盘（webviewToken：oauth 页轮询 localStorage 抓 refresh_token）。
//
// 移植自移动端 providers/aliyun_provider.dart。关键点：refresh_token
// 单次有效，每次刷新 access_token 后必须把新凭据带回调用方落盘——
// 通过 CloudOut.rotated_cred 传递，由 Dart 侧 updateCred 回写本地。

use serde_json::{json, Value};

use super::http;
use super::types::{direct_link_json, list_result_json, share_parse_json, CloudOut, CloudReq};
use super::{biz_err, pre_parse_share, require_cred};

const CLIENT_ID: &str = "25dzX3vbYqktVxyX";

fn ua() -> &'static str {
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn auth_headers(at: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".into(), ua().to_string()),
        ("Authorization".into(), format!("Bearer {at}")),
        ("Content-Type".into(), "application/json".into()),
    ]
}

fn anon_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".into(), ua().to_string()),
        ("Content-Type".into(), "application/json".into()),
    ]
}

/// 换 access_token。缓存有效直接用（无轮换）；否则用 refresh_token 换新，
/// 返回新凭据集供调用方放进 rotated_cred（不落盘，由调用方负责回写）。
async fn access_token(cred: &Value) -> Result<(String, Option<Value>), (i32, String)> {
    let cached = cred.get("accessToken").and_then(Value::as_str).unwrap_or("");
    let expire_ms: i64 = cred
        .get("accessExpireMs")
        .and_then(Value::as_str)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    if !cached.is_empty() && now_ms() < expire_ms {
        return Ok((cached.to_string(), None));
    }
    let refresh_token = cred
        .get("refreshToken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if refresh_token.is_empty() {
        return Err(biz_err("登录凭据缺失，请重新绑定"));
    }
    let resp = http::post_json(
        "https://auth.alipan.com/v2/account/token",
        &anon_headers(),
        &json!({
            "client_id": CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("登录已过期，请重新绑定"));
    }
    let data = resp.json().map_err(biz_err)?;
    let new_refresh = data
        .get("refresh_token")
        .and_then(Value::as_str)
        .unwrap_or(&refresh_token)
        .to_string();
    let access = data
        .get("access_token")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if access.is_empty() {
        return Err(biz_err("登录已过期，请重新绑定"));
    }
    let expires_in = data.get("expires_in").and_then(Value::as_i64).unwrap_or(7200);
    let s = |k: &str| {
        cred.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let new_cred = json!({
        "refreshToken": new_refresh,
        "userId": s("userId"),
        "nickname": s("nickname"),
        "accountId": s("accountId"),
        "accessToken": access,
        "accessExpireMs": (now_ms() + expires_in * 1000).to_string(),
    });
    Ok((access, Some(new_cred)))
}

async fn drive_id(cred: &Value, at: &str) -> Result<String, (i32, String)> {
    let resp = http::post_json(
        "https://api.alipan.com/adrive/v2/user/getInfo",
        &auth_headers(at),
        &json!({}),
    )
    .await
    .map_err(biz_err)?;
    let j = resp.json().map_err(biz_err)?;
    let id = j
        .pointer("/data/default_drive_id")
        .or_else(|| j.get("default_drive_id"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if id.is_empty() {
        return Err(biz_err("网盘信息获取失败"));
    }
    Ok(id)
}

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = access_token(&req.cred).await?;
    let resp = http::post_json(
        "https://api.alipan.com/adrive/v2/user/getInfo",
        &auth_headers(&at),
        &json!({}),
    )
    .await
    .map_err(biz_err)?;
    Ok(CloudOut {
        result: json!({ "valid": resp.is_ok() }),
        rotated_cred: rotated,
    })
}

fn files_from_items(items: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(list) = items.as_array() {
        for e in list {
            let id = e
                .get("file_id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let name = e
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let is_dir = e.get("type").and_then(Value::as_str) == Some("folder");
            let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
            let parent = e
                .get("parent_file_id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            out.push(super::types::file_json(
                &id,
                &name,
                is_dir,
                size,
                Some(&parent),
                None,
                None,
            ));
        }
    }
    out
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = access_token(&req.cred).await?;
    let drive = drive_id(&req.cred, &at).await?;
    let path = if req.param_str("path").is_empty() {
        "root".to_string()
    } else {
        req.param_str("path")
    };
    let resp = http::post_json(
        "https://api.alipan.com/adrive/v3/file/list",
        &auth_headers(&at),
        &json!({
            "drive_id": drive,
            "parent_file_id": path,
            "limit": 100,
            "marker": req.param_str("cursor"),
            "order_by": "name",
            "order_direction": "ASC",
            "fields": "*",
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let files = files_from_items(j.get("items").unwrap_or(&Value::Null));
    let next_marker = j
        .get("next_marker")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let next_cursor = if next_marker.is_empty() {
        None
    } else {
        Some(next_marker)
    };
    Ok(CloudOut {
        result: list_result_json(files, next_cursor),
        rotated_cred: rotated,
    })
}

fn file_from_share_item(e: &Value) -> Value {
    let id = e
        .get("file_id")
        .or_else(|| e.get("share_file_id"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let name = e
        .get("name")
        .or_else(|| e.get("file_name"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let is_dir = e.get("type").and_then(Value::as_str) == Some("folder");
    let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
    super::types::file_json(id, name, is_dir, size, None, None, None)
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "aliyun")?;
    let share_id = if info.share_id.is_empty() {
        info.url.clone()
    } else {
        info.share_id.clone()
    };
    let pwd = req.param_str("pwd");
    // 免提取码：匿名接口直接拿顶层文件。
    let mut files: Vec<Value> = Vec::new();
    let mut share_token: Option<String> = None;
    let anon_resp = http::post_json(
        "https://api.alipan.com/adrive/v2/share_link/get_share_by_anonymous",
        &anon_headers(),
        &json!({ "share_id": share_id }),
    )
    .await
    .map_err(biz_err)?;
    if anon_resp.is_ok() {
        if let Ok(j) = anon_resp.json() {
            if let Some(infos) = j.get("file_infos").and_then(Value::as_array) {
                files.extend(infos.iter().map(file_from_share_item));
            }
        }
    }
    // 匿名拿不到（目录分享/需提取码）→ share_token → 文件列表。
    if files.is_empty() {
        let tok_resp = http::post_json(
            "https://api.alipan.com/adrive/v2/share_link/get_share_token",
            &anon_headers(),
            &json!({ "share_id": share_id, "share_pwd": pwd }),
        )
        .await
        .map_err(biz_err)?;
        if !tok_resp.is_ok() {
            return Err(biz_err("分享链接解析失败"));
        }
        let tj = tok_resp.json().map_err(biz_err)?;
        let token = tj
            .pointer("/data/share_token")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if token.is_empty() {
            return Err(biz_err("提取码错误"));
        }
        let list_resp = http::post_json(
            "https://api.alipan.com/adrive/v3/share_link/file/list",
            &anon_headers(),
            &json!({
                "share_id": share_id,
                "share_token": token,
                "parent_file_id": "root",
                "limit": 100,
            }),
        )
        .await
        .map_err(biz_err)?;
        if !list_resp.is_ok() {
            return Err(biz_err("分享文件列表获取失败"));
        }
        let lj = list_resp.json().map_err(biz_err)?;
        if let Some(items) = lj.get("items").and_then(Value::as_array) {
            files.extend(items.iter().map(file_from_share_item));
        }
        share_token = Some(token);
    }
    Ok(CloudOut::plain(share_parse_json(
        "aliyun",
        files,
        Some(&share_id),
        share_token.as_deref(),
        Some(&pwd),
        false,
    )))
}

async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = access_token(&req.cred).await?;
    let drive = drive_id(&req.cred, &at).await?;
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
                "share_file_id": f.get("id").and_then(Value::as_str).unwrap_or(""),
                "file_name": f.get("name").and_then(Value::as_str).unwrap_or(""),
            })
        })
        .collect();
    let resp = http::post_json(
        "https://api.alipan.com/adrive/v2/share_link/save_created",
        &auth_headers(&at),
        &json!({
            "share_id": share.get("shareId").and_then(Value::as_str).unwrap_or(""),
            "share_token": token,
            "auto_import": true,
            "to_drive_id": drive,
            "to_parent_file_id": "root",
            "file_list": file_list,
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("转存失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let mut out = files_from_items(j.get("file_list").unwrap_or(&Value::Null));
    if out.is_empty() {
        // 接口不回新 id 时回退原 files（阿里 file_id 转存后不变）。
        out = files_in;
    }
    Ok(CloudOut {
        result: json!({ "files": out }),
        rotated_cred: rotated,
    })
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = access_token(&req.cred).await?;
    let drive = drive_id(&req.cred, &at).await?;
    let file = req.param_obj("file");
    let file_id = file.get("id").and_then(Value::as_str).unwrap_or("");
    let resp = http::post_json(
        "https://api.alipan.com/adrive/v2/file/get_download_url",
        &auth_headers(&at),
        &json!({ "drive_id": drive, "file_id": file_id }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let url = j
        .get("url")
        .or_else(|| j.pointer("/data/url"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    Ok(CloudOut {
        result: direct_link_json(
            &url,
            json!({ "User-Agent": ua() }),
            Some(name),
            size,
            Some(now_ms() + 4 * 3600 * 1000),
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
        "share_direct_link" => Err(biz_err("该盘分享不支持免转存直链")),
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn share_item_fallbacks() {
        let e = json!({ "share_file_id": "s1", "file_name": "a.flac", "type": "file", "size": 10 });
        let f = file_from_share_item(&e);
        assert_eq!(f["id"], "s1");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], false);
    }

    #[test]
    fn cred_cache_expiry_fields() {
        // 缓存有效期字段缺省为 0：必走刷新路径（网络调用），这里仅验证解析容错
        let cred = json!({ "accessToken": "a", "accessExpireMs": "" });
        let expire: i64 = cred
            .get("accessExpireMs")
            .and_then(Value::as_str)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        assert_eq!(expire, 0);
    }
}
