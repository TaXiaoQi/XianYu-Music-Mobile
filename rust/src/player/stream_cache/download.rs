//! 流式下载执行：缓存文件创建、后台下载线程、请求头注入。

use super::*;

/// 为在线音频创建流式缓存文件并启动后台下载。
/// 如果同一 URL 的缓存已存在（下载完成），直接复用。
pub fn start_streaming_download(
	url: &str,
	headers: Option<&std::collections::HashMap<String, String>>,
	user_agent: Option<&str>,
	ekey: Option<&str>,
	cek: Option<&str>,
) -> Result<StreamingTempFileState, String> {
	// Rust 端 URL 清洗：移除插件可能返回的反引号、引号、逗号等脏字符
	let cleaned_url = sanitize_stream_url(url);
	let url = cleaned_url.as_str();
	let hash = url_hash(url);
	let mut mgr = cache().lock().map_err(|e| e.to_string())?;

	// 已有缓存：检查是否下载完成
	if let Some(entry) = mgr.entries.get(&hash) {
		if entry.download_failed.load(Ordering::Relaxed) {
			if let Some(failed) = mgr.entries.remove(&hash) {
				let _ = std::fs::remove_file(&failed.path);
				mgr.current_size = mgr.current_size.saturating_sub(failed.size);
			}
		}
	}

	if let Some(entry) = mgr.entries.get_mut(&hash) {
		entry.last_accessed = SystemTime::now();
		if entry.download_complete.load(Ordering::Relaxed)
			&& !entry.download_failed.load(Ordering::Relaxed)
		{
			// [CENC] 复用已完成缓存：若文件仍是加密态且提供了 cek，就地解密。
			// 解密失败则移除缓存，走全新下载。
			if let Some(cek_str) = cek {
				if let Err(_) = decrypt_cenc_file(&entry.path, cek_str) {
					let failed = mgr.entries.remove(&hash);
					if let Some(failed) = failed {
						let _ = std::fs::remove_file(&failed.path);
						mgr.current_size = mgr.current_size.saturating_sub(failed.size);
					}
				}
			}
			// 重新查找（可能已被移除）
			if let Some(entry) = mgr.entries.get_mut(&hash) {
				let downloaded = entry.size;
				return Ok(StreamingTempFileState {
					path: entry.path.to_string_lossy().to_string(),
					downloaded_bytes: Arc::new(AtomicU64::new(downloaded)),
					download_complete: Arc::new(AtomicBool::new(true)),
					download_failed: Arc::new(AtomicBool::new(false)),
					total_bytes: Some(downloaded),
					ekey: Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string()))),
					cek: Arc::new(std::sync::Mutex::new(cek.map(|s| s.to_string()))),
					post_check_pending: None,
					cenc_metadata: Arc::new(std::sync::Mutex::new(None)),
					cenc_streaming: Arc::new(AtomicBool::new(false)),
					download_error: Arc::new(std::sync::Mutex::new(None)),
					content_length_shared: entry.content_length_shared.clone(),
				});
			}
		} else {
			// 下载进行中：复用同一个文件和下载状态
			return Ok(StreamingTempFileState {
				path: entry.path.to_string_lossy().to_string(),
				downloaded_bytes: entry.downloaded_bytes.clone(),
				download_complete: entry.download_complete.clone(),
				download_failed: entry.download_failed.clone(),
				total_bytes: None,
				ekey: Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string()))),
				cek: Arc::new(std::sync::Mutex::new(cek.map(|s| s.to_string()))),
				post_check_pending: None,
				cenc_metadata: Arc::new(std::sync::Mutex::new(None)),
				cenc_streaming: Arc::new(AtomicBool::new(false)),
				download_error: Arc::new(std::sync::Mutex::new(None)),
				content_length_shared: entry.content_length_shared.clone(),
			});
		}
	}

	// 创建缓存文件
	let temp_path = cache_dir().join(format!("{}.dat", hash));

	let file = OpenOptions::new()
		.write(true)
		.create(true)
		.truncate(true)
		.open(&temp_path)
		.map_err(|e| format!("创建缓存文件失败: {}", e))?;
	drop(file);

	let downloaded_bytes = Arc::new(AtomicU64::new(0));
	let download_complete = Arc::new(AtomicBool::new(false));
	let download_failed = Arc::new(AtomicBool::new(false));
	let post_check_pending = Arc::new(AtomicBool::new(false));
	let shared_ekey = Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string())));
	let shared_cek = Arc::new(std::sync::Mutex::new(cek.map(|s| s.to_string())));
	let download_error: Arc<std::sync::Mutex<Option<String>>> = Arc::new(std::sync::Mutex::new(None));
	let cenc_metadata = Arc::new(std::sync::Mutex::new(None));
	let cenc_streaming = Arc::new(AtomicBool::new(false));
	let content_length_shared = Arc::new(AtomicU64::new(0));

	// 启动后台下载线程
	let url_clone = url.to_string();
	let hash_clone = hash.clone();
	let headers_clone = headers.cloned();
	let ua_clone = user_agent.map(|s| s.to_string());
	let path_clone = temp_path.clone();
	let dl_bytes = downloaded_bytes.clone();
	let dl_complete = download_complete.clone();
	let dl_failed = download_failed.clone();
	let dl_post_check = post_check_pending.clone();
	let dl_ekey = shared_ekey.clone();
	let dl_cek = shared_cek.clone();
	let dl_error = download_error.clone();
	let dl_cenc_metadata = cenc_metadata.clone();
	let dl_cenc_streaming = cenc_streaming.clone();
	let dl_content_length = content_length_shared.clone();

	let handle = std::thread::spawn(move || {
		// 专用线程内建临时 runtime：下载走异步 reqwest（不再链接 blocking 模块），
		// 对外仍通过原子计数汇报进度，读取侧无需感知差异。
		let rt = match tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
		{
			Ok(rt) => rt,
			Err(e) => {
				dl_failed.store(true, Ordering::Relaxed);
				if let Ok(mut err) = dl_error.lock() {
					*err = Some(format!("创建下载运行时失败: {}", e));
				}
				return;
			}
		};
		rt.block_on(download_thread(
			&url_clone,
			&hash_clone,
			headers_clone.as_ref(),
			ua_clone.as_deref(),
			path_clone,
			dl_bytes,
			dl_complete,
			dl_failed,
			dl_post_check,
			dl_ekey,
			dl_cek,
			dl_error,
			dl_cenc_metadata,
			dl_cenc_streaming,
			dl_content_length,
		));
	});

	mgr.entries.insert(
		hash,
		CacheEntry {
			path: temp_path.clone(),
			size: 0,
			last_accessed: SystemTime::now(),
			downloaded_bytes: downloaded_bytes.clone(),
			download_complete: download_complete.clone(),
			download_failed: download_failed.clone(),
			content_length: None,
			content_length_shared: content_length_shared.clone(),
			_download_handle: Some(handle),
		},
	);
	mgr.evict_if_needed();

	Ok(StreamingTempFileState {
		path: temp_path.to_string_lossy().to_string(),
		downloaded_bytes,
		download_complete,
		download_failed,
		total_bytes: None,
		ekey: shared_ekey,
		cek: shared_cek,
		post_check_pending: Some(post_check_pending),
		cenc_metadata,
		cenc_streaming,
		download_error,
		content_length_shared,
	})
}

/// 从 JSON 响应文本中递归提取音频 URL 和 ekey。
/// 优先检查常见字段名（url, data, musicUrl, audioUrl, src, link, file, path），
/// 然后递归搜索任意层级的字符串值中以 http:// 或 https:// 开头且含音频扩展名的链接。
/// 最后回退到任意 HTTP URL（不检查音频特征），并搜索 ekey 字段。

pub(crate) fn apply_stream_request_headers(
	mut req: reqwest::RequestBuilder,
	headers: Option<&std::collections::HashMap<String, String>>,
	user_agent: Option<&str>,
) -> reqwest::RequestBuilder {
	let has_plugin_user_agent = headers
		.map(|hdrs| {
			hdrs
				.keys()
				.any(|key| key.eq_ignore_ascii_case("user-agent"))
		})
		.unwrap_or(false);

	// 插件提供的 User-Agent 必须优先。JOOX 等音源会严格校验 UA；
	// 如果先设置默认 UA 再追加插件 UA，最终请求可能携带重复 User-Agent，
	// 服务端会直接返回 403。
	if !has_plugin_user_agent {
		if let Some(ua) = user_agent {
			req = req.header(reqwest::header::USER_AGENT, ua);
		}
	}

	if let Some(hdrs) = headers {
		for (key, value) in hdrs {
			if !key.trim().is_empty() && !value.trim().is_empty() {
				if let (Ok(name), Ok(val)) = (
					reqwest::header::HeaderName::from_bytes(key.as_bytes()),
					reqwest::header::HeaderValue::from_str(value),
				) {
					req = req.header(name, val);
				}
			}
		}
	}
	req
}

/// 下载主体。在专用线程的临时 current-thread runtime 中执行（见 spawn 处），
/// 通过原子计数向读取侧汇报进度，架构与阻塞版完全一致。
async fn download_thread(
	url: &str,
	hash: &str,
	headers: Option<&std::collections::HashMap<String, String>>,
	user_agent: Option<&str>,
	path: PathBuf,
	downloaded_bytes: Arc<AtomicU64>,
	download_complete: Arc<AtomicBool>,
	download_failed: Arc<AtomicBool>,
	post_check_pending: Arc<AtomicBool>,
	ekey: Arc<std::sync::Mutex<Option<String>>>,
	cek: Arc<std::sync::Mutex<Option<String>>>,
	download_error: Arc<std::sync::Mutex<Option<String>>>,
	cenc_metadata: Arc<std::sync::Mutex<Option<crate::player::cenc::CencMetadata>>>,
	cenc_streaming: Arc<AtomicBool>,
	content_length_shared: Arc<AtomicU64>,
) {
	let fail_download = |reason: &str, bytes_written: u64| {
		downloaded_bytes.store(bytes_written, Ordering::Relaxed);
		download_failed.store(true, Ordering::Relaxed);
		if let Ok(mut err) = download_error.lock() {
			*err = Some(reason.to_string());
		}
		if let Ok(mut mgr) = cache().lock() {
			mgr.update_size(hash, bytes_written);
			mgr.evict_if_needed();
		}
	};

	// [CENC] 加密音源需在下载完成后做后处理解密。提前置位 post_check_pending，
	// 使 is_buffer_ready 与 reader 在解密完成前阻塞，避免解码器读到未解密的 enca 文件。
	let has_cek = cek.lock().map(|c| c.is_some()).unwrap_or(false);
	if has_cek {
		post_check_pending.store(true, Ordering::Relaxed);
	}

	let client = match reqwest::Client::builder()
		.timeout(Duration::from_secs(120))
		.connect_timeout(Duration::from_secs(10))
		// 空闲读超时：CDN 对并发连接会随机饿死（长时间 0 字节），
		// 不设此项被饿死的下载会吊满 120s 总超时才报失败，
		// 表现为 downloaded_bytes 长时间不推进（代理侧被迫回退直连）。
		.read_timeout(Duration::from_secs(15))
		// SSRF 纵深：跳转目标做 IP 字面量校验，防重定向到内网
		.redirect(crate::security::ssrf::ip_literal_redirect_policy())
		// DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
		.dns_resolver(crate::security::ssrf::pinned_dns_resolver())
		.gzip(true)
		.brotli(true)
		.deflate(true)
		.build()
	{
		Ok(c) => c,
		Err(e) => {
			fail_download(&format!("创建 HTTP 客户端失败: {}", e), 0);
			return;
		}
	};

	let req = apply_stream_request_headers(client.get(url), headers, user_agent);

	let mut response = match req.send().await {
		Ok(r) => r,
		Err(e) => {
			fail_download(&format!("下载请求失败: {}", e), 0);
			return;
		}
	};

	if !response.status().is_success() {
		fail_download(&format!("HTTP {}", response.status()), 0);
		return;
	}

	// 检查 Content-Type
	let content_type = response
		.headers()
		.get(reqwest::header::CONTENT_TYPE)
		.and_then(|v| v.to_str().ok())
		.unwrap_or("")
		.to_lowercase();
	let is_non_audio = content_type.contains("text/html")
		|| content_type.contains("application/json")
		|| content_type.contains("text/plain")
		|| content_type.contains("application/xml")
		|| content_type.contains("text/xml");
	if is_non_audio {
		// 部分 Baka 插件的 getMediaSource 返回的是 API 端点 URL（如酷狗 PHP 接口），
		// 响应可能是 JSON、text/plain 直链、甚至 HTML 页面。
		// 对所有非音频内容类型统一尝试解析正文提取 URL 并重试下载。
		let body_text: String = response.text().await.unwrap_or_default();
		if let Some((real_url, json_ekey)) = extract_audio_info_from_text(&body_text) {
			// 如果 JSON 中包含 ekey，更新共享 ekey 字段供后续 QMC 解密使用
			if let Some(ref ek) = json_ekey {
				if let Ok(mut ekey_guard) = ekey.lock() {
					if ekey_guard.is_none() {
						*ekey_guard = Some(ek.clone());
					}
				}
			}
			// 用提取到的 URL 重新请求
			let retry_req = apply_stream_request_headers(client.get(&real_url), headers, user_agent);
			match retry_req.send().await {
				Ok(retry_resp) if retry_resp.status().is_success() => {
					let retry_ct = retry_resp
						.headers()
						.get(reqwest::header::CONTENT_TYPE)
						.and_then(|v| v.to_str().ok())
						.unwrap_or("")
						.to_lowercase();
					if retry_ct.contains("text/html")
						|| retry_ct.contains("application/json")
						|| retry_ct.contains("text/plain")
						|| retry_ct.contains("application/xml")
						|| retry_ct.contains("text/xml")
					{
						// 二次提取：重试 URL 仍返回非音频内容，尝试再次提取
						let retry_body: String = retry_resp.text().await.unwrap_or_default();
						if let Some((real_url2, _)) = extract_audio_info_from_text(&retry_body) {
							// 用二次提取的 URL 再次请求
							let resp2_req =
								apply_stream_request_headers(client.get(&real_url2), headers, user_agent);
							match resp2_req.send().await {
								Ok(resp2) if resp2.status().is_success() => {
									let ct2 = resp2
										.headers()
										.get(reqwest::header::CONTENT_TYPE)
										.and_then(|v| v.to_str().ok())
										.unwrap_or("")
										.to_lowercase();
									if ct2.contains("text/html")
										|| ct2.contains("application/json")
										|| ct2.contains("text/plain")
									{
										fail_download(
											&format!("二次提取的 URL 仍返回非音频内容 (Content-Type: {})", ct2),
											0,
										);
										return;
									}
									response = resp2;
								}
								Ok(resp2) => {
									fail_download(&format!("二次提取的 URL 返回 HTTP {}", resp2.status()), 0);
									return;
								}
								Err(e) => {
									fail_download(&format!("二次提取的 URL 请求失败: {}", e), 0);
									return;
								}
							}
						} else {
							fail_download(
								&format!(
									"提取的 URL 仍返回非音频内容 (Content-Type: {})，二次提取失败",
									retry_ct
								),
								0,
							);
							return;
						}
					} else {
						// 重试 URL 返回的是音频内容，直接使用
						response = retry_resp;
					}
				}
				Ok(retry_resp) => {
					fail_download(&format!("提取的 URL 返回 HTTP {}", retry_resp.status()), 0);
					return;
				}
				Err(e) => {
					fail_download(&format!("提取的 URL 请求失败: {}", e), 0);
					return;
				}
			}
		} else {
			fail_download(
				&format!(
					"服务器返回非音频内容 (Content-Type: {})，URL提取失败",
					content_type
				),
				0,
			);
			return;
		}
	}

	let total_bytes = response
		.headers()
		.get(reqwest::header::CONTENT_LENGTH)
		.and_then(|v| v.to_str().ok())
		.and_then(|v| v.parse::<u64>().ok());

	// 下载中即上报总长：代理据此可在首播阶段（无头部探测缓存）直接
	// 从预热缓存伺服 206，避免与透传各开一条上游连接被 CDN 并发限制饿死。
	// 同时回填共享槽：symphonia FLAC/MP3 demuxer 的 seek 依赖 MediaSource::byte_len()。
	if let Some(total) = total_bytes {
		content_length_shared.store(total, Ordering::Relaxed);
		if let Ok(mut mgr) = cache().lock() {
			if let Some(entry) = mgr.entries.get_mut(hash) {
				entry.content_length = Some(total);
			}
		}
	}

	let mut file = match OpenOptions::new().write(true).open(&path) {
		Ok(f) => f,
		Err(e) => {
			fail_download(&format!("打开缓存文件写入失败: {}", e), 0);
			return;
		}
	};

	let mut bytes_written = 0u64;
	let mut error: Option<String> = None;
	let mut cenc_probe_done = false;

	loop {
		// Response 未实现 AsyncRead，用原生的 chunk() 逐块读取
		match response.chunk().await {
			Ok(Some(chunk)) => {
				if let Err(e) = file.write_all(&chunk) {
					error = Some(format!("写入缓存文件失败: {}", e));
					break;
				}
				bytes_written += chunk.len() as u64;
				downloaded_bytes.store(bytes_written, Ordering::Relaxed);

				// [CENC 流式] 下载达到 512KB 后尝试解析 moov（若在头部则启用流式解密）
				if has_cek && !cenc_probe_done && bytes_written >= MIN_BUFFER_BYTES {
					cenc_probe_done = true;
					let probe_len = bytes_written.min(1024 * 1024) as usize;
					let mut probe_buf = vec![0u8; probe_len];
					if let Ok(mut f) = std::fs::File::open(&path) {
						use std::io::Read as _;
						if f.read_exact(&mut probe_buf).is_ok() {
							let cek_str = cek.lock().ok().and_then(|c| c.clone());
							if let Some(ref cek_str) = cek_str {
								if let Ok(key) = crate::player::cenc::cek_to_key(cek_str) {
									if let Ok(Some(metadata)) =
										crate::player::cenc::parse_cenc_metadata(&probe_buf, &key)
									{
										if let Ok(mut md) = cenc_metadata.lock() {
											*md = Some(metadata);
										}
										cenc_streaming.store(true, Ordering::Relaxed);
										post_check_pending.store(false, Ordering::Relaxed);
									}
								}
							}
						}
					}
				}
			}
			Ok(None) => break,
			Err(e) => {
				error = Some(format!("下载流读取错误: {}", e));
				break;
			}
		}
	}

	let _ = file.flush();

	if let Some(error) = error {
		fail_download(&error, bytes_written);
		return;
	}

	if let Some(total) = total_bytes {
		if bytes_written != total {
			fail_download(
				&format!("下载字节数不完整: {} / {}", bytes_written, total),
				bytes_written,
			);
			return;
		}
	}

	// 验证下载内容的文件头魔数，防止 CDN 返回错误页/加密数据等非音频内容
	// 即使 Content-Type 为 audio/mpeg，仍可能返回非音频数据（如 vkey 过期时的错误响应）
	// 注意：当 ekey 存在时（QMC 加密音源），文件头是加密数据而非有效音频头，跳过此验证
	let has_ekey = ekey.lock().map(|e| e.is_some()).unwrap_or(false);
	if !has_ekey {
		if let Ok(mut verify_file) = File::open(&path) {
			let mut header = [0u8; 16];
			let header_len = verify_file.read(&mut header).unwrap_or(0);
			if header_len >= 4 && !is_valid_audio_header(&header[..header_len]) {
				let header_hex: String = header[..header_len]
					.iter()
					.map(|b| format!("{:02x}", b))
					.collect::<Vec<_>>()
					.join(" ");
				fail_download(
					&format!("下载内容非有效音频格式 (header: {})", header_hex),
					bytes_written,
				);
				post_check_pending.store(false, Ordering::Relaxed);
				return;
			}
		}
	}

	// [CENC] 后处理解密：仅当流式解密未激活（moov 在文件尾部）时才整文件就地解密。
	// 若流式已激活（cenc_streaming=true），样本在 reader 层按需解密，无需后处理。
	if has_cek && !cenc_streaming.load(Ordering::Relaxed) {
		let cek_str = cek.lock().ok().and_then(|c| c.clone());
		if let Some(ref cek_str) = cek_str {
			if let Err(e) = decrypt_cenc_file(&path, cek_str) {
				fail_download(&e, bytes_written);
				post_check_pending.store(false, Ordering::Relaxed);
				return;
			}
		}
		post_check_pending.store(false, Ordering::Relaxed);
	}

	download_complete.store(true, Ordering::Relaxed);

	// 更新缓存大小，并在完成后立即触发淘汰：否则多首歌下载完成而
	// 没有新下载启动时，current_size 会持续超出用户设置的上限。
	if let Ok(mut mgr) = cache().lock() {
		mgr.update_size(hash, bytes_written);
		mgr.evict_if_needed();
	}
}
