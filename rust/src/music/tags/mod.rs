pub(crate) use id3::TagLike;
pub(crate) use lofty::config::ParseOptions;
pub(crate) use lofty::file::{FileType, TaggedFile, TaggedFileExt};
pub(crate) use lofty::picture::{MimeType, Picture, PictureType};
pub(crate) use lofty::probe::Probe;
pub(crate) use lofty::properties::FileProperties;
pub(crate) use lofty::tag::{Accessor, ItemKey, ItemValue, Tag, TagItem, TagType};
pub(crate) use std::fs::File;
pub(crate) use std::io::{BufReader, Cursor, Read, Seek, SeekFrom};
pub(crate) use std::path::Path;

mod salvage;
mod write;

pub use write::*;
use salvage::*;
#[derive(Default, Debug, Clone, PartialEq, Eq)]
pub struct TagTextMetadata { // TagTextMetadata
	pub title: Option<String>,
	pub artist: Option<String>,
	pub album: Option<String>,
	pub album_artist: Option<String>,
}

#[derive(Default, Debug, Clone, PartialEq, Eq)]
pub struct TagDetailMetadata { // TagDetailMetadata
	pub genre: Option<String>,
	pub year: Option<String>,
	pub track_number: Option<String>,
	pub disc_number: Option<String>,
	pub comment: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbeddedLyricsMatch { // EmbeddedLyricsMatch
	pub tag_type: TagType,
	pub item_key: ItemKey,
	pub description: String,
	pub text: String,
}

pub fn read_tagged_file_from_path(path: &Path) -> lofty::error::Result<TaggedFile> {
	read_tagged_file_from_path_with_cover_mode(path, true)
}

pub fn read_tagged_file_from_path_for_scan(path: &Path) -> lofty::error::Result<TaggedFile> {
	read_tagged_file_from_path_with_cover_mode(path, false)
}

fn read_tagged_file_from_path_with_cover_mode(
	path: &Path,
	read_cover_art: bool,
) -> lofty::error::Result<TaggedFile> {
	let options = ParseOptions::new().read_cover_art(read_cover_art);

	// QMC 加密文件（mflac/mgg/qmc0 等）需要先解密再解析标签，
	// 否则 lofty 拿到的是密文，无法识别格式和读取元数据。
	if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
		if crate::player::qmc2::is_qmc_extension(ext) {
			if let Some(tagged) = read_qmc_tagged_file(path, options) {
				return Ok(tagged);
			}
			// 解密失败时回落到直接读（仍可能成功读出部分标签）
		}
	}

	match Probe::open(path)?
		.guess_file_type()?
		.options(options)
		.read()
	{
		Ok(mut tagged_file) => {
			prefer_leading_id3v2_text(path, &mut tagged_file);
			Ok(tagged_file)
		}
		Err(original_err) if is_wav_path(path) => {
			read_salvaged_wav_tags(path, read_cover_art).map_err(|_| original_err)
		}
		Err(original_err) if is_mpeg_path(path) => {
			read_salvaged_id3_tags(path, read_cover_art).map_err(|_| original_err)
		}
		Err(original_err) if is_bad_timestamp_error(&original_err) => {
			read_salvaged_id3_tags(path, read_cover_art).map_err(|_| original_err)
		}
		Err(original_err) => Err(original_err),
	}
}

/// 将 QMC 加密文件解密后交给 lofty 读取标签。
/// 先尝试流式解密读取器（内存效率高），按解密后格式提示文件类型。

pub fn extract_text_metadata<T>(tagged_file: &T) -> TagTextMetadata
where
	T: TaggedFileExt + ?Sized,
{
	let mut metadata = TagTextMetadata::default();

	for tag in ordered_tags(tagged_file) {
		if metadata.title.is_none() {
			metadata.title = read_title(tag);
		}

		if metadata.artist.is_none() {
			metadata.artist = read_artist(tag);
		}

		if metadata.album.is_none() {
			metadata.album = read_album(tag);
		}

		if metadata.album_artist.is_none() {
			metadata.album_artist = read_album_artist(tag);
		}

		if metadata.title.is_some()
			&& metadata.artist.is_some()
			&& metadata.album.is_some()
			&& metadata.album_artist.is_some()
		{
			break;
		}
	}

	metadata
}

pub fn extract_detail_metadata<T>(tagged_file: &T) -> TagDetailMetadata
where
	T: TaggedFileExt + ?Sized,
{
	let mut metadata = TagDetailMetadata::default();

	for tag in ordered_tags(tagged_file) {
		if metadata.genre.is_none() {
			metadata.genre = tag
				.genre()
				.as_deref()
				.and_then(clean_text)
				.or_else(|| read_tag_text(tag, &[], &["GENRE", "TCON", "IGNR"]));
		}

		if metadata.year.is_none() {
			metadata.year = tag
				.get_string(&ItemKey::RecordingDate)
				.and_then(clean_text)
				.or_else(|| read_tag_text(tag, &[], &["DATE", "YEAR", "TYER", "TDRC", "ICRD"]));
		}

		if metadata.track_number.is_none() {
			metadata.track_number = tag.track().map(|value| value.to_string()).or_else(|| {
				read_tag_text(
					tag,
					&[ItemKey::TrackNumber],
					&["TRACKNUMBER", "TRCK", "TRACK", "ITRK", "IPRT"],
				)
			});
		}

		if metadata.disc_number.is_none() {
			metadata.disc_number = tag.disk().map(|value| value.to_string()).or_else(|| {
				read_tag_text(
					tag,
					&[ItemKey::DiscNumber],
					&["DISCNUMBER", "DISC", "DISK", "TPOS"],
				)
			});
		}

		if metadata.comment.is_none() {
			metadata.comment = tag
				.get_string(&ItemKey::Comment)
				.and_then(clean_text)
				.or_else(|| {
					tag.items().find_map(|item| match item.key() {
						ItemKey::Comment | ItemKey::Description => item_text(item),
						ItemKey::Unknown(key)
							if matches!(
								key.to_ascii_uppercase().as_str(),
								"COMMENT" | "COMMENTS" | "DESCRIPTION"
							) =>
						{
							item_text(item)
						}
						_ => None,
					})
				});
		}

		if metadata.genre.is_some()
			&& metadata.year.is_some()
			&& metadata.track_number.is_some()
			&& metadata.disc_number.is_some()
			&& metadata.comment.is_some()
		{
			break;
		}
	}

	metadata
}

pub fn extract_embedded_lyrics<T>(tagged_file: &T) -> Option<String>
where
	T: TaggedFileExt + ?Sized,
{
	extract_embedded_lyrics_match(tagged_file).map(|lyrics_match| lyrics_match.text)
}

pub fn extract_embedded_lyrics_match<T>(tagged_file: &T) -> Option<EmbeddedLyricsMatch>
where
	T: TaggedFileExt + ?Sized,
{
	let tags = ordered_tags(tagged_file);

	for tag in &tags {
		if let Some(lyrics) = tag.get_string(&ItemKey::Lyrics).and_then(clean_text) {
			return Some(EmbeddedLyricsMatch {
				tag_type: tag.tag_type(),
				item_key: ItemKey::Lyrics,
				description: String::new(),
				text: lyrics,
			});
		}
	}

	for tag in &tags {
		for item in tag.items() {
			let Some(text) = item_text(item) else {
				continue;
			};

			let is_explicit_lyrics_field = match item.key() {
				ItemKey::Comment | ItemKey::Description => true,
				ItemKey::Unknown(key) => looks_like_lyrics_key(key),
				_ => false,
			} || looks_like_lyrics_description(item.description());

			if is_explicit_lyrics_field && seems_like_lyrics_text(&text) {
				return Some(EmbeddedLyricsMatch {
					tag_type: tag.tag_type(),
					item_key: item.key().clone(),
					description: item.description().to_string(),
					text,
				});
			}
		}
	}

	for tag in &tags {
		for item in tag.items() {
			let Some(text) = item_text(item) else {
				continue;
			};

			if contains_lrc_timestamp(&text) {
				return Some(EmbeddedLyricsMatch {
					tag_type: tag.tag_type(),
					item_key: item.key().clone(),
					description: item.description().to_string(),
					text,
				});
			}
		}
	}

	None
}

pub fn find_embedded_picture<'a, T>(tagged_file: &'a T) -> Option<&'a Picture>
where
	T: TaggedFileExt + ?Sized,
{
	let tags = ordered_tags(tagged_file);

	for tag in &tags {
		if let Some(picture) = tag
			.pictures()
			.iter()
			.find(|picture| picture.pic_type() == PictureType::CoverFront)
		{
			return Some(picture);
		}
	}

	for tag in &tags {
		if let Some(picture) = tag.pictures().first() {
			return Some(picture);
		}
	}

	None
}

pub fn find_embedded_artist_picture<'a, T>(tagged_file: &'a T) -> Option<&'a Picture>
where
	T: TaggedFileExt + ?Sized,
{
	let tags = ordered_tags(tagged_file);

	for tag in &tags {
		if let Some(picture) = tag
			.pictures()
			.iter()
			.find(|picture| picture.pic_type() == PictureType::Artist)
		{
			return Some(picture);
		}
	}

	None
}


pub fn contains_lrc_timestamp(text: &str) -> bool {
	let bytes = text.as_bytes();
	let mut index = 0usize;

	while index < bytes.len() {
		if bytes[index] == b'[' {
			let mut cursor = index + 1;
			let mut minutes_digits = 0usize;

			while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
				minutes_digits += 1;
				cursor += 1;
			}

			if minutes_digits > 0 && cursor < bytes.len() && bytes[cursor] == b':' {
				cursor += 1;

				if cursor + 1 < bytes.len()
					&& bytes[cursor].is_ascii_digit()
					&& bytes[cursor + 1].is_ascii_digit()
				{
					cursor += 2;

					if cursor < bytes.len() && bytes[cursor] == b'.' {
						cursor += 1;
						let mut fraction_digits = 0usize;
						while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
							fraction_digits += 1;
							cursor += 1;
						}

						if fraction_digits > 0 && cursor < bytes.len() && bytes[cursor] == b']' {
							return true;
						}
					} else if cursor < bytes.len() && bytes[cursor] == b']' {
						return true;
					}
				}
			}
		}

		index += 1;
	}

	false
}

pub(crate) fn ordered_tags<'a, T>(tagged_file: &'a T) -> Vec<&'a Tag>
where
	T: TaggedFileExt + ?Sized,
{
	let mut tags = Vec::new();

	push_unique_tag(&mut tags, tagged_file.tag(TagType::Id3v2));
	push_unique_tag(&mut tags, tagged_file.primary_tag());
	push_unique_tag(&mut tags, tagged_file.tag(TagType::RiffInfo));

	for tag in tagged_file.tags() {
		push_unique_tag(&mut tags, Some(tag));
	}

	tags
}

pub(crate) fn push_unique_tag<'a>(tags: &mut Vec<&'a Tag>, candidate: Option<&'a Tag>) {
	let Some(candidate) = candidate else {
		return;
	};

	if !tags
		.iter()
		.any(|existing| std::ptr::eq(*existing, candidate))
	{
		tags.push(candidate);
	}
}

pub(crate) fn read_title(tag: &Tag) -> Option<String> {
	tag
		.title()
		.as_deref()
		.and_then(clean_text)
		.or_else(|| read_tag_text(tag, &[ItemKey::TrackTitle], &["TITLE", "INAM"]))
}

pub(crate) fn read_artist(tag: &Tag) -> Option<String> {
	tag.artist().as_deref().and_then(clean_text).or_else(|| {
		read_tag_text(
			tag,
			&[
				ItemKey::TrackArtist,
				ItemKey::AlbumArtist,
				ItemKey::Performer,
				ItemKey::Composer,
			],
			&["ARTIST", "IART", "AUTHOR"],
		)
	})
}

pub(crate) fn read_album(tag: &Tag) -> Option<String> {
	tag.album().as_deref().and_then(clean_text).or_else(|| {
		read_tag_text(
			tag,
			&[ItemKey::AlbumTitle, ItemKey::OriginalAlbumTitle],
			&["ALBUM", "IPRD"],
		)
	})
}

pub(crate) fn read_album_artist(tag: &Tag) -> Option<String> {
	read_tag_text(
		tag,
		&[
			ItemKey::AlbumArtist,
			ItemKey::TrackArtist,
			ItemKey::Performer,
		],
		&["ALBUMARTIST", "ALBUM ARTIST", "TPE2", "IART"],
	)
}

pub(crate) fn read_tag_text(tag: &Tag, keys: &[ItemKey], unknown_keys: &[&str]) -> Option<String> {
	for key in keys {
		if let Some(text) = tag.get_string(key).and_then(clean_text) {
			return Some(text);
		}
	}

	tag.items().find_map(|item| match item.key() {
		ItemKey::Unknown(key)
			if unknown_keys
				.iter()
				.any(|candidate| key.eq_ignore_ascii_case(candidate)) =>
		{
			item_text(item)
		}
		_ => None,
	})
}

pub(crate) fn item_text(item: &TagItem) -> Option<String> {
	item
		.value()
		.text()
		.or_else(|| item.value().locator())
		.and_then(clean_text)
}

pub(crate) fn clean_text(value: &str) -> Option<String> {
	let trimmed = value.trim_matches('\0').trim();
	(!trimmed.is_empty()).then(|| trimmed.to_string())
}

pub(crate) fn looks_like_lyrics_key(raw_key: &str) -> bool {
	matches!(
		raw_key.to_ascii_uppercase().as_str(),
		"LYRICS" | "LYRIC" | "LRC" | "KLYRIC" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS"
	)
}

pub(crate) fn looks_like_lyrics_description(description: &str) -> bool {
	let normalized = description.trim().to_ascii_uppercase();
	!normalized.is_empty() && (normalized.contains("LYRIC") || normalized.contains("LRC"))
}

pub(crate) fn seems_like_lyrics_text(text: &str) -> bool {
	contains_lrc_timestamp(text) || text.lines().filter(|line| !line.trim().is_empty()).count() >= 2
}

#[cfg(test)] mod tests {
	use super::{
		extract_detail_metadata, extract_embedded_lyrics, extract_text_metadata, find_embedded_picture,
		read_tagged_file_from_path, read_tagged_file_from_path_for_scan, EmbedMetadataRequest,
	};
	use id3::frame::{Frame, Picture as Id3Picture, PictureType as Id3PictureType};
	use id3::TagLike;
	use id3::Version;
	use lofty::file::{FileType, TaggedFile, TaggedFileExt};
	use lofty::picture::{MimeType, Picture, PictureType};
	use lofty::probe::Probe;
	use lofty::properties::FileProperties;
	use lofty::tag::{ItemKey, ItemValue, Tag, TagItem, TagType};
	use std::fs;
	use std::time::{SystemTime, UNIX_EPOCH};

	fn make_tagged_file(tags: Vec<Tag>) -> TaggedFile {
		TaggedFile::new(FileType::Wav, FileProperties::default(), tags)
	}

	#[test]
	fn embed_metadata_request_accepts_frontend_camel_case_payload() {
		let json = serde_json::json!({
				"filePath": "D:\\Music\\song.mp3",
				"title": "测试歌曲",
				"artist": "测试歌手",
				"albumArtist": "测试专辑艺术家",
				"trackNumber": "7",
				"discNumber": "1",
				"coverMime": "image/png"
		});

		let request: EmbedMetadataRequest =
			serde_json::from_value(json).expect("frontend payload should deserialize");

		assert_eq!(request.file_path, "D:\\Music\\song.mp3");
		assert_eq!(request.title.as_deref(), Some("测试歌曲"));
		assert_eq!(request.artist.as_deref(), Some("测试歌手"));
		assert_eq!(request.album_artist.as_deref(), Some("测试专辑艺术家"));
		assert_eq!(request.track_number.as_deref(), Some("7"));
		assert_eq!(request.disc_number.as_deref(), Some("1"));
		assert_eq!(request.cover_mime.as_deref(), Some("image/png"));
	}

	fn minimal_wav_bytes() -> Vec<u8> {
		let mut wav = Vec::new();
		wav.extend_from_slice(b"RIFF");
		wav.extend_from_slice(&38u32.to_le_bytes());
		wav.extend_from_slice(b"WAVE");
		wav.extend_from_slice(b"fmt ");
		wav.extend_from_slice(&16u32.to_le_bytes());
		wav.extend_from_slice(&1u16.to_le_bytes());
		wav.extend_from_slice(&1u16.to_le_bytes());
		wav.extend_from_slice(&44_100u32.to_le_bytes());
		wav.extend_from_slice(&88_200u32.to_le_bytes());
		wav.extend_from_slice(&2u16.to_le_bytes());
		wav.extend_from_slice(&16u16.to_le_bytes());
		wav.extend_from_slice(b"data");
		wav.extend_from_slice(&2u32.to_le_bytes());
		wav.extend_from_slice(&[0, 0]);
		wav
	}

	fn create_id3_prefixed_wav_bytes(with_picture: bool) -> Vec<u8> {
		let mut id3_tag = id3::Tag::new();
		id3_tag.set_title("Fallback WAV");

		if with_picture {
			id3_tag.add_frame(Id3Picture {
				mime_type: "image/png".to_string(),
				picture_type: Id3PictureType::CoverFront,
				description: "front".to_string(),
				data: vec![137, 80, 78, 71],
			});
		}

		let mut bytes = Vec::new();
		id3_tag
			.write_to(&mut bytes, Version::Id3v24)
			.expect("id3 tag should serialize");
		bytes.extend_from_slice(&minimal_wav_bytes());
		bytes
	}

	fn create_mp3_with_id3v2_and_gbk_id3v1_bytes() -> Vec<u8> {
		let mut id3_tag = id3::Tag::new();
		id3_tag.set_title("爱琴海");
		id3_tag.set_artist("周杰伦");
		id3_tag.set_album("太阳之子");

		let mut bytes = Vec::new();
		id3_tag
			.write_to(&mut bytes, Version::Id3v23)
			.expect("id3v2 tag should serialize");

		bytes.extend_from_slice(&[0xFF, 0xFB, 0x90, 0x64]);
		bytes.extend(std::iter::repeat(0).take(413));

		let mut id3v1 = [0u8; 128];
		id3v1[..3].copy_from_slice(b"TAG");
		id3v1[3..9].copy_from_slice(&[0xB0, 0xAE, 0xC7, 0xD9, 0xBA, 0xA3]);
		id3v1[33..39].copy_from_slice(&[0xD6, 0xDC, 0xBD, 0xDC, 0xC2, 0xD7]);
		id3v1[63..71].copy_from_slice(&[0xCC, 0xAB, 0xD1, 0xF4, 0xD6, 0xAE, 0xD7, 0xD3]);
		bytes.extend_from_slice(&id3v1);

		bytes
	}

	fn create_mp3_with_non_ascii_id3_timestamp_bytes() -> Vec<u8> {
		let mut id3_tag = id3::Tag::new();
		id3_tag.set_title("Timestamp Demo");
		id3_tag.set_artist("Artist");
		id3_tag.add_frame(Frame::text("TDRC", "２０２４"));

		let mut bytes = Vec::new();
		id3_tag
			.write_to(&mut bytes, Version::Id3v24)
			.expect("id3v2 tag should serialize");
		bytes.extend_from_slice(&[0xFF, 0xFB, 0x90, 0x64]);
		bytes.extend(std::iter::repeat(0).take(413));

		bytes
	}

	#[test]
	fn prefers_id3v2_text_over_riff_info() {
		let mut riff = Tag::new(TagType::RiffInfo);
		riff.insert_text(ItemKey::TrackTitle, "RIFF Title".to_string());
		riff.insert_text(ItemKey::TrackArtist, "RIFF Artist".to_string());
		riff.insert_text(ItemKey::AlbumTitle, "RIFF Album".to_string());

		let mut id3 = Tag::new(TagType::Id3v2);
		id3.insert_text(ItemKey::TrackTitle, "ID3 Title".to_string());
		id3.insert_text(ItemKey::TrackArtist, "ID3 Artist".to_string());
		id3.insert_text(ItemKey::AlbumTitle, "ID3 Album".to_string());

		let metadata = extract_text_metadata(&make_tagged_file(vec![riff, id3]));

		assert_eq!(metadata.title.as_deref(), Some("ID3 Title"));
		assert_eq!(metadata.artist.as_deref(), Some("ID3 Artist"));
		assert_eq!(metadata.album.as_deref(), Some("ID3 Album"));
	}

	#[test]
	fn falls_back_to_riff_info_text() {
		let mut riff = Tag::new(TagType::RiffInfo);
		riff.insert_text(ItemKey::TrackTitle, "Wave Title".to_string());
		riff.insert_text(ItemKey::TrackArtist, "Wave Artist".to_string());
		riff.insert_text(ItemKey::AlbumTitle, "Wave Album".to_string());

		let metadata = extract_text_metadata(&make_tagged_file(vec![riff]));

		assert_eq!(metadata.title.as_deref(), Some("Wave Title"));
		assert_eq!(metadata.artist.as_deref(), Some("Wave Artist"));
		assert_eq!(metadata.album.as_deref(), Some("Wave Album"));
	}

	#[test]
	fn extracts_lyrics_from_comment_when_it_contains_lrc() {
		let mut id3 = Tag::new(TagType::Id3v2);
		id3.insert(TagItem::new(
			ItemKey::Comment,
			ItemValue::Text("[00:01.00]line one\n[00:02.00]line two".to_string()),
		));

		let lyrics = extract_embedded_lyrics(&make_tagged_file(vec![id3]));

		assert_eq!(
			lyrics.as_deref(),
			Some("[00:01.00]line one\n[00:02.00]line two")
		);
	}

	#[test]
	fn extracts_track_and_disc_numbers_from_detail_metadata() {
		let mut id3 = Tag::new(TagType::Id3v2);
		id3.insert_text(ItemKey::TrackNumber, "7".to_string());
		id3.insert_text(ItemKey::DiscNumber, "2".to_string());

		let metadata = extract_detail_metadata(&make_tagged_file(vec![id3]));

		assert_eq!(metadata.track_number.as_deref(), Some("7"));
		assert_eq!(metadata.disc_number.as_deref(), Some("2"));
	}

	#[test]
	fn prefers_front_cover_picture() {
		let mut id3 = Tag::new(TagType::Id3v2);
		id3.push_picture(Picture::new_unchecked(
			PictureType::CoverBack,
			Some(MimeType::Jpeg),
			None,
			vec![1, 2, 3],
		));

		let mut riff = Tag::new(TagType::RiffInfo);
		riff.push_picture(Picture::new_unchecked(
			PictureType::CoverFront,
			Some(MimeType::Png),
			None,
			vec![4, 5, 6],
		));

		let tagged_file = make_tagged_file(vec![id3, riff]);
		let picture = find_embedded_picture(&tagged_file).expect("picture should exist");

		assert_eq!(picture.pic_type(), PictureType::CoverFront);
		assert_eq!(picture.data(), &[4, 5, 6]);
	}

	#[test]
	fn reads_wav_with_leading_id3v2_header_via_fallback() {
		let temp_name = format!(
			"xianyu_id3_prefixed_{}.wav",
			SystemTime::now()
				.duration_since(UNIX_EPOCH)
				.unwrap_or_default()
				.as_nanos()
		);
		let temp_path = std::env::temp_dir().join(temp_name);

		fs::write(&temp_path, create_id3_prefixed_wav_bytes(false))
			.expect("temp wav should be written");

		let extension_only = Probe::open(&temp_path).expect("probe should open").read();
		assert!(extension_only.is_err());

		let tagged_file =
			read_tagged_file_from_path(&temp_path).expect("fallback parser should read the wav");
		assert_eq!(tagged_file.file_type(), FileType::Wav);

		let _ = fs::remove_file(temp_path);
	}

	#[test]
	fn mp3_text_prefers_id3v2_over_id3v1_tail() {
		let temp_name = format!(
			"xianyu_id3v2_priority_{}.mp3",
			SystemTime::now()
				.duration_since(UNIX_EPOCH)
				.unwrap_or_default()
				.as_nanos()
		);
		let temp_path = std::env::temp_dir().join(temp_name);

		fs::write(&temp_path, create_mp3_with_id3v2_and_gbk_id3v1_bytes())
			.expect("temp mp3 should be written");

		let tagged_file =
			read_tagged_file_from_path_for_scan(&temp_path).expect("mp3 tags should be read");
		let metadata = extract_text_metadata(&tagged_file);

		assert_eq!(metadata.title.as_deref(), Some("爱琴海"));
		assert_eq!(metadata.artist.as_deref(), Some("周杰伦"));
		assert_eq!(metadata.album.as_deref(), Some("太阳之子"));

		let _ = fs::remove_file(temp_path);
	}

	#[test]
	fn reads_mp3_text_when_id3_timestamp_contains_non_ascii_characters() {
		let temp_name = format!(
			"xianyu_bad_timestamp_{}.mp3",
			SystemTime::now()
				.duration_since(UNIX_EPOCH)
				.unwrap_or_default()
				.as_nanos()
		);
		let temp_path = std::env::temp_dir().join(temp_name);

		fs::write(&temp_path, create_mp3_with_non_ascii_id3_timestamp_bytes())
			.expect("temp mp3 should be written");

		let tagged_file = read_tagged_file_from_path_for_scan(&temp_path)
			.expect("fallback parser should ignore the invalid timestamp frame");
		let metadata = extract_text_metadata(&tagged_file);

		assert_eq!(metadata.title.as_deref(), Some("Timestamp Demo"));
		assert_eq!(metadata.artist.as_deref(), Some("Artist"));

		let _ = fs::remove_file(temp_path);
	}

	#[test]
	fn scan_reader_skips_cover_art_for_wav_fallback() {
		let temp_name = format!(
			"xianyu_id3_prefixed_cover_{}.wav",
			SystemTime::now()
				.duration_since(UNIX_EPOCH)
				.unwrap_or_default()
				.as_nanos()
		);
		let temp_path = std::env::temp_dir().join(temp_name);

		fs::write(&temp_path, create_id3_prefixed_wav_bytes(true)).expect("temp wav should be written");

		let full_tagged_file =
			read_tagged_file_from_path(&temp_path).expect("full parser should retain pictures");
		let scan_tagged_file = read_tagged_file_from_path_for_scan(&temp_path)
			.expect("scan parser should still read text tags");

		assert!(find_embedded_picture(&full_tagged_file).is_some());
		assert!(find_embedded_picture(&scan_tagged_file).is_none());

		let _ = fs::remove_file(temp_path);
	}
}
