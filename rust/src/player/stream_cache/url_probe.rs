//! 音频 URL 启发式探测：从插件返回的任意 JSON/文本/二进制头中提取音频地址与 ekey。



/// 从 JSON 响应文本中递归提取音频 URL 和 ekey。
/// 优先检查常见字段名（url, data, musicUrl, audioUrl, src, link, file, path），
/// 然后递归搜索任意层级的字符串值中以 http:// 或 https:// 开头且含音频扩展名的链接。
/// 最后回退到任意 HTTP URL（不检查音频特征），并搜索 ekey 字段。
pub(crate) fn extract_audio_info_from_json(body: &str) -> Option<(String, Option<String>)> {
	// 处理双重编码 JSON：有些 API 返回 JSON 字符串包裹的 JSON
	let value: serde_json::Value = match serde_json::from_str(body) {
		Ok(v) => v,
		Err(_) => {
			// 尝试去掉外层引号后重新解析
			let trimmed = body.trim().trim_matches('"');
			if trimmed != body.trim() {
				if let Ok(v) = serde_json::from_str(trimmed) {
					v
				} else {
					return None;
				}
			} else {
				return None;
			}
		}
	};

	// 优先字段名列表（按常见 API 返回格式排序）
	let priority_keys = [
		"url",
		"musicUrl",
		"audioUrl",
		"playUrl",
		"play_url",
		"music_url",
		"link",
		"src",
		"file",
		"fileUrl",
		"file_url",
		"data",
		"result",
		"music",
		"audio",
		"source",
		"sourceUrl",
		"source_url",
		"media",
		"mediaUrl",
		"stream",
		"streamUrl",
		"stream_url",
		"cdn",
		"cdnUrl",
		"play",
		"download",
		"downloadUrl",
		"download_url",
	];

	// 第一轮：检查优先字段名（接受任何 http/https URL，不检查音频特征）
	for key in &priority_keys {
		if let Some(found) = find_url_by_key(&value, key) {
			let ekey = find_ekey_in_json(&value);
			return Some((found, ekey));
		}
	}

	// 第二轮：递归搜索任意看起来像音频 URL 的字符串
	if let Some(url) = find_any_audio_url(&value) {
		let ekey = find_ekey_in_json(&value);
		return Some((url, ekey));
	}

	// 第三轮：回退到任意 HTTP/HTTPS URL（不检查音频特征）
	// 某些 CDN URL 没有标准音频扩展名，但仍可播放
	if let Some(url) = find_any_http_url(&value) {
		let ekey = find_ekey_in_json(&value);
		return Some((url, ekey));
	}

	None
}

pub(crate) fn sanitize_extracted_audio_url(url: &str) -> String {
	url
		.trim()
		.trim_matches(|c: char| {
			c.is_whitespace()
				|| matches!(
					c,
					'`' | '\'' | '"' | ',' | '，' | ';' | '；' | '‘' | '’' | '“' | '”'
				)
		})
		.to_string()
}

/// 从非音频文本响应中提取真实音频 URL。
///
/// 部分插件返回的播放地址其实是 API 端点，服务端可能以 `text/plain`
/// 返回真实直链，也可能 Content-Type 不准但正文是 JSON 或 HTML。
/// 提取策略（按优先级）：
///   1. 解析 JSON（含双重编码处理）
///   2. 纯文本直链（去掉引号后以 http 开头）
///   3. 从任意文本中扫描 HTTP URL（处理 HTML/错误页等）
pub(crate) fn extract_audio_info_from_text(body: &str) -> Option<(String, Option<String>)> {
	// 策略 1：尝试 JSON 解析
	if let Some(info) = extract_audio_info_from_json(body) {
		return Some(info);
	}

	// 策略 2：纯文本直链（去掉外层引号/空白后以 http 开头）
	let trimmed = sanitize_extracted_audio_url(body);
	if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
		// 音频特征检查宽松化：只要不是明显非音频 URL 就接受
		if looks_like_audio_url(&trimmed) || !is_obviously_non_audio_url(&trimmed) {
			return Some((trimmed, None));
		}
	}

	// 策略 3：从任意文本中扫描第一个 HTTP URL（处理 HTML/错误页等）
	if let Some(url) = extract_url_from_raw_text(body) {
		return Some((url, None));
	}

	None
}

/// 在 JSON 中搜索 ekey 字段
pub(crate) fn find_ekey_in_json(value: &serde_json::Value) -> Option<String> {
	let ekey_keys = ["ekey", "eKey", "encryptKey", "encryptionKey"];
	find_string_by_keys(value, &ekey_keys)
}

/// 在 JSON 中按指定 key 列表搜索非空字符串值
pub(crate) fn find_string_by_keys(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
	match value {
		serde_json::Value::Object(map) => {
			for &key in keys {
				if let Some(v) = map.get(key) {
					if let Some(s) = v.as_str() {
						if !s.is_empty() {
							return Some(s.to_string());
						}
					}
				}
			}
			for v in map.values() {
				if let Some(found) = find_string_by_keys(v, keys) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_string_by_keys(v, keys) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

/// 在 JSON 值中查找指定 key 对应的 URL 字符串
pub(crate) fn find_url_by_key(value: &serde_json::Value, key: &str) -> Option<String> {
	match value {
		serde_json::Value::Object(map) => {
			if let Some(v) = map.get(key) {
				if let Some(s) = v.as_str() {
					let clean = sanitize_extracted_audio_url(s);
					if clean.starts_with("http://") || clean.starts_with("https://") {
						return Some(clean);
					}
				}
				// 嵌套对象/数组中继续查找同一 key
				if let Some(found) = find_url_by_key(v, key) {
					return Some(found);
				}
			}
			// 在其他字段中继续查找
			for v in map.values() {
				if let Some(found) = find_url_by_key(v, key) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_url_by_key(v, key) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

/// 递归搜索 JSON 中任意以 http 开头且看起来像音频 URL 的字符串
pub(crate) fn find_any_audio_url(value: &serde_json::Value) -> Option<String> {
	match value {
		serde_json::Value::String(s) => {
			let clean = sanitize_extracted_audio_url(s);
			if (clean.starts_with("http://") || clean.starts_with("https://"))
				&& looks_like_audio_url(&clean)
			{
				Some(clean)
			} else {
				None
			}
		}
		serde_json::Value::Object(map) => {
			for v in map.values() {
				if let Some(found) = find_any_audio_url(v) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_any_audio_url(v) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

/// 递归搜索 JSON 中任意以 http 开头的 URL 字符串（不检查音频特征）。
/// 作为最后回退手段：某些 CDN 音频 URL 没有标准扩展名或已知域名。
/// 跳过明显非音频的 URL（如 .html、.htm、图片扩展名、CSS/JS 等）。
pub(crate) fn find_any_http_url(value: &serde_json::Value) -> Option<String> {
	match value {
		serde_json::Value::String(s) => {
			let clean = sanitize_extracted_audio_url(s);
			if clean.starts_with("http://") || clean.starts_with("https://") {
				if !is_obviously_non_audio_url(&clean) {
					return Some(clean);
				}
			}
			// 处理协议相对 URL：//cdn.example.com/path
			if s.starts_with("//") {
				let full = format!("https:{}", s);
				if !is_obviously_non_audio_url(&full) {
					return Some(full);
				}
			}
			None
		}
		serde_json::Value::Object(map) => {
			for v in map.values() {
				if let Some(found) = find_any_http_url(v) {
					return Some(found);
				}
			}
			None
		}
		serde_json::Value::Array(arr) => {
			for v in arr {
				if let Some(found) = find_any_http_url(v) {
					return Some(found);
				}
			}
			None
		}
		_ => None,
	}
}

/// 判断 URL 明显不是音频链接（排除 HTML、图片、CSS、JS 等）
pub(crate) fn is_obviously_non_audio_url(url: &str) -> bool {
	let lower = url.to_lowercase();
	lower.contains(".html")
		|| lower.contains(".htm")
		|| lower.contains(".php")
		|| lower.contains(".asp")
		|| lower.contains(".aspx")
		|| lower.contains(".jsp")
		|| lower.contains(".css")
		|| lower.contains(".js")
		|| lower.contains(".png")
		|| lower.contains(".jpg")
		|| lower.contains(".jpeg")
		|| lower.contains(".gif")
		|| lower.contains(".svg")
		|| lower.contains(".webp")
		|| lower.contains(".ico")
		|| lower.contains(".woff")
		|| lower.contains(".ttf")
		|| lower.contains(".pdf")
		|| lower.contains(".zip")
		|| lower.contains(".rar")
		|| lower.contains(".doc")
		|| lower.contains(".docx")
}

/// 使用正则从任意文本（非 JSON）中提取第一个 HTTP/HTTPS URL。
/// 用于处理 HTML 响应、错误页面、或格式异常的文本中隐藏的音频 URL。
pub(crate) fn extract_url_from_raw_text(text: &str) -> Option<String> {
	// 简单扫描：查找 http:// 或 https:// 开头的子串
	for prefix in &["https://", "http://"] {
		if let Some(start) = text.find(prefix) {
			// 从起始位置截取到下一个空白字符或引号
			let rest = &text[start..];
			let end = rest
				.find(|c: char| {
					c.is_whitespace() || c == '"' || c == '\'' || c == '<' || c == '>' || c == ',' || c == '}'
				})
				.unwrap_or(rest.len());
			let url = &rest[..end];
			if url.len() > 10 && !is_obviously_non_audio_url(url) {
				return Some(sanitize_extracted_audio_url(url));
			}
		}
	}
	None
}

/// 判断 URL 是否看起来像音频链接（包含常见音频扩展名或路径特征）
pub(crate) fn looks_like_audio_url(url: &str) -> bool {
	let lower = url.to_lowercase();
	// 检查常见音频扩展名
	lower.contains(".mp3")
        || lower.contains(".flac")
        || lower.contains(".m4a")
        || lower.contains(".aac")
        || lower.contains(".ogg")
        || lower.contains(".wav")
        || lower.contains(".wma")
        || lower.contains(".opus")
        || lower.contains(".mga")
        || lower.contains(".mgg")
        // QQ音乐/酷狗/酷我/网易云等流媒体域名
        || lower.contains("stream.qqmusic")
        || lower.contains("ws.stream.qqmusic")
        || lower.contains("dl.stream.qqmusic")
        || lower.contains("isure.stream")
        || lower.contains("trackmedia")
        || lower.contains("music.126.net")
        || lower.contains("m.kugou")
        || lower.contains("track.kg")
        || lower.contains("trackercdn.kugou")
        || lower.contains("fsandroid.kugou")
        || lower.contains("fsm.kugou")
        || lower.contains("mobilesdk.kugou")
        || lower.contains("kuwo")
        || lower.contains("car-lv.kuwo")
        || lower.contains("nmobi.kuwo")
        || lower.contains("sr.kuwo")
        || lower.contains("antiserver")
        // 咪咕音乐
        || lower.contains("migu.cn")
        || lower.contains("miguvideo")
        // 第三方 API 代理域名
        || lower.contains("haitangw")
        || lower.contains("musicapi")
        // 没有明确扩展名但路径中含 music/song/track/play 等关键词
        || (lower.contains("/music") || lower.contains("/song") || lower.contains("/track") || lower.contains("/play"))
}

/// 检查文件头魔数是否为已知音频格式。
/// 支持 MP3 (含 ID3 标签)、FLAC、RIFF/WAV、OGG、M4A/MP4、AAC ADTS、AIFF。
pub(crate) fn is_valid_audio_header(bytes: &[u8]) -> bool {
	if bytes.len() < 4 {
		return false;
	}

	// MP3: ID3 标签开头
	if &bytes[..3] == b"ID3" {
		return true;
	}

	// MP3: 同步字 (第一字节 0xFF，第二字节高3位为 111)
	if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
		return true;
	}

	// FLAC
	if &bytes[..4] == b"fLaC" {
		return true;
	}

	// RIFF (WAV)
	if &bytes[..4] == b"RIFF" {
		return true;
	}

	// OGG
	if &bytes[..4] == b"OggS" {
		return true;
	}

	// AIFF
	if &bytes[..4] == b"FORM" {
		return true;
	}

	// M4A/MP4: bytes 4-7 为 "ftyp"
	if bytes.len() >= 8 && &bytes[4..8] == b"ftyp" {
		return true;
	}

	false
}
