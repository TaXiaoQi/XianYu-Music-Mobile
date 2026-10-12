// 网盘业务实现（十盘：夸克/UC/阿里/百度/天翼/微云/蓝奏/移动139/123盘/PikPak/迅雷）。
//
// Dart 经 flutter_rust_bridge 的 api::cloud_proxy 调用本模块：请求 JSON 携带
// 凭据（cred），即用即弃、不落盘不打日志；凭据轮换（如阿里 refresh_token
// 单次有效）通过 rotated_cred 随响应带回，由 Dart 侧回写本地凭据存储。
//
// 日志脱敏约定：本模块不引 tracing、不输出任何日志，cred / token / cookie
// 不会出现在任何输出里。

pub mod aliyun;
pub mod baidu;
pub mod ecloud189;
pub mod http;
pub mod lanzou;
pub mod mobile139;
pub mod pan123;
pub mod parser;
pub mod pikpak;
pub mod quark_uc;
pub mod thunder;
pub mod types;
pub mod weiyun;

use serde_json::Value;

use types::CloudReq;

/// 十盘业务中心分发：按 provider 路由，返回 {"result": ..., "rotated_cred": ...}。
pub async fn dispatch(req: types::CloudReq) -> Result<serde_json::Value, (i32, String)> {
    let outcome: Result<types::CloudOut, (i32, String)> = match req.provider.as_str() {
        "quark" | "uc" => quark_uc::dispatch(&req).await,
        "aliyun" => aliyun::dispatch(&req).await,
        "baidu" => baidu::dispatch(&req).await,
        "ecloud189" => ecloud189::dispatch(&req).await,
        "lanzou" => lanzou::dispatch(&req).await,
        "mobile139" => mobile139::dispatch(&req).await,
        "pan123" => pan123::dispatch(&req).await,
        "pikpak" => pikpak::dispatch(&req).await,
        "thunder" => thunder::dispatch(&req).await,
        "weiyun" => weiyun::dispatch(&req).await,
        _ => Err((404, format!("未知网盘: {}", req.provider))),
    };
    match outcome {
        Ok(types::CloudOut {
            result,
            rotated_cred,
        }) => {
            let mut data = serde_json::json!({ "result": result });
            if let Some(rc) = rotated_cred {
                if rc.is_object() && !rc.as_object().unwrap().is_empty() {
                    data["rotated_cred"] = rc;
                }
            }
            Ok(data)
        }
        Err(e) => Err(e),
    }
}

/// 各盘 op 前置公共校验：需凭据的 op 拒绝空 cred。
pub fn require_cred(req: &CloudReq) -> Result<(), (i32, String)> {
    if req.cred.as_object().map(|m| m.is_empty()).unwrap_or(true) {
        return Err((400, "缺少网盘凭据".to_string()));
    }
    Ok(())
}

/// parse_share op 的公共前置：识别链接归属 + 要求 provider 一致。
pub fn pre_parse_share(
    req: &CloudReq,
    expect_provider: &str,
) -> Result<parser::ShareLinkInfo, (i32, String)> {
    let url = req.param_str("url");
    if url.is_empty() {
        return Err((400, "缺少分享链接".to_string()));
    }
    let info = parser::parse_url_to_provider(&url)
        .ok_or_else(|| (400, "无法识别的分享链接".to_string()))?;
    if info.provider_id != expect_provider {
        return Err((400, "分享链接与网盘不匹配".to_string()));
    }
    Ok(info)
}

/// 业务错误统一映射：网盘侧错误透传为 502（错误文案原样带给 Dart）。
pub fn biz_err(msg: impl std::fmt::Display) -> (i32, String) {
    (502, msg.to_string())
}

/// op 特定参数读取辅助：params 里任意 JSON 值。
pub fn param_value<'a>(req: &'a CloudReq, key: &str) -> Option<&'a Value> {
    req.params.get(key)
}
