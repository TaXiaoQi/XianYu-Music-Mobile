//! 元数据写入：EmbedMetadataRequest 解析与 ID3v2/Vorbis/MP4 tag 写入。

use super::*;

/// 元数据嵌入请求：将歌曲元数据写入音频文件 tag。
///
/// 所有字段均为可选，仅写入提供的非空字段。
/// `cover_data` 为封面二进制数据，`cover_mime` 标识 MIME 类型（默认 image/jpeg）。
#[derive(serde::Deserialize, Default, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct EmbedMetadataRequest {
	pub file_path: String,
	pub title: Option<String>,
	pub artist: Option<String>,
	pub album: Option<String>,
	pub album_artist: Option<String>,
	pub year: Option<String>,
	pub track_number: Option<String>,
	pub disc_number: Option<String>,
	pub lyrics: Option<String>,
	pub cover_data: Option<Vec<u8>>,
	pub cover_mime: Option<String>,
}

pub(crate) fn parse_u32_field(value: &Option<String>) -> Option<u32> {
	value.as_deref().and_then(|s| s.trim().parse::<u32>().ok())
}

pub(crate) fn guess_tag_type_from_path(path: &Path) -> TagType {
	match path
		.extension()
		.and_then(|ext| ext.to_str())
		.map(|ext| ext.to_ascii_lowercase())
		.as_deref()
	{
		Some("mp3") | Some("mpeg") | Some("mpga") => TagType::Id3v2,
		Some("flac") => TagType::VorbisComments,
		Some("m4a") | Some("mp4") | Some("alac") | Some("aac") => TagType::Mp4Ilst,
		Some("ogg") | Some("opus") | Some("oga") => TagType::VorbisComments,
		Some("wav") | Some("wave") => TagType::RiffInfo,
		_ => TagType::Id3v2,
	}
}

/// 将元数据写入音频文件的 tag（ID3v2/Vorbis Comment/MP4 Atom 等）。
///
/// 仅写入请求中提供的非空字段；已有的其他字段保持不变。
/// 若文件无现有 tag，则按扩展名推断 tag 类型后创建。
pub fn write_metadata_to_file(request: &EmbedMetadataRequest) -> Result<(), String> {
	use lofty::config::WriteOptions;
	use lofty::tag::TagExt;

	let path = Path::new(&request.file_path);
	if !path.exists() {
		return Err(format!("文件不存在: {}", request.file_path));
	}

	let mut tagged_file =
		read_tagged_file_from_path(path).map_err(|e| format!("读取音频文件失败: {e}"))?;

	// 若文件无现有 tag，按扩展名推断 tag 类型后创建
	if tagged_file.primary_tag().is_none() {
		let tag_type = guess_tag_type_from_path(path);
		tagged_file.insert_tag(Tag::new(tag_type));
	}

	let tag = tagged_file
		.primary_tag_mut()
		.ok_or_else(|| "无法获取或创建标签".to_string())?;

	// 文本字段：仅写入非空值
	if let Some(ref title) = request.title {
		if !title.trim().is_empty() {
			tag.set_title(title.clone());
		}
	}
	if let Some(ref artist) = request.artist {
		if !artist.trim().is_empty() {
			tag.set_artist(artist.clone());
		}
	}
	if let Some(ref album) = request.album {
		if !album.trim().is_empty() {
			tag.set_album(album.clone());
		}
	}
	if let Some(ref album_artist) = request.album_artist {
		if !album_artist.trim().is_empty() {
			tag.insert_text(ItemKey::AlbumArtist, album_artist.clone());
		}
	}
	if let Some(year) = parse_u32_field(&request.year) {
		tag.set_year(year);
	}
	if let Some(track) = parse_u32_field(&request.track_number) {
		tag.set_track(track);
	}
	if let Some(disc) = parse_u32_field(&request.disc_number) {
		tag.set_disk(disc);
	}

	// 歌词：写入 Lyrics ItemKey
	if let Some(ref lyrics) = request.lyrics {
		if !lyrics.trim().is_empty() {
			tag.insert_text(ItemKey::Lyrics, lyrics.clone());
		}
	}

	// 封面：写入 Picture
	if let Some(ref cover_data) = request.cover_data {
		if !cover_data.is_empty() {
			let mime_str = request.cover_mime.as_deref().unwrap_or("image/jpeg");
			let mime_type = match mime_str {
				"image/png" => MimeType::Png,
				"image/jpeg" | "image/jpg" => MimeType::Jpeg,
				"image/gif" => MimeType::Gif,
				"image/tiff" => MimeType::Tiff,
				"image/bmp" => MimeType::Bmp,
				_ => MimeType::Jpeg,
			};
			let picture = Picture::new_unchecked(
				PictureType::CoverFront,
				Some(mime_type),
				None,
				cover_data.clone(),
			);
			// 先移除已有的前置封面，避免重复堆积
			tag.remove_picture_type(PictureType::CoverFront);
			tag.push_picture(picture);
		}
	}

	// 保存 tag 到文件
	tag
		.save_to_path(path, WriteOptions::default())
		.map_err(|e| format!("保存标签失败: {e}"))?;

	Ok(())
}
