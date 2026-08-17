//! 工具箱：文件重命名、下载编排、QMC 解密、元数据嵌入、状态持久化等。
//!
//! 从桌面端移植时移除了以下桌面平台专用/无关命令：
//! `open_external_program`（启动外部程序）、`set_gpu_acceleration` 及 GPU 配置、
//! `run_installer`（安装程序）、`download_update_file`（桌面更新下载）。
//! 依赖 `AppHandle` 的路径获取改为由调用方传入 `data_dir` / 数据库连接。

use crate::music::tags::{
    extract_text_metadata, read_tagged_file_from_path, write_metadata_to_file, EmbedMetadataRequest,
};
use crate::music::utils::is_supported_library_extension;
use crate::security::path_validator;
use lofty::prelude::*;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use walkdir::WalkDir;

static TRACK_PREFIX_RE: OnceLock<Regex> = OnceLock::new();
static SOURCE_PREFIX_RE: OnceLock<Regex> = OnceLock::new();

#[derive(Debug, Serialize, Deserialize)]
pub struct RenameConfig {
    pub mode: String,
    pub template: String,
    pub remove_track_prefix: bool,
    pub remove_source_prefix: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RenamePreview {
    pub original_path: String,
    pub original_name: String,
    pub new_name: String,
    pub status: String,
    pub error: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RenameOperation {
    pub original_path: String,
    pub new_name: String,
}

fn sanitize_filename(name: &str) -> String {
    let invalid_chars = ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];
    let mut sanitized = String::new();
    for c in name.chars() {
        if invalid_chars.contains(&c) {
            sanitized.push('_');
        } else {
            sanitized.push(c);
        }
    }
    sanitized.trim().to_string()
}

fn process_file(path: &Path, config: &RenameConfig) -> RenamePreview {
    let original_name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let original_path_str = path.to_string_lossy().to_string();
    let ext = path
        .extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();

    if config.mode == "tags" || config.mode == "auto" {
        if let Ok(tagged_file) = read_tagged_file_from_path(path) {
            let metadata = extract_text_metadata(&tagged_file);
            let title = metadata.title.unwrap_or_default();
            let artist = metadata.artist.unwrap_or_default();
            let album = metadata.album.unwrap_or_default();

            let year = tagged_file
                .primary_tag()
                .and_then(|tag| tag.year())
                .map(|y| y.to_string())
                .unwrap_or_default();
            let track = tagged_file
                .primary_tag()
                .and_then(|tag| tag.track())
                .map(|t| format!("{:02}", t))
                .unwrap_or_default();

            if !title.is_empty() {
                let mut new_name_base = config.template.clone();
                new_name_base = new_name_base.replace("{title}", &title);
                new_name_base = new_name_base.replace("{artist}", &artist);
                new_name_base = new_name_base.replace("{album}", &album);
                new_name_base = new_name_base.replace("{year}", &year);
                new_name_base = new_name_base.replace("{track}", &track);

                let new_name = format!("{}.{}", sanitize_filename(&new_name_base), ext);

                if new_name != original_name {
                    return RenamePreview {
                        original_path: original_path_str,
                        original_name,
                        new_name,
                        status: "tags".to_string(),
                        error: None,
                    };
                } else if config.mode == "tags" {
                    return RenamePreview {
                        original_path: original_path_str,
                        original_name: original_name.clone(),
                        new_name: original_name,
                        status: "skipped".to_string(),
                        error: Some("Already named correctly".to_string()),
                    };
                }
            }
        }

        if config.mode == "tags" {
            return RenamePreview {
                original_path: original_path_str,
                original_name: original_name.clone(),
                new_name: original_name,
                status: "skipped".to_string(),
                error: Some("Missing tags".to_string()),
            };
        }
    }

    if config.mode == "rules" || config.mode == "auto" {
        let mut cleaned_name = original_name.clone();

        if let Some(stem) = path.file_stem() {
            let mut stem_str = stem.to_string_lossy().to_string();

            if config.remove_track_prefix {
                let re = TRACK_PREFIX_RE.get_or_init(|| Regex::new(r"^\d+[\.\-\s]+").unwrap());
                stem_str = re.replace(&stem_str, "").to_string();
            }

            if config.remove_source_prefix {
                let re = SOURCE_PREFIX_RE.get_or_init(|| Regex::new(r"^\s*\[.*?\]\s*").unwrap());
                stem_str = re.replace(&stem_str, "").to_string();
            }

            cleaned_name = format!("{}.{}", stem_str.trim(), ext);
        }

        if cleaned_name != original_name {
            return RenamePreview {
                original_path: original_path_str,
                original_name,
                new_name: cleaned_name,
                status: "rules".to_string(),
                error: None,
            };
        }
    }

    RenamePreview {
        original_path: original_path_str,
        original_name: original_name.clone(),
        new_name: original_name,
        status: "skipped".to_string(),
        error: Some("No rules matched or missing tags".to_string()),
    }
}

pub fn preview_rename(root_path: String, config: RenameConfig) -> Result<Vec<RenamePreview>, String> {
    let validated_root = path_validator::validate_path(&root_path, None)?;
    let root_path = validated_root.to_string_lossy().to_string();
    let mut results = Vec::new();

    for entry in WalkDir::new(root_path)
        .max_depth(1)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        if path.is_file() {
            if let Some(ext) = path.extension() {
                let ext = ext.to_string_lossy().to_lowercase();
                if is_supported_library_extension(&ext) {
                    results.push(process_file(path, &config));
                }
            }
        }
    }

    results.sort_by(|a, b| {
        let a_changed = a.status != "skipped";
        let b_changed = b.status != "skipped";
        if a_changed && !b_changed {
            std::cmp::Ordering::Less
        } else if !a_changed && b_changed {
            std::cmp::Ordering::Greater
        } else {
            a.original_name.cmp(&b.original_name)
        }
    });

    Ok(results)
}

pub fn apply_rename(operations: Vec<RenameOperation>) -> Result<u32, String> {
    let mut success_count = 0;

    for mut op in operations {
        let validated_path = path_validator::validate_path(&op.original_path, None)?;
        op.original_path = validated_path.to_string_lossy().to_string();
        op.new_name = path_validator::sanitize_filename_component(&op.new_name)?;
        let src = PathBuf::from(&op.original_path);
        if let Some(parent) = src.parent() {
            let dest = parent.join(&op.new_name);
            if fs::rename(&src, &dest).is_ok() {
                success_count += 1;
            }
        }
    }

    Ok(success_count)
}

pub fn refresh_folder_songs(
    conn: Arc<Mutex<rusqlite::Connection>>,
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<Vec<crate::music::types::Song>, String> {
    let validated = path_validator::validate_path(&folder_path, None)?;
    let folder_path = validated.to_string_lossy().to_string();
    crate::music::scanner::scan_single_directory_internal(
        folder_path,
        conn,
        None,
        None,
        1,
        1,
        crate::music::scanner::ScanOptions::from_minimum_duration_seconds(minimum_duration_seconds),
    )
}

pub fn file_exists(path: String) -> bool {
    if path_validator::validate_path(&path, None).is_err() {
        return false;
    }
    std::path::Path::new(&path).is_file()
}

/// 在目标目录中解析非冲突文件路径；若文件已存在且不覆盖，自动追加 ` (1)`/` (2)`…。
pub fn resolve_download_path(
    directory: String,
    file_name: String,
    overwrite_existing: bool,
) -> Result<String, String> {
    let dir = path_validator::validate_path(&directory, None)?;
    let file_name = path_validator::sanitize_filename_component(&file_name)?;
    let direct = dir.join(&file_name);

    if overwrite_existing || !direct.exists() {
        std::fs::create_dir_all(&dir).map_err(|e| format!("创建下载目录失败: {e}"))?;
        return Ok(direct.to_string_lossy().to_string());
    }

    let dot = file_name.rfind('.');
    let (stem, ext) = match dot {
        Some(idx) => (&file_name[..idx], &file_name[idx..]),
        None => (file_name.as_str(), ""),
    };

    for i in 1..1000 {
        let candidate_name = format!("{stem} ({i}){ext}");
        let candidate = dir.join(&candidate_name);
        if !candidate.exists() {
            return Ok(candidate.to_string_lossy().to_string());
        }
    }

    Ok(direct.to_string_lossy().to_string())
}

/// 下载文件名清洗：非法字符替换为空格、折叠连续空白、限长 180 字符。
fn sanitize_download_filename(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| {
            if c.is_control() || matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') {
                ' '
            } else {
                c
            }
        })
        .collect();
    let collapsed: String = sanitized.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = collapsed.trim();
    if trimmed.is_empty() {
        return "download".to_string();
    }
    trimmed.chars().take(180).collect()
}

/// 从 URL 路径推断音频文件扩展名（含点）；无法识别返回空串。
fn ext_from_url(url: &str) -> String {
    let path = match reqwest::Url::parse(url) {
        Ok(u) => u.path().to_string(),
        Err(_) => return String::new(),
    };
    let dot = match path.rfind('.') {
        Some(idx) => idx,
        None => return String::new(),
    };
    let ext = path[dot..].to_lowercase();
    match ext.as_str() {
        ".mp3" | ".flac" | ".wav" | ".m4a" | ".aac" | ".ape" | ".ogg" | ".wma" => ext,
        _ => String::new(),
    }
}

fn is_lossless_quality(quality: &str) -> bool {
    matches!(quality, "flac" | "flac24bit" | "hires" | "vinyl" | "master")
}

fn ext_from_quality(quality: &str) -> String {
    if is_lossless_quality(quality) {
        ".flac".to_string()
    } else {
        ".mp3".to_string()
    }
}

fn build_filename_base(title: &str, artist: &str, album: &str, style: &str) -> String {
    let title = if title.is_empty() {
        "未知歌曲"
    } else {
        title
    };
    let parts: Vec<&str> = match style {
        "title-artist" => vec![title, artist],
        "title-artist-album" => vec![title, artist, album],
        _ => vec![artist, title],
    };
    let joined: String = parts
        .iter()
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" - ");
    if joined.is_empty() {
        title.to_string()
    } else {
        joined
    }
}

fn build_download_filename(
    title: &str,
    artist: &str,
    album: &str,
    url: &str,
    quality: &str,
    keep_source_filename: bool,
    style: &str,
) -> String {
    let ext = {
        let e = ext_from_url(url);
        if e.is_empty() {
            ext_from_quality(quality)
        } else {
            e
        }
    };

    if keep_source_filename {
        if let Ok(u) = reqwest::Url::parse(url) {
            let path = u.path();
            if let Some(base) = path.rsplit('/').next() {
                if let Some(dot_idx) = base.rfind('.') {
                    let stem = &base[..dot_idx];
                    let decoded = urlencoding::decode(stem)
                        .map(|cow| cow.into_owned())
                        .unwrap_or_else(|_| stem.to_string());
                    if !decoded.is_empty() {
                        return format!("{}{}", sanitize_download_filename(&decoded), ext);
                    }
                }
            }
        }
    }

    let base = build_filename_base(title, artist, album, style);
    format!("{}{}", sanitize_download_filename(&base), ext)
}

/// 构建下载文件名并解析非冲突完整路径（单次调用）。
pub fn resolve_download_full_path(
    directory: String,
    title: String,
    artist: String,
    album: String,
    url: String,
    quality: String,
    keep_source_filename: bool,
    file_name_style: String,
    overwrite_existing: bool,
) -> Result<String, String> {
    let validated_dir = path_validator::validate_path(&directory, None)?;
    let directory = validated_dir.to_string_lossy().to_string();
    let file_name = build_download_filename(
        &title,
        &artist,
        &album,
        &url,
        &quality,
        keep_source_filename,
        &file_name_style,
    );
    let file_name = path_validator::sanitize_filename_component(&file_name)?;
    resolve_download_path(directory, file_name, overwrite_existing)
}

/// 构建下载附件（歌词/封面）的清洗后文件名基名（不含扩展名）。
pub fn build_download_basename(
    title: String,
    artist: String,
    album: String,
    file_name_style: String,
) -> String {
    let base = build_filename_base(&title, &artist, &album, &file_name_style);
    let cleaned = sanitize_download_filename(&base);
    path_validator::sanitize_filename_component(&cleaned).unwrap_or_else(|_| "download".to_string())
}

const DOWNLOAD_HISTORY_FILE: &str = "download_history.json";

pub async fn check_update_by_rust(owner: String, repo: String) -> Result<String, String> {
    let url = format!("https://api.github.com/repos/{owner}/{repo}/releases/latest");

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
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

/// 在线歌曲下载进度负载。
#[derive(Debug, Clone, serde::Serialize)]
pub struct SongDownloadProgress {
    pub progress: f64,
    pub downloaded: u64,
    pub total: u64,
    pub speed: f64,
}

/// 下载在线歌曲的真实音源直链到指定目标路径（流式写入 + QMC2 解密）。
pub async fn download_online_song(
    url: String,
    dest_path: String,
    ekey: Option<String>,
    headers: Option<std::collections::HashMap<String, String>>,
) -> Result<String, String> {
    use std::time::Instant;
    use tokio::fs::File;
    use tokio::io::AsyncWriteExt;

    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("无效的下载链接".to_string());
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(600))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .build()
        .map_err(|e| format!("创建下载请求客户端失败: {e}"))?;

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
                file.write_all(&chunk)
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

    file.flush()
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

/// 从文件尾部提取 QMC ekey（QTag/V1 footer 格式）。
fn try_extract_ekey_from_file(path: &Path) -> Option<String> {
    let metadata = fs::metadata(path).ok()?;
    let file_size = metadata.len();
    if file_size < 8 {
        return None;
    }

    let tail_size = (file_size.min(4096)) as usize;
    let mut file = fs::File::open(path).ok()?;
    use std::io::{Read, Seek, SeekFrom};
    file.seek(SeekFrom::Start(file_size - tail_size as u64)).ok()?;
    let mut tail = vec![0u8; tail_size];
    file.read_exact(&mut tail).ok()?;

    crate::player::qmc2::extract_ekey_from_footer(&tail)
}

/// 原地解密 QMC2 加密文件：读取加密内容，逐块解密，覆盖写回。
fn decrypt_qmc_file_inplace(path: &Path, ekey: &str) -> Result<u64, String> {
    use std::io::{Read, Write};

    let crypto = crate::player::qmc2::QmcCrypto::from_ekey(ekey)
        .map_err(|e| format!("ekey 解析失败: {e}"))?;

    let file_size = fs::metadata(path)
        .map_err(|e| format!("读取文件元数据失败: {e}"))?
        .len();

    let temp_path = path.with_extension("qmc_tmp_dec");

    {
        let mut input = fs::File::open(path)
            .map_err(|e| format!("打开加密文件失败: {e}"))?;
        let mut output = fs::File::create(&temp_path)
            .map_err(|e| format!("创建临时解密文件失败: {e}"))?;

        let mut offset: u64 = 0;
        let mut buf = vec![0u8; 64 * 1024];

        loop {
            let n = input.read(&mut buf)
                .map_err(|e| format!("读取加密数据失败: {e}"))?;
            if n == 0 {
                break;
            }
            crypto.decrypt(offset as usize, &mut buf[..n]);
            output.write_all(&buf[..n])
                .map_err(|e| format!("写入解密数据失败: {e}"))?;
            offset += n as u64;
        }

        output.flush()
            .map_err(|e| format!("刷新解密文件失败: {e}"))?;
    }

    fs::rename(&temp_path, path)
        .map_err(|e| {
            let _ = fs::remove_file(&temp_path);
            format!("替换原文件失败: {e}")
        })?;

    Ok(file_size)
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

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
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

fn download_history_path(data_dir: &Path) -> Result<PathBuf, String> {
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

#[derive(Debug, Clone, serde::Serialize)]
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

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .redirect(reqwest::redirect::Policy::limited(10))
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

pub async fn fetch_announcement() -> Result<String, String> {
    let url = "https://xy.zh2026.cn/chaoguan/public/api/app.php?action=app_announcement";

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
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
    let sanitized_key = path_validator::sanitize_filename_component(&key)
        .map_err(|e| format!("无效的 key: {}", e))?;
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
    let sanitized_key = path_validator::sanitize_filename_component(&key)
        .map_err(|e| format!("无效的 key: {}", e))?;
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
pub async fn download_wallpaper(
    data_dir: &Path,
    url: String,
    filename: String,
) -> Result<String, String> {
    use tokio::fs::File;
    use tokio::io::AsyncWriteExt;

    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("无效的壁纸下载链接".to_string());
    }

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
        file.write_all(&chunk)
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
    let canonical_dir = std::fs::canonicalize(&wallpaper_dir)
        .map_err(|e| format!("读取壁纸目录失败: {e}"))?;
    let canonical_target = std::fs::canonicalize(&target)
        .map_err(|e| format!("读取壁纸文件失败: {e}"))?;
    if !canonical_target.starts_with(&canonical_dir) {
        return Err("只能删除应用壁纸目录中的文件".to_string());
    }
    tokio::fs::remove_file(&target)
        .await
        .map_err(|e| format!("删除壁纸文件失败: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::FinalizeDownloadExtrasRequest;

    #[test]
    fn finalize_download_extras_request_accepts_frontend_camel_case_payload() {
        let json = serde_json::json!({
            "lyricsText": "[00:00.00]测试歌词",
            "lyricsPath": "/Music/song.lrc",
            "coverUrl": "https://example.com/cover.jpg",
            "coverPath": "/Music/song.jpg",
            "embedCover": true,
            "metadata": {
                "filePath": "/Music/song.mp3",
                "title": "测试歌曲",
                "albumArtist": "测试专辑艺术家",
                "trackNumber": "7",
                "coverMime": "image/jpeg"
            }
        });

        let request: FinalizeDownloadExtrasRequest =
            serde_json::from_value(json).expect("frontend payload should deserialize");

        assert_eq!(request.lyrics_text.as_deref(), Some("[00:00.00]测试歌词"));
        assert_eq!(request.lyrics_path.as_deref(), Some("/Music/song.lrc"));
        assert_eq!(request.cover_url.as_deref(), Some("https://example.com/cover.jpg"));
        assert_eq!(request.cover_path.as_deref(), Some("/Music/song.jpg"));
        assert!(request.embed_cover);

        let metadata = request.metadata.expect("metadata should deserialize");
        assert_eq!(metadata.file_path, "/Music/song.mp3");
        assert_eq!(metadata.title.as_deref(), Some("测试歌曲"));
        assert_eq!(metadata.album_artist.as_deref(), Some("测试专辑艺术家"));
        assert_eq!(metadata.track_number.as_deref(), Some("7"));
        assert_eq!(metadata.cover_mime.as_deref(), Some("image/jpeg"));
    }
}