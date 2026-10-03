//! 工具箱：文件重命名、下载编排、QMC 解密、元数据嵌入、状态持久化等。
//!
//! 从桌面端移植时移除了以下桌面平台专用/无关命令：
//! `open_external_program`（启动外部程序）、`set_gpu_acceleration` 及 GPU 配置、
//! `run_installer`（安装程序）、`download_update_file`（桌面更新下载）。
//! 依赖 `AppHandle` 的路径获取改为由调用方传入 `data_dir` / 数据库连接。

//! 拆分说明：重命名见 rename，文件名构建见 download_filename，下载编排见 download，
//! QMC 解密见 qmc_decrypt，其余 IO 见 misc_io。

pub(crate) use crate::music::tags::{
    extract_text_metadata, read_tagged_file_from_path, write_metadata_to_file, EmbedMetadataRequest,
};
pub(crate) use crate::music::utils::is_supported_library_extension;
pub(crate) use crate::security::path_validator;
pub(crate) use lofty::prelude::*;
pub(crate) use regex::Regex;
pub(crate) use serde::{Deserialize, Serialize};
pub(crate) use std::fs;
pub(crate) use std::path::{PathBuf, Path};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};
pub(crate) use walkdir::WalkDir;

mod download;
mod download_filename;
mod misc_io;
mod qmc_decrypt;
mod rename;

pub use download::*;
pub use download_filename::*;
pub use misc_io::*;
pub use qmc_decrypt::*;
pub use rename::*;

pub fn refresh_folder_songs( // refresh_folder_songs
	conn: Arc<Mutex<rusqlite::Connection>>,
	folder_path: String,
	minimum_duration_seconds: Option<u32>,
	cover_cache_dir: Option<PathBuf>,
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
		cover_cache_dir,
	)
}

pub fn file_exists(path: String) -> bool { // file_exists
	if path_validator::validate_path(&path, None).is_err() {
		return false;
	}
	std::path::Path::new(&path).is_file()
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
		assert_eq!(
			request.cover_url.as_deref(),
			Some("https://example.com/cover.jpg")
		);
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
