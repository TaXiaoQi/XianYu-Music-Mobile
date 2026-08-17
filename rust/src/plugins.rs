//! 插件管理：HTTP 请求、文件读写、图片代理、音频临时下载。

use crate::security::path_validator;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::Duration;

#[derive(Serialize)]
pub struct PluginHttpResponse {
    pub status: u16,
    pub url: String,
    pub headers: HashMap<String, String>,
    pub body: String,
}

#[derive(Serialize)]
pub struct PluginHttpBinaryResponse {
    pub status: u16,
    pub url: String,
    pub headers: HashMap<String, String>,
    pub body_base64: String,
}

const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 异步 HTTP 请求 —— 使用 reqwest 异步客户端，不阻塞调用线程。
pub async fn plugin_http_request(
    method: String,
    url: String,
    headers: Option<HashMap<String, String>>,
    body: Option<String>,
    timeout: Option<u64>,
    follow: Option<u32>,
) -> Result<PluginHttpResponse, String> {
    let method =
        reqwest::Method::from_bytes(method.trim().as_bytes()).map_err(|error| error.to_string())?;

    let redirect_limit = follow.unwrap_or(10);
    let timeout_secs = timeout.unwrap_or(30);
    let client_builder = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::limited(redirect_limit as usize))
        .gzip(true)
        .brotli(true)
        .deflate(true)
        .user_agent(USER_AGENT);
    let client = if timeout_secs == 0 {
        client_builder.build()
    } else {
        client_builder
            .timeout(Duration::from_secs(timeout_secs))
            .build()
    }
    .map_err(|error| error.to_string())?;

    let mut request = client.request(method, &url);
    if let Some(headers) = headers {
        for (key, value) in headers {
            if key.trim().is_empty() || value.trim().is_empty() {
                continue;
            }
            request = request.header(key, value);
        }
    }
    if let Some(body) = body {
        request = request.body(body);
    }

    let mut response = request.send().await.map_err(|error| error.to_string())?;
    let status = response.status().as_u16();
    let final_url = response.url().to_string();
    let mut response_headers = HashMap::new();
    for (key, value) in response.headers().iter() {
        if let Ok(value) = value.to_str() {
            response_headers.insert(key.as_str().to_string(), value.to_string());
        }
    }
    const MAX_BODY_SIZE: usize = 50 * 1024 * 1024;
    let body = {
        let mut buf = Vec::with_capacity(4096);
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) => {
                    if buf.len() + chunk.len() > MAX_BODY_SIZE {
                        break;
                    }
                    buf.extend_from_slice(&chunk);
                }
                Ok(None) => break,
                Err(e) => return Err(e.to_string()),
            }
        }
        String::from_utf8(buf).unwrap_or_else(|_| "[INVALID_UTF8]".to_string())
    };

    Ok(PluginHttpResponse {
        status,
        url: final_url,
        headers: response_headers,
        body,
    })
}

/// 异步二进制 HTTP 请求 —— 返回 base64 编码的 body。
pub async fn plugin_http_request_binary(
    method: String,
    url: String,
    headers: Option<HashMap<String, String>>,
    body: Option<String>,
    timeout: Option<u64>,
    follow: Option<u32>,
) -> Result<PluginHttpBinaryResponse, String> {
    use base64::{engine::general_purpose, Engine as _};

    let method =
        reqwest::Method::from_bytes(method.trim().as_bytes()).map_err(|error| error.to_string())?;

    let redirect_limit = follow.unwrap_or(10);
    let request_timeout = Duration::from_secs(timeout.unwrap_or(30));
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::limited(redirect_limit as usize))
        .timeout(request_timeout)
        .user_agent(USER_AGENT)
        .build()
        .map_err(|error| error.to_string())?;

    let mut request = client.request(method, &url);
    if let Some(headers) = headers {
        for (key, value) in headers {
            if key.trim().is_empty() || value.trim().is_empty() {
                continue;
            }
            request = request.header(key, value);
        }
    }
    if let Some(body) = body {
        request = request.body(body);
    }

    let mut response = request.send().await.map_err(|error| error.to_string())?;
    let status = response.status().as_u16();
    let final_url = response.url().to_string();
    let mut response_headers = HashMap::new();
    for (key, value) in response.headers().iter() {
        if let Ok(value) = value.to_str() {
            response_headers.insert(key.as_str().to_string(), value.to_string());
        }
    }
    const MAX_BODY_SIZE: usize = 50 * 1024 * 1024;
    let body_base64 = {
        let mut buf = Vec::with_capacity(4096);
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) => {
                    if buf.len() + chunk.len() > MAX_BODY_SIZE {
                        break;
                    }
                    buf.extend_from_slice(&chunk);
                }
                Ok(None) => break,
                Err(e) => return Err(e.to_string()),
            }
        }
        general_purpose::STANDARD.encode(&buf)
    };

    Ok(PluginHttpBinaryResponse {
        status,
        url: final_url,
        headers: response_headers,
        body_base64,
    })
}

/// 读取本地插件/备份文件内容（.js / .json / .txt / .m3u / .m3u8）。
pub fn read_plugin_file(path: String) -> Result<String, String> {
    let validated = path_validator::validate_path(&path, None)
        .map_err(|e| format!("路径校验失败: {} (路径: {})", e, path))?;
    let path_obj = validated.as_path();
    if !path_obj.is_file() {
        return Err(format!("插件文件不存在: {}", path));
    }

    let ext = path_obj
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !matches!(ext.as_str(), "js" | "json" | "txt" | "m3u" | "m3u8") {
        return Err(format!(
            "不支持的文件类型: .{} (仅支持 .js/.json/.txt/.m3u/.m3u8)",
            ext
        ));
    }

    let metadata =
        fs::metadata(path_obj).map_err(|error| format!("读取文件元数据失败: {}", error))?;
    let max_size = if ext == "json" {
        50 * 1024 * 1024
    } else {
        5 * 1024 * 1024
    };
    if metadata.len() > max_size {
        return Err(format!(
            "文件过大: {} MB (上限 {} MB)",
            metadata.len() / 1024 / 1024,
            max_size / 1024 / 1024
        ));
    }

    fs::read_to_string(path_obj).map_err(|error| format!("读取文件内容失败: {}", error))
}

/// 将插件脚本保存到 `{data_dir}/plugins/{id}.js`，返回保存后的完整路径。
pub fn save_plugin_script(data_dir: &Path, id: String, script: String) -> Result<String, String> {
    let sanitized_id = path_validator::sanitize_filename_component(&id)
        .map_err(|e| format!("无效的插件 id: {}", e))?;
    if script.len() > 2 * 1024 * 1024 {
        return Err(format!(
            "插件脚本过大: {} bytes (上限 2MB)",
            script.len()
        ));
    }
    let plugins_dir = data_dir.join("plugins");
    fs::create_dir_all(&plugins_dir).map_err(|e| format!("创建插件目录失败: {e}"))?;
    let file_path = plugins_dir.join(format!("{sanitized_id}.js"));
    fs::write(&file_path, &script).map_err(|e| format!("写入插件脚本失败: {e}"))?;
    Ok(file_path.to_string_lossy().to_string())
}

/// 读取本地文件的二进制内容（base64 编码返回，.json / .zip / .lxmc）。
pub fn read_file_bytes(path: String) -> Result<String, String> {
    use base64::{engine::general_purpose, Engine as _};

    let validated = path_validator::validate_path(&path, None)
        .map_err(|e| format!("路径校验失败: {} (路径: {})", e, path))?;
    let path_obj = validated.as_path();
    if !path_obj.is_file() {
        return Err(format!("文件不存在: {}", path));
    }

    let ext = path_obj
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !matches!(ext.as_str(), "json" | "zip" | "lxmc") {
        return Err(format!(
            "不支持的文件类型: .{} (仅支持 .json/.zip/.lxmc)",
            ext
        ));
    }

    let metadata =
        fs::metadata(path_obj).map_err(|error| format!("读取文件元数据失败: {}", error))?;
    let max_size = 50 * 1024 * 1024;
    if metadata.len() > max_size {
        return Err(format!(
            "文件过大: {} MB (上限 {} MB)",
            metadata.len() / 1024 / 1024,
            max_size / 1024 / 1024
        ));
    }

    let bytes = fs::read(path_obj).map_err(|error| format!("读取文件内容失败: {}", error))?;
    Ok(general_purpose::STANDARD.encode(&bytes))
}

/// 代理图片请求 —— 自动添加 Referer 头，解决 CDN 403 问题，返回 data URL。
pub async fn proxy_image(url: String, referer: Option<String>) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .user_agent(USER_AGENT)
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = client.get(&url);
    let ref_url = referer.unwrap_or_else(|| {
        if url.contains("hdslb.com") || url.contains("bilivideo.com") {
            "https://www.bilibili.com".to_string()
        } else if url.contains("126.net") || url.contains("163.com") {
            "https://music.163.com/".to_string()
        } else if url.contains("kuwo.cn") || url.contains("kuwo.com") {
            "http://www.kuwo.cn/".to_string()
        } else if url.contains("kugou.com") || url.contains("kgmusic.com") {
            "http://www.kugou.com/".to_string()
        } else if url.contains("gtimg.cn") || url.contains("qq.com") {
            "https://y.qq.com/".to_string()
        } else if url.contains("migu.cn") {
            "https://m.music.migu.cn/".to_string()
        } else {
            String::new()
        }
    });
    if !ref_url.is_empty() {
        req = req.header("Referer", &ref_url);
    }

    let response = req.send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }

    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();

    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    if bytes.len() > 5 * 1024 * 1024 {
        return Err("Image too large".to_string());
    }

    use base64::{engine::general_purpose, Engine as _};
    let b64 = general_purpose::STANDARD.encode(&bytes);
    Ok(format!("data:{};base64,{}", content_type, b64))
}

/// 异步下载音频到临时文件，返回本地文件路径。
pub async fn download_audio_to_temp(
    url: String,
    headers: Option<HashMap<String, String>>,
) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .gzip(true)
        .brotli(true)
        .deflate(true)
        .user_agent(USER_AGENT)
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = client.get(&url);
    if let Some(hdrs) = headers {
        for (key, value) in hdrs {
            if !key.trim().is_empty() && !value.trim().is_empty() {
                req = req.header(key, value);
            }
        }
    }

    let response = req.send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }

    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    if bytes.is_empty() {
        return Err("Empty response".to_string());
    }

    let temp_dir = std::env::temp_dir();
    let file_name = format!(
        "xy_music_{}.m4s",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    let temp_path = temp_dir.join(&file_name);
    std::fs::write(&temp_path, &bytes).map_err(|e| e.to_string())?;

    Ok(temp_path.to_string_lossy().to_string())
}