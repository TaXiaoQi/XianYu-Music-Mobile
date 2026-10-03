//! 歌词持久化 I/O：sidecar LRC 读写、嵌入式标签写入、远程（WebDAV）歌词读取。

use super::build_structured_lyrics_payload;
use crate::music::tags::{
    extract_embedded_lyrics, extract_embedded_lyrics_match, read_tagged_file_from_path,
};
use crate::music::types::{LyricsStorageSource, SongLyricsForEdit};
use crate::music::utils::normalize_path;
use crate::remote::cache::is_remote_uri;
use crate::remote::repository::{get_song_cache_path, get_source_for_remote_uri};
use crate::remote::webdav;
use encoding_rs::{GBK, UTF_16BE, UTF_16LE};
use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::tag::{ItemKey, ItemValue, Tag, TagItem};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

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

pub(crate) fn decode_lyrics_file_bytes(bytes: &[u8]) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::{params, Connection};
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
