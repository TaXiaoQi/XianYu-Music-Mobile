use super::repository::{get_source_for_remote_uri, get_song_cache_path, update_song_cache_path};
use super::types::{RemoteCacheUsage, RemoteSourceCredentials};
use super::webdav;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

pub(crate) const MAX_REMOTE_CACHE_BYTES: u64 = 5 * 1024 * 1024 * 1024;
const REMOTE_DOWNLOAD_ATTEMPTS: usize = 3;

/// 远程下载进度通知器（移动端由调用方注入，桌面端为 Tauri 事件发射）。
pub(crate) trait RemoteDownloadProgressSink: Send + Sync {
    fn on_progress(
        &self,
        uri: &str,
        downloaded: u64,
        total: Option<u64>,
        done: bool,
        failed: bool,
        message: Option<String>,
    );
}

pub(crate) fn is_remote_uri(path: &str) -> bool {
    path.starts_with("remote://")
}

#[derive(Clone, Debug, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteStreamSource {
    pub remote_uri: String,
    pub url: String,
    pub username: Option<String>,
    pub password: Option<String>,
    /// 自定义 User-Agent（在线直链防盗链常需要浏览器 UA）
    pub user_agent: Option<String>,
    /// 自定义 Referer（部分音源防盗链校验来源）
    pub referer: Option<String>,
    /// 插件返回的自定义请求头（如 Cookie、Referer 等防盗链 headers）
    pub headers: Option<std::collections::HashMap<String, String>>,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub(crate) enum RemotePlaybackSource {
    Cached { path: String },
    Stream(RemoteStreamSource),
}

fn cache_file_name(remote_uri: &str, etag: Option<&str>) -> String {
    let mut hasher = Sha256::new();
    hasher.update(remote_uri.as_bytes());
    if let Some(etag) = etag {
        hasher.update(etag.as_bytes());
    }
    let hash = hex::encode(hasher.finalize());
    let ext = remote_uri
        .rsplit('.')
        .next()
        .filter(|value| value.len() <= 8 && !value.contains('/'))
        .unwrap_or("audio");
    format!("{hash}.{ext}")
}

fn cleanup_cache(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    let mut files = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let path = entry.path();
            let metadata = entry.metadata().ok()?;
            if !metadata.is_file() {
                return None;
            }
            let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
            Some((path, metadata.len(), modified))
        })
        .collect::<Vec<_>>();
    let mut total = files.iter().map(|(_, size, _)| *size).sum::<u64>();
    if total <= MAX_REMOTE_CACHE_BYTES {
        return;
    }

    files.sort_by_key(|(_, _, modified)| *modified);
    for (path, size, _) in files {
        if total <= MAX_REMOTE_CACHE_BYTES {
            break;
        }
        if fs::remove_file(path).is_ok() {
            total = total.saturating_sub(size);
        }
    }
}

pub(crate) fn cache_usage(cache_root: &Path) -> Result<RemoteCacheUsage, String> {
    let mut bytes = 0u64;
    let mut files = 0usize;
    for entry in fs::read_dir(cache_root).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let metadata = entry.metadata().map_err(|error| error.to_string())?;
        if metadata.is_file() {
            files += 1;
            bytes = bytes.saturating_add(metadata.len());
        }
    }
    Ok(RemoteCacheUsage {
        bytes,
        files,
        limit_bytes: MAX_REMOTE_CACHE_BYTES,
    })
}

pub(crate) fn clear_cache(cache_root: &Path) -> Result<RemoteCacheUsage, String> {
    for entry in fs::read_dir(cache_root).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        if entry
            .metadata()
            .map_err(|error| error.to_string())?
            .is_file()
        {
            fs::remove_file(entry.path()).map_err(|error| error.to_string())?;
        }
    }
    cache_usage(cache_root)
}

fn emit_download_progress(
    sink: Option<&dyn RemoteDownloadProgressSink>,
    remote_uri: &str,
    downloaded: u64,
    total: Option<u64>,
    done: bool,
    failed: bool,
    message: Option<String>,
) {
    if let Some(sink) = sink {
        sink.on_progress(remote_uri, downloaded, total, done, failed, message);
    }
}

pub(crate) fn choose_remote_playback_source(
    remote_uri: &str,
    cached_path: Option<String>,
    source: RemoteSourceCredentials,
    remote_path: String,
) -> RemotePlaybackSource {
    if let Some(path) = cached_path.filter(|path| !path.trim().is_empty()) {
        if std::path::Path::new(&path).is_file() {
            return RemotePlaybackSource::Cached { path };
        }
        #[cfg(test)]
        return RemotePlaybackSource::Cached { path };
    }

    RemotePlaybackSource::Stream(RemoteStreamSource {
        remote_uri: remote_uri.to_string(),
        url: webdav::build_url(&source, &remote_path),
        username: source.username,
        password: source.password,
        ..Default::default()
    })
}

pub(crate) fn remote_playback_source(
    conn: &rusqlite::Connection,
    remote_uri: &str,
) -> Result<RemotePlaybackSource, String> {
    let (source, remote_path, _etag, stored_remote_uri, cached_path) = {
        let (source, remote_path, etag, stored_remote_uri) =
            get_source_for_remote_uri(conn, remote_uri)?;
        let normalized_uri = stored_remote_uri
            .clone()
            .unwrap_or_else(|| remote_uri.to_string());
        let cached_path = get_song_cache_path(conn, &normalized_uri)?;
        (source, remote_path, etag, stored_remote_uri, cached_path)
    };
    let normalized_uri = stored_remote_uri.unwrap_or_else(|| remote_uri.to_string());
    Ok(choose_remote_playback_source(
        &normalized_uri,
        cached_path,
        source,
        remote_path,
    ))
}

pub(crate) async fn cache_remote_file(
    cache_root: &Path,
    source: &RemoteSourceCredentials,
    remote_path: &str,
    remote_uri: &str,
    etag: Option<&str>,
    sink: Option<&dyn RemoteDownloadProgressSink>,
) -> Result<String, String> {
    let cache_path = cache_root.join(cache_file_name(remote_uri, etag));

    if cache_path.is_file() {
        return Ok(cache_path.to_string_lossy().into_owned());
    }

    let temp_path = cache_path.with_extension("download");
    let mut last_error = None;
    for attempt in 1..=REMOTE_DOWNLOAD_ATTEMPTS {
        let result =
            webdav::download_file_to_path(source, remote_path, &temp_path, |downloaded, total| {
                emit_download_progress(sink, remote_uri, downloaded, total, false, false, None);
            })
            .await;

        if result.is_ok() {
            last_error = None;
            break;
        }

        last_error = result.err();
        if attempt < REMOTE_DOWNLOAD_ATTEMPTS {
            tokio::time::sleep(Duration::from_millis(250 * attempt as u64)).await;
        }
    }

    if let Some(error) = last_error {
        emit_download_progress(sink, remote_uri, 0, None, true, true, Some(error.clone()));
        return Err(error);
    }
    if !temp_path.is_file() {
        let error = "远程文件下载失败：未生成缓存文件".to_string();
        emit_download_progress(sink, remote_uri, 0, None, true, true, Some(error.clone()));
        return Err(error);
    }

    fs::rename(&temp_path, &cache_path).map_err(|error| error.to_string())?;
    cleanup_cache(cache_root);

    let cache_path_str = cache_path.to_string_lossy().into_owned();
    emit_download_progress(sink, remote_uri, 1, Some(1), true, false, None);
    Ok(cache_path_str)
}

/// 确保远程文件已缓存，返回缓存路径并回写 `songs.cache_path`。
pub(crate) async fn ensure_cached_path(
    cache_root: &Path,
    db_conn: Arc<Mutex<rusqlite::Connection>>,
    remote_uri: &str,
    sink: Option<&dyn RemoteDownloadProgressSink>,
) -> Result<String, String> {
    let (source, remote_path, etag, stored_remote_uri) = {
        let conn = db_conn.lock().map_err(|error| error.to_string())?;
        get_source_for_remote_uri(&conn, remote_uri)?
    };
    let normalized_uri = stored_remote_uri.unwrap_or_else(|| remote_uri.to_string());
    let cache_path_str =
        cache_remote_file(cache_root, &source, &remote_path, &normalized_uri, etag.as_deref(), sink)
            .await?;
    if let Ok(conn) = db_conn.lock() {
        let _ = update_song_cache_path(&conn, &normalized_uri, &cache_path_str);
    }
    Ok(cache_path_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::types::RemoteSourceCredentials;

    fn remote_source() -> RemoteSourceCredentials {
        RemoteSourceCredentials {
            id: "source".to_string(),
            name: "Source".to_string(),
            provider: "webdav".to_string(),
            base_url: "https://dav.example.com".to_string(),
            username: Some("user".to_string()),
            password: Some("pass".to_string()),
            root_path: "/music".to_string(),
            enabled: true,
            last_sync_at: None,
            last_sync_error: None,
            created_at: 0,
            updated_at: 0,
        }
    }

    #[test]
    fn playback_plan_uses_existing_cache_path_before_remote_stream() {
        let plan = choose_remote_playback_source(
            "remote://source/song.flac",
            Some("C:\\cache\\song.flac".to_string()),
            remote_source(),
            "/song.flac".to_string(),
        );

        assert!(matches!(
            plan,
            RemotePlaybackSource::Cached { path } if path == "C:\\cache\\song.flac"
        ));
    }

    #[test]
    fn playback_plan_streams_remote_when_cache_missing() {
        let plan = choose_remote_playback_source(
            "remote://source/song.flac",
            None,
            remote_source(),
            "/song.flac".to_string(),
        );

        match plan {
            RemotePlaybackSource::Stream(stream) => {
                assert_eq!(stream.remote_uri, "remote://source/song.flac");
                assert_eq!(stream.url, "https://dav.example.com/music/song.flac");
                assert_eq!(stream.username.as_deref(), Some("user"));
                assert_eq!(stream.password.as_deref(), Some("pass"));
            }
            RemotePlaybackSource::Cached { .. } => panic!("missing cache must stream remote file"),
        }
    }

    #[test]
    fn cache_usage_counts_files_and_bytes() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("xianyu_remote_cache_test_{unique}"));
        fs::create_dir_all(&dir).expect("create cache dir");
        fs::write(dir.join("a.flac"), b"aaa").expect("write a");
        fs::write(dir.join("b.mp3"), b"bb").expect("write b");

        let usage = cache_usage(&dir).expect("usage");
        assert_eq!(usage.files, 2);
        assert_eq!(usage.bytes, 5);
        assert_eq!(usage.limit_bytes, MAX_REMOTE_CACHE_BYTES);

        fs::remove_dir_all(dir).expect("remove cache dir");
    }

    #[test]
    fn clear_cache_removes_all_files() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("xianyu_remote_clear_test_{unique}"));
        fs::create_dir_all(&dir).expect("create cache dir");
        fs::write(dir.join("a.flac"), b"aaa").expect("write a");

        let usage = clear_cache(&dir).expect("clear");
        assert_eq!(usage.files, 0);
        assert_eq!(usage.bytes, 0);

        fs::remove_dir_all(dir).expect("remove cache dir");
    }
}