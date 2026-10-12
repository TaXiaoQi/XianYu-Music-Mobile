// cloud_proxy 统一请求/响应模型。
//
// 调用方每次请求携带网盘凭据（cred），即用即弃、不落盘不打日志；
// 凭据轮换（如阿里 refresh_token 单次有效）通过 rotated_cred 随响应带回，
// 由客户端检测后回写本地凭据存储。
//
// 字段名与移动端 lib/src/cloud/cloud_types.dart 的 toJson 对齐（isDir、
// parentId 等驼峰键），客户端不做任何改名转换。

use serde_json::{json, Value};

/// 本地内联 Server 版 handlers/helpers 的三个纯函数（避免跨包 crate 路径）。
fn parse_body(body: &str) -> Value {
    serde_json::from_str(body).unwrap_or(Value::Null)
}

fn str_of(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string()
}

fn int_of(v: &Value, key: &str) -> i64 {
    v.get(key)
        .and_then(|x| {
            x.as_i64()
                .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
        })
        .unwrap_or(0)
}

/// 允许代理的操作（登录类操作留在客户端，不后端化）。
pub const OPS: &[&str] = &[
    "validate",
    "list_dir",
    "parse_share",
    "transfer_share",
    "direct_link",
    "share_direct_link",
];

pub struct CloudReq {
    pub provider: String,
    pub op: String,
    pub cred: Value,
    pub params: Value,
}

impl CloudReq {
    pub fn parse(body: &str) -> Result<Self, (i32, String)> {
        let data = parse_body(body);
        let provider = str_of(&data, "provider");
        if provider.is_empty() {
            return Err((400, "缺少 provider".into()));
        }
        let op = str_of(&data, "op");
        if !OPS.contains(&op.as_str()) {
            return Err((400, "未知操作".to_string()));
        }
        let cred = data.get("cred").cloned().unwrap_or_else(|| json!({}));
        if !cred.is_object() {
            return Err((400, "cred 格式错误".to_string()));
        }
        let params = data.get("params").cloned().unwrap_or_else(|| json!({}));
        Ok(Self {
            provider,
            op,
            cred,
            params,
        })
    }

    /// cred 内字符串值读取（缺失/非串返回空串）。
    pub fn cred_str(&self, key: &str) -> String {
        self.cred
            .get(key)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    }

    /// params 内字符串值读取。
    pub fn param_str(&self, key: &str) -> String {
        self.params
            .get(key)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    }

    /// params 内整数值读取（兼容字符串数字）。
    pub fn param_int(&self, key: &str) -> i64 {
        int_of(&self.params, key)
    }

    pub fn param_obj(&self, key: &str) -> Value {
        self.params
            .get(key)
            .cloned()
            .unwrap_or_else(|| json!({}))
    }
}

/// 单次代理调用的产出：op 特定结果 + 可选的轮换凭据。
pub struct CloudOut {
    pub result: Value,
    pub rotated_cred: Option<Value>,
}

impl CloudOut {
    pub fn plain(result: Value) -> Self {
        Self {
            result,
            rotated_cred: None,
        }
    }

    pub fn rotated(result: Value, rotated_cred: Value) -> Self {
        Self {
            result,
            rotated_cred: Some(rotated_cred),
        }
    }
}

/// CloudFile 序列化（对齐 CloudFile.toJson：isDir/parentId 驼峰键）。
#[allow(clippy::too_many_arguments)]
pub fn file_json(
    id: &str,
    name: &str,
    is_dir: bool,
    size: i64,
    parent_id: Option<&str>,
    path: Option<&str>,
    token: Option<&str>,
) -> Value {
    let mut v = json!({
        "id": id,
        "name": name,
        "isDir": is_dir,
        "size": size,
    });
    if let Some(p) = parent_id {
        v["parentId"] = json!(p);
    }
    if let Some(p) = path {
        v["path"] = json!(p);
    }
    if let Some(t) = token {
        v["token"] = json!(t);
    }
    v
}

/// CloudListResult 序列化；next_cursor 为 None 表示已到底。
pub fn list_result_json(files: Vec<Value>, next_cursor: Option<String>) -> Value {
    json!({
        "files": files,
        "nextCursor": next_cursor,
    })
}

/// CloudDirectLink 序列化；expire_at_ms 为毫秒时间戳，None 交客户端按默认 TTL。
pub fn direct_link_json(
    url: &str,
    headers: Value,
    file_name: Option<&str>,
    size: Option<i64>,
    expire_at_ms: Option<i64>,
) -> Value {
    let mut v = json!({
        "url": url,
        "headers": headers,
    });
    if let Some(n) = file_name {
        v["fileName"] = json!(n);
    }
    if let Some(s) = size {
        v["size"] = json!(s);
    }
    if let Some(e) = expire_at_ms {
        v["expireAt"] = json!(e);
    }
    v
}

/// CloudShareParse 序列化（对齐 CloudPlayContext.share 的载荷键名）。
pub fn share_parse_json(
    provider_id: &str,
    files: Vec<Value>,
    share_id: Option<&str>,
    share_token: Option<&str>,
    passcode: Option<&str>,
    direct_playable: bool,
) -> Value {
    let mut v = json!({
        "providerId": provider_id,
        "files": files,
        "directPlayable": direct_playable,
    });
    if let Some(s) = share_id {
        v["shareId"] = json!(s);
    }
    if let Some(s) = share_token {
        v["shareToken"] = json!(s);
    }
    if let Some(p) = passcode {
        v["passcode"] = json!(p);
    }
    v
}
