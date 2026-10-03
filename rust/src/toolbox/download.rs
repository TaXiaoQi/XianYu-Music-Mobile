//! 在线下载编排：进度上报、附加产物落地、下载历史、URL 体积探测。

use super::*;

pub(crate) const DOWNLOAD_HISTORY_FILE: &str = "download_history.json";

/// 在线歌曲下载进度负载。
#[derive(serde::Serialize, Clone, Debug)]
pub struct SongDownloadProgress {
	pub progress: f64,
	pub downloaded: u64,
	pub total: u64,
	pub speed: f64,
}

/// 下载在线歌曲的真实音源直链到指定目标路径（流式写入 + QMC2/CENC 解密）。
pub async fn download_online_song(
	url: String,
	dest_path: String,
	ekey: Option<String>,
	cek: Option<String>,
	headers: Option<std::collections::HashMap<String, String>>,
) -> Result<String, String> { // 实现
	use std::time::Instant;
	use tokio::fs::File;
	use tokio::io::AsyncWriteExt;

	if !(url.starts_with("http://") || url.starts_with("https://")) {
		return Err("无效的下载链接".to_string());
	}

	// SSRF 防护：音源直链仅允许公网 http/https 目标，拒绝内网/回环/云元数据等
	crate::security::ssrf::validate_outbound_url(&url)
		.await
		.map_err(|e| format!("下载链接校验失败: {e}"))?;

	let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(600))
        // 每个跳转目标都需通过 SSRF 校验，防重定向到内网/元数据地址
        .redirect(crate::security::ssrf::ssrf_redirect_policy())
        // DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
        .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .build()
        .map_err(|e| format!("创建下载请求客户端失败: {e}"))?; // 实现

	let send_with_range = |with_range: bool| {
		let mut builder = client.get(&url).header(
			"Accept",
			"audio/webm,audio/ogg,audio/wav,audio/*;q=0.9,application/ogg;q=0.7,video/*;q=0.6,*/*;q=0.5",
		);
		if with_range {
			builder = builder.header("Range", "bytes=0-");
		}
		if let Some(ref hdrs) = headers {
			for (key, value) in hdrs {
				if key.eq_ignore_ascii_case("accept") || key.eq_ignore_ascii_case("range") {
					continue;
				}
				builder = builder.header(key.as_str(), value.as_str());
			}
		}
		builder.send()
	};

	let mut response = send_with_range(true)
		.await
		.map_err(|e| format!("发送下载请求失败: {e}"))?;
	let status_code = response.status().as_u16();
	if !response.status().is_success()
		&& (status_code == 502 || status_code == 416 || status_code == 403)
	{
		response = send_with_range(false)
			.await
			.map_err(|e| format!("发送下载请求（无 Range 回退）失败: {e}"))?;
	}
	if !response.status().is_success() {
		return Err(format!("下载服务器返回错误状态: {}", response.status()));
	}

	let total_size = response.content_length().unwrap_or(0);

	let dest = PathBuf::from(&dest_path);
	if let Some(parent) = dest.parent() {
		tokio::fs::create_dir_all(parent)
			.await
			.map_err(|e| format!("创建下载目录失败: {e}"))?;
	}

	let mut file = File::create(&dest)
		.await
		.map_err(|e| format!("创建目标文件失败: {e}"))?;
	let mut downloaded: u64 = 0;
	let start_time = Instant::now();

	let mut response = response;
	loop {
		match response.chunk().await {
			Ok(Some(chunk)) => {
				file
					.write_all(&chunk)
					.await
					.map_err(|e| format!("写入文件失败: {e}"))?;
				downloaded += chunk.len() as u64;
			}
			Ok(None) => break,
			Err(e) => {
				drop(file);
				let _ = tokio::fs::remove_file(&dest).await;
				return Err(format!("下载数据分块失败: {e}"));
			}
		}
	}

	file
		.flush()
		.await
		.map_err(|e| format!("刷新文件缓存失败: {e}"))?;
	drop(file);

	if total_size > 0 && downloaded < total_size {
		let _ = tokio::fs::remove_file(&dest).await;
		return Err(format!(
            "下载不完整（{downloaded}/{total_size} 字节），可能被其他下载器（如 IDM）拦截。请在下载器设置中排除本应用，或临时退出下载器后重试。"
        ));
	}

	if let Some(ref ek) = ekey {
		if !ek.is_empty() {
			match decrypt_qmc_file_inplace(&dest, ek) {
				Ok(_) => {}
				Err(e) => {
					return Err(format!("QMC2 解密失败: {e}"));
				}
			}
		}
	} else if let Some(ref ck) = cek {
		if !ck.is_empty() {
			// CENC 加密流（如网易 dolby 的渐进式 MP4/AES-CTR）：样本级
			// 就地解密，非 CENC 文件为无操作，与流缓存后处理同一实现。
			crate::player::stream_cache::decrypt_cenc_file(&dest, ck)
				.map_err(|e| format!("CENC 解密失败: {e}"))?;
		}
	} else if let Some(extracted_ekey) = try_extract_ekey_from_file(&dest) {
		match decrypt_qmc_file_inplace(&dest, &extracted_ekey) {
			Ok(_) => {}
			Err(e) => {
				return Err(format!("QMC2 解密失败（footer ekey）: {e}"));
			}
		}
	}

	let _ = start_time;
	Ok(dest.to_string_lossy().to_string())
}

#[derive(Debug, serde::Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FinalizeDownloadExtrasRequest {
	pub lyrics_text: Option<String>,
	pub lyrics_path: Option<String>,
	pub cover_url: Option<String>,
	pub cover_path: Option<String>,
	pub metadata: Option<EmbedMetadataRequest>,
	pub embed_cover: bool,
}

#[derive(Debug, Serialize, Default)]
pub struct FinalizeDownloadExtrasResult {
	pub lyrics_saved: bool,
	pub cover_saved: bool,
	pub metadata_embedded: bool,
	pub metadata_error: Option<String>,
	pub cover_data: Option<Vec<u8>>,
	pub cover_mime: String,
}

/// 下载后收尾编排：歌词保存 + 封面下载保存 + 元数据嵌入。
pub async fn finalize_download_extras(
	request: FinalizeDownloadExtrasRequest,
) -> Result<FinalizeDownloadExtrasResult, String> {
	let mut result = FinalizeDownloadExtrasResult::default();

	if let (Some(text), Some(path)) = (&request.lyrics_text, &request.lyrics_path) {
		if !text.is_empty() {
			let dest = PathBuf::from(path);
			if let Some(parent) = dest.parent() {
				let _ = tokio::fs::create_dir_all(parent).await;
			}
			match tokio::fs::write(&dest, text).await {
				Ok(_) => result.lyrics_saved = true,
				Err(_) => {}
			}
		}
	}

	if let Some(url) = &request.cover_url {
		if !url.is_empty() && (url.starts_with("http://") || url.starts_with("https://")) {
			match fetch_image_bytes(url.clone()).await {
				Ok(img) => {
					if let Some(path) = &request.cover_path {
						let actual_ext = if img.mime.contains("png") {
							".png"
						} else {
							".jpg"
						};
						let final_path = if path.ends_with(".jpg") && actual_ext == ".png" {
							format!("{}.png", &path[..path.len() - 4])
						} else if path.ends_with(".png") && actual_ext == ".jpg" {
							format!("{}.jpg", &path[..path.len() - 4])
						} else {
							path.clone()
						};
						let dest = PathBuf::from(&final_path);
						if let Some(parent) = dest.parent() {
							let _ = tokio::fs::create_dir_all(parent).await;
						}
						match tokio::fs::write(&dest, &img.data).await {
							Ok(_) => {
								result.cover_saved = true;
							}
							Err(_) => {}
						}
					}
					result.cover_data = Some(img.data);
					result.cover_mime = img.mime;
				}
				Err(_) => {}
			}
		}
	}

	if let Some(mut meta) = request.metadata {
		if request.embed_cover && meta.cover_data.is_none() {
			if let Some(data) = &result.cover_data {
				meta.cover_data = Some(data.clone());
				meta.cover_mime = Some(result.cover_mime.clone());
			}
		}
		let meta = meta.clone();
		match tokio::task::spawn_blocking(move || write_metadata_to_file(&meta)).await {
			Ok(Ok(())) => result.metadata_embedded = true,
			Ok(Err(e)) => {
				result.metadata_error = Some(e);
			}
			Err(e) => {
				result.metadata_error = Some(format!("元数据嵌入任务失败: {e}"));
			}
		}
	}

	Ok(result)
}

pub(crate) fn download_history_path(data_dir: &Path) -> Result<PathBuf, String> {
	Ok(data_dir.join(DOWNLOAD_HISTORY_FILE))
}

/// 读取下载记录 JSON 文本。文件不存在或损坏时返回 `"{}"`。
pub async fn read_download_history(data_dir: &Path) -> Result<String, String> {
	let path = download_history_path(data_dir)?;
	if !path.is_file() {
		return Ok("{}".to_string());
	}
	match tokio::fs::read_to_string(&path).await {
		Ok(content) if !content.trim().is_empty() => Ok(content),
		Ok(_) => Ok("{}".to_string()),
		Err(e) => Err(format!("读取下载记录失败: {e}")),
	}
}

/// 写入下载记录 JSON 文本（整体覆盖），自动创建父目录。
pub async fn write_download_history(data_dir: &Path, content: String) -> Result<(), String> {
	let path = download_history_path(data_dir)?;
	if let Some(parent) = path.parent() {
		tokio::fs::create_dir_all(parent)
			.await
			.map_err(|e| format!("创建下载记录目录失败: {e}"))?;
	}
	tokio::fs::write(&path, content)
		.await
		.map_err(|e| format!("写入下载记录失败: {e}"))?;
	Ok(())
}

#[derive(serde::Serialize, Clone, Debug)]
pub struct ProbeUrlInfo {
	pub url: String,
	pub size: u64,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub error: Option<String>,
}

/// 用 `Range: bytes=0-0` 探测直链文件大小。
pub async fn probe_url_size(url: String) -> Result<ProbeUrlInfo, String> {
	if !(url.starts_with("http://") || url.starts_with("https://")) {
		return Err("无效的探测链接".to_string());
	}

	// SSRF 防护：探测目标仅允许公网 http/https 地址
	crate::security::ssrf::validate_outbound_url(&url)
		.await
		.map_err(|e| format!("探测链接校验失败: {e}"))?;

	let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        // 每次跳转目标都需通过 SSRF 校验
        .redirect(crate::security::ssrf::ssrf_redirect_policy())
        // DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
        .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .build()
        .map_err(|e| format!("创建探测客户端失败: {e}"))?;

	let resp = match client
		.get(&url)
		.header(reqwest::header::RANGE, "bytes=0-0")
		.header(
			reqwest::header::ACCEPT,
			"audio/webm,audio/ogg,audio/wav,audio/*;q=0.9,*/*;q=0.5",
		)
		.send()
		.await
	{
		Ok(r) => r,
		Err(e) => {
			return Ok(ProbeUrlInfo {
				url,
				size: 0,
				error: Some(format!("请求失败: {e}")),
			});
		}
	};

	let final_url = resp.url().to_string();
	let status = resp.status();

	if status == reqwest::StatusCode::PARTIAL_CONTENT {
		let size = resp
			.headers()
			.get(reqwest::header::CONTENT_RANGE)
			.and_then(|v| v.to_str().ok())
			.and_then(|v| v.rsplit('/').next())
			.and_then(|v| v.parse::<u64>().ok())
			.unwrap_or(0);
		return Ok(ProbeUrlInfo {
			url: final_url,
			size,
			error: None,
		});
	}
	if status.is_success() {
		let size = resp
			.headers()
			.get(reqwest::header::CONTENT_LENGTH)
			.and_then(|v| v.to_str().ok())
			.and_then(|v| v.trim().parse::<u64>().ok())
			.unwrap_or(0);
		return Ok(ProbeUrlInfo {
			url: final_url,
			size,
			error: None,
		});
	}

	Ok(ProbeUrlInfo {
		url: final_url,
		size: 0,
		error: Some(format!("HTTP {status}")),
	})
}
