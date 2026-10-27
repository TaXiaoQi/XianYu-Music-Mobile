// 阿里云盘（webviewToken：oauth 页轮询 localStorage 抓 refresh_token）。
//
// 移植自移动端 providers/aliyun_provider.dart。关键点：refresh_token
// 单次有效，每次刷新 access_token 后必须把新凭据带回调用方落盘——
// 通过 CloudOut.rotated_cred 传递，由 Dart 侧 updateCred 回写本地。

use std::sync::{Mutex, OnceLock};

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
    // Content-Type 由 http::post_json 统一注入——显式带会与注入的
    // 重复合并成 "application/json,application/json"，被阿里 400。
    // origin/referer/X-Canary：2026-10 接口收紧后对齐官方 web 端请求头
    // （同 OpenList 现役驱动，缺了部分端点会被拒）。
    vec![
        ("User-Agent".into(), ua().to_string()),
        ("Authorization".into(), format!("Bearer {at}")),
        ("Origin".into(), "https://www.alipan.com".into()),
        ("Referer".into(), "https://www.alipan.com/".into()),
        (
            "X-Canary".into(),
            "client=Android,app=adrive,version=v4.1.0".into(),
        ),
    ]
}

fn anon_headers() -> Vec<(String, String)> {
    vec![("User-Agent".into(), ua().to_string())]
}

/// 分享域请求头：x-share-token 即鉴权（无登录态），Canary 用 share 应用
/// 形态（OpenList 分享驱动同款）。
fn share_headers(token: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".into(), ua().to_string()),
        (
            "X-Canary".into(),
            "client=web,app=share,version=v2.3.1".into(),
        ),
        ("x-share-token".into(), token.to_string()),
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
        // 错误信息带阿里响应片段（code/message），便于确诊 rt 无效/风控等，
        // 不含凭据本身。
        let brief: String = resp.body.chars().take(180).collect();
        return Err(biz_err(format!(
            "登录已过期，请重新绑定（阿里 {} {}）",
            resp.status, brief
        )));
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
        let brief: String = resp.body.chars().take(180).collect();
        return Err(biz_err(format!(
            "登录已过期，请重新绑定（阿里响应缺 access_token {}）",
            brief
        )));
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

/// drive_id 每 token 缓存：网盘页全量遍历是几十上百次并发 list_dir，
/// 每次都带一发 /v2/user/get 会把请求量翻倍、放大触发限流的概率。
/// access_token 未变时直接复用上次结果（token 轮换后键不匹配即重取）。
static DRIVE_ID_CACHE: OnceLock<Mutex<(String, String)>> = OnceLock::new();

async fn drive_id(at: &str) -> Result<String, (i32, String)> {
    let cache = DRIVE_ID_CACHE.get_or_init(|| Mutex::new((String::new(), String::new())));
    if let Ok(guard) = cache.lock() {
        if guard.0 == at && !guard.1.is_empty() {
            return Ok(guard.1.clone());
        }
    }
    // 2026-10 阿里下线 /adrive/v2/user/getInfo（404 NotFound），取 drive_id
    // 改用 web 端现役的 /v2/user/get（响应字段顶层平铺，pick 兼容 data 包裹）。
    let resp = http::post_json(
        "https://api.alipan.com/v2/user/get",
        &auth_headers(at),
        &json!({}),
    )
    .await
    .map_err(biz_err)?;
    let j = resp.json().map_err(biz_err)?;
    // 兼容多种字段命名（含保险箱盘），全部为空才失败；失败时错误带上
    // 响应片段便于诊断（文案长度受控，避免刷屏）。
    let pick = |name: &str| -> String {
        j.pointer(&format!("/data/{name}"))
            .or_else(|| j.get(name))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    // 兼容多种字段命名（含保险箱盘），全部为空才失败；失败时错误带上
    // 响应片段便于诊断（文案长度受控，避免刷屏）。
    let mut id = pick("default_drive_id");
    if id.is_empty() {
        id = pick("resource_drive_id");
    }
    if id.is_empty() {
        id = pick("backup_drive_id");
    }
    if id.is_empty() {
        id = pick("default_sbox_drive_id");
    }
    if id.is_empty() {
        let body = serde_json::to_string(&j).unwrap_or_default();
        let head: String = body.chars().take(160).collect();
        return Err((412, format!("网盘信息获取失败，响应: {head}")));
    }
    if let Ok(mut guard) = cache.lock() {
        *guard = (at.to_string(), id.clone());
    }
    Ok(id)
}

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = access_token(&req.cred).await?;
    // 有效性以 drive_id 可取为准（token 可用 + 盘信息可读），防
    // 「绑定成功但一用就挂」的假阳性；失败文案由 drive_id/access_token 带出。
    let valid = drive_id(&at).await.is_ok();
    Ok(CloudOut {
        result: json!({ "valid": valid }),
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
    let drive = drive_id(&at).await?;
    let path = if req.param_str("path").is_empty() {
        "root".to_string()
    } else {
        req.param_str("path")
    };
    let resp = http::post_json(
        "https://api.alipan.com/v2/file/list",
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

/// 搜索请求体（纯函数，单测断言）：offset 数值游标 + 固定 limit 100，
/// 响应 items 与 file/list 同构（files_from_items 直接复用）。
fn search_body(drive: &str, keyword: &str, offset: i64) -> Value {
    json!({
        "drive_id": drive,
        "keyword": keyword,
        "limit": 100,
        "offset": offset,
        "fields": "*",
    })
}

/// 文件搜索：keyword 必填，cursor 为 offset 数值游标；drive_id 复用
/// list_dir 的获取方式，凭据轮换随 CloudOut 回传（返回结构与 list_dir 同构）。
async fn search_files(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let keyword = req.param_str("keyword");
    if keyword.is_empty() {
        return Err(biz_err("缺少搜索关键词"));
    }
    let (at, rotated) = access_token(&req.cred).await?;
    let drive = drive_id(&at).await?;
    let offset: i64 = req.param_str("cursor").parse().unwrap_or(0);
    if offset < 0 {
        return Err(biz_err("非法翻页游标"));
    }
    // openapi.alipan.com 域的同路径已 404，search 仅 api 域存活。
    let resp = http::post_json(
        "https://api.alipan.com/adrive/v3/file/search",
        &auth_headers(&at),
        &search_body(&drive, &keyword, offset),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("搜索请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let files = files_from_items(j.get("items").unwrap_or(&Value::Null));
    let next_cursor = if files.len() >= 100 {
        Some((offset + 100).to_string())
    } else {
        None
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
    // 2026-10 share_link 旧域全下线：token 走 /v2/share_link/get_share_token，
    // 列表复用 /adrive/v3/file/list（鉴权从 body 的 share_token 改为
    // x-share-token 头，body 里 share_id 取代 drive_id）。
    if files.is_empty() {
        let tok_resp = http::post_json(
            "https://api.alipan.com/v2/share_link/get_share_token",
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
            .or_else(|| tj.get("share_token"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if token.is_empty() {
            return Err(biz_err("提取码错误"));
        }
        let list_resp = http::post_json(
            "https://api.alipan.com/adrive/v3/file/list",
            &share_headers(&token),
            &json!({
                "share_id": share_id,
                "parent_file_id": "root",
                "limit": 100,
                "order_by": "name",
                "order_direction": "ASC",
                "fields": "*",
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
    let drive = drive_id(&at).await?;
    let share = req.param_obj("share");
    let token = share
        .get("shareToken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if token.is_empty() {
        return Err(biz_err("请先填写提取码"));
    }
    let share_id = share
        .get("shareId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let files_in = share
        .get("files")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // 2026-10 share_link/save_created 全域下线，转存改为逐文件
    // /v2/file/copy（登录态 + x-share-token 双鉴权）。
    let mut headers = auth_headers(&at);
    headers.push(("x-share-token".into(), token.clone()));
    let mut out = Vec::new();
    for f in &files_in {
        let file_id = f.get("id").and_then(Value::as_str).unwrap_or("");
        let resp = http::post_json(
            "https://api.alipan.com/v2/file/copy",
            &headers,
            &json!({
                "share_id": share_id,
                "file_id": file_id,
                "to_drive_id": drive,
                "to_parent_file_id": "root",
            }),
        )
        .await
        .map_err(biz_err)?;
        if !resp.is_ok() {
            return Err(biz_err("转存失败"));
        }
        let j = resp.json().unwrap_or(Value::Null);
        // 响应 {file_id, async_task_id}（可能包 data 层）：新 id 缺失时
        // 回退原 id（复制后 file_id 不变的旧约定，兜底直链解析）。
        let new_id = j
            .get("file_id")
            .or_else(|| j.pointer("/data/file_id"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .unwrap_or(file_id);
        out.push(super::types::file_json(
            new_id,
            f.get("name").and_then(Value::as_str).unwrap_or(""),
            f.get("isDir").and_then(Value::as_bool).unwrap_or(false),
            f.get("size").and_then(Value::as_i64).unwrap_or(0),
            None,
            None,
            None,
        ));
    }
    Ok(CloudOut {
        result: json!({ "files": out }),
        rotated_cred: rotated,
    })
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let (at, rotated) = access_token(&req.cred).await?;
    let drive = drive_id(&at).await?;
    let file = req.param_obj("file");
    let file_id = file.get("id").and_then(Value::as_str).unwrap_or("");

    let resp = http::post_json(
        "https://api.alipan.com/v2/file/get_download_url",
        &auth_headers(&at),
        &json!({ "drive_id": drive, "file_id": file_id, "expire_sec": 14400 }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let field = |k: &str| {
        j.get(k)
            .or_else(|| j.pointer(&format!("/data/{k}")))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let url = field("url");
    if url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    // dl1 直连节点对非会员限速严重（实测手机端断流级 <3KB/s，喂不满
    // FLAC 实时码率，也拉不动 2MB 头部预探——封面/时长/内嵌歌词全丢）；
    // API 同时返回 cdn_url（真正的 CDN 边缘节点）。探测可用则优先用
    // （直链带 4h 缓存，探测每 4h 一次，开销可忽略）。与桌面端同构，
    // 另透传探测诊断（cdnProbe）供 Dart 侧 logcat 排查。
    let mut final_url = url.clone();
    let mut cdn_probe = "empty".to_string();
    let cdn = field("cdn_url");
    if !cdn.is_empty() {
        // 5s：移动网络首次连 CDN（DNS+TLS）可能偏慢；探测失败会回退
        // 断流级 dl1，预探必挂，宁可多等几秒（直链 4h 缓存，开销可忽略）。
        let probe = match reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(5000))
            .build()
        {
            Err(e) => Err(format!("client_err({e})")),
            Ok(c) => {
                match c
                    .get(&cdn)
                    .header("Range", "bytes=0-0")
                    .header("User-Agent", ua())
                    .header("Referer", "https://www.aliyundrive.com/")
                    .send()
                    .await
                {
                    Err(e) => Err(format!(
                        "err({})",
                        if e.is_timeout() {
                            "timeout"
                        } else if e.is_connect() {
                            "connect"
                        } else {
                            "request"
                        }
                    )),
                    Ok(r) => {
                        let st = r.status();
                        Ok(st)
                    }
                }
            }
        };
        match probe {
            Err(note) => cdn_probe = note,
            Ok(st) => {
                if st.is_success() {
                    final_url = cdn;
                    cdn_probe = format!("ok({st})");
                } else {
                    cdn_probe = format!("reject({st})");
                }
            }
        }
    }
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    let mut result = direct_link_json(
        &final_url,
        // PDS 生成的下载 URL 把 referer 写进 x-oss-additional-headers 参与
        // OSS V4 签名：缺头 400 AuthorizationArgumentError，值不符 403。
        // 实测必须带 https://www.aliyundrive.com/（alipan.com 会 403）。
        json!({ "User-Agent": ua(), "Referer": "https://www.aliyundrive.com/" }),
        Some(name),
        size,
        Some(now_ms() + 4 * 3600 * 1000),
    );
    result["cdnProbe"] = json!(cdn_probe);
    Ok(CloudOut {
        result,
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

    #[test]
    fn search_body_shape() {
        let b = search_body("drv1", "周深", 200);
        assert_eq!(b["drive_id"], "drv1");
        assert_eq!(b["keyword"], "周深");
        assert_eq!(b["limit"], json!(100));
        assert_eq!(b["offset"], json!(200));
        assert_eq!(b["fields"], "*");
    }

    #[test]
    fn search_items_mapping() {
        // 搜索响应 items 与 file/list 同构：播放（get_download_url）只需 file_id。
        let items = json!([
            { "file_id": "f1", "name": "a.flac", "type": "file", "size": 123, "parent_file_id": "p0" },
            { "file_id": "f2", "name": "dir", "type": "folder" },
        ]);
        let files = files_from_items(&items);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0]["id"], "f1");
        assert_eq!(files[0]["name"], "a.flac");
        assert_eq!(files[0]["isDir"], false);
        assert_eq!(files[0]["size"], 123);
        assert_eq!(files[0]["parentId"], "p0");
        assert_eq!(files[1]["isDir"], true);
        assert_eq!(files[1]["size"], 0);
    }
}
