// music/files.rs - 文件操作功能

use super::scanner::{apply_scan_changes, parse_song_from_file};
use super::tags::{extract_detail_metadata, read_tagged_file_from_path};
use super::types::{SaveArtistAvatarResponse, SaveSongInfoResponse, SongDetail, SongInfoEditPayload};
use super::utils::normalize_path;
use crate::remote::cache::is_remote_uri;
use crate::security::path_validator;
use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::tag::{ItemKey, Tag};
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Serialize)]
pub struct MovedMusicFilePath {
    old_path: String,
    new_path: String,
}

#[derive(Serialize)]
pub struct BatchMoveMusicFilesResult {
    moved_paths: Vec<MovedMusicFilePath>,
}


fn normalized_optional_text(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn write_optional_text(tag: &mut Tag, key: ItemKey, value: Option<String>) {
    if let Some(value) = normalized_optional_text(value) {
        let _ = tag.insert_text(key, value);
    } else {
        tag.remove_key(&key);
    }
}

fn picture_mime_from_path(path: &Path) -> MimeType {
    match path
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase())
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => MimeType::Jpeg,
        Some("png") => MimeType::Png,
        Some("gif") => MimeType::Gif,
        Some("bmp") => MimeType::Bmp,
        Some("tif") | Some("tiff") => MimeType::Tiff,
        Some("webp") => MimeType::Unknown("image/webp".to_string()),
        _ => MimeType::Unknown("application/octet-stream".to_string()),
    }
}

fn write_song_info_tags(path_obj: &Path, payload: &SongInfoEditPayload) -> Result<(), String> {
    let title = payload.title.trim();
    if title.is_empty() {
        return Err("歌名不能为空".to_string());
    }

    let mut tagged_file = read_tagged_file_from_path(path_obj).map_err(|e| e.to_string())?;
    let tag_type = tagged_file.primary_tag_type();

    if tagged_file.tag_mut(tag_type).is_none() {
        tagged_file.insert_tag(Tag::new(tag_type));
    }

    let tag = tagged_file
        .tag_mut(tag_type)
        .ok_or_else(|| "当前歌曲格式不支持写入标签".to_string())?;

    let _ = tag.insert_text(ItemKey::TrackTitle, title.to_string());
    write_optional_text(tag, ItemKey::TrackArtist, Some(payload.artist.clone()));
    write_optional_text(tag, ItemKey::AlbumTitle, Some(payload.album.clone()));
    write_optional_text(tag, ItemKey::AlbumArtist, Some(payload.artist.clone()));
    write_optional_text(tag, ItemKey::TrackNumber, payload.track_number.clone());
    write_optional_text(tag, ItemKey::DiscNumber, payload.disc_number.clone());
    write_optional_text(tag, ItemKey::RecordingDate, payload.year.clone());
    if normalized_optional_text(payload.year.clone()).is_none() {
        tag.remove_key(&ItemKey::Year);
    }

    if let Some(cover_path) = normalized_optional_text(payload.cover_path.clone()) {
        let cover_path_obj = Path::new(&cover_path);
        if !cover_path_obj.is_file() {
            return Err("选择的封面图片不存在".to_string());
        }

        let image_bytes = fs::read(cover_path_obj).map_err(|e| e.to_string())?;
        let picture = Picture::new_unchecked(
            PictureType::CoverFront,
            Some(picture_mime_from_path(cover_path_obj)),
            None,
            image_bytes,
        );
        tag.remove_picture_type(PictureType::CoverFront);
        tag.push_picture(picture);
    }

    tagged_file
        .save_to_path(path_obj, WriteOptions::default())
        .map_err(|e| e.to_string())
}

fn build_song_detail_from_file(path_obj: &Path, normalized_path: &str) -> SongDetail {
    let mut detail = SongDetail {
        path: normalized_path.to_string(),
        ..SongDetail::default()
    };

    if let Ok(metadata) = fs::metadata(path_obj) {
        detail.file_size = Some(metadata.len());
    }

    if let Ok(tagged_file) = read_tagged_file_from_path(path_obj) {
        let tag_detail = extract_detail_metadata(&tagged_file);
        detail.genre = tag_detail.genre;
        detail.year = tag_detail.year;
        detail.track_number = tag_detail.track_number;
        detail.disc_number = tag_detail.disc_number;
        detail.comment = tag_detail.comment;
    }

    detail.container = path_obj
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase());

    detail
}

fn load_song_id(conn: &rusqlite::Connection, path: &str) -> Result<Option<i64>, String> {
    conn.query_row(
        "SELECT id FROM songs WHERE path = ?1 LIMIT 1",
        params![path],
        |row| row.get::<_, i64>(0),
    )
    .optional()
    .map_err(|e| e.to_string())
}

fn sync_moved_song_paths(
    conn: &mut rusqlite::Connection,
    moved_paths: &[(String, String)],
) -> Result<(), String> {
    if moved_paths.is_empty() {
        return Ok(());
    }

    let tx = conn.transaction().map_err(|e| e.to_string())?;

    {
        let mut update_song_stmt = tx
            .prepare("UPDATE songs SET path = ?1 WHERE path = ?2")
            .map_err(|e| e.to_string())?;
        let mut update_history_stmt = tx
            .prepare("UPDATE play_history SET song_path = ?1 WHERE song_path = ?2")
            .map_err(|e| e.to_string())?;

        for (old_path, new_path) in moved_paths {
            update_song_stmt
                .execute(params![new_path, old_path])
                .map_err(|e| format!("failed to update song path '{}': {}", old_path, e))?;
            update_history_stmt
                .execute(params![new_path, old_path])
                .map_err(|e| format!("failed to update play history '{}': {}", old_path, e))?;
        }
    }

    tx.commit().map_err(|e| e.to_string())
}


pub fn save_song_info(
    conn: &mut rusqlite::Connection,
    path: String,
    payload: SongInfoEditPayload,
) -> Result<String, String> {
    if is_remote_uri(&path) {
        return Err("远程歌曲暂不支持直接编辑文件标签".to_string());
    }

    let normalized_path = normalize_path(&path);
    let path_obj = Path::new(&path);
    if !path_obj.is_file() {
        return Err("歌曲文件不存在".to_string());
    }

    let existing_song_id = load_song_id(conn, &normalized_path)?;
    write_song_info_tags(path_obj, &payload)?;

    let extension = path_obj
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase())
        .unwrap_or_default();
    let mut song = parse_song_from_file(path_obj, &normalized_path, &extension)
        .ok_or_else(|| "保存后无法重新读取歌曲信息".to_string())?;
    song.id = existing_song_id;

    if existing_song_id.is_some() {
        apply_scan_changes(conn, &[], std::slice::from_ref(&song), &[], None)?;
    } else {
        apply_scan_changes(conn, std::slice::from_ref(&song), &[], &[], None)?;
        song.id = load_song_id(conn, &normalized_path)?;
    }

    let mut detail = build_song_detail_from_file(path_obj, &normalized_path);
    detail.container = song.container.clone().or(detail.container);
    detail.codec = song.codec.clone();
    detail.file_size = Some(song.file_size);

    let result = SaveSongInfoResponse { song, detail };
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

fn get_song_background_dir(song_backgrounds_root: &Path) -> PathBuf {
    let dir = song_backgrounds_root.join("song_backgrounds");
    if !dir.exists() {
        let _ = fs::create_dir_all(&dir);
    }
    dir
}

pub fn save_song_background(
    conn: &rusqlite::Connection,
    song_backgrounds_root: &Path,
    song_path: String,
    background_path: String,
) -> Result<String, String> {
    let normalized_song_path = normalize_path(&song_path);

    let src_path = Path::new(&background_path);
    if !src_path.is_file() {
        return Err("背景图片文件不存在".to_string());
    }

    let bg_dir = get_song_background_dir(song_backgrounds_root);
    let ext = src_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("png");
    let dest_name = format!("{}.{}", Uuid::new_v4().to_string().replace('-', ""), ext);
    let dest_path = bg_dir.join(&dest_name);
    fs::copy(src_path, &dest_path).map_err(|e| format!("复制背景图片失败: {}", e))?;

    let stored_path = dest_path.to_string_lossy().into_owned();

    conn.execute(
        "INSERT OR REPLACE INTO song_backgrounds (song_path, background_path) VALUES (?1, ?2)",
        params![&normalized_song_path, &stored_path],
    )
    .map_err(|e| format!("写入数据库失败: {}", e))?;

    Ok(stored_path)
}

pub fn get_song_background(
    conn: &rusqlite::Connection,
    song_path: String,
) -> Result<Option<String>, String> {
    let normalized_song_path = normalize_path(&song_path);
    let result: Option<String> = conn
        .query_row(
            "SELECT background_path FROM song_backgrounds WHERE song_path = ?1",
            params![&normalized_song_path],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| format!("查询失败: {}", e))?;

    if let Some(ref p) = result {
        if !Path::new(p).is_file() {
            return Ok(None);
        }
    }
    Ok(result)
}

pub fn clear_song_background(
    conn: &rusqlite::Connection,
    song_backgrounds_root: &Path,
    song_path: String,
) -> Result<(), String> {
    let normalized_song_path = normalize_path(&song_path);
    let bg_path: Option<String> = conn
        .query_row(
            "SELECT background_path FROM song_backgrounds WHERE song_path = ?1",
            params![&normalized_song_path],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| format!("查询失败: {}", e))?;

    conn.execute(
        "DELETE FROM song_backgrounds WHERE song_path = ?1",
        params![&normalized_song_path],
    )
    .map_err(|e| format!("删除失败: {}", e))?;

    if let Some(p) = bg_path {
        let _ = fs::remove_file(&p);
    }

    let _ = song_backgrounds_root;
    Ok(())
}

pub fn get_song_detail(conn: &rusqlite::Connection, path: String) -> Result<String, String> {
    let normalized_path = normalize_path(&path);
    let path_obj = Path::new(&path);
    let mut detail = SongDetail {
        path: normalized_path.clone(),
        ..SongDetail::default()
    };

    if let Some((container, codec, file_size, bitrate, sample_rate, bit_depth, format)) = conn
        .query_row(
            "SELECT container, codec, file_size, bitrate, sample_rate, bit_depth, format
             FROM songs WHERE path = ?1 LIMIT 1",
            params![&normalized_path],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                ))
            },
        )
        .optional()
        .map_err(|e| e.to_string())?
    {
        detail.container = container.filter(|value| !value.trim().is_empty());
        detail.codec = codec.filter(|value| !value.trim().is_empty());
        detail.file_size = file_size.and_then(|value| u64::try_from(value).ok());
        detail.bitrate = bitrate.and_then(|value| u32::try_from(value).ok()).filter(|v| *v > 0);
        detail.sample_rate = sample_rate
            .and_then(|value| u32::try_from(value).ok())
            .filter(|v| *v > 0);
        detail.bit_depth = bit_depth
            .and_then(|value| u8::try_from(value).ok())
            .filter(|v| *v > 0);
        detail.format = format.filter(|value| !value.trim().is_empty());
    }

    if let Ok(metadata) = fs::metadata(path_obj) {
        detail.file_size = Some(metadata.len());
    }

    if let Ok(tagged_file) = read_tagged_file_from_path(path_obj) {
        let tag_detail = extract_detail_metadata(&tagged_file);
        detail.genre = tag_detail.genre;
        detail.year = tag_detail.year;
        detail.track_number = tag_detail.track_number;
        detail.disc_number = tag_detail.disc_number;
        detail.comment = tag_detail.comment;

        if detail.container.is_none() {
            detail.container = path_obj
                .extension()
                .and_then(|ext| ext.to_str())
                .map(|ext| ext.to_ascii_lowercase());
        }
    }

    serde_json::to_string(&detail).map_err(|e| e.to_string())
}

pub fn batch_move_music_files(
    conn: &mut rusqlite::Connection,
    paths: Vec<String>,
    target_folder: String,
) -> Result<String, String> {
    let validated_target = path_validator::validate_path(&target_folder, None)?;
    if !validated_target.exists() || !validated_target.is_dir() {
        return Err("目标文件夹不存在".to_string());
    }
    let mut moved_paths: Vec<(String, String)> = Vec::new();
    for path_str in paths {
        let validated_src = match path_validator::validate_path(&path_str, None) {
            Ok(p) => p,
            Err(_) => continue,
        };
        if let Some(file_name) = validated_src.file_name() {
            let dest = validated_target.join(file_name);
            if fs::rename(&validated_src, &dest).is_ok() {
                moved_paths.push((
                    normalize_path(&path_str),
                    normalize_path(&dest.to_string_lossy()),
                ));
            }
        }
    }
    if !moved_paths.is_empty() {
        sync_moved_song_paths(conn, &moved_paths)?;
    }

    let result = BatchMoveMusicFilesResult {
        moved_paths: moved_paths
            .into_iter()
            .map(|(old_path, new_path)| MovedMusicFilePath { old_path, new_path })
            .collect(),
    };
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub fn move_music_file(
    conn: &mut rusqlite::Connection,
    old_path: String,
    new_path: String,
) -> Result<(), String> {
    let validated_src = path_validator::validate_path(&old_path, None)?;
    let validated_dest = path_validator::validate_path(&new_path, None)?;
    if !validated_src.exists() {
        return Err("源文件不存在".to_string());
    }
    if let Some(parent) = validated_dest.parent() {
        if !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
    }
    fs::rename(&validated_src, &validated_dest).map_err(|e| e.to_string())?;
    let normalized_old_path = normalize_path(&old_path);
    let normalized_new_path = normalize_path(&validated_dest.to_string_lossy());
    sync_moved_song_paths(conn, &[(normalized_old_path, normalized_new_path)])
}

pub fn delete_music_file(path: String) -> Result<(), String> {
    let validated_path = path_validator::validate_path(&path, None)?;
    fs::remove_file(validated_path).map_err(|e| e.to_string())
}

pub fn delete_folder(path: String) -> Result<(), String> {
    let validated_path = path_validator::validate_path(&path, None)?;
    fs::remove_dir_all(validated_path).map_err(|e| e.to_string())
}

pub fn create_folder(parent_path: String, folder_name: String) -> Result<String, String> {
    let sanitized_name = path_validator::sanitize_filename_component(folder_name.trim())?;
    let validated_parent = path_validator::validate_path(&parent_path, None)?;
    if !validated_parent.exists() || !validated_parent.is_dir() {
        return Err("Parent folder does not exist".to_string());
    }

    let new_folder_path = validated_parent.join(&sanitized_name);
    if new_folder_path.exists() {
        return Err("Folder already exists".to_string());
    }

    fs::create_dir(&new_folder_path).map_err(|e| e.to_string())?;

    Ok(normalize_path(&new_folder_path.to_string_lossy()))
}

pub fn move_file_to_folder(
    conn: &mut rusqlite::Connection,
    source_path: String,
    target_folder: String,
) -> Result<(), String> {
    let source = Path::new(&source_path);
    let filename = source.file_name().ok_or("Invalid source filename")?;
    let target = Path::new(&target_folder).join(filename);

    if target.exists() {
        return Err("Target file already exists".to_string());
    }

    fs::rename(source, &target).map_err(|e| e.to_string())?;
    let normalized_source = normalize_path(&source_path);
    let normalized_target = normalize_path(&target.to_string_lossy());
    sync_moved_song_paths(conn, &[(normalized_source, normalized_target)])
}

pub fn is_directory(path: String) -> bool {
    Path::new(&path).is_dir()
}

struct SongTagWriteInfo {
    path: String,
    source_type: Option<String>,
    remote_source_id: Option<String>,
    cue_source_path: Option<String>,
    artist_count: i64,
}

/// 保存歌手头像。`write_to_tags` 为 true 时同步把头像写入该歌手所有歌曲的标签。
pub fn save_artist_avatar(
    conn: &rusqlite::Connection,
    covers_root: &Path,
    artist_id: i64,
    image_path: String,
    write_to_tags: bool,
) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use std::io::{Read, Seek};

    let path = Path::new(&image_path);
    if !path.exists() {
        return Err("Image file does not exist".to_string());
    }

    let mut file = fs::File::open(path).map_err(|e| format!("Failed to open image file: {}", e))?;
    let mut header = [0u8; 12];
    let bytes_read = file
        .read(&mut header)
        .map_err(|e| format!("Failed to read image header: {}", e))?;

    if bytes_read < 3 {
        return Err("Invalid image file: too short".to_string());
    }

    let ext = if header[..3] == [0xFF, 0xD8, 0xFF] {
        "jpg"
    } else if bytes_read >= 8 && header[..8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
        "png"
    } else if bytes_read >= 12 && &header[0..4] == b"RIFF" && &header[8..12] == b"WEBP" {
        "webp"
    } else {
        return Err("Unsupported image format. Only JPEG, PNG, and WEBP are allowed.".to_string());
    };

    file.seek(std::io::SeekFrom::Start(0))
        .map_err(|e| format!("Failed to seek image file: {}", e))?;

    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];
    loop {
        let n = file
            .read(&mut buffer)
            .map_err(|e| format!("Failed to read image file for hashing: {}", e))?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    let hash_result = hasher.finalize();
    let sha256_hex = format!("{:x}", hash_result);

    let covers_dir = super::covers::get_cover_cache_dir(covers_root);
    let target_filename = format!("artist-avatar-{}-{}.{}", artist_id, sha256_hex, ext);
    let target_path = covers_dir.join(target_filename);

    fs::copy(path, &target_path)
        .map_err(|e| format!("Failed to copy image to covers directory: {}", e))?;

    let target_path_str = normalize_path(&target_path.to_string_lossy());

    conn.execute(
        "UPDATE artists SET avatar_path = ?1 WHERE id = ?2",
        params![Some(&target_path_str), artist_id],
    )
    .map_err(|e| format!("Failed to update database: {}", e))?;

    if write_to_tags {
        let mut stmt = conn
            .prepare(
                "SELECT s.path, s.source_type, s.remote_source_id, s.cue_source_path, \
             (SELECT COUNT(*) FROM song_artists sa2 WHERE sa2.song_id = s.id) AS artist_count \
             FROM songs s \
             INNER JOIN song_artists sa ON s.id = sa.song_id \
             WHERE sa.artist_id = ?1",
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![artist_id], |row| {
                Ok(SongTagWriteInfo {
                    path: row.get(0)?,
                    source_type: row.get(1)?,
                    remote_source_id: row.get(2)?,
                    cue_source_path: row.get(3)?,
                    artist_count: row.get(4)?,
                })
            })
            .map_err(|e| e.to_string())?;

        let mut items = Vec::new();
        for r in rows {
            if let Ok(item) = r {
                items.push(item);
            }
        }

        if !items.is_empty() {
            let image_bytes = fs::read(&target_path_str)
                .map_err(|e| format!("Failed to read avatar cache: {}", e))?;
            let mime = match ext {
                "jpg" | "jpeg" => MimeType::Jpeg,
                "png" => MimeType::Png,
                "webp" => MimeType::Unknown("image/webp".to_string()),
                _ => MimeType::Unknown("application/octet-stream".to_string()),
            };

            for item in &items {
                let path_obj = Path::new(&item.path);

                let is_remote = {
                    let is_remote_source = match &item.source_type {
                        Some(s) => !s.is_empty() && s != "local",
                        None => false,
                    };
                    let is_remote_id = match &item.remote_source_id {
                        Some(s) => !s.is_empty(),
                        None => false,
                    };
                    is_remote_source || is_remote_id || is_remote_uri(&item.path)
                };

                let is_cue = match &item.cue_source_path {
                    Some(s) => !s.is_empty(),
                    None => false,
                };

                if is_remote || is_cue || item.artist_count > 1 || !path_obj.is_file() {
                    continue;
                }

                let is_readonly = match fs::metadata(path_obj) {
                    Ok(meta) => meta.permissions().readonly(),
                    Err(_) => false,
                };
                if is_readonly {
                    continue;
                }

                if let Ok(mut tagged_file) = read_tagged_file_from_path(path_obj) {
                    let tag_type = tagged_file.primary_tag_type();
                    if tagged_file.tag_mut(tag_type).is_none() {
                        tagged_file.insert_tag(Tag::new(tag_type));
                    }
                    if let Some(tag) = tagged_file.tag_mut(tag_type) {
                        let picture = Picture::new_unchecked(
                            PictureType::Artist,
                            Some(mime.clone()),
                            None,
                            image_bytes.clone(),
                        );
                        tag.remove_picture_type(PictureType::Artist);
                        tag.push_picture(picture);
                        let _ = tagged_file.save_to_path(path_obj, WriteOptions::default());
                    }
                }
            }
        }
    }

    let result = SaveArtistAvatarResponse {
        artist_id,
        avatar_path: target_path_str,
        task_id: None,
    };
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

