//! QMC 加密文件解密：ekey 提取、就地解密与独立解密命令。

use super::*;

/// 从文件尾部提取 QMC ekey（QTag/V1 footer 格式）。
pub(crate) fn try_extract_ekey_from_file(path: &Path) -> Option<String> {
	let metadata = fs::metadata(path).ok()?;
	let file_size = metadata.len();
	if file_size < 8 {
		return None;
	}

	let tail_size = (file_size.min(4096)) as usize;
	let mut file = fs::File::open(path).ok()?;
	use std::io::{Read, Seek, SeekFrom};
	file
		.seek(SeekFrom::Start(file_size - tail_size as u64))
		.ok()?;
	let mut tail = vec![0u8; tail_size];
	file.read_exact(&mut tail).ok()?;

	crate::player::qmc2::extract_ekey_from_footer(&tail)
}

/// 原地解密 QMC 加密文件：读取加密内容，逐块解密，覆盖写回。
pub(crate) fn decrypt_qmc_file_inplace(path: &Path, ekey: &str) -> Result<u64, String> {
	let crypto =
		crate::player::qmc2::QmcCrypto::from_ekey(ekey).map_err(|e| format!("ekey 解析失败: {e}"))?;
	decrypt_with_crypto_inplace(path, &crypto)
}

/// 用指定 QMC 密码学实例原地解密（临时文件 + 原子替换）。
pub(crate) fn decrypt_with_crypto_inplace(
	path: &Path,
	crypto: &crate::player::qmc2::QmcCrypto,
) -> Result<u64, String> {
	use std::io::{Read, Write};

	let file_size = fs::metadata(path)
		.map_err(|e| format!("读取文件元数据失败: {e}"))?
		.len();

	let temp_path = path.with_extension("qmc_tmp_dec");

	{
		let mut input = fs::File::open(path).map_err(|e| format!("打开加密文件失败: {e}"))?;
		let mut output =
			fs::File::create(&temp_path).map_err(|e| format!("创建临时解密文件失败: {e}"))?;

		let mut offset: u64 = 0;
		let mut buf = vec![0u8; 64 * 1024];

		loop {
			let n = input
				.read(&mut buf)
				.map_err(|e| format!("读取加密数据失败: {e}"))?;
			if n == 0 {
				break;
			}
			crypto.decrypt(offset as usize, &mut buf[..n]);
			output
				.write_all(&buf[..n])
				.map_err(|e| format!("写入解密数据失败: {e}"))?;
			offset += n as u64;
		}

		output
			.flush()
			.map_err(|e| format!("刷新解密文件失败: {e}"))?;
	}

	fs::rename(&temp_path, path).map_err(|e| {
		let _ = fs::remove_file(&temp_path);
		format!("替换原文件失败: {e}")
	})?;

	Ok(file_size)
}

/// 读取文件头部（最多 16 字节）。
pub(crate) fn read_file_header(path: &Path) -> Result<Vec<u8>, String> {
	use std::io::Read;
	let mut file = fs::File::open(path).map_err(|e| format!("打开文件失败: {e}"))?;
	let mut header = vec![0u8; 16];
	let mut filled = 0;
	while filled < header.len() {
		let n = file
			.read(&mut header[filled..])
			.map_err(|e| format!("读取文件头失败: {e}"))?;
		if n == 0 {
			break;
		}
		filled += n;
	}
	header.truncate(filled);
	Ok(header)
}

/// 判断是否 QMC1 老格式扩展名（固定密钥加密，无需 ekey）。
pub(crate) fn is_qmc1_extension(path: &Path) -> bool {
	let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
		return false;
	};
	let lower = name.to_lowercase();
	matches!(
		lower.as_str(),
		"qmcflac" | "qmcmp3" | "qmcogg" | "qmcwav" | "qmcape" | "qmcwma"
	) || lower.starts_with("qmc")
}

/// 解密后按真实音频格式修正文件扩展名（如 .qmcflac → .flac），返回新路径。
pub(crate) fn rename_to_audio_extension(path: &Path) -> Result<Option<PathBuf>, String> {
	let header = read_file_header(path)?;
	let Some(real_ext) = crate::player::qmc2::detect_audio_extension(&header) else {
		return Ok(None);
	};
	let cur_ext = path
		.extension()
		.and_then(|e| e.to_str())
		.map(|e| e.to_lowercase())
		.unwrap_or_default();
	if cur_ext == real_ext {
		return Ok(None);
	}
	let stem = path.file_stem().unwrap_or_default();
	let new_path = path.with_file_name(format!("{}.{}", stem.to_string_lossy(), real_ext));
	if new_path.exists() && new_path != path {
		// 目标名已存在：跳过改名，保留解密后内容。
		return Ok(None);
	}
	fs::rename(path, &new_path).map_err(|e| format!("修正扩展名失败: {e}"))?;
	Ok(Some(new_path))
}

/// 独立解密 QMC 加密文件（用户手动选择文件的工具入口）。
///
/// 解密策略（按优先级）：
/// 1. 调用方提供 ekey（非空）→ QMC2 解密；
/// 2. 文件尾部 footer 携带 ekey（QTag / V1 footer）→ QMC2 解密；
/// 3. 无 ekey 但文件名是 QMC1 老格式（.qmcflac/.qmcmp3 等）→ 固定密钥 QMC1 解密，
///    并校验解密结果确为音频格式（校验失败则还原原文件）；
/// 4. 以上都不满足 → 未加密或缺少密钥，不做任何修改。
///
/// 解密成功后按内容修正扩展名（如 .mflac → .flac）。
/// 返回 JSON：`{"status": "decrypted"|"not_encrypted", "outputPath": "...", "renamedTo": "..."}`
pub fn decrypt_qmc_file_standalone(
	file_path: String,
	ekey: Option<String>,
) -> Result<String, String> { // 实现
	let path = path_validator::validate_path(&file_path, None)?;

	if !path.is_file() {
		return Err(format!("文件不存在: {}", path.display()));
	}

	let actual_ekey = if let Some(ref ek) = ekey {
		if !ek.is_empty() {
			Some(ek.clone())
		} else {
			try_extract_ekey_from_file(&path)
		}
	} else {
		try_extract_ekey_from_file(&path)
	};

	let (decrypt_result, crypto_name) = if let Some(ek) = actual_ekey {
		let crypto =
			crate::player::qmc2::QmcCrypto::from_ekey(&ek).map_err(|e| format!("ekey 解析失败: {e}"))?;
		(decrypt_with_crypto_inplace(&path, &crypto), "QMC2")
	} else if is_qmc1_extension(&path) {
		// QMC1 固定密钥解密：先解密到临时产物，校验头部有效后再替换原文件。
		let crypto = crate::player::qmc2::QmcCrypto::qmc1();
		let backup = path.with_extension("qmc_tmp_backup");
		fs::copy(&path, &backup).map_err(|e| format!("备份原文件失败: {e}"))?;
		let result = decrypt_with_crypto_inplace(&path, &crypto);
		match result {
			Ok(_) => {
				// 校验解密结果是否为有效音频格式；无效则还原。
				let header = read_file_header(&path).unwrap_or_default();
				if crate::player::qmc2::detect_audio_extension(&header).is_none() {
					let _ = fs::rename(&backup, &path);
					return Err("解密结果不是有效音频（该文件可能不是 QMC1 格式）".to_string());
				}
				let _ = fs::remove_file(&backup);
				(Ok(0), "QMC1")
			}
			Err(e) => {
				let _ = fs::rename(&backup, &path);
				return Err(format!("QMC1 解密失败: {e}"));
			}
		}
	} else {
		return Ok(
			serde_json::json!({
					"status": "not_encrypted",
					"outputPath": path.to_string_lossy(),
					"renamedTo": null,
			})
			.to_string(),
		);
	};

	match decrypt_result {
		Ok(_) => {
			let renamed_to = rename_to_audio_extension(&path)?;
			let output = renamed_to.as_ref().unwrap_or(&path);
			Ok(
				serde_json::json!({
						"status": "decrypted",
						"outputPath": output.to_string_lossy(),
						"renamedTo": renamed_to.as_ref().map(|p| p.to_string_lossy().to_string()),
						"crypto": crypto_name,
				})
				.to_string(),
			)
		}
		Err(e) => Err(format!("{crypto_name} 解密失败: {e}")),
	}
}

/// 原地解密 QMC2 加密文件（用于缓存复用路径）。无 ekey 且无 footer 时返回 false。
pub fn decrypt_qmc_file(file_path: String, ekey: Option<String>) -> Result<bool, String> {
	let path = path_validator::validate_path(&file_path, None)?;

	if !path.is_file() {
		return Err(format!("文件不存在: {}", path.display()));
	}

	let actual_ekey = if let Some(ref ek) = ekey {
		if !ek.is_empty() {
			Some(ek.clone())
		} else {
			try_extract_ekey_from_file(&path)
		}
	} else {
		try_extract_ekey_from_file(&path)
	};

	if let Some(ek) = actual_ekey {
		match decrypt_qmc_file_inplace(&path, &ek) {
			Ok(_) => Ok(true),
			Err(e) => Err(format!("QMC2 解密失败: {e}")),
		}
	} else {
		Ok(false)
	}
}
