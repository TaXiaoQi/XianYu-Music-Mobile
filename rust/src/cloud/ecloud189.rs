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

/// 天翼网关把 COOKIE_LOGIN_USER 绑定到登录请求的出口 IP（实测 400 响应：
/// InvalidSessionKey / "check ip error - curIp=x, cookiesIp=y"）。移动/
/// 宽带 CGNAT 会在多个出口 IP 间轮换，跨出口的请求一律被拒。策略：优先
/// 复用上次成功的独立连接池（保活连接出口稳定），命中 IP 错误则换新连接
/// 重试，成功后重新记住该客户端。
static PREFERRED_CLIENT: std::sync::RwLock<Option<reqwest::Client>> =
    std::sync::RwLock::new(None);

fn fresh_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .connect_timeout(std::time::Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_default()
}

fn is_ip_session_error(out: &http::Outbound) -> bool {
    !out.is_ok()
        && (out.body.contains("check ip error") || out.body.contains("InvalidSessionKey"))
}

/// 会话绑 IP 的 GET：命中出口 IP 错误时换新连接重试（最多 3 次）。
async fn get_ipbound(
    url: &str,
    headers: &[(String, String)],
) -> Result<http::Outbound, String> {
    let preferred = PREFERRED_CLIENT.read().ok().and_then(|g| g.clone());
    if let Some(c) = &preferred {
        let out = http::request_with_client(c, url, headers).await?;
        if !is_ip_session_error(&out) {
            return Ok(out);
        }
    }
    let mut last_ip_err: Option<http::Outbound> = None;
    for _ in 0..3 {
        let c = fresh_client();
        let out = http::request_with_client(&c, url, headers).await?;
        if !is_ip_session_error(&out) {
            if out.is_ok() {
                if let Ok(mut g) = PREFERRED_CLIENT.write() {
                    *g = Some(c);
                }
            }
            return Ok(out);
        }
        last_ip_err = Some(out);
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    // 新连接全部命中 IP 错误：退回共享池再试一次，仍错则返回最后的
    // IP 错误响应（调用方按非 2xx 报错，信息带 curIp/cookiesIp）。
    let out = http::get(url, headers).await?;
    if !is_ip_session_error(&out) {
        return Ok(out);
    }
    Ok(last_ip_err.unwrap_or(out))
}

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
#[cfg(test)]
fn file_id_of(data: &Value) -> String {
    data.get("fileId")
        .filter(|v| !v.is_null())
        .map(|v| jstr(Some(v)))
        .unwrap_or_else(|| "-1".to_string())
}

/// 天翼 open 分享接口固定返回 XML（Accept/UA 协商均无效，2026-10-23 实测），
/// 不引 XML 依赖，按平铺标量做文本提取：取首个 `<tag>text</tag>` 的内文。
fn xml_text(xml: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = xml.find(&open)? + open.len();
    let end = start + xml[start..].find(&close)?;
    Some(xml[start..end].trim().to_string())
}

/// 提取重复条目块（listShareDir 的 fileShareResponseInfos）：返回每个
/// `<tag>…</tag>` 的内文切片，块内平铺标量再逐个 xml_text 取字段。
fn xml_blocks(xml: &str, tag: &str) -> Vec<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let mut out = Vec::new();
    let mut rest = xml;
    while let Some(i) = rest.find(&open) {
        let start = i + open.len();
        let Some(j) = rest[start..].find(&close) else { break };
        out.push(rest[start..start + j].to_string());
        rest = &rest[start + j + close.len()..];
    }
    out
}

/// checkAccessCode 响应判定：成功回空体，错误码 HTTP 200 且
/// `<successResp><success>false</success></successResp>`（2026-10-23 实测）。
fn access_code_ok(body: &str) -> bool {
    !body.contains("<success>false</success>")
}

/// 通用请求头（Cookie 非空才带，对齐 Dart `if (cookie.isNotEmpty)`）。
fn auth_headers(cookie: &str) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".into(), UA.into()),
        ("Referer".into(), "https://cloud.189.cn/web/main/".into()),
        ("Accept".into(), "application/json;charset=UTF-8".into()),
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
    let ok = match get_ipbound(
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
    let cookie = req.cred_str("cookie");
    let resp = get_ipbound(&url, &auth_headers(&cookie))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        let head: String = resp.body.chars().take(160).collect();
        return Err(biz_err(&format!("目录列表请求失败(HTTP {}) {head}", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    // 实测响应存在两种形态：open 网关为 {"data":{"fileListAO":…}}，
    // PC web 会话为顶层 {"fileListAO":…}；且目录条目在 folderList
    // （fileList 仅文件，根目录只有文件夹时 fileList 为空数组）。
    let ao = j
        .pointer("/data/fileListAO")
        .or_else(|| j.get("fileListAO"))
        .cloned()
        .unwrap_or(Value::Null);
    let mut files = Vec::new();
    if let Some(folders) = ao.get("folderList").and_then(Value::as_array) {
        for e in folders {
            files.push(file_json(
                &jstr(e.get("id")),
                &jstr(e.get("name")),
                true, // folderList 内必为目录；实测条目无 dir/isdir 字段
                0,
                Some(&path),
                None,
                None,
            ));
        }
    }
    if let Some(list) = ao.get("fileList").and_then(Value::as_array) {
        for e in list {
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
    }
    let next_cursor = if files.len() >= 60 {
        Some((page + 1).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

/// 文件搜索 URL（纯函数，单测断言）：filename 关键词 + 全盘 folderId=-11
/// 递归搜索。路径**无 /api 前缀**（cloud.189.cn/open/file/searchFiles.action，
/// 带 /api 的 open 路径 404，MediaHelp 等同域 Cookie 实现同款），参数含
/// recursive=1（递归子目录）与 mediaType=0；翻页 pageNum。pageSize 实测
/// 上限 100（1000 直接 HTTP 400，2026-10-23 桌面端实测），取抓包参考值 60。
const SEARCH_PAGE_SIZE: i64 = 60;

fn search_url(keyword: &str, page: i64) -> String {
    format!(
        "https://cloud.189.cn/open/file/searchFiles.action?folderId=-11&pageSize={SEARCH_PAGE_SIZE}&pageNum={page}&recursive=1&mediaType=0&filename={}",
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
    let resp = get_ipbound(
        &search_url(&keyword, page),
        &auth_headers(&req.cred_str("cookie")),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err(&format!("搜索请求失败(HTTP {})", resp.status)));
    }
    let j = resp.json().map_err(biz_err)?;
    // 接口形状防御式解析：data 包裹与裸 fileListAO 两种形态都接；
    // fileList + folderList 合并（搜索会返回匹配的文件夹，UI 侧按
    // isAudio 过滤）。
    let mut files = Vec::new();
    for key in ["fileList", "folderList"] {
        let list = j
            .pointer(&format!("/data/fileListAO/{key}"))
            .or_else(|| j.pointer(&format!("/fileListAO/{key}")))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for e in &list {
            files.push(file_from_search_item(e));
        }
    }
    let next_cursor = if files.len() >= SEARCH_PAGE_SIZE as usize {
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
    // 接口固定返回 XML（<shareVO>…</shareVO>；Accept/UA 协商均无效，
    // 2026-10-23 实测），按平铺标量提取；失效/错误包无 fileId。
    let xml = info_resp.body;
    let file_id = xml_text(&xml, "fileId").ok_or_else(|| biz_err("分享已失效"))?;
    let share_id = xml_text(&xml, "shareId").unwrap_or_default();
    let is_dir = xml_text(&xml, "isFolder").as_deref() == Some("true");
    // 有提取码：checkAccessCode 校验。错误码也是 HTTP 200（
    // <successResp><success>false</success></successResp>），必须看响应体。
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
        if !chk.is_ok() || !access_code_ok(&chk.body) {
            return Err(biz_err("提取码错误"));
        }
    }
    let mut files = Vec::new();
    if !is_dir {
        files.push(file_json(
            &file_id,
            &xml_text(&xml, "fileName").unwrap_or_default(),
            false,
            xml_text(&xml, "fileSize")
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(0),
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
        // XML：重复 <fileShareResponseInfos> 条目块（字段名与旧 JSON 同构，
        // 块内平铺标量；目录型分享报文形态未实测）。
        for b in xml_blocks(&list_resp.body, "fileShareResponseInfos") {
            let entry_dir = xml_text(&b, "isDir")
                .or_else(|| xml_text(&b, "isFolder"))
                .as_deref()
                == Some("true");
            files.push(file_json(
                &xml_text(&b, "fileId").unwrap_or_default(),
                &xml_text(&b, "fileName").unwrap_or_default(),
                entry_dir,
                xml_text(&b, "fileSize")
                    .and_then(|s| s.parse::<i64>().ok())
                    .unwrap_or(0),
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
    let resp = get_ipbound(&url, &auth_headers(&req.cred_str("cookie")))
        .await
        .map_err(biz_err)?;
    if !resp.is_ok() {
        let head: String = resp.body.chars().take(160).collect();
        return Err(biz_err(&format!(
            "直链获取失败(HTTP {}) {head}",
            resp.status
        )));
    }
    let j = resp.json().map_err(biz_err)?;
    // open 网关包 data，PC web 会话为顶层（对齐 listFiles 实测形态）。
    let url = jstr(
        j.pointer("/data/fileDownloadUrl")
            .or_else(|| j.get("fileDownloadUrl"))
            .filter(|v| !v.is_null()),
    );
    if url.is_empty() {
        let head: String = resp.body.chars().take(160).collect();
        return Err(biz_err(&format!("直链为空 {head}")));
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
        assert_eq!(h[1].1, "https://cloud.189.cn/web/main/");
        assert_eq!(h[2].1, "application/json;charset=UTF-8");
        assert_eq!(h[3].0, "Cookie");
        assert_eq!(h[3].1, "SESSION=x");
        // 空串不带 Cookie 头。
        assert_eq!(auth_headers("").len(), 3);
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
    fn xml_text_extracts_sharevo() {
        // 2026-10-23 实测报文（截取）：平铺标量、值两端无空白。
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><shareVO><fileId>725191279626469549</fileId><fileName>Falling U (爱上你)-T-ara.flac</fileName><fileSize>28002902</fileSize><isFolder>false</isFolder><needAccessCode>1</needAccessCode><expireTime>0</expireTime></shareVO>";
        assert_eq!(xml_text(xml, "fileId").as_deref(), Some("725191279626469549"));
        assert_eq!(xml_text(xml, "isFolder").as_deref(), Some("false"));
        assert_eq!(xml_text(xml, "fileSize").as_deref(), Some("28002902"));
        assert_eq!(xml_text(xml, "shareId"), None);
        assert_eq!(xml_text(xml, "missing"), None);
    }

    #[test]
    fn xml_blocks_extracts_entries() {
        let xml = "<listShareDirResponse><count>2</count><fileShareResponseInfos><fileId>a1</fileId><fileName>甲.flac</fileName><isDir>false</isDir></fileShareResponseInfos><fileShareResponseInfos><fileId>b2</fileId><fileName>专辑</fileName><isDir>true</isDir></fileShareResponseInfos></listShareDirResponse>";
        let blocks = xml_blocks(xml, "fileShareResponseInfos");
        assert_eq!(blocks.len(), 2);
        assert_eq!(xml_text(&blocks[0], "fileId").as_deref(), Some("a1"));
        assert_eq!(xml_text(&blocks[0], "isDir").as_deref(), Some("false"));
        assert_eq!(xml_text(&blocks[1], "fileId").as_deref(), Some("b2"));
        assert_eq!(xml_text(&blocks[1], "isDir").as_deref(), Some("true"));
        assert!(xml_blocks(xml, "nonexistent").is_empty());
    }

    #[test]
    fn access_code_body_rule() {
        // 错误码 HTTP 200 + <success>false</success>；成功为空体。
        assert!(!access_code_ok(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><successResp><success>false</success></successResp>"
        ));
        assert!(access_code_ok(""));
        assert!(access_code_ok("<successResp><success>true</success></successResp>"));
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
        // 无 /api 前缀 + recursive/mediaType 参数（对齐同域 Cookie 实现抓包）。
        assert_eq!(
            search_url("lo fi", 2),
            "https://cloud.189.cn/open/file/searchFiles.action?folderId=-11&pageSize=60&pageNum=2&recursive=1&mediaType=0&filename=lo+fi"
        );
        assert_eq!(
            search_url("周深", 1),
            "https://cloud.189.cn/open/file/searchFiles.action?folderId=-11&pageSize=1000&pageNum=1&recursive=1&mediaType=0&filename=%E5%91%A8%E6%B7%B1"
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
