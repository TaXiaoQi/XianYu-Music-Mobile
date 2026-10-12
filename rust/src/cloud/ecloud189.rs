// 天翼云盘（189）provider（smsPassword 登录留在客户端，仅移植业务 op）。
//
// 移植自移动端 providers/ecloud189_provider.dart。关键行为对齐点：
// - cred 存整串 cookie（'cookie' 键，与 Dart saveAccount 一致）；请求头
//   UA + Referer https://cloud.189.cn/（Cookie 非空才带）；
// - parse_share 匿名（仅 UA 头）：getShareInfoByCodeV2 → 有提取码先
//   checkAccessCode 校验（仅看 HTTP 状态）→ 文件直取或 listShareDir 列表；
// - isDir 语义：list 目录用 `dir == true || isdir == true`（严格布尔），
//   分享用 `isDir == true || isDir == 1`（布尔或数值 1）；
// - 转存 createBatchTask（taskInfos 为 JSON 字符串表单字段）→
//   checkBatchTask 轮询 taskStatus == '2'（20 次 × 800ms）；
// - 直链 getFileDownloadUrl 后手动跟随重定向归一终态 URL；
// - 登录/RSA logbox 链路/短信二次验证/portal 会话交换（Set-Cookie 逐跳
//   采集）不移植，业务 op 不产生凭据轮换；
// - 日志不打 cred/cookie 内容。

use serde_json::{json, Value};

use super::http;
use super::types::{
    direct_link_json, file_json, list_result_json, share_parse_json, CloudOut, CloudReq,
};
use super::{biz_err, pre_parse_share, require_cred};

const UA: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn jstr(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn num_i64(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))
}

/// Dart `x == true`：严格布尔。
fn dart_bool(v: Option<&Value>) -> bool {
    v == Some(&Value::Bool(true))
}

/// Dart `x == true || x == 1`：布尔真或数值 1。
fn dir_flag_189(v: Option<&Value>) -> bool {
    dart_bool(v) || num_i64(v) == Some(1)
}

/// `(data['fileId'] ?? '-1').toString()`。
fn file_id_of(data: &Value) -> String {
    data.get("fileId")
        .filter(|v| !v.is_null())
        .map(|v| jstr(Some(v)))
        .unwrap_or_else(|| "-1".to_string())
}

/// 通用请求头（Cookie 非空才带，对齐 Dart `if (cookie.isNotEmpty)`）。
fn auth_headers(cookie: &str) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".into(), UA.into()),
        ("Referer".into(), "https://cloud.189.cn/".into()),
    ];
    if !cookie.is_empty() {
        h.push(("Cookie".into(), cookie.to_string()));
    }
    h
}

fn check_task_url(task_id: &str) -> String {
    format!(
        "https://cloud.189.cn/api/open/batch/checkBatchTask.action?taskId={}",
        http::url_encode(task_id)
    )
}

fn task_done(state: &str) -> bool {
    state == "2"
}

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    // Dart 侧 try/catch 全吞：网络失败一律 valid=false。
    let ok = match http::get(
        "https://cloud.189.cn/api/open/file/listFiles.action?folderId=-11&pageNum=1&pageSize=1",
        &auth_headers(&req.cred_str("cookie")),
    )
    .await
    {
        Ok(resp) => resp.is_ok(),
        Err(_) => false,
    };
    Ok(CloudOut::plain(json!({ "valid": ok })))
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let path = req.param_str("path");
    let url = format!(
        "https://cloud.189.cn/api/open/file/listFiles.action?folderId={}&pageNum={page}&pageSize=60",
        http::url_encode(&path)
    );
    let resp = http::get(&url, &auth_headers(&req.cred_str("cookie")))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("目录列表请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let list = j
        .pointer("/data/fileListAO/fileList")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &list {
        files.push(file_json(
            &jstr(e.get("id")),
            &jstr(e.get("name")),
            dart_bool(e.get("dir")) || dart_bool(e.get("isdir")),
            num_i64(e.get("size")).unwrap_or(0),
            Some(&path),
            None,
            None,
        ));
    }
    let next_cursor = if files.len() >= 60 {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

/// 文件搜索 URL（纯函数，单测断言）：filename 关键词 + 全盘 folderId=-11，
/// 翻页 pageNum/pageSize 照 list_dir 风格（60 条/页）。
fn search_url(keyword: &str, page: i64) -> String {
    format!(
        "https://cloud.189.cn/api/open/file/searchFiles.action?filename={}&folderId=-11&pageNum={page}&pageSize=60",
        http::url_encode(keyword)
    )
}

/// searchFiles 条目 → CloudFile（映射纯函数，单测断言）。字段防御式解析：
/// 搜索结果条目键名在列表/分享两种形态间摇摆（id|fileId、name|fileName、
/// dir|isdir|isDir、size|fileSize）；播放（getFileDownloadUrl）只需 id。
fn file_from_search_item(e: &Value) -> Value {
    let id = jstr(e.get("id").filter(|v| !v.is_null()).or_else(|| e.get("fileId")));
    let name = jstr(
        e.get("name")
            .filter(|v| !v.is_null())
            .or_else(|| e.get("fileName")),
    );
    let is_dir = dart_bool(e.get("dir")) || dart_bool(e.get("isdir")) || dir_flag_189(e.get("isDir"));
    let size = num_i64(e.get("size"))
        .or_else(|| num_i64(e.get("fileSize")))
        .unwrap_or(0);
    file_json(&id, &name, is_dir, size, None, None, None)
}

/// 文件搜索：keyword 必填，cursor 为页码（与 list_dir 同风格），
/// 返回结构与 list_dir 同构（list_result_json）。
async fn search_files(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let keyword = req.param_str("keyword");
    if keyword.is_empty() {
        return Err(biz_err("缺少搜索关键词"));
    }
    let page: i64 = req.param_str("cursor").parse().unwrap_or(1);
    let resp = http::get(&search_url(&keyword, page), &auth_headers(&req.cred_str("cookie")))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("搜索请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    // 接口形状防御式解析：data 包裹与裸 fileListAO 两种形态都接。
    let list = j
        .pointer("/data/fileListAO/fileList")
        .or_else(|| j.pointer("/fileListAO/fileList"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &list {
        files.push(file_from_search_item(e));
    }
    let next_cursor = if files.len() >= 60 {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "ecloud189")?;
    let share_code = if info.share_id.is_empty() {
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
    let headers = vec![("User-Agent".into(), UA.into())];
    let info_url = format!(
        "https://cloud.189.cn/api/open/share/getShareInfoByCodeV2.action?shareCode={}",
        http::url_encode(&share_code)
    );
    let info_resp = http::get(&info_url, &headers)
        .await
        .map_err(biz_err)?;
    if !info_resp.is_ok() {
        return Err(biz_err("分享链接解析失败"));
    }
    let ij = info_resp.json().map_err(biz_err)?;
    let data = ij.get("data").cloned().unwrap_or(Value::Null);
    if !data.is_object() {
        return Err(biz_err("分享已失效"));
    }
    let share_id = jstr(data.get("shareId"));
    let file_id = file_id_of(&data);
    let is_dir = dir_flag_189(data.get("isDir"));
    // 有提取码：checkAccessCode 校验（仅看 HTTP 状态，对齐 Dart）。
    if !pwd.is_empty() {
        let chk = http::post_form(
            "https://cloud.189.cn/api/open/share/checkAccessCode.action",
            &headers,
            vec![
                ("shareCode".into(), share_code.clone()),
                ("accessCode".into(), pwd.clone()),
            ],
        )
        .await
        .map_err(biz_err)?;
        if !chk.is_ok() {
            return Err(biz_err("提取码错误"));
        }
    }
    let mut files = Vec::new();
    if !is_dir {
        files.push(file_json(
            &file_id,
            &jstr(data.get("fileName")),
            false,
            num_i64(data.get("fileSize")).unwrap_or(0),
            None,
            None,
            None,
        ));
    } else {
        let list_url = format!(
            "https://cloud.189.cn/api/open/share/listShareDir.action?shareId={}&fileId={}&pageNum=1&pageSize=60",
            http::url_encode(&share_id),
            http::url_encode(&file_id)
        );
        let list_resp = http::get(&list_url, &headers).await.map_err(biz_err)?;
        if !list_resp.is_ok() {
            return Err(biz_err("分享文件列表获取失败"));
        }
        let lj = list_resp.json().map_err(biz_err)?;
        let entries = lj
            .pointer("/data/fileShareResponseInfos")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for e in &entries {
            files.push(file_json(
                &jstr(e.get("fileId")),
                &jstr(e.get("fileName")),
                dir_flag_189(e.get("isDir")),
                num_i64(e.get("fileSize")).unwrap_or(0),
                None,
                None,
                None,
            ));
        }
    }
    Ok(CloudOut::plain(share_parse_json(
        "ecloud189",
        files,
        Some(&share_id),
        None,
        if pwd.is_empty() { None } else { Some(&pwd) },
        false,
    )))
}

async fn transfer_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let share = req.param_obj("share");
    let files_in = share
        .get("files")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let headers = vec![
        ("User-Agent".into(), UA.into()),
        ("Cookie".into(), req.cred_str("cookie")),
    ];
    let share_id = jstr(share.get("shareId"));
    let task_infos: Vec<Value> = files_in
        .iter()
        .map(|f| {
            json!({
                "fileId": jstr(f.get("id")),
                "fileName": jstr(f.get("name")),
                "isDir": f.get("isDir").and_then(Value::as_bool).unwrap_or(false),
                "shareId": share_id,
            })
        })
        .collect();
    let resp = http::post_form(
        "https://cloud.189.cn/api/open/share/createBatchTask.action",
        &headers,
        vec![
            ("type".into(), "SHARE_SAVE".into()),
            ("taskInfos".into(), json!(task_infos).to_string()),
            ("targetFolderId".into(), "-11".into()),
        ],
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("转存失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let task_id = jstr(j.pointer("/data/taskId"));
    if task_id.is_empty() {
        return Err(biz_err("转存失败"));
    }
    for _ in 0..20 {
        tokio::time::sleep(std::time::Duration::from_millis(800)).await;
        let t_resp = http::get(&check_task_url(&task_id), &headers)
            .await
            .map_err(biz_err)?;
        if !t_resp.is_ok() {
            continue;
        }
        let tj = t_resp.json().map_err(biz_err)?;
        if task_done(&jstr(tj.pointer("/data/taskStatus"))) {
            // 接口不回新文件 id；返回原 files（对齐 Dart）。
            return Ok(CloudOut::plain(json!({ "files": files_in })));
        }
    }
    Err(biz_err("转存失败"))
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
    let url = format!(
        "https://cloud.189.cn/api/open/file/getFileDownloadUrl.action?fileId={}",
        http::url_encode(&jstr(file.get("id")))
    );
    let resp = http::get(&url, &auth_headers(&req.cred_str("cookie")))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("直链获取失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let url = jstr(j.pointer("/data/fileDownloadUrl"));
    if url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    let final_url = resolve_final_url(&url, &[("User-Agent".into(), UA.into())]).await;
    let name = jstr(file.get("name"));
    let size = num_i64(file.get("size")).unwrap_or(0);
    Ok(CloudOut::plain(direct_link_json(
        &final_url,
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
        "share_direct_link" => Err(biz_err("该盘分享不支持免转存直链")),
        _ => Err((400, "未知操作".to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_cookie_conditional() {
        let h = auth_headers("SESSION=x");
        assert_eq!(h[0].1, UA);
        assert_eq!(h[1].1, "https://cloud.189.cn/");
        assert_eq!(h[2].0, "Cookie");
        assert_eq!(h[2].1, "SESSION=x");
        // 空串不带 Cookie 头。
        assert_eq!(auth_headers("").len(), 2);
    }

    #[test]
    fn dir_flag_semantics() {
        // list 目录用严格布尔。
        assert!(dart_bool(json!({ "dir": true }).get("dir")));
        assert!(!dart_bool(Some(&json!(1))));
        assert!(!dart_bool(None));
        // 分享用布尔或数值 1。
        assert!(dir_flag_189(Some(&json!(true))));
        assert!(dir_flag_189(Some(&json!(1))));
        assert!(dir_flag_189(Some(&json!(1.0))));
        assert!(!dir_flag_189(Some(&json!("1"))));
        assert!(!dir_flag_189(None));
    }

    #[test]
    fn file_id_default() {
        assert_eq!(file_id_of(&json!({ "fileId": 999 })), "999");
        assert_eq!(file_id_of(&json!({ "fileId": "f-1" })), "f-1");
        assert_eq!(file_id_of(&json!({})), "-1");
        assert_eq!(file_id_of(&json!({ "fileId": null })), "-1");
    }

    #[test]
    fn poll_url_and_state() {
        assert_eq!(
            check_task_url("T1"),
            "https://cloud.189.cn/api/open/batch/checkBatchTask.action?taskId=T1"
        );
        assert_eq!(
            check_task_url("a b"),
            "https://cloud.189.cn/api/open/batch/checkBatchTask.action?taskId=a+b"
        );
        assert!(task_done("2"));
        assert!(!task_done("1"));
        assert!(!task_done(""));
    }

    #[test]
    fn task_status_num_or_str() {
        // taskStatus 数值 2 与字符串 "2" 均视为完成。
        let j = json!({ "data": { "taskStatus": 2 } });
        let state = jstr(j.pointer("/data/taskStatus"));
        assert_eq!(state, "2");
        assert!(task_done(&state));
        let j2 = json!({ "data": { "taskStatus": "2" } });
        assert!(task_done(&jstr(j2.pointer("/data/taskStatus"))));
    }

    #[test]
    fn search_url_shape() {
        assert_eq!(
            search_url("lo fi", 2),
            "https://cloud.189.cn/api/open/file/searchFiles.action?filename=lo+fi&folderId=-11&pageNum=2&pageSize=60"
        );
        assert_eq!(
            search_url("周深", 1),
            "https://cloud.189.cn/api/open/file/searchFiles.action?filename=%E5%91%A8%E6%B7%B1&folderId=-11&pageNum=1&pageSize=60"
        );
    }

    #[test]
    fn file_from_search_item_maps_fields() {
        // 列表形态键名。
        let f = file_from_search_item(&json!({
            "id": "f1", "name": "a.flac", "dir": true, "size": 123,
        }));
        assert_eq!(f["id"], "f1");
        assert_eq!(f["name"], "a.flac");
        assert_eq!(f["isDir"], true);
        assert_eq!(f["size"], 123);
        // 分享形态键名兜底（fileId/fileName/isDir/fileSize）。
        let f2 = file_from_search_item(&json!({
            "fileId": 999, "fileName": "b.mp3", "isDir": false, "fileSize": 9,
        }));
        assert_eq!(f2["id"], "999");
        assert_eq!(f2["name"], "b.mp3");
        assert_eq!(f2["isDir"], false);
        assert_eq!(f2["size"], 9);
        // 播放只需 id，parentId/path 留空。
        assert!(f.get("parentId").is_none());
        assert!(f.get("path").is_none());
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
