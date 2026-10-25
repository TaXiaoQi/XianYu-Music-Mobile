use super::cache;
use super::repository::{replace_remote_files, update_song_cache_path, update_sync_status};
use super::types::{RemoteFileEntry, RemoteSourceCredentials, RemoteSyncResult};
use super::webdav;
use crate::music::covers;
use crate::music::scanner::{apply_scan_changes, parse_song_from_file};
use crate::music::types::Song;
use crate::music::utils::{i64_to_bool, i64_to_u64_opt, i64_to_u8_opt};
use rusqlite::params;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};

#[derive(Clone)]
struct RemoteSongSnapshot {
	etag: Option<String>,
	size: u64,
	modified_at: Option<String>,
	song: Option<Song>,
}

fn extension_from_path(path: &str) -> String {
	path
		.rsplit('.')
		.next()
		.map(|value| value.to_ascii_lowercase())
		.unwrap_or_default()
}

fn title_from_name(name: &str) -> String {
	crate::filename_meta::title_from_name(name)
}

/// 前导曲目序号与 feat 清理、文件名切分统一走
/// `crate::filename_meta` 公共模块（本地曲库/远程/网盘三线共用）。

/// percent-decode（与 cloud http 同语义：'+' 不转空格；解码失败原样返回）。
/// WebDAV 路径常带 %XX 编码的中文目录名，不解码则专辑名乱码。
fn percent_decode(s: &str) -> String {
	let b = s.as_bytes();
	let mut out: Vec<u8> = Vec::with_capacity(b.len());
	let mut i = 0;
	while i < b.len() {
		if b[i] == b'%' && i + 2 < b.len() {
			let hi = (b[i + 1] as char).to_digit(16);
			let lo = (b[i + 2] as char).to_digit(16);
			if let (Some(h), Some(l)) = (hi, lo) {
				out.push((h * 16 + l) as u8);
				i += 3;
				continue;
			}
		}
		out.push(b[i]);
		i += 1;
	}
	String::from_utf8_lossy(&out).into_owned()
}

/// 泛音乐目录名（声影同款精选）：歌曲所在目录命中这些名字时没有专辑
/// 语义，专辑名向上一级回退，避免「专辑=Music」。
const GENERIC_FOLDER_NAMES: &[&str] = &[
	"music",
	"musics",
	"audios",
	"audio",
	"songs",
	"song",
	"netdisk",
	"cloud",
	"webdav",
	"temp",
	"tmp",
	"download",
	"downloads",
	"本地音乐",
	"我的音乐",
	"无损音乐",
	"车载音乐",
	"音乐",
	"下载",
	"资源",
	"新建文件夹",
	"未分类",
	"根目录",
	"全部",
];

fn album_from_remote_path(path: &str) -> String {
	let mut segments = path
		.trim_matches('/')
		.split('/')
		.filter(|segment| !segment.trim().is_empty())
		.collect::<Vec<_>>();
	let mut album = "未知专辑".to_string();
	if segments.len() >= 2 {
		segments.pop(); // 末段为文件名，歌曲所在目录及其上一级参与回退
		for segment in segments.iter().rev().take(2) {
			let name = percent_decode(segment).trim().to_string();
			if name.is_empty() {
				continue;
			}
			let is_generic = GENERIC_FOLDER_NAMES
				.iter()
				.any(|g| name.eq_ignore_ascii_case(g));
			if !is_generic {
				album = name;
				break;
			}
		}
	}
	album
}

fn is_unknown_text(value: &str, unknown: &str) -> bool {
	let trimmed = value.trim();
	trimmed.is_empty() || trimmed == unknown
}

fn split_filename_title_artist(name: &str) -> Option<(String, String)> {
	crate::filename_meta::split_filename_title_artist(name)
}

fn refresh_artist_fields(song: &mut Song, artist: String) {
	// 多艺人拆分与本地曲库同构（A/B、A、B、A& B、A feat. B → 多歌手），
	// 主 artist 字段保持整串兼容既有单值消费方。
	let names = crate::music::scanner::split_artist_names(&artist);
	song.artist = artist.clone();
	song.artist_names = names.clone();
	song.effective_artist_names = names;
	song.album_artist = artist;
	song.album_key = format!(
		"{}::{}",
		song.album.to_lowercase(),
		song.album_artist.to_lowercase()
	);
}

fn apply_filename_metadata_fallback(song: &mut Song, file: &RemoteFileEntry) {
	let needs_artist = is_unknown_text(&song.artist, "未知歌手");
	let needs_title = song.title.trim().is_empty() || song.title == title_from_name(&file.name);

	if !(needs_artist || needs_title) {
		return;
	}

	let Some((title, artist)) = split_filename_title_artist(&file.name) else {
		return;
	};

	if needs_title {
		song.title = title;
	}
	if needs_artist {
		refresh_artist_fields(song, artist);
	}
}

fn song_from_remote_file(source: &RemoteSourceCredentials, file: &RemoteFileEntry) -> Song {
	let remote_uri = file.remote_uri(&source.id);
	let title = title_from_name(&file.name);
	let artist = "未知歌手".to_string();
	let album = album_from_remote_path(&file.remote_path);

	let mut song = Song {
		id: None,
		artist_avatar_bytes: None,
		name: file.name.clone(),
		title,
		path: remote_uri,
		artist: artist.clone(),
		artist_names: vec![artist.clone()],
		effective_artist_names: vec![artist.clone()],
		album: album.clone(),
		album_artist: artist.clone(),
		album_key: format!("{}::{}", album.to_lowercase(), artist.to_lowercase()),
		is_various_artists_album: false,
		collapse_artist_credits: false,
		duration: 0,
		cover_thumb_path: None,
		bitrate: 0,
		sample_rate: 0,
		bit_depth: None,
		format: extension_from_path(&file.remote_path),
		container: None,
		codec: None,
		file_size: file.size,
		track_number: None,
		disc_number: None,
		added_at: None,
		file_modified_at: None,
		cue_source_path: None,
		cue_start_offset: None,
		cue_end_offset: None,
		comment: None,
		artist_avatar_path: None,
	};
	apply_filename_metadata_fallback(&mut song, file);
	song
}

fn song_for_remote_index(source: &RemoteSourceCredentials, file: &RemoteFileEntry) -> Song {
	song_from_remote_file(source, file)
}

pub(crate) fn song_from_cached_remote_file( // song_from_cached_remote_file
	source: &RemoteSourceCredentials,
	file: &RemoteFileEntry,
	cache_path: &Path,
) -> Option<Song> { // 实现
	let remote_uri = file.remote_uri(&source.id);
	let format = extension_from_path(&file.remote_path);
	let mut parsed = parse_song_from_file(cache_path, &remote_uri, &format)?;
	let fallback = song_from_remote_file(source, file);

	parsed.name = file.name.clone();
	parsed.format = if parsed.format.trim().is_empty() {
		fallback.format
	} else {
		parsed.format
	};
	parsed.file_size = if file.size > 0 {
		file.size
	} else {
		parsed.file_size
	};
	parsed.added_at = None;
	parsed.file_modified_at = None;

	let cache_stem = cache_path
		.file_stem()
		.map(|value| value.to_string_lossy().to_string())
		.unwrap_or_default();
	if parsed.title.trim().is_empty() || (!cache_stem.is_empty() && parsed.title == cache_stem) {
		parsed.title = fallback.title;
	}
	if is_unknown_text(&parsed.artist, "未知歌手") {
		parsed.artist = fallback.artist;
	}
	if parsed.artist_names.is_empty() {
		parsed.artist_names = fallback.artist_names;
	}
	if parsed.effective_artist_names.is_empty() {
		parsed.effective_artist_names = parsed.artist_names.clone();
	}
	if is_unknown_text(&parsed.album, "未知专辑") {
		parsed.album = fallback.album;
	}
	if parsed.album_artist.trim().is_empty() {
		parsed.album_artist = parsed.artist.clone();
	}
	if parsed.album_key.trim().is_empty() {
		parsed.album_key = format!(
			"{}::{}",
			parsed.album.to_lowercase(),
			parsed.album_artist.to_lowercase()
		);
	}
	apply_filename_metadata_fallback(&mut parsed, file);

	Some(parsed)
}

async fn cache_and_parse_remote_song(
	cache_root: &Path,
	source: &RemoteSourceCredentials,
	file: &RemoteFileEntry,
) -> (Song, Option<String>) {
	let remote_uri = file.remote_uri(&source.id);
	let cache_path = cache::cache_remote_file(
		cache_root,
		source,
		&file.remote_path,
		&remote_uri,
		file.etag.as_deref(),
	)
	.await;

	match cache_path {
		Ok(cache_path) => {
			let parsed = song_from_cached_remote_file(source, file, Path::new(&cache_path))
				.unwrap_or_else(|| song_for_remote_index(source, file));
			(parsed, Some(cache_path))
		}
		Err(_) => (song_for_remote_index(source, file), None),
	}
}

fn deserialize_string_list(raw: Option<String>) -> Vec<String> { // deserialize_string_list
	raw
		.and_then(|value| serde_json::from_str::<Vec<String>>(&value).ok())
		.unwrap_or_default()
}

fn i64_to_u32(value: Option<i64>) -> u32 { // i64_to_u32
	value.unwrap_or(0).clamp(0, u32::MAX as i64) as u32
}

fn remote_file_needs_refresh(
	snapshot: Option<&RemoteSongSnapshot>,
	file: &RemoteFileEntry,
) -> bool {
	let Some(snapshot) = snapshot else {
		return true;
	};
	if snapshot.song.is_none() {
		return true;
	}
	if snapshot
		.song
		.as_ref()
		.map(|song| song.duration == 0 || song.bitrate == 0 || song.sample_rate == 0)
		.unwrap_or(true)
	{
		return true;
	}

	match (snapshot.etag.as_deref(), file.etag.as_deref()) {
		(Some(previous), Some(current)) if !previous.is_empty() && !current.is_empty() => {
			previous != current
		}
		_ => {
			snapshot.size != file.size
				|| match (snapshot.modified_at.as_deref(), file.modified_at.as_deref()) {
					(Some(previous), Some(current)) => previous != current,
					_ => false,
				}
		}
	}
}

fn load_remote_song_snapshots(
	conn: &rusqlite::Connection,
	source_id: &str,
) -> Result<HashMap<String, RemoteSongSnapshot>, String> {
	let mut stmt = conn
		.prepare(
			"SELECT
                rf.remote_uri, 
                rf.etag,
                rf.size,
                rf.modified_at, 
                s.id,
                s.path,
                s.title,
                s.artist,
                s.artist_names, 
                s.effective_artist_names, 
                s.album,
                s.album_artist, 
                s.album_key, 
                s.is_various_artists_album, 
                s.collapse_artist_credits, 
                s.duration,
                s.cover_thumb_path, 
                s.bitrate,
                s.sample_rate, 
                s.bit_depth, 
                s.format,
                s.container, 
                s.codec,
                s.file_size, 
                s.track_number, 
                s.disc_number, 
                s.added_at,
                s.file_modified_at, 
                s.comment
             FROM remote_files rf 
             LEFT JOIN songs s ON s.path = rf.remote_uri 
             WHERE rf.source_id = ?1 AND rf.is_audio = 1", 
		)
		.map_err(|error| error.to_string())?;

	let rows = stmt
		.query_map([source_id], |row| {
			let remote_uri: String = row.get(0)?;
			let song_path: Option<String> = row.get(5)?;
			let song = match song_path {
				Some(path) => {
					let artist_names = deserialize_string_list(row.get::<_, Option<String>>(8)?);
					let effective_artist_names = deserialize_string_list(row.get::<_, Option<String>>(9)?);
					let name = Path::new(&path)
						.file_name()
						.map(|name| name.to_string_lossy().into_owned())
						.unwrap_or_else(|| path.clone());

					Some(Song {
						id: row.get::<_, Option<i64>>(4)?,
						artist_avatar_bytes: None,
						name,
						path,
						title: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
						artist: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
						artist_names,
						effective_artist_names,
						album: row.get::<_, Option<String>>(10)?.unwrap_or_default(),
						album_artist: row.get::<_, Option<String>>(11)?.unwrap_or_default(),
						album_key: row.get::<_, Option<String>>(12)?.unwrap_or_default(),
						is_various_artists_album: i64_to_bool(row.get::<_, Option<i64>>(13)?),
						collapse_artist_credits: i64_to_bool(row.get::<_, Option<i64>>(14)?),
						duration: i64_to_u32(row.get::<_, Option<i64>>(15)?),
						cover_thumb_path: row.get::<_, Option<String>>(16)?,
						bitrate: i64_to_u32(row.get::<_, Option<i64>>(17)?),
						sample_rate: i64_to_u32(row.get::<_, Option<i64>>(18)?),
						bit_depth: i64_to_u8_opt(row.get::<_, Option<i64>>(19)?),
						format: row.get::<_, Option<String>>(20)?.unwrap_or_default(),
						container: row.get::<_, Option<String>>(21)?,
						codec: row.get::<_, Option<String>>(22)?,
						file_size: row.get::<_, Option<i64>>(23)?.unwrap_or(0).max(0) as u64,
						track_number: row.get::<_, Option<String>>(24)?,
						disc_number: row.get::<_, Option<String>>(25)?,
						added_at: i64_to_u64_opt(row.get::<_, Option<i64>>(26)?),
						file_modified_at: i64_to_u64_opt(row.get::<_, Option<i64>>(27)?),
						cue_source_path: None,
						cue_start_offset: None,
						cue_end_offset: None,
						comment: row.get::<_, Option<String>>(28)?,
						artist_avatar_path: None,
					})
				}
				None => None,
			};

			Ok((
				remote_uri,
				RemoteSongSnapshot {
					etag: row.get::<_, Option<String>>(1)?,
					size: row.get::<_, i64>(2)?.max(0) as u64,
					modified_at: row.get::<_, Option<String>>(3)?,
					song,
				},
			))
		})
		.map_err(|error| error.to_string())?;

	let mut snapshots = HashMap::new();
	for row in rows {
		let (remote_uri, snapshot) = row.map_err(|error| error.to_string())?;
		snapshots.insert(remote_uri, snapshot);
	}
	Ok(snapshots)
}

fn existing_remote_song_paths(
	conn: &rusqlite::Connection,
	source_id: &str,
) -> Result<Vec<String>, String> {
	let mut stmt = conn
		.prepare("SELECT path FROM songs WHERE remote_source_id = ?1")
		.map_err(|error| error.to_string())?;
	let rows = stmt
		.query_map([source_id], |row| row.get::<_, String>(0))
		.map_err(|error| error.to_string())?;
	Ok(rows.filter_map(Result::ok).collect())
}

fn mark_remote_songs(
	conn: &rusqlite::Connection,
	source: &RemoteSourceCredentials,
	files: &[RemoteFileEntry],
) -> Result<(), String> { // 实现
	let mut stmt = conn
		.prepare(
			"UPDATE songs
             SET source_type = 'remote', 
                 remote_source_id = ?1, 
                 remote_uri = ?2, 
                 remote_etag = ?3 
             WHERE path = ?2", 
		)
		.map_err(|error| error.to_string())?;

	for file in files {
		let remote_uri = file.remote_uri(&source.id);
		stmt
			.execute(params![&source.id, remote_uri, &file.etag])
			.map_err(|error| error.to_string())?;
	}

	Ok(())
}

/// 目录封面候选名（声影 g13 同款：固定名优先，按此序首个命中即用）。
const DIR_COVER_NAMES: [&str; 10] = [
	"cover.jpg",
	"cover.jpeg",
	"cover.png",
	"cover.webp",
	"folder.jpg",
	"folder.png",
	"folder.webp",
	"front.jpg",
	"album.jpg",
	"albumart.jpg",
];

/// 目录封面候选路径：固定名 + 「目录名.图扩展名」专辑同名词变体
/// （remote_path 为 %XX 编码形态，目录末段解码后参与匹配）。
fn dir_cover_candidates(dir_path: &str) -> Vec<String> {
	let mut candidates: Vec<String> = DIR_COVER_NAMES
		.iter()
		.map(|name| format!("{dir_path}/{name}"))
		.collect();
	let dir_name = dir_path.rsplit('/').next().unwrap_or("").trim();
	if !dir_name.is_empty() {
		let decoded = percent_decode(dir_name);
		if !decoded.is_empty() && decoded != dir_name {
			for ext in ["jpg", "jpeg", "png", "webp"] {
				candidates.push(format!("{dir_path}/{decoded}.{ext}"));
			}
		}
	}
	candidates
}

/// 探测并落盘目录封面（声影 g13 同款规则）：按候选序 GET 同目录图片，
/// magic byte 校验 + 内容指纹共享缓存（save_embedded_cover_from_bytes，
/// 同图跨曲/跨会话复用）落盘，返回值直接作 songs.cover_thumb_path。
/// 无封面的目录由调用方按目录缓存只探测一轮，失败静默。
async fn fetch_dir_cover(
	source: &RemoteSourceCredentials,
	dir_path: &str,
	covers_dir: &Path,
) -> Option<String> {
	const MAX_COVER_BYTES: usize = 5 * 1024 * 1024;
	for path in dir_cover_candidates(dir_path) {
		if let Some(bytes) = webdav::download_small_file(source, &path, MAX_COVER_BYTES).await {
			if let Some(cover_path) =
				covers::save_embedded_cover_from_bytes(&bytes, covers_dir)
			{
				return Some(cover_path);
			}
		}
	}
	None
}

pub(crate) async fn sync_source( // 实现
	cache_root: &Path,
	db_path: &str,
	db_conn: Arc<Mutex<rusqlite::Connection>>,
	source: RemoteSourceCredentials,
) -> Result<RemoteSyncResult, String> { // 实现
	let files = match webdav::collect_audio_files(&source).await {
		Ok(files) => files,
		Err(error) => {
			if let Ok(conn) = db_conn.lock() {
				let _ = update_sync_status(&conn, &source.id, Some(&error));
			}
			return Err(error);
		}
	};
	let snapshots = {
		let conn = db_conn.lock().map_err(|error| error.to_string())?;
		match load_remote_song_snapshots(&conn, &source.id) {
			Ok(snapshots) => snapshots,
			Err(error) => {
				let _ = update_sync_status(&conn, &source.id, Some(&error));
				return Err(error);
			}
		}
	};

	let mut songs = Vec::with_capacity(files.len());
	let mut cache_updates = Vec::new();
	// 目录封面（声影 g13 同款）：同目录歌曲共享一张封面，按目录缓存探测
	// 结果——每目录至多一轮候选 GET（命中即停/全 404 放弃），不重复探测。
	let covers_dir = crate::music::scanner::derive_cover_cache_dir(db_path)
		.unwrap_or_else(|| cache_root.join("cover_cache"));
	let mut dir_covers: HashMap<String, Option<String>> = HashMap::new();
	for file in files.iter() {
		let remote_uri = file.remote_uri(&source.id);
		if let Some(snapshot) = snapshots.get(&remote_uri) {
			if !remote_file_needs_refresh(Some(snapshot), file) {
				if let Some(song) = snapshot.song.clone() {
					songs.push(song);
					continue;
				}
			}
		}
		let (mut song, cache_path) = cache_and_parse_remote_song(cache_root, &source, file).await;
		if let Some(cache_path) = cache_path {
			cache_updates.push((remote_uri, cache_path));
		}
		if song.cover_thumb_path.is_none() {
			let dir_path = file.remote_path.trim_end_matches('/');
			let dir_path = match dir_path.rfind('/') {
				Some(index) if index > 0 => &dir_path[..index],
				_ => "/",
			}
			.to_string();
			let cover = match dir_covers.get(&dir_path) {
				Some(cached) => cached.clone(),
				None => {
					let found = fetch_dir_cover(&source, &dir_path, &covers_dir).await;
					dir_covers.insert(dir_path.clone(), found.clone());
					found
				}
			};
			song.cover_thumb_path = cover;
		}
		songs.push(song);
	}

	let write_result = (|| -> Result<(), String> {
		let mut conn = db_conn.lock().map_err(|error| error.to_string())?;
		let next_paths = songs
			.iter()
			.map(|song| song.path.clone())
			.collect::<HashSet<_>>();
		let to_delete = existing_remote_song_paths(&conn, &source.id)?
			.into_iter()
			.filter(|path| !next_paths.contains(path))
			.collect::<Vec<_>>();

		replace_remote_files(&mut conn, &source.id, &files)?;
		apply_scan_changes(&mut conn, &songs, &[], &to_delete, None)?;
		mark_remote_songs(&conn, &source, &files)?;
		for (remote_uri, cache_path) in &cache_updates {
			update_song_cache_path(&conn, remote_uri, cache_path)?;
		}
		update_sync_status(&conn, &source.id, None)?;
		Ok(())
	})();

	if let Err(error) = write_result {
		if let Ok(conn) = db_conn.lock() {
			let _ = update_sync_status(&conn, &source.id, Some(&error));
		}
		return Err(error);
	}

	Ok(RemoteSyncResult {
		source_id: source.id,
		indexed_files: files.len(),
		audio_files: files.len(),
		parsed_songs: songs.len(),
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn dir_cover_candidates_fixed_names_first_then_album_named() {
		// 固定名优先（保持声明序），目录名非编码时不加同名词变体
		let candidates = dir_cover_candidates("/music/叶惠敏精选");
		assert_eq!(candidates.first().map(String::as_str), Some("/music/叶惠敏精选/cover.jpg"));
		assert_eq!(candidates.len(), DIR_COVER_NAMES.len());
		// 中文 %XX 编码目录：追加「目录名.扩展名」变体（声影同款）
		let candidates = dir_cover_candidates("/music/%E5%8F%B6%E6%83%A0%E6%95%8F");
		assert_eq!(candidates.len(), DIR_COVER_NAMES.len() + 4);
		assert_eq!(
			candidates.last().map(String::as_str),
			Some("/music/%E5%8F%B6%E6%83%A0%E6%95%8F/叶惠敏.webp")
		);
	}

	#[test]
	fn album_falls_back_past_generic_folders_and_decodes_percent() {
		// 中文目录 %XX 编码解码
		assert_eq!(
			album_from_remote_path("/music/%E5%8F%B6%E6%83%A0%E6%95%8F/demo.flac"),
			"叶惠敏".to_string()
		);
		// 泛目录名向上一级回退
		assert_eq!(
			album_from_remote_path("/音乐/周杰伦/晴天.flac"),
			"周杰伦".to_string()
		);
		// 整条路径都是泛目录 → 未知专辑
		assert_eq!(
			album_from_remote_path("/music/temp/demo.flac"),
			"未知专辑".to_string()
		);
		// 普通两级目录行为与旧版一致
		assert_eq!(
			album_from_remote_path("/叶惠敏/晴天/demo.flac"),
			"晴天".to_string()
		);
	}

	fn remote_file(etag: Option<&str>, size: u64, modified_at: Option<&str>) -> RemoteFileEntry {
		RemoteFileEntry {
			remote_path: "/demo.flac".to_string(),
			name: "demo.flac".to_string(),
			size,
			etag: etag.map(ToOwned::to_owned),
			modified_at: modified_at.map(ToOwned::to_owned),
			is_dir: false,
		}
	}

	fn remote_source() -> RemoteSourceCredentials {
		RemoteSourceCredentials {
			id: "source".to_string(),
			name: "Source".to_string(),
			provider: "webdav".to_string(),
			base_url: "https://example.com".to_string(),
			username: None,
			password: None,
			root_path: "/".to_string(),
			enabled: true,
			last_sync_at: None,
			last_sync_error: None,
			created_at: 0,
			updated_at: 0,
		}
	}

	fn complete_remote_song() -> Song {
		let mut song = song_from_remote_file(
			&remote_source(),
			&remote_file(Some("etag-a"), 1024, Some("Mon, 04 May 2026 10:00:00 GMT")),
		);
		song.duration = 180;
		song.bitrate = 320;
		song.sample_rate = 44_100;
		song
	}

	#[test]
	fn unchanged_remote_file_with_existing_song_does_not_need_refresh() {
		let snapshot = RemoteSongSnapshot {
			etag: Some("etag-a".to_string()),
			size: 1024,
			modified_at: Some("Mon, 04 May 2026 10:00:00 GMT".to_string()),
			song: Some(complete_remote_song()),
		};

		assert!(!remote_file_needs_refresh(
			Some(&snapshot),
			&remote_file(Some("etag-a"), 2048, Some("changed"))
		));
	}

	#[test]
	fn first_index_song_uses_remote_file_without_requiring_metadata_download() {
		let source = remote_source();
		let file = remote_file(
			Some("etag-a"),
			12_345,
			Some("Mon, 04 May 2026 10:00:00 GMT"),
		);

		let song = song_for_remote_index(&source, &file);

		assert_eq!(song.path, "remote://source/demo.flac");
		assert_eq!(song.title, "demo");
		assert_eq!(song.file_size, 12_345);
		assert_eq!(song.duration, 0);
		assert_eq!(song.bitrate, 0);
		assert_eq!(song.sample_rate, 0);
	}

	#[test]
	fn first_index_song_uses_parent_folder_as_album_fallback() {
		let source = remote_source();
		let mut file = remote_file(Some("etag-a"), 12_345, None);
		file.remote_path = "/Artist/Album/demo.flac".to_string();

		let song = song_for_remote_index(&source, &file);

		assert_eq!(song.album, "Album");
		assert_eq!(song.album_key, "album::未知歌手");
	}

	#[test]
	fn filename_metadata_fallback_splits_title_and_artist() {
		let source = remote_source();
		let mut file = remote_file(Some("etag-a"), 12_345, None);
		file.remote_path = "/Album/爱琴海-周杰伦.mp3".to_string();
		file.name = "爱琴海-周杰伦.mp3".to_string();
		let mut song = song_from_remote_file(&source, &file);

		apply_filename_metadata_fallback(&mut song, &file);

		assert_eq!(song.title, "爱琴海");
		assert_eq!(song.artist, "周杰伦");
		assert_eq!(song.artist_names, vec!["周杰伦".to_string()]);
		assert_eq!(song.album, "Album");
		assert_eq!(song.album_artist, "周杰伦");
		assert_eq!(song.album_key, "album::周杰伦");
	}

	#[test]
	fn incomplete_remote_song_needs_refresh_even_when_etag_matches() {
		let snapshot = RemoteSongSnapshot {
			etag: Some("etag-a".to_string()),
			size: 1024,
			modified_at: Some("Mon, 04 May 2026 10:00:00 GMT".to_string()),
			song: Some(song_from_remote_file(
				&remote_source(),
				&remote_file(Some("etag-a"), 1024, Some("Mon, 04 May 2026 10:00:00 GMT")),
			)),
		};

		assert!(remote_file_needs_refresh(
			Some(&snapshot),
			&remote_file(Some("etag-a"), 1024, Some("Mon, 04 May 2026 10:00:00 GMT"))
		));
	}

	#[test]
	fn changed_remote_file_needs_refresh() {
		let snapshot = RemoteSongSnapshot {
			etag: Some("etag-a".to_string()),
			size: 1024,
			modified_at: Some("Mon, 04 May 2026 10:00:00 GMT".to_string()),
			song: None,
		};

		assert!(remote_file_needs_refresh(
			Some(&snapshot),
			&remote_file(Some("etag-b"), 1024, Some("Mon, 04 May 2026 10:00:00 GMT"))
		));
	}

	#[test]
	fn remote_file_without_existing_song_needs_refresh() {
		let snapshot = RemoteSongSnapshot {
			etag: Some("etag-a".to_string()),
			size: 1024,
			modified_at: Some("Mon, 04 May 2026 10:00:00 GMT".to_string()),
			song: None,
		};

		assert!(remote_file_needs_refresh(
			Some(&snapshot),
			&remote_file(Some("etag-a"), 1024, Some("Mon, 04 May 2026 10:00:00 GMT"))
		));
	}
}
