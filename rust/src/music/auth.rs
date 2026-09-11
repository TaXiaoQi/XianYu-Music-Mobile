// music/auth.rs - 账号认证与签名请求
//
// 从桌面端（authService.ts + httpClient.ts + md5.ts 迁移）移植：
// MD5 签名算法、带签名头的 POST 请求、token 的安全存储。
// 移动端 token 以文件形式存于 auth 目录（与 base_url/api_secret 一致），
// 需要系统安全存储时可由宿主在 Flutter 侧覆盖。
//
// 签名密钥不再暴露在前端 JS 中，全部在 Rust 侧完成。

use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

/// 默认 API 签名密钥。自建后端可在客户端账号设置页覆盖。
const DEFAULT_API_SECRET: &str = "bf027fedb4d1b4f969c10495f12f17042bf0de02de128200";

/// 官方后端地址
const OFFICIAL_AUTH_BASE_URL: &str = "https://api.xianyumusic.cn/api";

/// 默认后端地址：仅支持 HTTPS，避免 Nginx 重定向丢失 POST 请求体
const DEFAULT_AUTH_BASE_URL: &str = OFFICIAL_AUTH_BASE_URL;

/// token 文件名
const TOKEN_FILE: &str = "auth-token.txt";

/// 默认 fetch 超时（跨境链路丢包重传较多，25s 偏紧）
const DEFAULT_FETCH_TIMEOUT_MS: u64 = 40_000;

/// 服务器时间偏移文件（秒，服务器时间 - 本地时间），用于校准签名 timestamp
const TIME_OFFSET_FILE: &str = "time_offset.txt";

/// 全局 HTTP 客户端单例：复用连接池 / TLS 会话，避免每次请求重建 Client。
/// 超时通过 per-request `timeout()` 覆盖，不放在全局默认上。
static HTTP_CLIENT: OnceLock<Result<reqwest::Client, String>> = OnceLock::new();

fn http_client() -> &'static Result<reqwest::Client, String> {
    HTTP_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            // SSRF 纵深：跳转目标做 IP 字面量校验，防重定向到内网
            .redirect(crate::security::ssrf::ip_literal_redirect_policy())
            // DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
            .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
            .build()
            .map_err(|e| format!("创建 HTTP 客户端失败: {e}"))
    })
}

// ─── 辅助结构 ──────────────────────────────────────────

struct SignedHeaders {
    timestamp: String,
    nonce: String,
    sign: String,
}

/// 生成随机 nonce（32 位十六进制字符串）
fn generate_nonce() -> String {
    uuid::Uuid::new_v4().as_simple().to_string()
}

/// 计算签名并返回带签名的请求头信息（timestamp 由调用方传入，可含时间偏移校准）
fn build_signed_headers(body: &str, api_secret: &str, timestamp: i64) -> SignedHeaders {
    let nonce = generate_nonce();
    let sign_input = format!("{}{}{}{}", timestamp, nonce, body, api_secret);
    let digest = md5::compute(sign_input.as_bytes());
    let sign = format!("{:x}", digest);
    SignedHeaders {
        timestamp: timestamp.to_string(),
        nonce,
        sign,
    }
}

/// 本地时钟（秒）
fn local_now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// 解析 HTTP Date 头（RFC 7231 IMF-fixdate，如 `Wed, 10 Sep 2026 06:34:48 GMT`）为 epoch 秒
fn parse_http_date(s: &str) -> Option<i64> {
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let b = s.as_bytes();
    if b.len() < 29 {
        return None;
    }
    let day: i64 = s.get(5..7)?.trim().parse().ok()?;
    let month_part = s.get(8..11)?;
    let mon = MONTHS
        .iter()
        .position(|m| month_part.eq_ignore_ascii_case(m))? as i64;
    let year: i64 = s.get(12..16)?.parse().ok()?;
    let mut t = s.get(17..25)?.split(':');
    let hour: i64 = t.next()?.parse().ok()?;
    let min: i64 = t.next()?.parse().ok()?;
    let sec: i64 = t.next()?.parse().ok()?;
    if !(1..=31).contains(&day)
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&min)
        || !(0..=60).contains(&sec)
    {
        return None;
    }
    Some(days_from_civil(year, mon + 1, day) * 86400 + hour * 3600 + min * 60 + sec)
}

/// Howard Hinnant 民用日期算法：公历日期 → 自 1970-01-01 起的天数
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

// ─── 凭证存储（文件） ──────────────────────────────────

/// 获取 auth 数据目录（`<data_dir>/auth`）
fn auth_data_dir(data_dir: &Path) -> Result<PathBuf, String> {
    let dir = data_dir.join("auth");
    fs::create_dir_all(&dir).map_err(|e| format!("创建 auth 目录失败: {e}"))?;
    Ok(dir)
}

/// user JSON 文件路径
fn user_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join("user.json"))
}

/// base_url 文件路径
fn base_url_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join("base_url.txt"))
}

/// api_secret 文件路径
fn api_secret_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join("api_secret.txt"))
}

/// token 文件路径
fn token_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join(TOKEN_FILE))
}

/// 从文件读取 base_url，不存在时返回默认值。
/// 自动将旧版 back.xymusic.cc 迁移到 api.xianyumusic.cn 并升级为 https。
fn read_base_url(data_dir: &Path) -> String {
    match base_url_file_path(data_dir) {
        Ok(path) => {
            if path.exists() {
                let saved = fs::read_to_string(&path)
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if saved.is_empty() {
                    return DEFAULT_AUTH_BASE_URL.to_string();
                }
                let upgraded = saved
                    .replace("http://back.xymusic.cc", "https://api.xianyumusic.cn")
                    .replace("https://back.xymusic.cc", "https://api.xianyumusic.cn");
                if upgraded != saved {
                    let _ = fs::write(&path, &upgraded);
                }
                upgraded
            } else {
                DEFAULT_AUTH_BASE_URL.to_string()
            }
        }
        Err(_) => DEFAULT_AUTH_BASE_URL.to_string(),
    }
}

/// 从文件读取 API 签名密钥，不存在时返回默认值
fn read_api_secret(data_dir: &Path) -> String {
    match api_secret_file_path(data_dir) {
        Ok(path) => {
            if path.exists() {
                let saved = fs::read_to_string(&path)
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if saved.is_empty() {
                    DEFAULT_API_SECRET.to_string()
                } else {
                    saved
                }
            } else {
                DEFAULT_API_SECRET.to_string()
            }
        }
        Err(_) => DEFAULT_API_SECRET.to_string(),
    }
}

/// 从文件读取 token
fn read_token(data_dir: &Path) -> Option<String> {
    token_file_path(data_dir)
        .ok()
        .filter(|path| path.exists())
        .and_then(|path| fs::read_to_string(&path).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// 时间偏移文件路径
fn time_offset_file_path(data_dir: &Path) -> Result<PathBuf, String> {
    Ok(auth_data_dir(data_dir)?.join(TIME_OFFSET_FILE))
}

/// 读取时间偏移（秒，服务器 - 本地）。文件缺失/损坏按 0（未校准）。
fn read_time_offset(data_dir: &Path) -> i64 {
    time_offset_file_path(data_dir)
        .ok()
        .filter(|path| path.exists())
        .and_then(|path| fs::read_to_string(&path).ok())
        .and_then(|s| s.trim().parse::<i64>().ok())
        .unwrap_or(0)
}

/// 保存时间偏移（秒）。写入失败静默（校准是尽力而为的优化）。
fn save_time_offset(data_dir: &Path, offset: i64) {
    if let Ok(path) = time_offset_file_path(data_dir) {
        let _ = fs::write(&path, offset.to_string());
    }
}

/// 将 token 写入文件
fn save_token(data_dir: &Path, token: &str) -> Result<(), String> {
    let path = token_file_path(data_dir)?;
    fs::write(&path, token).map_err(|e| format!("token 写入失败: {e}"))
}

/// 删除 token 文件
fn delete_token(data_dir: &Path) -> Result<(), String> {
    let path = token_file_path(data_dir)?;
    if path.exists() {
        fs::remove_file(&path).map_err(|e| format!("token 删除失败: {e}"))?;
    }
    Ok(())
}

// ─── 公开 API ──────────────────────────────────────────

#[derive(Serialize)]
pub struct AuthCredentials {
    pub token: String,
    pub user: Value,
}

/// 向账号 API 发起带签名的 POST 请求。
///
/// 自动构造 URL：`{base_url}/?action={action}`，
/// 生成 MD5 签名头（X-Timestamp / X-Nonce / X-Sign），
/// 返回完整的响应 JSON（`{ code, msg, data }`）。
///
/// - `data_dir`：调用方传入的应用数据目录
/// - `fetch_timeout_ms`：单个 HTTP 请求超时（默认 25s）
pub async fn authed_request(
    data_dir: &Path,
    action: String,
    body: Value,
    fetch_timeout_ms: Option<u64>,
) -> Result<Value, String> {
    let base_url = read_base_url(data_dir);
    let url = format!("{}/?action={}", base_url, action);
    let api_secret = read_api_secret(data_dir);

    do_signed_post(data_dir, &url, &action, body, fetch_timeout_ms, &api_secret).await
}

/// 向任意 URL 发起带签名的 POST 请求（壁纸等非账号 API 端点）。
///
/// 签名算法与 `authed_request` 完全一致：
/// `sign = md5(timestamp + nonce + body + api_secret)`
pub async fn signed_post_json(
    data_dir: &Path,
    url: String,
    body: Value,
    fetch_timeout_ms: Option<u64>,
) -> Result<Value, String> {
    let api_secret = read_api_secret(data_dir);
    do_signed_post(data_dir, &url, "signedPostJson", body, fetch_timeout_ms, &api_secret).await
}

/// 内部：执行带签名的 POST 请求。
///
/// - 签名 timestamp = 本地时钟 + 持久化的服务器时间偏移。部分网络（运营商热点/
///   企业网/校园网）拦 NTP 导致设备时钟漂移，漂移超过服务端 tolerance 即被拒签
///   ——这是「部分网络登录提示签名验证失败」的主因，偏移校准可根治。
/// - 每次收到响应都从 Date 头重校偏移（变化 ≥3s 才写盘，滤掉亚秒级噪声）。
/// - 网络错误/超时自动重试一次（换 nonce）；服务端 403「签名验证失败」时已用
///   本响应 Date 重校偏移，立即重试一次。
async fn do_signed_post(
    data_dir: &Path,
    url: &str,
    action: &str,
    body: Value,
    fetch_timeout_ms: Option<u64>,
    api_secret: &str,
) -> Result<Value, String> {
    let body_str = serde_json::to_string(&body).unwrap_or_default();
    let timeout_ms = fetch_timeout_ms.unwrap_or(DEFAULT_FETCH_TIMEOUT_MS);
    let client = http_client().as_ref().map_err(|e| e.clone())?;
    let mut offset = read_time_offset(data_dir);

    for attempt in 0..2 {
        let headers = build_signed_headers(&body_str, api_secret, local_now_secs() + offset);
        let start = std::time::Instant::now();

        let response = match client
            .post(url)
            .timeout(Duration::from_millis(timeout_ms))
            .header("Content-Type", "application/json")
            .header("X-Timestamp", &headers.timestamp)
            .header("X-Nonce", &headers.nonce)
            .header("X-Sign", &headers.sign)
            .body(body_str.clone())
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                if attempt == 0 {
                    continue; // 网络错误/超时：换 nonce 重试一次
                }
                let elapsed = start.elapsed().as_millis();
                let msg = e.to_string();
                let is_timeout = msg.contains("timeout") || msg.contains("elapsed");
                return Err(if is_timeout {
                    format!("请求超时（{}s），action={}", timeout_ms / 1000, action)
                } else {
                    format!("网络请求失败（action={}, {}ms）: {}", action, elapsed, msg)
                });
            }
        };

        let status = response.status();
        let date_header = response
            .headers()
            .get(reqwest::header::DATE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());
        let text = response
            .text()
            .await
            .map_err(|e| format!("响应体读取失败（action={}）: {}", action, e))?;

        // 从 Date 头校准服务器时间偏移并持久化（±3s 内视为噪声不更新）
        if let Some(server_secs) = date_header.as_deref().and_then(parse_http_date) {
            let new_offset = server_secs - local_now_secs();
            if (new_offset - offset).abs() >= 3 {
                offset = new_offset;
                save_time_offset(data_dir, offset);
            }
        }

        // 403 签名验证失败：偏移已按本响应 Date 重校，立即重试一次
        if attempt == 0 && status.as_u16() == 403 && text.contains("签名验证失败") {
            continue;
        }

        // 检测宝塔 WAF / nginx 错误页面
        if text.contains("宝塔WAF") || text.contains("缓冲区溢出") {
            return Err(format!(
                "服务器WAF拦截（action={}, HTTP {}）: 请求体过大，触发Nginx缓冲区溢出",
                action, status
            ));
        }

        // 解析 JSON
        let payload: Value = serde_json::from_str(&text).map_err(|e| {
            if !status.is_success() {
                format!(
                    "HTTP {}（action={}）: 服务器返回非 JSON 响应",
                    status, action
                )
            } else {
                format!("响应解析失败（action={}, HTTP {}）: {}", action, status, e)
            }
        })?;
        return Ok(payload);
    }
    unreachable!("重试循环两次尝试内必然返回")
}

/// 保存认证凭证：token 与 user JSON 均写入 auth 目录文件。
pub fn save_auth_credentials(data_dir: &Path, token: String, user: Value) -> Result<(), String> {
    save_token(data_dir, &token)?;

    let user_path = user_file_path(data_dir)?;
    let user_json =
        serde_json::to_string_pretty(&user).map_err(|e| format!("user 序列化失败: {e}"))?;
    fs::write(&user_path, user_json).map_err(|e| format!("user 文件写入失败: {e}"))?;

    Ok(())
}

/// 读取认证凭证：从文件读取 token 和 user。
/// 返回 None 表示未登录。
pub fn get_auth_credentials(data_dir: &Path) -> Result<Option<AuthCredentials>, String> {
    let Some(token) = read_token(data_dir) else {
        return Ok(None);
    };

    let user_path = user_file_path(data_dir)?;
    let user: Value = if user_path.exists() {
        let content =
            fs::read_to_string(&user_path).map_err(|e| format!("user 文件读取失败: {e}"))?;
        serde_json::from_str(&content).map_err(|e| format!("user JSON 解析失败: {e}"))?
    } else {
        Value::Null
    };

    Ok(Some(AuthCredentials { token, user }))
}

/// 清除认证凭证：删除 token 和 user 文件。
pub fn clear_auth_credentials(data_dir: &Path) -> Result<(), String> {
    delete_token(data_dir)?;

    let user_path = user_file_path(data_dir)?;
    if user_path.exists() {
        let _ = fs::remove_file(&user_path);
    }

    Ok(())
}

/// 设置 API 基地址（自定义服务器地址）。
pub fn set_auth_base_url(data_dir: &Path, base_url: String) -> Result<(), String> {
    let trimmed = base_url.trim();
    let url = if trimmed.is_empty() {
        DEFAULT_AUTH_BASE_URL.to_string()
    } else {
        trimmed.to_string()
    };

    let path = base_url_file_path(data_dir)?;
    fs::write(&path, &url).map_err(|e| format!("base_url 文件写入失败: {e}"))?;
    Ok(())
}

/// 获取当前 API 基地址。
pub fn get_auth_base_url(data_dir: &Path) -> Result<String, String> {
    Ok(read_base_url(data_dir))
}

/// 设置 API 签名密钥（自建服务器使用）。
pub fn set_auth_api_secret(data_dir: &Path, api_secret: String) -> Result<(), String> {
    let trimmed = api_secret.trim();
    let secret = if trimmed.is_empty() {
        DEFAULT_API_SECRET.to_string()
    } else {
        trimmed.to_string()
    };

    let path = api_secret_file_path(data_dir)?;
    fs::write(&path, &secret).map_err(|e| format!("api_secret 文件写入失败: {e}"))?;
    Ok(())
}

/// 获取当前 API 签名密钥。
pub fn get_auth_api_secret(data_dir: &Path) -> Result<String, String> {
    Ok(read_api_secret(data_dir))
}

#[cfg(test)]
mod time_calibrate_tests {
    use super::*;

    #[test]
    fn parse_http_date_standard() {
        // hyper 响应 Date 头标准格式
        let secs = parse_http_date("Thu, 10 Sep 2026 06:34:48 GMT").expect("应解析成功");
        let local = local_now_secs();
        // 服务器时间应在「当前 ±1 天」内（2026-09-10 前后），排除日期表/算法低级错误
        assert!(
            (secs - local).abs() < 86_400,
            "解析结果 {} 与本地时间 {} 偏差超过一天",
            secs,
            local
        );
        // 精确值：2026-09-10 06:34:48 UTC = 1789022088
        assert_eq!(secs, 1789022088);
    }

    #[test]
    fn parse_http_date_invalid() {
        assert!(parse_http_date("").is_none());
        assert!(parse_http_date("short").is_none());
        assert!(parse_http_date("Thu, Foo Sep 2026 06:34:48 GMT").is_none());
        assert!(parse_http_date("Thu, 10 Sep 2026 06:34:48").is_none());
        // 越界日期
        assert!(parse_http_date("Thu, 32 Sep 2026 06:34:48 GMT").is_none());
    }

    #[test]
    fn days_from_civil_epoch() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2000, 3, 1), 11017);
        assert_eq!(days_from_civil(2026, 9, 10), 20706);
    }

    #[test]
    fn offset_sign_semantics() {
        // 服务器快 10 分钟 → 偏移 +600，签名 timestamp = 本地 + 600
        let local = local_now_secs();
        let server = local + 600;
        let offset = server - local;
        assert_eq!(local + offset, server);
    }
}