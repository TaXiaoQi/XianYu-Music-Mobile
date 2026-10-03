//! 标签抢救解析：QMC 解密读取、WAV chunk 手工解析、头部 ID3v2 手工解析与 lofty 转换。

use super::*;

/// 将 QMC 加密文件解密后交给 lofty 读取标签。
/// 先尝试流式解密读取器（内存效率高），按解密后格式提示文件类型。
pub(crate) fn read_qmc_tagged_file(path: &Path, options: ParseOptions) -> Option<TaggedFile> {
	let crypto = crate::player::qmc2::detect_qmc_crypto(path)?;
	let file = File::open(path).ok()?;
	let reader = crate::player::qmc2::QmcDecryptReader::new(file, crypto);

	// 推断解密后实际格式（qmcflac→flac、mgg→ogg、qmc0→mp3 等）
	let inner_ext = path
		.extension()
		.and_then(|e| e.to_str())
		.and_then(crate::player::qmc2::inner_audio_extension);
	let mut probe = if let Some(ext) = inner_ext {
		let mut p = Probe::new(reader);
		if let Ok(ft) = lofty_file_type_from_ext(ext) {
			p = p.set_file_type(ft);
		}
		p
	} else {
		Probe::new(reader).guess_file_type().ok()?
	};

	probe = probe.options(options);
	probe.read().ok()
}

/// 将扩展名映射为 lofty FileType（仅支持 QMC 解密后的常见格式）。
pub(crate) fn lofty_file_type_from_ext(ext: &str) -> Result<FileType, ()> {
	Ok(match ext {
		"flac" => FileType::Flac,
		"mp3" => FileType::Mpeg,
		"ogg" => FileType::Vorbis,
		"m4a" | "mp4" => FileType::Mp4,
		_ => return Err(()),
	})
}

pub(crate) fn is_wav_path(path: &Path) -> bool {
	path
		.extension()
		.and_then(|ext| ext.to_str())
		.map(|ext| matches!(ext.to_ascii_lowercase().as_str(), "wav" | "wave"))
		.unwrap_or(false)
}

pub(crate) fn is_mpeg_path(path: &Path) -> bool {
	path
		.extension()
		.and_then(|ext| ext.to_str())
		.map(|ext| matches!(ext.to_ascii_lowercase().as_str(), "mp3" | "mpeg" | "mpga"))
		.unwrap_or(false)
}

pub(crate) fn is_bad_timestamp_error(error: &lofty::error::LoftyError) -> bool {
	matches!(error.kind(), lofty::error::ErrorKind::BadTimestamp(_))
}

pub(crate) fn read_salvaged_id3_tags(path: &Path, read_cover_art: bool) -> Result<TaggedFile, ()> {
	let file = File::open(path).map_err(|_| ())?;
	let mut reader = BufReader::new(file);
	let mut tags = Vec::new();

	if read_leading_id3_tag(&mut reader, &mut tags, read_cover_art)?.is_none() || tags.is_empty() {
		return Err(());
	}

	Ok(TaggedFile::new(
		FileType::from_path(path).unwrap_or(FileType::Mpeg),
		FileProperties::default(),
		tags,
	))
}

pub(crate) fn read_salvaged_wav_tags(path: &Path, read_cover_art: bool) -> Result<TaggedFile, ()> {
	let file = File::open(path).map_err(|_| ())?;
	let mut reader = BufReader::new(file);
	let mut tags = Vec::new();

	let wav_start = match read_leading_id3_tag(&mut reader, &mut tags, read_cover_art)? {
		Some(id3_size) => id3_size,
		None => 0,
	};

	reader.seek(SeekFrom::Start(wav_start)).map_err(|_| ())?;
	tags.extend(parse_wav_chunks(&mut reader, read_cover_art)?);

	if tags.is_empty() {
		return Err(());
	}

	Ok(TaggedFile::new(
		FileType::Wav,
		FileProperties::default(),
		tags,
	))
}

pub(crate) fn read_leading_id3_tag<R>(
	reader: &mut R,
	tags: &mut Vec<Tag>,
	read_cover_art: bool,
) -> Result<Option<u64>, ()>
where
	R: Read + Seek,
{
	let mut header = [0u8; 10];
	match reader.read_exact(&mut header) {
		Ok(()) => {}
		Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => {
			reader.seek(SeekFrom::Start(0)).map_err(|_| ())?;
			return Ok(None);
		}
		Err(_) => return Err(()),
	}

	let Some(id3_size) = leading_id3v2_size(&header).map(|size| size as u64) else {
		reader.seek(SeekFrom::Start(0)).map_err(|_| ())?;
		return Ok(None);
	};

	reader.seek(SeekFrom::Start(0)).map_err(|_| ())?;
	if let Some(id3_bytes) = read_chunk(reader, id3_size as usize) {
		push_id3_tag(tags, &id3_bytes, read_cover_art);
	}

	Ok(Some(id3_size))
}

pub(crate) fn leading_id3v2_size(bytes: &[u8]) -> Option<usize> {
	if bytes.len() < 10 || &bytes[..3] != b"ID3" {
		return None;
	}

	let size = ((bytes[6] as usize) << 21)
		| ((bytes[7] as usize) << 14)
		| ((bytes[8] as usize) << 7)
		| (bytes[9] as usize);

	Some(10 + size)
}

pub(crate) fn parse_wav_chunks<R>(reader: &mut R, read_cover_art: bool) -> Result<Vec<Tag>, ()>
where
	R: Read + Seek,
{
	if !has_wav_header(reader)? {
		return Ok(Vec::new());
	}

	let mut tags = Vec::new();
	loop {
		let mut chunk_header = [0u8; 8];
		match reader.read_exact(&mut chunk_header) {
			Ok(()) => {}
			Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => break,
			Err(_) => return Err(()),
		}

		let chunk_id = &chunk_header[..4];
		let chunk_size = u32::from_le_bytes(chunk_header[4..8].try_into().map_err(|_| ())?) as usize;

		match chunk_id {
			b"id3 " | b"ID3 " => {
				let Some(chunk_bytes) = read_chunk(reader, chunk_size) else {
					break;
				};
				push_id3_tag(&mut tags, &chunk_bytes, read_cover_art);
			}
			b"LIST" => {
				let Some(chunk_bytes) = read_chunk(reader, chunk_size) else {
					break;
				};
				if let Some(tag) = parse_riff_info_list(&chunk_bytes) {
					tags.push(tag);
				}
			}
			_ => {
				if skip_chunk(reader, chunk_size as u64).is_err() {
					break;
				}
			}
		}

		if chunk_size % 2 == 1 && skip_chunk(reader, 1).is_err() {
			break;
		}
	}

	Ok(tags)
}

pub(crate) fn read_chunk<R>(reader: &mut R, size: usize) -> Option<Vec<u8>>
where
	R: Read,
{
	let mut bytes = vec![0u8; size];
	reader.read_exact(&mut bytes).ok()?;
	Some(bytes)
}

pub(crate) fn prefer_leading_id3v2_text(path: &Path, tagged_file: &mut TaggedFile) {
	if tagged_file.file_type() != FileType::Mpeg {
		return;
	}

	let Ok(file) = File::open(path) else {
		return;
	};
	let Some(leading_tag) = read_leading_id3v2_text_tag(&mut BufReader::new(file)) else {
		return;
	};

	match tagged_file.tag_mut(TagType::Id3v2) {
		Some(target_tag) => copy_preferred_id3v2_text(target_tag, &leading_tag),
		None => {
			let _ = tagged_file.insert_tag(leading_tag);
		}
	}
}

pub(crate) fn read_leading_id3v2_text_tag<R>(reader: &mut R) -> Option<Tag>
where
	R: Read + Seek,
{
	let mut header = [0u8; 10];
	reader.read_exact(&mut header).ok()?;
	if &header[..3] != b"ID3" {
		return None;
	}

	let major = header[3];
	if !(2..=4).contains(&major) {
		return None;
	}

	let mut remaining = leading_id3v2_size(&header)?.saturating_sub(10);
	if header[5] & 0x40 != 0 {
		remaining = skip_id3v2_extended_header(reader, major, remaining)?;
	}

	let mut tag = Tag::new(TagType::Id3v2);
	let frame_header_size = if major == 2 { 6 } else { 10 };

	while remaining >= frame_header_size {
		let mut frame_header = vec![0u8; frame_header_size];
		reader.read_exact(&mut frame_header).ok()?;
		remaining = remaining.saturating_sub(frame_header_size);

		let (frame_id, frame_size) = if major == 2 {
			let id = std::str::from_utf8(&frame_header[..3]).ok()?.to_string();
			let size = ((frame_header[3] as usize) << 16)
				| ((frame_header[4] as usize) << 8)
				| frame_header[5] as usize;
			(id, size)
		} else {
			let id = std::str::from_utf8(&frame_header[..4]).ok()?.to_string();
			let size = if major == 4 {
				syncsafe_u32(&frame_header[4..8])?
			} else {
				u32::from_be_bytes(frame_header[4..8].try_into().ok()?) as usize
			};
			(id, size)
		};

		if frame_id.as_bytes().iter().all(|byte| *byte == 0) || frame_size == 0 {
			break;
		}
		if frame_size > remaining {
			break;
		}

		if let Some(key) = id3v2_text_frame_key(&frame_id) {
			let mut data = vec![0u8; frame_size];
			reader.read_exact(&mut data).ok()?;
			if let Some(text) = decode_id3v2_text_frame(&data) {
				let _ = tag.insert_text(key, text);
			}
		} else {
			reader.seek(SeekFrom::Current(frame_size as i64)).ok()?;
		}

		remaining = remaining.saturating_sub(frame_size);

		if tag.get_string(&ItemKey::TrackTitle).is_some()
			&& tag.get_string(&ItemKey::TrackArtist).is_some()
			&& tag.get_string(&ItemKey::AlbumTitle).is_some()
			&& tag.get_string(&ItemKey::AlbumArtist).is_some()
		{
			break;
		}
	}

	let has_items = tag.items().next().is_some();
	has_items.then_some(tag)
}

pub(crate) fn skip_id3v2_extended_header<R>(reader: &mut R, major: u8, remaining: usize) -> Option<usize>
where
	R: Read + Seek,
{
	if remaining < 4 {
		return None;
	}

	let mut size_bytes = [0u8; 4];
	reader.read_exact(&mut size_bytes).ok()?;

	let skip_size = if major == 4 {
		syncsafe_u32(&size_bytes)?.saturating_sub(4)
	} else {
		u32::from_be_bytes(size_bytes) as usize
	};
	if skip_size > remaining.saturating_sub(4) {
		return None;
	}

	reader.seek(SeekFrom::Current(skip_size as i64)).ok()?;
	Some(remaining.saturating_sub(4 + skip_size))
}

pub(crate) fn syncsafe_u32(bytes: &[u8]) -> Option<usize> {
	if bytes.len() != 4 || bytes.iter().any(|byte| byte & 0x80 != 0) {
		return None;
	}

	Some(
		((bytes[0] as usize) << 21)
			| ((bytes[1] as usize) << 14)
			| ((bytes[2] as usize) << 7)
			| bytes[3] as usize,
	)
}

pub(crate) fn id3v2_text_frame_key(frame_id: &str) -> Option<ItemKey> {
	match frame_id {
		"TIT2" | "TT2" => Some(ItemKey::TrackTitle),
		"TPE1" | "TP1" => Some(ItemKey::TrackArtist),
		"TALB" | "TAL" => Some(ItemKey::AlbumTitle),
		"TPE2" | "TP2" => Some(ItemKey::AlbumArtist),
		_ => None,
	}
}

pub(crate) fn decode_id3v2_text_frame(data: &[u8]) -> Option<String> {
	let (encoding, text_bytes) = data.split_first()?;
	let decoded = match encoding {
		0 => text_bytes.iter().map(|byte| char::from(*byte)).collect(),
		1 => decode_utf16_with_bom(text_bytes)?,
		2 => decode_utf16_be(text_bytes)?,
		3 => std::str::from_utf8(text_bytes).ok()?.to_string(),
		_ => return None,
	};

	clean_text(decoded.trim_matches('\0'))
}

pub(crate) fn decode_utf16_with_bom(bytes: &[u8]) -> Option<String> {
	if bytes.starts_with(&[0xFE, 0xFF]) {
		decode_utf16_be(&bytes[2..])
	} else if bytes.starts_with(&[0xFF, 0xFE]) {
		decode_utf16_le(&bytes[2..])
	} else {
		decode_utf16_le(bytes)
	}
}

pub(crate) fn decode_utf16_le(bytes: &[u8]) -> Option<String> {
	if bytes.len() % 2 != 0 {
		return None;
	}

	let units: Vec<u16> = bytes
		.chunks_exact(2)
		.map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
		.collect();
	String::from_utf16(&units).ok()
}

pub(crate) fn decode_utf16_be(bytes: &[u8]) -> Option<String> {
	if bytes.len() % 2 != 0 {
		return None;
	}

	let units: Vec<u16> = bytes
		.chunks_exact(2)
		.map(|chunk| u16::from_be_bytes([chunk[0], chunk[1]]))
		.collect();
	String::from_utf16(&units).ok()
}

pub(crate) fn copy_preferred_id3v2_text(target_tag: &mut Tag, leading_tag: &Tag) {
	const KEYS: &[ItemKey] = &[
		ItemKey::TrackTitle,
		ItemKey::TrackArtist,
		ItemKey::AlbumTitle,
		ItemKey::AlbumArtist,
	];

	for key in KEYS {
		if let Some(value) = leading_tag.get_string(key).and_then(clean_text) {
			let _ = target_tag.insert_text(key.clone(), value);
		}
	}
}

pub(crate) fn skip_chunk<R>(reader: &mut R, size: u64) -> Result<(), ()>
where
	R: Seek,
{
	reader
		.seek(SeekFrom::Current(size as i64))
		.map(|_| ())
		.map_err(|_| ())
}

pub(crate) fn has_wav_header<R>(reader: &mut R) -> Result<bool, ()>
where
	R: Read,
{
	let mut header = [0u8; 12];
	match reader.read_exact(&mut header) {
		Ok(()) => Ok(&header[..4] == b"RIFF" && &header[8..12] == b"WAVE"),
		Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => Ok(false),
		Err(_) => Err(()),
	}
}

pub(crate) fn push_id3_tag(tags: &mut Vec<Tag>, bytes: &[u8], read_cover_art: bool) {
	if let Ok(tag) = id3::Tag::read_from2(Cursor::new(bytes)) {
		tags.push(lofty_tag_from_id3(tag, read_cover_art));
	}
}

pub(crate) fn parse_riff_info_list(bytes: &[u8]) -> Option<Tag> {
	if bytes.len() < 4 || &bytes[..4] != b"INFO" {
		return None;
	}

	let mut tag = Tag::new(TagType::RiffInfo);
	let mut offset = 4usize;

	while offset + 8 <= bytes.len() {
		let key = &bytes[offset..offset + 4];
		let item_size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().ok()?) as usize;
		let data_start = offset + 8;
		let data_end = data_start.saturating_add(item_size);

		if data_end > bytes.len() {
			break;
		}

		if let Some(value) = decode_riff_info_text(&bytes[data_start..data_end]) {
			let key = String::from_utf8_lossy(key);
			let _ = tag.insert(TagItem::new(
				ItemKey::from_key(TagType::RiffInfo, &key),
				ItemValue::Text(value),
			));
		}

		offset = offset.saturating_add(8 + item_size + (item_size % 2));
	}

	let has_items = tag.items().next().is_some();
	has_items.then_some(tag)
}

pub(crate) fn decode_riff_info_text(raw: &[u8]) -> Option<String> {
	let raw = raw
		.split(|byte| *byte == 0)
		.next()
		.unwrap_or(raw)
		.trim_ascii();

	if raw.is_empty() {
		return None;
	}

	if raw.len() >= 2 && raw.len() % 2 == 0 {
		let units: Vec<u16> = raw
			.chunks_exact(2)
			.map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
			.collect();

		if let Ok(decoded) = String::from_utf16(&units) {
			if let Some(text) = clean_text(&decoded) {
				return Some(text);
			}
		}
	}

	if let Ok(decoded) = std::str::from_utf8(raw) {
		if let Some(text) = clean_text(decoded) {
			return Some(text);
		}
	}

	let (decoded, _, _) = encoding_rs::GBK.decode(raw);
	clean_text(&decoded)
}

pub(crate) fn lofty_tag_from_id3(id3_tag: id3::Tag, read_cover_art: bool) -> Tag {
	let mut lofty_tag = Tag::new(TagType::Id3v2);

	insert_optional_text(&mut lofty_tag, ItemKey::TrackTitle, id3_tag.title());
	insert_optional_text(&mut lofty_tag, ItemKey::TrackArtist, id3_tag.artist());
	insert_optional_text(&mut lofty_tag, ItemKey::AlbumTitle, id3_tag.album());
	insert_optional_text(&mut lofty_tag, ItemKey::AlbumArtist, id3_tag.album_artist());
	insert_optional_text(
		&mut lofty_tag,
		ItemKey::RecordingDate,
		id3_tag.year().map(|value| value.to_string()).as_deref(),
	);
	insert_optional_text(
		&mut lofty_tag,
		ItemKey::TrackNumber,
		id3_tag.track().map(|value| value.to_string()).as_deref(),
	);
	insert_optional_text(
		&mut lofty_tag,
		ItemKey::DiscNumber,
		id3_tag.disc().map(|value| value.to_string()).as_deref(),
	);

	for comment in id3_tag.comments() {
		let Some(text) = clean_text(&comment.text) else {
			continue;
		};
		let _ = lofty_tag.insert(TagItem::new(ItemKey::Comment, ItemValue::Text(text)));
	}

	for lyrics in id3_tag.lyrics() {
		let Some(text) = clean_text(&lyrics.text) else {
			continue;
		};
		let _ = lofty_tag.insert(TagItem::new(ItemKey::Lyrics, ItemValue::Text(text)));
	}

	if read_cover_art {
		for picture in id3_tag.pictures() {
			lofty_tag.push_picture(Picture::new_unchecked(
				PictureType::from_u8(u8::from(picture.picture_type)),
				Some(MimeType::from_str(&picture.mime_type)),
				clean_text(&picture.description),
				picture.data.clone(),
			));
		}
	}

	lofty_tag
}

pub(crate) fn insert_optional_text(tag: &mut Tag, key: ItemKey, value: Option<&str>) {
	if let Some(value) = value.and_then(clean_text) {
		let _ = tag.insert_text(key, value);
	}
}
