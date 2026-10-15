// 夸克 / UC 网盘共用实现（两家同为阿里系 XCloud 架构，接口同构）。
//
// 移植自移动端 providers/quark_uc_base.dart + quark_provider.dart +
// uc_provider.dart：仅域名与 UA 品牌串不同，op 六件套逐一对齐 Dart 行为。

use serde_json::{json, Value};

use super::http;
use super::types::{direct_link_json, list_result_json, share_parse_json, CloudOut, CloudReq};
use super::{biz_err, pre_parse_share, require_cred};

struct Brand {
    api_host: &'static str,
    web_host: &'static str,
    pr: &'static str,
    ua_brand: &'static str,
}

// pr 两家同为 ucpro：drive-pc.*.cn 是同一套 UC 专业版客户端网关，
// 对 Web Cookie（__pus 系）校验宽松；pr=quark 是夸克官方客户端通道，
// 2026-10 起要求真客户端环境，Web Cookie 会被风控降为游客
// （401 require login [guest]，真机实测）。
const QUARK: Brand = Brand {
    api_host: "drive-pc.quark.cn",
    web_host: "pan.quark.cn",
    pr: "ucpro",
    ua_brand: "quark-cloud-drive",
};

const UC: Brand = Brand {
    api_host: "pc-api.uc.cn",
    web_host: "drive.uc.cn",
    pr: "ucpro",
    ua_brand: "uc-cloud-drive",
};

fn brand_of(provider: &str) -> &'static Brand {
    if provider == "uc" {
        &UC
    } else {
        &QUARK
    }
}

fn common_query(b: &Brand) -> String {
    format!("pr={}&fr=pc&sys=win32&ve=3.23.2", b.pr)
}

/// 文件搜索 URL（纯函数，单测断言）。端点 file/search 为设计稿形态：
/// 公共 query 逐字照抄 list，p=1/f=1-2 为设计稿过滤参数，以抓包为准。
fn search_url(b: &Brand, keyword: &str, page: i64) -> String {
    format!(
        "https://{}/1/clouddrive/file/search?{}&_page={page}&_size=50&p=1&f=1-2&keyword={}",
        b.api_host,
        common_query(b),
        http::url_encode(keyword)
    )
}

/// 桌面版浏览器 UA（分享/直链请求用）。
fn desktop_ua() -> &'static str {
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}

/// PC 客户端 Electron UA（取链与下载必须同串：夸克 CDN 校验 UA 与
/// 取链请求一致，不一致 403，真机实测）。
fn client_ua(b: &Brand) -> String {
    format!(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) {}/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch",
        b.ua_brand
    )
}

/// 带凭据的通用请求头。UA 为夸克/UC PC 客户端 Electron 串：pr=ucpro
/// 网关按此 UA 识别客户端身份（OpenList 同款配置，网页 Cookie 可用）。
fn auth_headers(b: &Brand, cred: &Value) -> Vec<(String, String)> {
    let pairs: Vec<(String, String)> = cred
        .as_object()
        .map(|m| {
            m.iter()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                .collect()
        })
        .unwrap_or_default();
    vec![
        ("User-Agent".into(), client_ua(b)),
        ("Referer".into(), format!("https://{}/", b.web_host)),
        ("Cookie".into(), http::cookie_header(&pairs)),
    ]
}

fn headers_with_ua(b: &Brand, ua: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".into(), ua.to_string()),
        ("Referer".into(), format!("https://{}/", b.web_host)),
    ]
}

/// download 接口 data 兼容数组/对象两种形态，提取 download_url。
fn extract_download_url(data: &Value) -> Option<String> {
    let url = if let Some(list) = data.as_array() {
        list.first()
            .and_then(|e| e.get("download_url"))
            .and_then(Value::as_str)
    } else {
        data.get("download_url").and_then(Value::as_str)
    }?;
    if url.is_empty() {
        None
    } else {
        Some(url.to_string())
    }
}

fn share_files_from_list(list: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(items) = list.as_array() {
        for e in items {
            let id = e
                .get("fid")
                .or_else(|| e.get("share_fid"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let name = e
                .get("file_name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let is_dir = e.get("dir").map(|d| d == &json!(true) || d == &json!(1)).unwrap_or(false);
            let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
            let token = e.get("fid_token").and_then(Value::as_str).map(str::to_string);
            out.push(super::types::file_json(
                id,
                &name,
                is_dir,
                size,
                None,
                None,
                token.as_deref(),
            ));
        }
    }
    out
}

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let b = brand_of(&req.provider);
    let url = format!("https://{}/1/clouddrive/member?{}", b.api_host, common_query(b));
    let resp = http::get(&url, &auth_headers(b, &req.cred))
        .await
        .map_err(biz_err)?;
    Ok(CloudOut::plain(json!({ "valid": resp.status == 200 })))
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let b = brand_of(&req.provider);
    let path = if req.param_str("path").is_empty() {
        "0".to_string()
    } else {
        req.param_str("path")
    };
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    if page < 1 {
        return Err(biz_err("非法翻页游标"));
    }
    let url = format!(
        "https://{}/1/clouddrive/file?{}&_page={}&_size=100&pdir_fid={}&_sort=file_type:asc,file_name:asc",
        b.api_host,
        common_query(b),
        page,
        http::url_encode(&path)
    );
    let resp = http::get(&url, &auth_headers(b, &req.cred))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        // 带上 status + 响应体片段：夸克凭据/风控问题只能从响应体定位
        // （如 NotLogin / 风控文案），光报「请求失败」没法排障。
        let body: String = resp.body.chars().take(300).collect();
        return Err((502, format!("目录列表请求失败 status={}: {body}", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    let data = j.get("data").cloned().unwrap_or(Value::Null);
    let list = data.get("list").cloned().unwrap_or(Value::Null);
    let mut files = Vec::new();
    if let Some(items) = list.as_array() {
        for e in items {
            let id = e.get("fid").and_then(Value::as_str).unwrap_or("");
            let name = e
                .get("file_name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let is_dir = e.get("dir").map(|d| d == &json!(true) || d == &json!(1)).unwrap_or(false);
            let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
            let pdir = e.get("pdir_fid").and_then(Value::as_str).unwrap_or("");
            let token = e.get("fid_token").and_then(Value::as_str).map(str::to_string);
            files.push(super::types::file_json(
                id,
                &name,
                is_dir,
                size,
                Some(pdir),
                Some(&path),
                token.as_deref(),
            ));
        }
    }
    let total = data.get("_total").and_then(Value::as_i64).unwrap_or(0);
    let has_next = page * 100 < total;
    let next_cursor = if has_next { Some((page + 1).to_string()) } else { None };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

/// file/search 的 data.metadata 条目 → CloudFile（映射纯函数，单测断言）。
/// 播放（file/download）只需 fid；parentId（pdir_fid）与 fid_token 照
/// list_dir 一并带回。
fn file_from_search_item(e: &Value) -> Value {
    let id = e.get("fid").and_then(Value::as_str).unwrap_or("");
    let name = e
        .get("file_name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let is_dir = e
        .get("dir")
        .map(|d| d == &json!(true) || d == &json!(1))
        .unwrap_or(false);
    let size = e.get("size").and_then(Value::as_i64).unwrap_or(0);
    let pdir = e.get("pdir_fid").and_then(Value::as_str).unwrap_or("");
    let token = e.get("fid_token").and_then(Value::as_str).map(str::to_string);
    super::types::file_json(id, &name, is_dir, size, Some(pdir), None, token.as_deref())
}

/// 文件搜索：keyword 必填，cursor 为页码（与 list_dir 同风格），
/// 返回结构与 list_dir 同构（list_result_json）。
async fn search_files(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let keyword = req.param_str("keyword");
    if keyword.is_empty() {
        return Err(biz_err("缺少搜索关键词"));
    }
    let b = brand_of(&req.provider);
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    if page < 1 {
        return Err(biz_err("非法翻页游标"));
    }
    let resp = http::get(&search_url(b, &keyword, page), &auth_headers(b, &req.cred))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("搜索请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let data = j.get("data").cloned().unwrap_or(Value::Null);
    let list = data.get("metadata").cloned().unwrap_or(Value::Null);
    let mut files = Vec::new();
    if let Some(items) = list.as_array() {
        for e in items {
            files.push(file_from_search_item(e));
        }
    }
    // 有更多判定照 list_dir：_total 对每页条数（此处 _size=50）。
    let total = data.get("_total").and_then(Value::as_i64).unwrap_or(0);
    let has_next = page * 50 < total;
    let next_cursor = if has_next { Some((page + 1).to_string()) } else { None };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, &req.provider)?;
    let b = brand_of(&req.provider);
    let pwd_id = if info.share_id.is_empty() {
        info.url.clone()
    } else {
        info.share_id.clone()
    };
    let pwd = req.param_str("pwd");
    let passcode = if pwd.is_empty() {
        info.passcode.clone().unwrap_or_default()
    } else {
        pwd
    };
    // 换 stoken（提取码错误时接口直接报）。
    let token_url = format!(
        "https://{}/1/clouddrive/share/sharepage/token?{}",
        b.api_host,
        common_query(b)
    );
    let token_resp = http::post_json(
        &token_url,
        &headers_with_ua(b, desktop_ua()),
        &json!({ "pwd_id": pwd_id, "passcode": passcode }),
    )
    .await
    .map_err(biz_err)?;
    if !token_resp.is_ok() {
        return Err(biz_err("分享链接解析失败"));
    }
    let tj = token_resp.json().map_err(biz_err)?;
    let stoken = tj
        .pointer("/data/stoken")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if stoken.is_empty() {
        let msg = tj
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("提取码错误");
        return Err(biz_err(msg));
    }
    let detail_url = format!(
        "https://{}/1/clouddrive/share/sharepage/detail?{}&pwd_id={}&stoken={}&pdir_fid=0&_page=1&_size=100&_sort=file_type:asc,file_name:asc",
        b.api_host,
        common_query(b),
        http::url_encode(&pwd_id),
        http::url_encode(&stoken)
    );
    let resp = http::get(&detail_url, &headers_with_ua(b, desktop_ua()))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("分享文件列表获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let files = j
        .pointer("/data/list")
        .map(share_files_from_list)
        .unwrap_or_default();
    Ok(CloudOut::plain(share_parse_json(
        &req.provider,
        files,
        Some(&pwd_id),
        Some(&stoken),
        Some(&passcode),
        true,
    )))
}

/// 分享免转存直链（夸克/UC 分享页下载接口）。
async fn share_direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let b = brand_of(&req.provider);
    let file = req.param_obj("file");
    let share = req.param_obj("share");
    let url = format!(
        "https://{}/1/clouddrive/share/sharepage/download?{}",
        b.api_host,
        common_query(b)
    );
    let body = json!({
        "pwd_id": share.get("shareId").and_then(Value::as_str).unwrap_or(""),
        "stoken": share.get("shareToken").and_then(Value::as_str).unwrap_or(""),
        "fids": [file.get("id").cloned().unwrap_or(json!(""))],
    });
    let resp = http::post_json(&url, &auth_headers(b, &req.cred), &body)
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("分享直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let dl = j
        .get("data")
        .cloned()
        .unwrap_or(Value::Null);
    let dl_url = extract_download_url(&dl).ok_or_else(|| biz_err("分享直链获取失败"))?;
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(CloudOut::plain(direct_link_json(
        &dl_url,
        json!({ "User-Agent": desktop_ua(), "Referer": format!("https://{}/", b.web_host) }),
        Some(name),
        size,
        Some(now_ms + 2 * 3600 * 1000),
    )))
}

/// 转存 → 轮询任务 → 完成后按文件名回查新 fid（转存后 fid 会变）。
async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let b = brand_of(&req.provider);
    let share = req.param_obj("share");
    let files_in = share
        .get("files")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if files_in.is_empty() {
        return Err(biz_err("分享内无可转存文件"));
    }
    let fid_list: Vec<&str> = files_in
        .iter()
        .map(|f| f.get("id").and_then(Value::as_str).unwrap_or(""))
        .collect();
    let fid_token_list: Vec<String> = files_in
        .iter()
        .map(|f| {
            f.get("token")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        })
        .collect();
    let save_url = format!(
        "https://{}/1/clouddrive/share/sharepage/save?{}",
        b.api_host,
        common_query(b)
    );
    let body = json!({
        "to_pdir_fid": "0",
        "fid_list": fid_list,
        "fid_token_list": fid_token_list,
        "pwd_id": share.get("shareId").and_then(Value::as_str).unwrap_or(""),
        "stoken": share.get("shareToken").and_then(Value::as_str).unwrap_or(""),
    });
    let save_resp = http::post_json(&save_url, &auth_headers(b, &req.cred), &body)
        .await
        .map_err(biz_err)?;
    if !save_resp.is_ok() {
        return Err(biz_err("转存请求失败"));
    }
    let sj = save_resp.json().map_err(biz_err)?;
    let task_id = sj
        .pointer("/data/task_id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if task_id.is_empty() {
        return Err(biz_err("转存失败"));
    }
    for i in 0..30 {
        tokio::time::sleep(std::time::Duration::from_millis(800)).await;
        let t_url = format!(
            "https://{}/1/clouddrive/task?{}&task_id={}&retry_index={}",
            b.api_host,
            common_query(b),
            http::url_encode(&task_id),
            i
        );
        let Ok(t_resp) = http::get(&t_url, &auth_headers(b, &req.cred)).await else {
            continue;
        };
        if !t_resp.is_ok() {
            continue;
        }
        let Ok(tj) = t_resp.json() else { continue };
        let status = tj.pointer("/data/status").and_then(Value::as_i64);
        if status == Some(2) {
            break;
        }
        if let Some(s) = status {
            if s >= 3 {
                return Err(biz_err("转存失败"));
            }
        }
    }
    // 按文件名回查新 fid。
    let list_req = CloudReq {
        provider: req.provider.clone(),
        op: "list_dir".into(),
        cred: req.cred.clone(),
        params: json!({ "path": "0" }),
    };
    let listed = list_dir(&list_req).await?.result;
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
    Ok(CloudOut::plain(json!({ "files": out })))
}

/// route1：我的网盘文件直链（file/download 接口）。
async fn direct_link_route1(b: &Brand, req: &CloudReq, file: &Value) -> Result<Value, (i32, String)> {
    let url = format!(
        "https://{}/1/clouddrive/file/download?{}",
        b.api_host,
        common_query(b)
    );
    let body = json!({ "fids": [file.get("id").cloned().unwrap_or(json!(""))] });
    let resp = http::post_json(&url, &auth_headers(b, &req.cred), &body)
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let dl = j.get("data").cloned().unwrap_or(Value::Null);
    let dl_url = extract_download_url(&dl).ok_or_else(|| biz_err("直链获取失败"))?;
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(direct_link_json(
        &dl_url,
        json!({ "User-Agent": client_ua(b), "Referer": format!("https://{}/", b.web_host) }),
        Some(name),
        size,
        Some(now_ms + 2 * 3600 * 1000),
    ))
}

/// 免速兜底路由：fast-transfer sendToPC 通道（仅夸克；任何异常归一为直链失败）。
async fn direct_link_route2_quark(
    b: &Brand,
    req: &CloudReq,
    file: &Value,
) -> Result<Value, (i32, String)> {
    let tok_url = "https://drive-social-api.quark.cn/1/clouddrive/chat/conv/file/acquire_dl_token?pr=quark&fr=pc".to_string();
    let tok_body = json!({ "file_id": file.get("id").cloned().unwrap_or(json!("")) });
    let tok_resp = http::post_json(&tok_url, &auth_headers(b, &req.cred), &tok_body)
        .await
        .map_err(|_| biz_err("直链获取失败"))?;
    let Ok(tj) = tok_resp.json() else {
        return Err(biz_err("直链获取失败"));
    };
    let dl_token = tj
        .pointer("/data/dl_token")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if dl_token.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let url = format!(
        "https://{}/1/clouddrive/file/download?{}&dl_token={}",
        b.api_host,
        common_query(b),
        http::url_encode(&dl_token)
    );
    let body = json!({ "fids": [file.get("id").cloned().unwrap_or(json!(""))] });
    let resp = http::post_json(&url, &auth_headers(b, &req.cred), &body)
        .await
        .map_err(|_| biz_err("直链获取失败"))?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(|_| biz_err("直链获取失败"))?;
    let dl = j.get("data").cloned().unwrap_or(Value::Null);
    let dl_url = extract_download_url(&dl).ok_or_else(|| biz_err("直链获取失败"))?;
    let name = file.get("name").and_then(Value::as_str).unwrap_or("");
    let size = file.get("size").and_then(Value::as_i64);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(direct_link_json(
        &dl_url,
        json!({ "User-Agent": client_ua(b), "Referer": format!("https://{}/", b.web_host) }),
        Some(name),
        size,
        Some(now_ms + 2 * 3600 * 1000),
    ))
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let b = brand_of(&req.provider);
    let file = req.param_obj("file");
    match direct_link_route1(b, req, &file).await {
        Ok(v) => Ok(CloudOut::plain(v)),
        Err(_) => {
            if req.provider == "quark" {
                let v = direct_link_route2_quark(b, req, &file).await?;
                Ok(CloudOut::plain(v))
            } else {
                Err(biz_err("直链获取失败"))
            }
        }
    }
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
    fn brand_constants() {
        assert_eq!(brand_of("quark").api_host, "drive-pc.quark.cn");
        // 两家 pr 同为 ucpro（UC 专业版网关对 Web Cookie 宽容）。
        assert_eq!(brand_of("quark").pr, "ucpro");
        assert_eq!(brand_of("uc").pr, "ucpro");
        assert_eq!(common_query(&QUARK), "pr=ucpro&fr=pc&sys=win32&ve=3.23.2");
    }

    #[test]
    fn auth_headers_shape() {
        let cred = json!({ "kps": "a", "sign": "b" });
        let h = auth_headers(&QUARK, &cred);
        assert!(h[0].1.contains("quark-cloud-drive/2.5.20"));
        assert_eq!(h[1].1, "https://pan.quark.cn/");
        assert_eq!(h[2].1, "kps=a; sign=b");
    }

    #[test]
    fn extract_url_array_and_object() {
        assert_eq!(
            extract_download_url(&json!([{ "download_url": "http://x" }])),
            Some("http://x".to_string())
        );
        assert_eq!(
            extract_download_url(&json!({ "download_url": "http://y" })),
            Some("http://y".to_string())
        );
        assert_eq!(extract_download_url(&json!({ "download_url": "" })), None);
    }

    #[test]
    fn search_url_shape() {
        // 两家仅域名与 pr 不同，query 其余逐字一致。
        assert_eq!(
            search_url(&QUARK, "lofi beats", 2),
            "https://drive-pc.quark.cn/1/clouddrive/file/search?pr=ucpro&fr=pc&sys=win32&ve=3.23.2&_page=2&_size=50&p=1&f=1-2&keyword=lofi+beats"
        );
        assert_eq!(
            search_url(&UC, "flac", 1),
            "https://pc-api.uc.cn/1/clouddrive/file/search?pr=ucpro&fr=pc&sys=win32&ve=3.23.2&_page=1&_size=50&p=1&f=1-2&keyword=flac"
        );
    }

    #[test]
    fn file_from_search_item_maps_fields() {
        let e = json!({
            "fid": "fid1",
            "file_name": "a.flac",
            "dir": 1,
            "size": 123,
            "pdir_fid": "p0",
            "fid_token": "tok",
        });
        let f = file_from_search_item(&e);
        assert_eq!(f["id"], "fid1");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], true);
        assert_eq!(f["size"], 123);
        assert_eq!(f["parentId"], "p0");
        assert_eq!(f["token"], "tok");
        // 搜索无目录上下文：path 留空。
        assert!(f.get("path").is_none());
        // 缺字段：isDir 回 false、token 留空。
        let f2 = file_from_search_item(&json!({ "fid": "fid2", "file_name": "b.mp3" }));
        assert_eq!(f2["isDir"], false);
        assert_eq!(f2["parentId"], "");
        assert!(f2.get("token").is_none());
    }
}
