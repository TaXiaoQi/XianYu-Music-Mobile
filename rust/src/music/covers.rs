// music/covers.rs - 封面缓存与缩略图生成

use super::tags::{find_embedded_picture, read_tagged_file_from_path};
use super::utils::normalize_path;
use crate::remote::cache::{ensure_cached_path, is_remote_uri};
use image::{DynamicImage, ImageFormat};
use lofty::picture::MimeType;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

// 移动端降档：封面可随时从音频标签重新提取，1GB 上限 + LRU 淘汰足够
const COVER_CACHE_MAX_SIZE_BYTES: u64 = 1024 * 1024 * 1024; // 1 GB
const THUMBNAIL_EDGE_PX: u32 = 150;
const FULL_COVER_EDGE_PX: u32 = 800;
const FULL_COVER_CACHE_VERSION: &str = "v3";
const FULL_COVER_FALLBACK_EXT: &str = "png";
const FULL_COVER_CACHE_EXTENSIONS: [&str; 5] = ["jpg", "png", "webp", "gif", "bmp"];
const CACHE_ALIAS_EXT: &str = "ref";

/// 缩略图并发信号量（全局共享，限制解码/缩放时的内存占用）。
fn thumbnail_semaphore() -> &'static tokio::sync::Semaphore {
    static SEM: OnceLock<tokio::sync::Semaphore> = OnceLock::new();
    SEM.get_or_init(|| {
        tokio::sync::Semaphore::new(super::types::THUMBNAIL_IMAGE_CONCURRENCY_LIMIT)
    })
}

/// 高清封面并发信号量（全局共享）。
fn full_cover_semaphore() -> &'static tokio::sync::Semaphore {
    static SEM: OnceLock<tokio::sync::Semaphore> = OnceLock::new();
    SEM.get_or_init(|| {
        tokio::sync::Semaphore::new(super::types::FULL_COVER_IMAGE_CONCURRENCY_LIMIT)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_cover_edge_is_capped_for_now_playing_memory() {
        assert_eq!(FULL_COVER_EDGE_PX, 800);
    }
}

/// 封面缓存目录（`{cache_root}/covers`）。
pub fn get_cover_cache_dir(cache_root: &Path) -> PathBuf {
    let dir = cache_root.join("covers");
    if !dir.exists() {
        let _ = fs::create_dir_all(&dir);
    }
    dir
}

pub fn run_cache_cleanup(cache_dir: &Path) {
    let cache_dir = cache_dir.to_path_buf();
    let max_size = COVER_CACHE_MAX_SIZE_BYTES;

    std::thread::spawn(move || {
        if let Ok(read_dir) = fs::read_dir(&cache_dir) {
            let mut files: Vec<_> = read_dir
                .filter_map(|entry| entry.ok())
                .filter_map(|entry| {
                    let metadata = entry.metadata().ok()?;
                    let len = metadata.len();
                    let accessed = metadata
                        .accessed()
                        .or(metadata.modified())
                        .unwrap_or(SystemTime::now());
                    Some((entry.path(), len, accessed))
                })
                .collect();

            files.sort_by_key(|&(_, _, time)| time);
            let mut total_size: u64 = files.iter().map(|&(_, len, _)| len).sum();

            if total_size > max_size {
                for (path, len, _) in files {
                    if total_size <= max_size {
                        break;
                    }
                    if fs::remove_file(&path).is_ok() {
                        total_size = total_size.saturating_sub(len);
                    }
                }
            }
        }
    });
}

fn remove_cache_dir_contents(cache_dir: &Path) -> Result<(), String> {
    if !cache_dir.exists() {
        return Ok(());
    }

    let read_dir = fs::read_dir(cache_dir).map_err(|error| error.to_string())?;
    for entry in read_dir {
        let entry = entry.map_err(|error| error.to_string())?;
        let path = entry.path();
        if path.is_file() {
            fs::remove_file(&path).map_err(|error| error.to_string())?;
        }
    }

    Ok(())
}

// ---- 无图负缓存（提取失败路径的 TTL 记忆） ----
//
// 对齐 RwaS CoilArtworkRuntime 的「无图缓存 TTL」：对提取不到内嵌封面的音频，
// 在 TTL 窗口内不再重复尝试（避免列表滚动/重扫时对无封面文件反复
// FFI + 解码 + 写盘），TTL 过后才允许重试，以便用户补写封面后能回流。
const NO_COVER_NEGATIVE_TTL_SECS: u64 = 3600; // 1 小时
const NO_COVER_NEGATIVE_CAP: usize = 100_000;

/// 路径（规范化主键）→ 最近一次封面提取失败的 Unix 秒。
fn no_cover_negative_cache() -> &'static Mutex<HashMap<String, u64>> {
    static CACHE: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cover_now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

/// 记录该路径最近一次封面提取失败的 Unix 秒（幂等刷新 TTL）。
fn mark_no_cover(key: &str, at_secs: u64) {
    if let Ok(mut map) = no_cover_negative_cache().lock() {
        map.insert(key.to_string(), at_secs);
        // 容量保护：进程内常驻且只在此处增长，超过上限时整体清空重建
        if map.len() > NO_COVER_NEGATIVE_CAP {
            map.clear();
        }
    }
}

/// 是否命中无图负缓存（TLL 窗口内跳过重试）。
fn is_no_cover_cached(key: &str, now_secs: u64) -> bool {
    no_cover_negative_cache()
        .lock()
        .map(|map| {
            map.get(key)
                .map(|&at| now_secs.saturating_sub(at) < NO_COVER_NEGATIVE_TTL_SECS)
                .unwrap_or(false)
        })
        .unwrap_or(false)
}

pub fn clear_cover_cache(cache_dir: &Path) -> Result<(), String> {
    remove_cache_dir_contents(cache_dir)
}

/// 清空无图负缓存（用户主动重扫/清缓存时释放记忆，允许立即可重试提取）。
pub fn clear_no_cover_negative_cache() {
    if let Ok(mut map) = no_cover_negative_cache().lock() {
        map.clear();
    }
}

fn generate_source_hash(path: &Path) -> String {
    let mut hasher = Sha256::new();
    let normalized_path = normalize_path(&path.to_string_lossy());
    hasher.update(normalized_path.as_bytes());

    if let Ok(metadata) = fs::metadata(path) {
        let len = metadata.len();
        let mtime_nanos = metadata
            .modified()
            .unwrap_or(SystemTime::now())
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();

        hasher.update(len.to_be_bytes());
        hasher.update(mtime_nanos.to_be_bytes());
    }

    hex::encode(hasher.finalize())
}

fn generate_content_hash(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn is_cached_cover_valid(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.len() > 0)
        .unwrap_or(false)
}

fn is_cache_image_decodable(path: &Path) -> bool {
    image::open(path).is_ok()
}

fn create_temp_cache_path(cache_path: &Path) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let file_name = cache_path.file_name().unwrap_or_default().to_string_lossy();
    cache_path.with_file_name(format!("{file_name}.{nonce}.tmp"))
}

fn persist_bytes_atomically(bytes: &[u8], cache_path: &Path) -> Option<String> {
    let temp_path = create_temp_cache_path(cache_path);
    let file = fs::File::create(&temp_path).ok()?;
    let mut writer = BufWriter::new(file);

    if writer.write_all(bytes).is_err() || writer.flush().is_err() {
        let _ = fs::remove_file(&temp_path);
        return None;
    }
    drop(writer);

    if cache_path.exists() {
        if is_cache_image_decodable(cache_path) {
            let _ = fs::remove_file(&temp_path);
            return Some(cache_path.to_string_lossy().into_owned());
        }
        let _ = fs::remove_file(cache_path);
    }

    if fs::rename(&temp_path, cache_path).is_err() {
        let _ = fs::remove_file(&temp_path);
        if is_cache_image_decodable(cache_path) {
            return Some(cache_path.to_string_lossy().into_owned());
        }
        return None;
    }

    Some(cache_path.to_string_lossy().into_owned())
}

fn persist_image_atomically(
    img: &DynamicImage,
    format: ImageFormat,
    cache_path: &Path,
) -> Option<String> {
    let temp_path = create_temp_cache_path(cache_path);
    let file = fs::File::create(&temp_path).ok()?;
    let mut writer = BufWriter::new(file);

    if img.write_to(&mut writer, format).is_err() || writer.flush().is_err() {
        let _ = fs::remove_file(&temp_path);
        return None;
    }
    drop(writer);

    if cache_path.exists() {
        if is_cache_image_decodable(cache_path) {
            let _ = fs::remove_file(&temp_path);
            return Some(cache_path.to_string_lossy().into_owned());
        }
        let _ = fs::remove_file(cache_path);
    }

    if fs::rename(&temp_path, cache_path).is_err() {
        let _ = fs::remove_file(&temp_path);
        if is_cache_image_decodable(cache_path) {
            return Some(cache_path.to_string_lossy().into_owned());
        }
        return None;
    }

    Some(cache_path.to_string_lossy().into_owned())
}

fn full_cover_cache_stem(hash: &str) -> String {
    format!("{hash}_full_{FULL_COVER_CACHE_VERSION}")
}

fn thumbnail_cache_stem(hash: &str) -> String {
    format!("{hash}_thumb_{THUMBNAIL_EDGE_PX}")
}

fn thumbnail_alias_path(cache_dir: &Path, source_hash: &str) -> PathBuf {
    cache_dir.join(format!(
        "{source_hash}_thumb_{THUMBNAIL_EDGE_PX}.{CACHE_ALIAS_EXT}"
    ))
}

fn full_cover_alias_path(cache_dir: &Path, source_hash: &str) -> PathBuf {
    cache_dir.join(format!(
        "{source_hash}_full_{FULL_COVER_CACHE_VERSION}.{CACHE_ALIAS_EXT}"
    ))
}

fn full_cover_extension_from_mime(mime: Option<&MimeType>) -> Option<&'static str> {
    match mime {
        Some(MimeType::Jpeg) => Some("jpg"),
        Some(MimeType::Png) => Some("png"),
        Some(MimeType::Gif) => Some("gif"),
        Some(MimeType::Bmp) => Some("bmp"),
        Some(MimeType::Unknown(value)) if value.eq_ignore_ascii_case("image/webp") => Some("webp"),
        _ => None,
    }
}

fn resolve_alias_target(cache_dir: &Path, alias_path: &Path) -> Option<String> {
    let file_name = fs::read_to_string(alias_path).ok()?;
    let trimmed = file_name.trim();
    if trimmed.is_empty() {
        let _ = fs::remove_file(alias_path);
        return None;
    }

    let target_path = cache_dir.join(trimmed);
    if is_cached_cover_valid(&target_path) {
        return Some(target_path.to_string_lossy().into_owned());
    }

    let _ = fs::remove_file(alias_path);
    if target_path.exists() {
        let _ = fs::remove_file(target_path);
    }
    None
}

fn persist_alias_target(alias_path: &Path, target_path: &Path) -> Option<()> {
    let file_name = target_path.file_name()?.to_string_lossy().into_owned();
    persist_bytes_atomically(file_name.as_bytes(), alias_path)?;
    Some(())
}

fn cleanup_invalid_full_cover_variants(cache_dir: &Path, stem: &str) {
    for ext in FULL_COVER_CACHE_EXTENSIONS {
        let candidate = cache_dir.join(format!("{stem}.{ext}"));
        if candidate.exists() && !is_cache_image_decodable(&candidate) {
            let _ = fs::remove_file(candidate);
        }
    }
}

fn find_cached_full_cover(cache_dir: &Path, stem: &str) -> Option<String> {
    for ext in FULL_COVER_CACHE_EXTENSIONS {
        let candidate = cache_dir.join(format!("{stem}.{ext}"));
        if !candidate.exists() {
            continue;
        }

        if is_cached_cover_valid(&candidate) {
            return Some(candidate.to_string_lossy().into_owned());
        }

        let _ = fs::remove_file(candidate);
    }

    None
}

pub fn get_or_create_thumbnail(path: &Path, cache_dir: &Path) -> Option<String> {
    let source_hash = generate_source_hash(path);
    let now = cover_now_unix_secs();
    let path_key = normalize_path(&path.to_string_lossy());
    let alias_path = thumbnail_alias_path(cache_dir, &source_hash);

    if let Some(existing) = resolve_alias_target(cache_dir, &alias_path) {
        return Some(existing);
    }

    // 无图负缓存：TTL 内提取失败过的路径直接回落默认图，不再重读文件
    if is_no_cover_cached(&path_key, now) {
        return None;
    }

    if let Ok(tagged_file) = read_tagged_file_from_path(path) {
        if let Some(pic) = find_embedded_picture(&tagged_file) {
            let shared_hash = generate_content_hash(pic.data());
            let cache_path = cache_dir.join(format!("{}.jpg", thumbnail_cache_stem(&shared_hash)));

            if is_cached_cover_valid(&cache_path) {
                let _ = persist_alias_target(&alias_path, &cache_path);
                return Some(cache_path.to_string_lossy().into_owned());
            }
            if cache_path.exists() {
                let _ = fs::remove_file(&cache_path);
            }

            if let Ok(img) = image::load_from_memory(pic.data()) {
                let resized = img.resize(
                    THUMBNAIL_EDGE_PX,
                    THUMBNAIL_EDGE_PX,
                    image::imageops::FilterType::Triangle,
                );
                let persisted = persist_image_atomically(&resized, ImageFormat::Jpeg, &cache_path)?;
                let _ = persist_alias_target(&alias_path, &cache_path);
                return Some(persisted);
            }
        }
    }
    mark_no_cover(&path_key, now);
    None
}

/// 通用别名封面提取：从 [read_path] 读取音频标签中的内嵌封面，但缓存别名按
/// [source_key]（稳定主键，如 SAF content URI）哈希。
///
/// 这样扫描阶段产出的缩略图，能在播放/列表展示时按同一 source_key 命中，
/// 避免运行时再去读无法直接以文件路径访问的 content URI。
fn get_or_create_thumbnail_aliased(
    source_key: &str,
    read_path: &Path,
    cache_dir: &Path,
) -> Option<String> {
    let source_hash = generate_source_hash(Path::new(source_key));
    let now = cover_now_unix_secs();
    let key = normalize_path(source_key);
    let alias_path = thumbnail_alias_path(cache_dir, &source_hash);

    if let Some(existing) = resolve_alias_target(cache_dir, &alias_path) {
        return Some(existing);
    }

    // 无图负缓存：TTL 内提取失败过的稳定主键直接回落默认图，不再重读
    if is_no_cover_cached(&key, now) {
        return None;
    }

    if let Ok(tagged_file) = read_tagged_file_from_path(read_path) {
        if let Some(pic) = find_embedded_picture(&tagged_file) {
            let shared_hash = generate_content_hash(pic.data());
            let cache_path =
                cache_dir.join(format!("{}.jpg", thumbnail_cache_stem(&shared_hash)));

            if is_cached_cover_valid(&cache_path) {
                let _ = persist_alias_target(&alias_path, &cache_path);
                return Some(cache_path.to_string_lossy().into_owned());
            }
            if cache_path.exists() {
                let _ = fs::remove_file(&cache_path);
            }

            if let Ok(img) = image::load_from_memory(pic.data()) {
                let resized = img.resize(
                    THUMBNAIL_EDGE_PX,
                    THUMBNAIL_EDGE_PX,
                    image::imageops::FilterType::Triangle,
                );
                let persisted =
                    persist_image_atomically(&resized, ImageFormat::Jpeg, &cache_path)?;
                let _ = persist_alias_target(&alias_path, &cache_path);
                return Some(persisted);
            }
        }
    }
    mark_no_cover(&key, now);
    None
}

/// 扫描 SAF 音频时从已打开的 `content://` fd 提取内嵌封面并写入封面缓存。
///
/// 读文件走 `/proc/self/fd/{fd}`，别名按 `source_path`（content URI）哈希，
/// 与播放/列表时 `get_song_cover_thumbnail` 按同路径查找所命中的别名一致。
pub fn get_or_create_thumbnail_from_fd(
    source_path: &str,
    fd: i32,
    cache_dir: &Path,
) -> Option<String> {
    let fd_path = format!("/proc/self/fd/{fd}");
    get_or_create_thumbnail_aliased(source_path, Path::new(&fd_path), cache_dir)
}

/// 扫描 SAF 音频时从物化到应用内部存储的真实文件路径提取封面。
///
/// 别名仍按 `source_key`（content URI）哈希，与展示路径一致；读取走稳定真实路径，
/// 比 `/proc/self/fd/{fd}` 更可靠，适用于复制成功后统一走路径式解析的场景。
pub fn get_or_create_thumbnail_from_path(
    source_key: &str,
    real_path: &Path,
    cache_dir: &Path,
) -> Option<String> {
    get_or_create_thumbnail_aliased(source_key, real_path, cache_dir)
}

pub fn get_or_create_full_cover(path: &Path, cache_dir: &Path) -> Option<String> {
    let source_hash = generate_source_hash(path);
    let alias_path = full_cover_alias_path(cache_dir, &source_hash);

    if let Some(existing) = resolve_alias_target(cache_dir, &alias_path) {
        return Some(existing);
    }

    if let Ok(tagged_file) = read_tagged_file_from_path(path) {
        if let Some(pic) = find_embedded_picture(&tagged_file) {
            let shared_hash = generate_content_hash(pic.data());
            let cache_stem = full_cover_cache_stem(&shared_hash);

            if let Some(existing) = find_cached_full_cover(cache_dir, &cache_stem) {
                let existing_path = Path::new(&existing);
                let _ = persist_alias_target(&alias_path, &existing_path);
                return Some(existing);
            }

            cleanup_invalid_full_cover_variants(cache_dir, &cache_stem);

            if let Ok(img) = image::load_from_memory(pic.data()) {
                let should_resize =
                    img.width() > FULL_COVER_EDGE_PX || img.height() > FULL_COVER_EDGE_PX;

                if !should_resize {
                    if let Some(ext) = full_cover_extension_from_mime(pic.mime_type()) {
                        let cache_path = cache_dir.join(format!("{cache_stem}.{ext}"));
                        let persisted = persist_bytes_atomically(pic.data(), &cache_path)?;
                        let _ = persist_alias_target(&alias_path, &cache_path);
                        return Some(persisted);
                    }
                }

                // 将显示封面钳制到高质量边长，以免把原始数千像素的大图解码进内存。
                let display_img = if should_resize {
                    img.resize(
                        FULL_COVER_EDGE_PX,
                        FULL_COVER_EDGE_PX,
                        image::imageops::FilterType::Lanczos3,
                    )
                } else {
                    img
                };

                let cache_path =
                    cache_dir.join(format!("{cache_stem}.{FULL_COVER_FALLBACK_EXT}"));
                let persisted =
                    persist_image_atomically(&display_img, ImageFormat::Png, &cache_path)?;
                let _ = persist_alias_target(&alias_path, &cache_path);
                return Some(persisted);
            }

            if let Some(ext) = full_cover_extension_from_mime(pic.mime_type()) {
                let cache_path = cache_dir.join(format!("{cache_stem}.{ext}"));
                let persisted = persist_bytes_atomically(pic.data(), &cache_path)?;
                let _ = persist_alias_target(&alias_path, &cache_path);
                return Some(persisted);
            }
        }
    }
    None
}

/// 获取歌曲缩略图封面（远程 URI 先保证缓存到本地）。
///
/// 成功后回写 `songs.cover_thumb_path`。
pub async fn get_song_cover_thumbnail(
    cache_root: PathBuf,
    db_conn: Arc<Mutex<rusqlite::Connection>>,
    path: String,
) -> Result<String, String> {
    let _permit = thumbnail_semaphore()
        .acquire()
        .await
        .map_err(|e| e.to_string())?;
    let source_path = if is_remote_uri(&path) {
        ensure_cached_path(&cache_root, db_conn.clone(), &path).await?
    } else {
        path.clone()
    };

    let cache_dir = get_cover_cache_dir(&cache_root);
    let p = Path::new(&source_path);
    let p_buf = p.to_path_buf();

    let result = std::thread::spawn(move || get_or_create_thumbnail(&p_buf, &cache_dir))
        .join()
        .map_err(|_| "缩略图生成线程异常".to_string())?;

    if let Some(cache_path_str) = result {
        if !cache_path_str.is_empty() {
            if let Ok(conn) = db_conn.lock() {
                let _ = conn.execute(
                    "UPDATE songs SET cover_thumb_path = ?1 WHERE path = ?2",
                    rusqlite::params![&cache_path_str, &path],
                );
            }
        }
        return Ok(cache_path_str);
    }
    Ok(String::new())
}

/// 获取歌曲高清封面（远程 URI 先保证缓存到本地）。
pub async fn get_song_cover(
    cache_root: PathBuf,
    db_conn: Arc<Mutex<rusqlite::Connection>>,
    path: String,
) -> Result<String, String> {
    let _permit = full_cover_semaphore()
        .acquire()
        .await
        .map_err(|e| e.to_string())?;
    let source_path = if is_remote_uri(&path) {
        ensure_cached_path(&cache_root, db_conn, &path).await?
    } else {
        path.clone()
    };

    let cache_dir = get_cover_cache_dir(&cache_root);
    let p = Path::new(&source_path);
    let p_buf = p.to_path_buf();

    let result = std::thread::spawn(move || get_or_create_full_cover(&p_buf, &cache_dir))
        .join()
        .map_err(|_| "高清封面生成线程异常".to_string())?;

    if let Some(cache_path_str) = result {
        return Ok(cache_path_str);
    }
    Ok(String::new())
}

pub fn save_artist_avatar_auto(bytes: &[u8], covers_dir: &std::path::Path) -> Option<String> {
    let ext = if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("jpg")
    } else if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some("png")
    } else if bytes.starts_with(b"RIFF") && bytes.len() >= 12 && &bytes[8..12] == b"WEBP" {
        Some("webp")
    } else {
        None
    };

    let Some(ext) = ext else {
        return None;
    };

    let sha256_hex = generate_content_hash(bytes);
    let target_filename = format!("artist-avatar-auto-{}.{}", sha256_hex, ext);
    let target_path = covers_dir.join(target_filename);

    if !covers_dir.exists() {
        if std::fs::create_dir_all(covers_dir).is_err() {
            return None;
        }
    }

    if let Some(path_str) = persist_bytes_atomically(bytes, &target_path) {
        Some(normalize_path(&path_str))
    } else {
        None
    }
}