//! 杂项 IO：更新检查、文本/图片/字节写入、元数据嵌入、公告、状态持久化、壁纸。

use super::*;

pub async fn check_update_by_rust(owner: String, repo: String) -> Result<String, String> {
	let url = format!("https://api.github.com/repos/{owner}/{repo}/releases/latest");

	let client = reqwest::Client::builder()
		.timeout(std::time::Duration::from_secs(10))
		.dns_resolver(crate::security::ssrf::pinned_dns_resolver())
		.user_agent("XY-Music-Updater")
		.build()
		.map_err(|e| format!("创建更新请求失败: {e}"))?;

	client
		.get(&url)
		.header("Accept", "application/vnd.github+json")
		.send()
		.await
		.map_err(|e| format!("请求更新接口失败: {e}"))?
		.error_for_status()
		.map_err(|e| format!("更新接口返回错误状态: {e}"))?
		.text()
		.await
		.map_err(|e| format!("读取更新数据失败: {e}"))
}

/// 保存歌词文本到指定文件。
pub async fn save_download_lyrics(content: String, dest_path: String) -> Result<String, String> {
	write_text_file(content, dest_path).await
}

/// 将文本内容写入指定路径（自动创建父目录）。
pub async fn write_text_file(content: String, dest_path: String) -> Result<String, String> {
	let dest = path_validator::validate_path(&dest_path, None)?;
	if let Some(parent) = dest.parent() {
		tokio::fs::create_dir_all(parent)
			.await
			.map_err(|e| format!("创建目录失败: {e}"))?;
	}
	tokio::fs::write(&dest, content)
		.await
		.map_err(|e| format!("写入文件失败: {e}"))?;
	Ok(dest.to_string_lossy().to_string())
}

#[derive(Debug, Serialize)]
pub struct FetchedImage {
	pub data: Vec<u8>,
	pub mime: String,
}

/// 通过 reqwest 下载图片二进制数据（绕过 WebView CORS 限制）。
pub async fn fetch_image_bytes(url: String) -> Result<FetchedImage, String> {
	if !(url.starts_with("http://") || url.starts_with("https://")) {
		return Err("无效的图片链接".to_string());
	}

	// SSRF 防护：图片直链仅允许公网 http/https 目标
	crate::security::ssrf::validate_outbound_url(&url)
		.await
		.map_err(|e| format!("图片链接校验失败: {e}"))?;

	let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        // 每个跳转目标都需通过 SSRF 校验
        .redirect(crate::security::ssrf::ssrf_redirect_policy())
        // DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
        .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .build()
        .map_err(|e| format!("创建请求客户端失败: {e}"))?;

	let response = client
		.get(&url)
		.send()
		.await
		.map_err(|e| format!("请求图片失败: {e}"))?;

	if !response.status().is_success() {
		return Err(format!("图片服务器返回错误状态: {}", response.status()));
	}

	let mime = response
		.headers()
		.get(reqwest::header::CONTENT_TYPE)
		.and_then(|v| v.to_str().ok())
		.unwrap_or("image/jpeg")
		.to_string();

	let data = response
		.bytes()
		.await
		.map_err(|e| format!("读取图片数据失败: {e}"))?
		.to_vec();

	if data.is_empty() {
		return Err("图片数据为空".to_string());
	}

	Ok(FetchedImage { data, mime })
}

/// 将前端已下载的字节数据写入目标文件。
pub async fn save_download_bytes(data: Vec<u8>, dest_path: String) -> Result<String, String> {
	if data.is_empty() {
		return Err("下载数据为空".to_string());
	}
	let dest = path_validator::validate_path(&dest_path, None)?;
	if let Some(parent) = dest.parent() {
		tokio::fs::create_dir_all(parent)
			.await
			.map_err(|e| format!("创建下载目录失败: {e}"))?;
	}
	tokio::fs::write(&dest, &data)
		.await
		.map_err(|e| format!("写入文件失败: {e}"))?;
	Ok(dest.to_string_lossy().to_string())
}

/// 将歌曲元数据写入音频文件 tag。
pub async fn embed_audio_metadata(request: EmbedMetadataRequest) -> Result<(), String> {
	let request = request.clone();
	tokio::task::spawn_blocking(move || write_metadata_to_file(&request))
		.await
		.map_err(|e| format!("元数据嵌入任务失败: {e}"))?
}

pub async fn fetch_announcement() -> Result<String, String> {
	let url = "https://xy.zh2026.cn/chaoguan/public/api/app.php?action=app_announcement";

	let client = reqwest::Client::builder()
		.timeout(std::time::Duration::from_secs(15))
		// DNS pinning：公告接口为固定地址，钉住解析结果防 rebinding
		.dns_resolver(crate::security::ssrf::pinned_dns_resolver())
		.user_agent("XY-Music-Updater")
		.http1_only()
		.build()
		.map_err(|e| format!("创建请求客户端失败: {e}"))?;

	let resp = client
		.get(url)
		.header("Accept", "application/json")
		.header("Cache-Control", "no-cache")
		.send()
		.await
		.map_err(|e| format!("请求公告接口失败: {e}"))?;

	let status = resp.status();
	let text = resp
		.text()
		.await
		.map_err(|e| format!("读取公告数据失败: {e}"))?;

	if !status.is_success() {
		let snippet: String = text.chars().take(200).collect();
		return Err(format!("公告接口返回错误状态: {status} | 响应: {snippet}"));
	}

	match serde_json::from_str::<serde_json::Value>(&text) {
		Ok(v) => {
			let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(0);
			if code == 200 {
				match v.get("data") {
					Some(d) if !d.is_null() => return Ok(d.to_string()),
					_ => return Ok("{}".to_string()),
				}
			}
			let msg = v
				.get("msg")
				.and_then(|m| m.as_str())
				.unwrap_or("公告接口返回未知错误");
			Err(format!("公告接口返回错误: {msg}"))
		}
		Err(_) => {
			let snippet: String = text.chars().take(200).collect();
			Err(format!("公告数据解析失败，原始响应: {snippet}"))
		}
	}
}

/// 将 JSON 字符串写入 `{data_dir}/state/{key}.json`。
pub async fn write_state_json(data_dir: &Path, key: String, value: String) -> Result<(), String> {
	let sanitized_key =
		path_validator::sanitize_filename_component(&key).map_err(|e| format!("无效的 key: {}", e))?;
	let state_dir = data_dir.join("state");
	tokio::fs::create_dir_all(&state_dir)
		.await
		.map_err(|e| format!("创建 state 目录失败: {e}"))?;
	let file_path = state_dir.join(format!("{sanitized_key}.json"));
	tokio::fs::write(&file_path, &value)
		.await
		.map_err(|e| format!("写入 state 文件失败: {e}"))?;
	Ok(())
}

/// 从 `{data_dir}/state/{key}.json` 读取 JSON 字符串。文件不存在时返回 None。
pub async fn read_state_json(data_dir: &Path, key: String) -> Result<Option<String>, String> {
	let sanitized_key =
		path_validator::sanitize_filename_component(&key).map_err(|e| format!("无效的 key: {}", e))?;
	let file_path = data_dir.join("state").join(format!("{sanitized_key}.json"));
	if !file_path.exists() {
		return Ok(None);
	}
	let content = tokio::fs::read_to_string(&file_path)
		.await
		.map_err(|e| format!("读取 state 文件失败: {e}"))?;
	Ok(Some(content))
}

/// 下载壁纸图片到 `{data_dir}/wallpapers/{filename}`，返回本地文件路径。
pub async fn download_wallpaper( // 实现
	data_dir: &Path,
	url: String,
	filename: String,
) -> Result<String, String> { // 实现
	use tokio::fs::File;
	use tokio::io::AsyncWriteExt;

	if !(url.starts_with("http://") || url.starts_with("https://")) {
		return Err("无效的壁纸下载链接".to_string());
	}

	// SSRF 防护：壁纸源仅允许公网 http/https 目标
	crate::security::ssrf::validate_outbound_url(&url)
		.await
		.map_err(|e| format!("壁纸链接校验失败: {e}"))?;

	let safe_name = std::path::Path::new(&filename)
		.file_name()
		.and_then(|n| n.to_str())
		.unwrap_or("wallpaper.jpg")
		.to_string();
	let safe_name = if std::path::Path::new(&safe_name).extension().is_none() {
		format!("{safe_name}.jpg")
	} else {
		safe_name
	};

	let wallpaper_dir = data_dir.join("wallpapers");
	tokio::fs::create_dir_all(&wallpaper_dir)
		.await
		.map_err(|e| format!("创建壁纸目录失败: {e}"))?;
	let dest_path = wallpaper_dir.join(&safe_name);

	let client = reqwest::Client::builder()
		.timeout(std::time::Duration::from_secs(60))
		// 每个跳转目标都需通过 SSRF 校验
		.redirect(crate::security::ssrf::ssrf_redirect_policy())
		// DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
		.dns_resolver(crate::security::ssrf::pinned_dns_resolver())
		.user_agent("XY-Music-WallpaperDownloader")
		.build()
		.map_err(|e| format!("创建HTTP客户端失败: {e}"))?;

	let mut response = client
		.get(&url)
		.send()
		.await
		.map_err(|e| format!("下载壁纸失败: {e}"))?;
	if !response.status().is_success() {
		return Err(format!("下载服务器返回错误状态: {}", response.status()));
	}

	let mut file = File::create(&dest_path)
		.await
		.map_err(|e| format!("创建文件失败: {e}"))?;
	while let Some(chunk) = response
		.chunk()
		.await
		.map_err(|e| format!("读取响应数据失败: {e}"))?
	{
		file
			.write_all(&chunk)
			.await
			.map_err(|e| format!("写入文件失败: {e}"))?;
	}

	Ok(dest_path.to_string_lossy().to_string())
}

/// 删除 `{data_dir}/wallpapers` 下的已下载壁纸文件。
pub async fn delete_wallpaper_file(data_dir: &Path, local_path: String) -> Result<(), String> {
	let wallpaper_dir = data_dir.join("wallpapers");
	let target = PathBuf::from(&local_path);

	if !target.exists() {
		return Ok(());
	}
	if !target.is_file() {
		return Err("目标不是可删除的壁纸文件".to_string());
	}
	let canonical_dir =
		std::fs::canonicalize(&wallpaper_dir).map_err(|e| format!("读取壁纸目录失败: {e}"))?;
	let canonical_target =
		std::fs::canonicalize(&target).map_err(|e| format!("读取壁纸文件失败: {e}"))?;
	if !canonical_target.starts_with(&canonical_dir) {
		return Err("只能删除应用壁纸目录中的文件".to_string());
	}
	tokio::fs::remove_file(&target)
		.await
		.map_err(|e| format!("删除壁纸文件失败: {e}"))?;
	Ok(())
}
