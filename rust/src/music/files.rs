// music/files.rs - 文件操作功能

use super::lyrics::build_structured_lyrics_payload;
use super::scanner::{apply_scan_changes, parse_song_from_file};
use super::tags::{
    extract_detail_metadata, extract_embedded_lyrics, extract_embedded_lyrics_match,
    read_tagged_file_from_path,
};
use super::types::{
    LyricsStorageSource, SaveArtistAvatarResponse, SaveSongInfoResponse, SongDetail,
    SongInfoEditPayload, SongLyricsForEdit,
};
use super::utils::normalize_path;
use crate::remote::cache::is_remote_uri;
use crate::remote::repository::{get_song_cache_path, get_source_for_remote_uri};
use crate::remote::webdav;
use crate::security::path_validator;
use encoding_rs::{GBK, UTF_16BE, UTF_16LE};
use std::sync::{Arc, Mutex};
use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::tag::{ItemKey, ItemValue, Tag, TagItem};
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
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

fn read_sidecar_lrc(path_obj: &Path) -> Option<String> {
    read_sidecar_lrc_with_path(path_obj).map(|(content, _)| content)
}

fn read_sidecar_lrc_with_path(path_obj: &Path) -> Option<(String, PathBuf)> {
    let stem = path_obj.file_stem()?.to_string_lossy().to_string();
    let parent = path_obj.parent()?;

    // 支持的侧边歌词文件后缀，按照优先级排序
    let extensions = ["lrc", "ttml", "qrc", "yrc", "lys", "txt"];

    // 1. 优先尝试精确匹配
    for ext in &extensions {
        let exact_path = parent.join(format!("{}.{}", stem, ext));
        if let Ok(content) = fs::read_to_string(&exact_path) {
            return Some((content, exact_path));
        }
    }

    // 2. 如果没有精确匹配到，进行目录遍历（不区分后缀大小写）
    let entries = fs::read_dir(parent).ok()?;
    for entry in entries.flatten() {
        let candidate = entry.path();
        if !candidate.is_file() {
            continue;
        }

        let is_valid_ext = candidate
            .extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| {
                extensions
                    .iter()
                    .any(|&valid_ext| ext.eq_ignore_ascii_case(valid_ext))
            })
            .unwrap_or(false);
        if !is_valid_ext {
            continue;
        }

        let candidate_stem = candidate.file_stem()?.to_string_lossy().to_string();
        if !candidate_stem.eq_ignore_ascii_case(&stem) {
            continue;
        }

        if let Ok(content) = fs::read_to_string(&candidate) {
            return Some((content, candidate));
        }
    }

    None
}

fn get_sidecar_lrc_path(path_obj: &Path) -> Result<PathBuf, String> {
    let stem = path_obj
        .file_stem()
        .ok_or_else(|| "Invalid song path".to_string())?
        .to_string_lossy()
        .to_string();
    let parent = path_obj
        .parent()
        .ok_or_else(|| "Song parent folder does not exist".to_string())?;

    Ok(parent.join(format!("{}.lrc", stem)))
}

fn remote_sidecar_lrc_path(remote_path: &str) -> Option<String> {
    let normalized = remote_path.replace('\\', "/");
    let trimmed = normalized.trim_end_matches('/');
    let (parent, file_name) = trimmed.rsplit_once('/')?;
    let stem = file_name.rsplit_once('.').map(|(stem, _)| stem)?;
    let parent = if parent.is_empty() { "/" } else { parent };
    Some(format!("{}/{}.lrc", parent.trim_end_matches('/'), stem))
}

fn write_sidecar_lyrics(
    path_obj: &Path,
    source_path: Option<String>,
    lyrics: String,
) -> Result<String, String> {
    let lrc_path = source_path
        .filter(|path| !path.trim().is_empty())
        .map(PathBuf::from)
        .map(Ok)
        .unwrap_or_else(|| get_sidecar_lrc_path(path_obj))?;

    fs::write(&lrc_path, lyrics).map_err(|e| e.to_string())?;

    Ok(normalize_path(&lrc_path.to_string_lossy()))
}

fn write_tag_item(tag: &mut Tag, key: ItemKey, description: String, lyrics: String) {
    if lyrics.trim().is_empty() {
        let _ = tag
            .take_filter(&key, |item| item.description() == description)
            .count();
        return;
    }

    let _ = tag
        .take_filter(&key, |item| item.description() == description)
        .count();

    let mut item = TagItem::new(key.clone(), ItemValue::Text(lyrics));
    if !description.is_empty() {
        item.set_description(description);
    }

    if matches!(key, ItemKey::Unknown(_)) {
        tag.push_unchecked(item);
    } else {
        let _ = tag.push(item);
    }
}

fn write_embedded_lyrics(path_obj: &Path, lyrics: String) -> Result<String, String> {
    let mut tagged_file = read_tagged_file_from_path(path_obj).map_err(|e| e.to_string())?;
    let current_lyrics = extract_embedded_lyrics_match(&tagged_file);
    let tag_type = current_lyrics
        .as_ref()
        .map(|lyrics_match| lyrics_match.tag_type)
        .unwrap_or_else(|| tagged_file.primary_tag_type());

    if tagged_file.tag_mut(tag_type).is_none() {
        tagged_file.insert_tag(Tag::new(tag_type));
    }

    let tag = tagged_file
        .tag_mut(tag_type)
        .ok_or_else(|| "Song file does not support writable lyrics tags".to_string())?;

    if let Some(lyrics_match) = current_lyrics {
        write_tag_item(tag, lyrics_match.item_key, lyrics_match.description, lyrics);
    } else if lyrics.trim().is_empty() {
        tag.remove_key(&ItemKey::Lyrics);
    } else {
        let _ = tag.insert_text(ItemKey::Lyrics, lyrics);
    }

    tagged_file
        .save_to_path(path_obj, WriteOptions::default())
        .map_err(|e| e.to_string())?;

    Ok(normalize_path(&path_obj.to_string_lossy()))
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

fn read_song_lyrics_raw(path: &str) -> String {
    if let Ok(tagged_file) = read_tagged_file_from_path(Path::new(path)) {
        if let Some(lyrics) = extract_embedded_lyrics(&tagged_file) {
            return lyrics;
        }
    }

    let path_obj = Path::new(path);
    if let Some(content) = read_sidecar_lrc(path_obj) {
        return content;
    }

    String::new()
}

/// 同步提取远程歌词所需的 owned 上下文（避免 &Connection 跨 await，不够 Send）。
struct RemoteLyricsCtx {
    source: crate::remote::types::RemoteSourceCredentials,
    lrc_path: String,
    local_lyrics: Option<String>,
}

fn resolve_remote_lyrics_ctx(
    path: &str,
    conn: &rusqlite::Connection,
) -> Option<RemoteLyricsCtx> {
    let lookup = get_source_for_remote_uri(conn, path).ok()?;
    let cache_path = get_song_cache_path(conn, lookup.3.as_deref().unwrap_or(path))
        .ok()
        .flatten();

    if let Some(cache_path) = cache_path {
        if Path::new(&cache_path).is_file() {
            let lyrics = read_song_lyrics_raw(&cache_path);
            if !lyrics.trim().is_empty() {
                return Some(RemoteLyricsCtx {
                    source: lookup.0,
                    lrc_path: cache_path,
                    local_lyrics: Some(lyrics),
                });
            }
        }
    }

    let lrc_path = remote_sidecar_lrc_path(&lookup.1)?;
    Some(RemoteLyricsCtx {
        source: lookup.0,
        lrc_path,
        local_lyrics: None,
    })
}

async fn read_remote_song_lyrics_raw(ctx: RemoteLyricsCtx) -> String {
    if let Some(lyrics) = ctx.local_lyrics {
        return lyrics;
    }
    webdav::read_text_file(&ctx.source, &ctx.lrc_path)
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

pub async fn get_song_lyrics(
    path: String,
    conn: Arc<Mutex<rusqlite::Connection>>,
) -> Result<String, String> {
    if !is_remote_uri(&path) {
        return Ok(read_song_lyrics_raw(&path));
    }
    let ctx = {
        let guard = conn.lock().map_err(|e| e.to_string())?;
        resolve_remote_lyrics_ctx(&path, &guard)
    };
    match ctx {
        Some(ctx) => Ok(read_remote_song_lyrics_raw(ctx).await),
        None => Ok(String::new()),
    }
}

fn decode_lyrics_file_bytes(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0xff, 0xfe]) {
        let (decoded, _, _) = UTF_16LE.decode(&bytes[2..]);
        return decoded.trim_start_matches('\u{feff}').to_string();
    }
    if bytes.starts_with(&[0xfe, 0xff]) {
        let (decoded, _, _) = UTF_16BE.decode(&bytes[2..]);
        return decoded.trim_start_matches('\u{feff}').to_string();
    }
    if let Ok(text) = std::str::from_utf8(bytes) {
        return text.trim_start_matches('\u{feff}').to_string();
    }

    let (decoded, _, _) = GBK.decode(bytes);
    decoded.trim_start_matches('\u{feff}').to_string()
}

/// 读取用户主动选择的 LRC 文件。只允许歌词扩展名，并限制大小以避免误选大文件。
pub fn read_lyrics_file(path: String) -> Result<String, String> {
    const MAX_LYRICS_FILE_SIZE: u64 = 2 * 1024 * 1024;
    let path_obj = Path::new(&path);
    let is_lrc = path_obj
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("lrc"));
    if !is_lrc {
        return Err("请选择 .lrc 歌词文件".to_string());
    }

    let metadata = fs::metadata(path_obj).map_err(|error| error.to_string())?;
    if !metadata.is_file() {
        return Err("所选路径不是文件".to_string());
    }
    if metadata.len() > MAX_LYRICS_FILE_SIZE {
        return Err("LRC 文件不能超过 2 MB".to_string());
    }

    let bytes = fs::read(path_obj).map_err(|error| error.to_string())?;
    Ok(decode_lyrics_file_bytes(&bytes))
}

pub async fn get_song_lyrics_payload(
    path: String,
    conn: Arc<Mutex<rusqlite::Connection>>,
) -> Result<String, String> {
    let raw = get_song_lyrics(path, conn).await?;
    let payload = build_structured_lyrics_payload(raw);
    serde_json::to_string(&payload).map_err(|e| e.to_string())
}

pub async fn get_song_lyrics_for_edit(path: String) -> Result<String, String> {
    if let Ok(tagged_file) = read_tagged_file_from_path(Path::new(&path)) {
        if let Some(lyrics) = extract_embedded_lyrics(&tagged_file) {
            let result = SongLyricsForEdit {
                lyrics,
                source: LyricsStorageSource::Embedded,
                source_path: None,
            };
            return serde_json::to_string(&result).map_err(|e| e.to_string());
        }
    }

    let path_obj = Path::new(&path);
    if let Some((content, lrc_path)) = read_sidecar_lrc_with_path(path_obj) {
        let result = SongLyricsForEdit {
            lyrics: content,
            source: LyricsStorageSource::Sidecar,
            source_path: Some(normalize_path(&lrc_path.to_string_lossy())),
        };
        return serde_json::to_string(&result).map_err(|e| e.to_string());
    }

    let result = SongLyricsForEdit {
        lyrics: String::new(),
        source: LyricsStorageSource::Empty,
        source_path: None,
    };
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

pub async fn save_song_lyrics(
    path: String,
    lyrics: String,
    source: LyricsStorageSource,
    source_path: Option<String>,
) -> Result<String, String> {
    let path_obj = Path::new(&path);
    if !path_obj.exists() {
        return Err("Song file does not exist".to_string());
    }

    let result = match source {
        LyricsStorageSource::Embedded => {
            let saved_path = write_embedded_lyrics(path_obj, lyrics.clone())?;
            SongLyricsForEdit {
                lyrics,
                source: LyricsStorageSource::Embedded,
                source_path: Some(saved_path),
            }
        }
        LyricsStorageSource::Sidecar | LyricsStorageSource::Empty => {
            let saved_path = write_sidecar_lyrics(path_obj, source_path, lyrics.clone())?;
            SongLyricsForEdit {
                lyrics,
                source: LyricsStorageSource::Sidecar,
                source_path: Some(saved_path),
            }
        }
    };

    serde_json::to_string(&result).map_err(|e| e.to_string())
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

    if let Some((container, codec, file_size)) = conn
        .query_row(
            "SELECT container, codec, file_size FROM songs WHERE path = ?1 LIMIT 1",
            params![&normalized_path],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()
        .map_err(|e| e.to_string())?
    {
        detail.container = container.filter(|value| !value.trim().is_empty());
        detail.codec = codec.filter(|value| !value.trim().is_empty());
        detail.file_size = file_size.and_then(|value| u64::try_from(value).ok());
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

pub fn show_in_folder(path: String) -> Result<(), String> {
    let validated = path_validator::validate_path(&path, None)?;
    let path_str = validated.to_string_lossy().to_string();
    #[cfg(target_os = "windows")]
    {
        Command::new("explorer")
            .args(["/select,", &path_str])
            .spawn()
            .map_err(|e| format!("Failed to open folder: {}", e))?;
    }
    #[cfg(target_os = "macos")]
    {
        Command::new("open")
            .args(["-R", &path_str])
            .spawn()
            .map_err(|e| format!("Failed to open folder: {}", e))?;
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(parent) = validated.parent() {
            Command::new("xdg-open")
                .arg(parent)
                .spawn()
                .map_err(|e| format!("Failed to open folder: {}", e))?;
        }
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn decode_lyrics_file_supports_utf8_bom_and_gbk() {
        assert_eq!(
            decode_lyrics_file_bytes(b"\xef\xbb\xbf[00:01.00]hello"),
            "[00:01.00]hello"
        );

        let (gbk, _, _) = GBK.encode("[00:01.00]中文歌词");
        assert_eq!(decode_lyrics_file_bytes(gbk.as_ref()), "[00:01.00]中文歌词");
    }

    #[test]
    fn remote_sidecar_lrc_path_uses_remote_song_parent_and_stem() {
        assert_eq!(
            remote_sidecar_lrc_path("/Artist/Album/Demo.flac").as_deref(),
            Some("/Artist/Album/Demo.lrc")
        );
    }

    #[tokio::test]
    async fn remote_lyrics_use_cached_sidecar_before_remote_lrc() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("xianyu_remote_lyrics_test_{unique}"));
        fs::create_dir_all(&dir).unwrap();
        let cached_audio = dir.join("Demo.flac");
        let cached_lrc = dir.join("Demo.lrc");
        fs::write(&cached_audio, b"not real audio").unwrap();
        fs::write(&cached_lrc, "[00:01.00]cached lyric").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE remote_sources (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                provider TEXT NOT NULL,
                base_url TEXT NOT NULL,
                username TEXT,
                password TEXT,
                root_path TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                last_sync_at INTEGER,
                last_sync_error TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE remote_files (
                source_id TEXT NOT NULL,
                remote_path TEXT NOT NULL,
                remote_uri TEXT NOT NULL,
                etag TEXT
            );
            CREATE TABLE songs (
                path TEXT PRIMARY KEY,
                cache_path TEXT
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO remote_sources (
                id, name, provider, base_url, root_path, enabled, created_at, updated_at
             ) VALUES ('source', 'Source', 'webdav', 'https://dav.invalid', '/', 1, 0, 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO remote_files (source_id, remote_path, remote_uri)
             VALUES ('source', '/Artist/Album/Demo.flac', 'remote://source/Artist/Album/Demo.flac')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO songs (path, cache_path) VALUES (?1, ?2)",
            params![
                "remote://source/Artist/Album/Demo.flac",
                cached_audio.to_string_lossy()
            ],
        )
        .unwrap();

        let ctx = resolve_remote_lyrics_ctx("remote://source/Artist/Album/Demo.flac", &conn).unwrap();
        let lyrics = read_remote_song_lyrics_raw(ctx).await;

        assert_eq!(lyrics, "[00:01.00]cached lyric");
        let _ = fs::remove_dir_all(dir);
    }
}