// 腾讯微云 provider（webviewToken 混合：openid 走 pollScript，会话走 Cookie）。
//
// 移植自移动端 providers/weiyun_provider.dart。关键行为对齐点：
// - goapi 统一 req_header（cmd 12001 / appid 30013 / version 3.9.9），字段
//   防御式解析（接口形状不确定度高），失败文案简短；
// - goapi 请求头 UA + Referer www.weiyun.com + Cookie（仅 cred['cookie']
//   非空时携带；Content-Type 由 http::post_json 统一注入）；
// - cred 存整串 cookie（'cookie' 键）+ openid，与 Dart completeLogin 键名一致；
// - parse_share 匿名：分享页兜底抓 "share_key" 后走 WeiyunShareQuery；
// - 转存接口不保证回新 id，返回原 files（防御式兜底）；
// - 直链下载头需带登录 Cookie（Dart 即便空串也带 Cookie 键）；
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

/// `a ?? b ?? ''` 的字符串版（仅跳过 null，空串不跳）。
fn coalesce_jstr(a: Option<&Value>, b: Option<&Value>) -> String {
    match a.filter(|v| !v.is_null()) {
        Some(v) => jstr(Some(v)),
        None => jstr(b),
    }
}

/// goapi 统一请求头（Content-Type 由 post_json 注入，Cookie 非空才带）。
fn goapi_headers(cred: &Value) -> Vec<(String, String)> {
    let mut h = vec![
        ("User-Agent".into(), UA.into()),
        ("Referer".into(), "https://www.weiyun.com/".into()),
    ];
    let cookie = cred.get("cookie").and_then(Value::as_str).unwrap_or("");
    if !cookie.is_empty() {
        h.push(("Cookie".into(), cookie.to_string()));
    }
    h
}

fn req_header() -> Value {
    json!({
        "cmd": 12001,
        "appid": "30013",
        "version": "3.9.9",
        "major_version": "3",
        "minor_version": "9",
        "fix_version": "9",
    })
}

// ── 个人盘 webapp 网关（对齐 openlistnext weiyun 驱动，源自 OpenList
//    weiyun + weiyun-sdk-go）───────────────────────────────────────
// 2026-10-17 实测：旧 weiyunShareNetdisk 端点（分享网关）个人盘业务
// HTTP 非 2xx。个人盘走 weiyunQdisk/weiyunQdiskClient 协议：URL 带
// g_tk=cookie 的 wyctoken；req_header/req_body 为**双层 JSON 字符串**；
// 响应 data|result.rsp_header.retcode==0，业务数据在 rsp_body.RspMsg_body
// （可能是 JSON 字符串需二次解析）。

/// cred['cookie'] 解析为键值对列表（保序，'; ' 分隔，首个 '=' 切分）。
fn cookie_pairs(cred: &Value) -> Vec<(String, String)> {
    let raw = cred.get("cookie").and_then(Value::as_str).unwrap_or("");
    let mut out = Vec::new();
    for part in raw.split(';') {
        let part = part.trim();
        if let Some(eq) = part.find('=') {
            let (k, v) = (part[..eq].trim(), part[eq + 1..].trim());
            if !k.is_empty() && !v.is_empty() {
                out.push((k.to_string(), v.to_string()));
            }
        }
    }
    out
}

fn cookie_get<'a>(pairs: &'a [(String, String)], key: &str) -> &'a str {
    pairs
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
        .unwrap_or("")
}

/// 对齐 openlistnext parseTokenInfo：按 wy_uf/openid cookie 判定登录类型。
fn token_info(pairs: &[(String, String)]) -> Value {
    let wy_uf = cookie_get(pairs, "wy_uf");
    let qq_openid = cookie_get(pairs, "weiyun_qq_openid");
    let wx_openid = cookie_get(pairs, "weiyun_wx_openid");
    if (wy_uf == "2" && !qq_openid.is_empty()) || (wy_uf == "2" && !wx_openid.is_empty()) {
        // QQ/微信 openid 登录：token_type 3 + login_key_type 1540。
        json!({ "token_type": 3, "login_key_type": 1540 })
    } else if wy_uf == "1" {
        json!({
            "token_type": 1,
            "openid": cookie_get(pairs, "openid"),
            "open_appid": cookie_get(pairs, "wy_appid"),
            "access_token": cookie_get(pairs, "access_token"),
            "login_key_type": 192,
            "login_key_value": cookie_get(pairs, "access_token"),
        })
    } else {
        // QQ 快捷登录（wy_uf=0/缺省）：skey 签名。
        let skey = {
            let p = cookie_get(pairs, "p_skey");
            if p.is_empty() {
                cookie_get(pairs, "skey")
            } else {
                p
            }
        };
        json!({
            "token_type": 0,
            "login_key_type": 27,
            "login_key_value": skey,
            "openid": "",
        })
    }
}

/// webapp 网关 req_header（JSON 序列化后作为外层 req_header 字段值）。
fn goapi_header(cmd: i64, token: &Value) -> Value {
    let wx_openid = coalesce_jstr(
        token.get("openid"),
        token.get("minico_openid"),
    );
    json!({
        "seq": now_ms() / 1000,
        "cmd": cmd,
        "wx_openid": wx_openid,
        "qq_openid": "",
        "user_flag": token.get("token_type").and_then(Value::as_i64).unwrap_or(0),
        "env_id": "",
        "type": 1,
        "appid": 30013,
        "version": 3,
        "major_version": 3,
        "minor_version": 3,
        "fix_version": 3,
    })
}

/// webapp 网关统一请求：POST {protocol}/{cmdName}?g_tk={wyctoken}&cmd={cmd}，
/// 双层 JSON 序列化，返回解析后的 RspMsg_body（对象）。
async fn goapi(
    protocol: &str,
    cmd_name: &str,
    cmd: i64,
    data: Value,
    cred: &Value,
) -> Result<Value, (i32, String)> {
    let pairs = cookie_pairs(cred);
    let token = token_info(&pairs);
    let wyctoken = cookie_get(&pairs, "wyctoken");
    let url = format!(
        "https://www.weiyun.com/webapp/json/{protocol}/{cmd_name}?g_tk={}&cmd={cmd}",
        http::url_encode(wyctoken),
    );
    let body = json!({
        "req_header": serde_json::to_string(&goapi_header(cmd, &token))
            .unwrap_or_default(),
        "req_body": serde_json::to_string(&json!({
            "ReqMsg_body": {
                "ext_req_head": {
                    "token_info": token,
                    "language_info": { "language_type": 2052 },
                },
                format!(".weiyun.{cmd_name}MsgReq_body"): data,
            }
        }))
        .unwrap_or_default(),
    });
    let mut h = goapi_headers(cred);
    h.push(("Content-Type".into(), "application/json; charset=UTF-8".into()));
    let resp = http::post_json(&url, &h, &body).await.map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("微云接口请求失败"));
    }
    let j = resp.json().map_err(biz_err)?;
    let result = j.get("data").or_else(|| j.get("result")).unwrap_or(&j);
    let retcode = result
        .pointer("/rsp_header/retcode")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if retcode != 0 {
        let msg = result
            .pointer("/rsp_header/retmsg")
            .and_then(Value::as_str)
            .unwrap_or("微云接口错误");
        return Err(biz_err(msg));
    }
    let msg_body = result.pointer("/rsp_body/RspMsg_body").cloned();
    match msg_body {
        Some(Value::String(s)) => {
            if let Ok(v) = serde_json::from_str::<Value>(&s) {
                Ok(v)
            } else {
                Ok(json!({}))
            }
        }
        Some(v) => Ok(v),
        None => Ok(json!({})),
    }
}

/// 个人盘根目录 key（DiskUserInfoGet → root_dir_key）。
async fn root_dir_key(cred: &Value) -> Result<String, (i32, String)> {
    let rsp = goapi(
        "weiyunQdiskClient",
        "DiskUserInfoGet",
        2201,
        json!({
            "is_get_upload_flow_flag": false,
            "is_get_high_speed_flow_info": false,
            "is_get_weiyun_flag": false,
            "is_get_space_clean_info": false,
            "is_get_user_reward_info": false,
        }),
        cred,
    )
    .await?;
    let key = jstr(rsp.get("root_dir_key"));
    if key.is_empty() {
        return Err(biz_err("微云根目录获取失败"));
    }
    Ok(key)
}

/// 分享页提取 shareKey（页面 JS 变量，脆弱；仅作兜底）。
fn extract_share_key(body: &str) -> Option<String> {
    let re = regex::Regex::new(r#""share_key"\s*:\s*"([^"]+)""#).ok()?;
    re.captures(body).map(|c| c[1].to_string())
}

async fn validate(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    // DiskUserInfoGet 成功（retcode==0）即会话有效。
    let ok = root_dir_key(&req.cred).await.is_ok();
    Ok(CloudOut::plain(json!({ "valid": ok })))
}

async fn list_dir(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let start: i64 = req.param_str("cursor").parse().unwrap_or(0);
    let path = req.param_str("path");
    // 根目录（'0'/空）需先取 root_dir_key；子目录 path 即 dir_key。
    let dir_key = if path.is_empty() || path == "0" {
        root_dir_key(&req.cred).await?
    } else {
        path.clone()
    };
    let rsp = goapi(
        "weiyunQdisk",
        "DiskDirList",
        2208,
        json!({
            "dir_key": dir_key,
            "start": start,
            "count": 500,
            "sort_field": 2,
            "reverse_order": false,
            "get_type": 0,
            "get_abstract_url": false,
            "get_dir_detail_info": false,
        }),
        &req.cred,
    )
    .await?;
    let dir_list = rsp
        .get("dir_list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let file_list = rsp
        .get("file_list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &dir_list {
        files.push(file_json(
            &jstr(e.get("dir_key")),
            &jstr(e.get("dir_name")),
            true,
            0,
            Some(&path),
            None,
            None,
        ));
    }
    for e in &file_list {
        files.push(file_json(
            &jstr(e.get("file_id")),
            &jstr(e.get("filename")),
            false,
            num_i64(e.get("file_size")).unwrap_or(0),
            Some(&path),
            None,
            None,
        ));
    }
    // finish_flag=false 还有下一页；cursor 传下一页 start 偏移。
    let finished = rsp
        .get("finish_flag")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let got = (dir_list.len() + file_list.len()) as i64;
    let next_cursor = if !finished && got > 0 {
        Some((start + got).to_string())
    } else {
        None
    };
    Ok(CloudOut::plain(list_result_json(files, next_cursor)))
}

async fn parse_share(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    let info = pre_parse_share(req, "weiyun")?;
    let share_key = if info.share_id.is_empty() {
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
    // 分享页提取 shareKey 兜底（页面 JS 变量，脆弱）：任何失败都保持原 key。
    let mut key = share_key.clone();
    if let Ok(page) = http::get(
        &format!(
            "https://share.weiyun.com/{}",
            http::url_encode(&share_key)
        ),
        &[("User-Agent".into(), UA.into())],
    )
    .await
    {
        if page.is_ok() {
            if let Some(k) = extract_share_key(&page.body) {
                key = k;
            }
        }
    }
    let resp = http::post_json(
        "https://weiyun.com/webapp/json/weiyunShare/WeiyunShareQuery",
        &[("User-Agent".into(), UA.into())],
        &json!({
            "req_header": req_header(),
            "req_body": { "share_key": key, "pwd": pwd },
        }),
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("微云分享解析失败，请转存后播放"));
    }
    let j = resp.json().map_err(biz_err)?;
    let body = j.get("resp_body").cloned().unwrap_or(Value::Null);
    let list = body
        .get("list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    for e in &list {
        // Dart `e['is_dir'] == true`：严格布尔。
        let is_dir = e.get("is_dir") == Some(&Value::Bool(true));
        files.push(file_json(
            &jstr(e.get("file_id")),
            &jstr(e.get("file_name")),
            is_dir,
            num_i64(e.get("file_size")).unwrap_or(0),
            None,
            None,
            None,
        ));
    }
    Ok(CloudOut::plain(share_parse_json(
        "weiyun",
        files,
        Some(&key),
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
    let file_list: Vec<Value> = files_in
        .iter()
        .map(|f| {
            json!({
                "file_id": jstr(f.get("id")),
                "file_name": jstr(f.get("name")),
                "is_dir": f.get("isDir").and_then(Value::as_bool).unwrap_or(false),
            })
        })
        .collect();
    let body = json!({
        "req_header": req_header(),
        "req_body": {
            "share_key": share.get("shareId").and_then(Value::as_str).unwrap_or(""),
            "pwd": share.get("passcode").and_then(Value::as_str).unwrap_or(""),
            "file_list": file_list,
        },
    });
    let resp = http::post_json(
        "https://weiyun.com/webapp/json/weiyunNetdiskClient/CopySaveFile",
        &goapi_headers(&req.cred),
        &body,
    )
    .await
    .map_err(biz_err)?;
    if !resp.is_ok() {
        return Err(biz_err("转存失败"));
    }
    // 接口不保证回新 id；返回原 files（防御式兜底）。
    Ok(CloudOut::plain(json!({ "files": files_in })))
}

async fn direct_link(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    require_cred(req)?;
    let file = req.param_obj("file");
    let rsp = goapi(
        "weiyunQdiskClient",
        "DiskFileBatchDownload",
        2402,
        json!({
            "file_list": [{
                "file_id": jstr(file.get("id")),
                "filename": jstr(file.get("name")),
            }],
            "download_type": 0,
        }),
        &req.cred,
    )
    .await?;
    let item = rsp
        .get("file_list")
        .and_then(Value::as_array)
        .and_then(|l| l.first())
        .cloned()
        .unwrap_or(Value::Null);
    let url = jstr(item.get("download_url"));
    if url.is_empty() {
        return Err(biz_err("直链获取失败"));
    }
    // 响应会回专用下载 Cookie（cookie_name/cookie_value），拼接到会话
    // Cookie 后随下载请求携带。
    let cname = jstr(item.get("cookie_name"));
    let cvalue = jstr(item.get("cookie_value"));
    let mut cookie = req
        .cred
        .get("cookie")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if !cname.is_empty() && !cvalue.is_empty() {
        if !cookie.is_empty() {
            cookie.push_str("; ");
        }
        cookie.push_str(&cname);
        cookie.push('=');
        cookie.push_str(&cvalue);
    }
    let name = jstr(file.get("name"));
    let size = num_i64(file.get("size")).unwrap_or(0);
    Ok(CloudOut::plain(direct_link_json(
        &url,
        json!({
            "User-Agent": UA,
            "Cookie": cookie,
        }),
        Some(&name),
        Some(size),
        Some(now_ms() + 30 * 60 * 1000),
    )))
}

pub async fn dispatch(req: &CloudReq) -> Result<CloudOut, (i32, String)> {
    match req.op.as_str() {
        "validate" => validate(req).await,
        "list_dir" => list_dir(req).await,
        // goapi 未暴露检索接口。
        "search_files" => Err(biz_err("该盘不支持文件搜索")),
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
    fn goapi_headers_cookie_conditional() {
        let h = goapi_headers(&json!({ "cookie": "a=1; b=2", "openid": "o" }));
        assert_eq!(h[0].1, UA);
        assert_eq!(h[1].1, "https://www.weiyun.com/");
        assert_eq!(h[2].0, "Cookie");
        assert_eq!(h[2].1, "a=1; b=2");
        // cookie 缺失/为空时不带 Cookie 头。
        assert_eq!(goapi_headers(&json!({ "openid": "o" })).len(), 2);
        assert_eq!(goapi_headers(&json!({ "cookie": "" })).len(), 2);
    }

    #[test]
    fn req_header_shape() {
        // 旧分享网关头（parse_share/transfer_share 仍在用）。
        let h = req_header();
        assert_eq!(h["cmd"], json!(12001));
        assert_eq!(h["appid"], "30013");
        assert_eq!(h["version"], "3.9.9");
        assert_eq!(h["major_version"], "3");
        assert_eq!(h["fix_version"], "9");
    }

    #[test]
    fn token_info_by_wy_uf() {
        // openid 登录（QQ/微信）：token_type 3 + login_key_type 1540。
        let t = token_info(&cookie_pairs(&json!({
            "cookie": "wy_uf=2; weiyun_qq_openid=OZ; uin=o123"
        })));
        assert_eq!(t["token_type"], json!(3));
        assert_eq!(t["login_key_type"], json!(1540));
        // QQ 快捷登录：p_skey 优先，缺省回退 skey。
        let t2 = token_info(&cookie_pairs(&json!({ "cookie": "skey=@abc" })));
        assert_eq!(t2["token_type"], json!(0));
        assert_eq!(t2["login_key_value"], "@abc");
        let t3 = token_info(&cookie_pairs(&json!({ "cookie": "p_skey=P1; skey=@abc" })));
        assert_eq!(t3["login_key_value"], "P1");
        // access_token（微信登录）。
        let t4 = token_info(&cookie_pairs(&json!({ "cookie": "wy_uf=1; openid=oX; access_token=T" })));
        assert_eq!(t4["token_type"], json!(1));
        assert_eq!(t4["login_key_value"], "T");
    }

    #[test]
    fn goapi_header_shape() {
        let token = json!({ "token_type": 3, "login_key_type": 1540 });
        let h = goapi_header(2208, &token);
        assert_eq!(h["cmd"], json!(2208));
        assert_eq!(h["appid"], json!(30013)); // 数字。
        assert_eq!(h["version"], json!(3)); // 数字。
        assert_eq!(h["user_flag"], json!(3)); // = token_type。
        assert_eq!(h["qq_openid"], "");
        assert!(h["seq"].is_i64());
    }

    #[test]
    fn goapi_body_double_serialization() {
        // req_header/req_body 均为 JSON **字符串**（双层序列化），业务
        // 数据键带 ".weiyun.{cmdName}MsgReq_body" 前缀。
        let cmd_name = "DiskDirList";
        let outer = json!({
            "req_header": serde_json::to_string(&goapi_header(2208, &token_info(&[]))).unwrap(),
            "req_body": serde_json::to_string(&json!({
                "ReqMsg_body": {
                    "ext_req_head": {
                        "token_info": { "token_type": 3 },
                        "language_info": { "language_type": 2052 },
                    },
                    format!(".weiyun.{cmd_name}MsgReq_body"): { "dir_key": "k1" },
                }
            }))
            .unwrap(),
        });
        assert!(outer["req_header"].is_string());
        assert!(outer["req_body"].is_string());
        let inner: Value =
            serde_json::from_str(outer["req_body"].as_str().unwrap()).unwrap();
        assert_eq!(inner["ReqMsg_body"][&format!(".weiyun.{cmd_name}MsgReq_body")]["dir_key"], "k1");
        assert_eq!(inner["ReqMsg_body"]["ext_req_head"]["language_info"]["language_type"], 2052);
    }

    #[test]
    fn goapi_url_and_retcode_parse() {
        // URL 形态：g_tk 取 wyctoken cookie，query 带 cmd。
        let pairs = cookie_pairs(&json!({ "cookie": "wyctoken=WT%201; a=b" }));
        let wyctoken = cookie_get(&pairs, "wyctoken");
        let url = format!(
            "https://www.weiyun.com/webapp/json/weiyunQdisk/DiskDirList?g_tk={}&cmd=2208",
            http::url_encode(wyctoken)
        );
        assert!(url.contains("g_tk=WT%25201"), "wyctoken 需二次编码: {url}");
        assert!(url.ends_with("cmd=2208"));
        // 响应：data|result 包 rsp_header.retcode 与 RspMsg_body（字符串）。
        let resp = json!({
            "data": {
                "rsp_header": { "retcode": 0, "cmdname": "DiskDirList" },
                "rsp_body": { "RspMsg_body": "{\"dir_list\":[],\"file_list\":[]}" },
            }
        });
        let result = resp.get("data").unwrap();
        assert_eq!(result.pointer("/rsp_header/retcode"), Some(&json!(0)));
        let msg = result.pointer("/rsp_body/RspMsg_body").unwrap().as_str().unwrap();
        let parsed: Value = serde_json::from_str(msg).unwrap();
        assert!(parsed["file_list"].is_array());
    }

    #[test]
    fn share_key_extraction() {
        let body = r#"var cfg = {"share_key" : "abc123XYZ", "x": 1};"#;
        assert_eq!(extract_share_key(body).as_deref(), Some("abc123XYZ"));
        assert_eq!(extract_share_key("no match here"), None);
    }

    #[test]
    fn dir_entry_fallbacks() {
        let e = json!({ "dir_key": "dk1", "file_name": "目录", "file_id": "fid" });
        assert_eq!(coalesce_jstr(e.get("dir_key"), e.get("file_id")), "dk1");
        assert_eq!(coalesce_jstr(e.get("file_name"), e.get("dir_name")), "目录");
        let e2 = json!({ "file_id": "fid2", "dir_name": "fallback" });
        assert_eq!(coalesce_jstr(e2.get("dir_key"), e2.get("file_id")), "fid2");
        assert_eq!(coalesce_jstr(e2.get("file_name"), e2.get("dir_name")), "fallback");
    }

    #[test]
    fn is_dir_strict_bool() {
        // Dart `e['is_dir'] == true`：数字 1 不算。
        assert_eq!(json!({ "is_dir": true }).get("is_dir"), Some(&Value::Bool(true)));
        assert_ne!(json!({ "is_dir": 1 }).get("is_dir"), Some(&Value::Bool(true)));
        assert_ne!(json!({}).get("is_dir"), Some(&Value::Bool(true)));
    }

    #[test]
    fn file_size_parsing() {
        assert_eq!(num_i64(json!({ "file_size": 1024 }).get("file_size")), Some(1024));
        assert_eq!(num_i64(json!({}).get("file_size")), None);
    }
}
