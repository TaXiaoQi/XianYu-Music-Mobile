//! Never truncate a source audio file while editing tags. FLAC audio is copied
//! with bounded memory; other formats are edited by Lofty on a private copy.
use super::*;
use lofty::config::WriteOptions;
use lofty::file::AudioFile;
use lofty::ogg::VorbisComments;
use lofty::picture::PictureInformation;
use lofty::tag::TagExt;
use sha2::{Digest, Sha256};
use std::io::{self, Write};
use std::sync::Mutex;

// Covers the entire read/modify/commit operation, including different paths to
// the same file. A single lock also bounds concurrent tag writer memory usage.
static TAG_WRITE_LOCK: Mutex<()> = Mutex::new(());
const COPY_BUFFER: usize = 1024 * 1024;
const MAX_BLOCK: usize = 0xff_ffff;

pub(crate) fn edit_tags(
    path: &Path,
    edit: impl FnOnce(&mut TaggedFile) -> Result<(), String>,
) -> Result<(), String> {
    let _guard = TAG_WRITE_LOCK
        .lock()
        .map_err(|_| "Tag writer lock poisoned")?;
    // Resolve symlinks so commit replaces the target rather than the link.
    let path = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
    let mut tagged = read_tagged_file_from_path(&path).map_err(|e| e.to_string())?;
    edit(&mut tagged)?;
    commit(&path, &tagged).map_err(|e| format!("Tag transaction failed: {e}"))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn commit(path: &Path, tagged: &TaggedFile) -> io::Result<()> {
    let mut temporary = tempfile::Builder::new()
        .prefix(".xianyu-tags-")
        .tempfile_in(
            path.parent()
                .ok_or_else(|| invalid("Missing parent directory"))?,
        )?;
    if tagged.file_type() == FileType::Flac {
        let tag = tagged
            .tag(TagType::VorbisComments)
            .ok_or_else(|| invalid("Missing FLAC Vorbis comments"))?;
        write_flac(path, temporary.as_file_mut(), tag)?;
    } else {
        let mut source = File::open(path)?;
        copy_hash(&mut source, temporary.as_file_mut())?;
        temporary.as_file_mut().rewind()?;
        tagged
            .save_to(temporary.as_file_mut(), WriteOptions::default())
            .map_err(|e| invalid(&e.to_string()))?;
    }
    temporary.as_file_mut().flush()?;
    temporary.as_file().sync_all()?;
    // Content-based probing works even though the private file has no suffix.
    let verified = Probe::open(temporary.path())
        .map_err(|e| invalid(&e.to_string()))?
        .guess_file_type()?
        .read()
        .map_err(|e| invalid(&format!("Cannot read written tags: {e}")))?;
    if verified.file_type() != tagged.file_type() {
        return Err(invalid("Audio format changed during tag writing"));
    }
    for expected in tagged.tags() {
        let actual = verified
            .tag(expected.tag_type())
            .ok_or_else(|| invalid("Written tag is missing"))?;
        // Validate common text and pictures. Numeric/date and format-specific
        // fields can be normalized by their format's serializer.
        for item in expected.items() {
            if !matches!(
                item.key(),
                ItemKey::TrackTitle
                    | ItemKey::TrackArtist
                    | ItemKey::AlbumTitle
                    | ItemKey::AlbumArtist
                    | ItemKey::Lyrics
            ) {
                continue;
            }
            if let ItemValue::Text(text) = item.value() {
                if !text.is_empty()
                    && !actual
                        .get_items(item.key())
                        .any(|found| found.value() == item.value())
                {
                    return Err(invalid("Written tag text did not round trip"));
                }
            }
        }
        for picture in expected.pictures() {
            if !actual
                .pictures()
                .iter()
                .any(|p| p.pic_type() == picture.pic_type() && p.data() == picture.data())
            {
                return Err(invalid("Written picture did not round trip"));
            }
        }
    }
    std::fs::set_permissions(temporary.path(), std::fs::metadata(path)?.permissions())?;
    // tempfile uses overwrite-rename on Unix and MoveFileExW(REPLACE_EXISTING)
    // on Windows. No delete-first fallback: failure leaves the original intact.
    temporary.persist(path).map_err(|e| e.error)?;
    Ok(())
}

#[derive(Debug)]
struct Block {
    kind: u8,
    offset: u64,
    len: u32,
}

fn flac_layout(source: &mut File) -> io::Result<(Vec<Block>, [u8; 34], u64)> {
    source.rewind()?;
    let mut magic = [0; 4];
    source.read_exact(&mut magic)?;
    if &magic != b"fLaC" {
        return Err(invalid(
            "FLAC must start with fLaC (leading ID3 is unsupported)",
        ));
    }
    let file_len = source.metadata()?.len();
    let mut blocks = Vec::new();
    let mut streaminfo = [0; 34];
    loop {
        // Bound malformed inputs with millions of empty metadata blocks.
        if blocks.len() >= 65536 {
            return Err(invalid("Too many FLAC blocks"));
        }
        let mut header = [0; 4];
        source.read_exact(&mut header)?;
        let kind = header[0] & 0x7f;
        let len = u32::from_be_bytes([0, header[1], header[2], header[3]]);
        let offset = source.stream_position()?;
        if kind == 127 || offset + u64::from(len) > file_len {
            return Err(invalid("Invalid FLAC metadata block"));
        }
        if blocks.is_empty() {
            if kind != 0 || len != 34 {
                return Err(invalid("Invalid FLAC STREAMINFO"));
            }
            source.read_exact(&mut streaminfo)?;
        } else if kind == 0 {
            return Err(invalid("Duplicate FLAC STREAMINFO"));
        }
        source.seek(SeekFrom::Start(offset + u64::from(len)))?;
        blocks.push(Block { kind, offset, len });
        if header[0] & 0x80 != 0 {
            break;
        }
    }
    let audio_offset = source.stream_position()?;
    let mut sync = [0; 2];
    source.read_exact(&mut sync)?;
    if sync[0] != 0xff || sync[1] & 0xfe != 0xf8 {
        return Err(invalid("Missing FLAC audio frame"));
    }
    source.seek(SeekFrom::Start(audio_offset))?;
    Ok((blocks, streaminfo, audio_offset))
}

fn block_header(out: &mut File, kind: u8, len: usize) -> io::Result<()> {
    if len > MAX_BLOCK {
        return Err(invalid("FLAC metadata exceeds 24-bit block size"));
    }
    let size = (len as u32).to_be_bytes();
    out.write_all(&[kind, size[1], size[2], size[3]])
}

fn write_flac(path: &Path, out: &mut File, tag: &Tag) -> io::Result<()> {
    let mut source = File::open(path)?;
    let (blocks, streaminfo, audio_offset) = flac_layout(&mut source)?;
    out.write_all(b"fLaC")?;
    for block in blocks.iter().filter(|b| !matches!(b.kind, 1 | 4 | 6)) {
        block_header(out, block.kind, block.len as usize)?;
        source.seek(SeekFrom::Start(block.offset))?;
        let mut bytes = (&mut source).take(u64::from(block.len));
        let (copied, _) = copy_hash(&mut bytes, out)?;
        if copied != u64::from(block.len) {
            return Err(invalid("Truncated FLAC metadata"));
        }
    }
    let mut text_tag = tag.clone();
    while !text_tag.pictures().is_empty() {
        text_tag.remove_picture(0);
    }
    let comments = VorbisComments::from(text_tag);
    let mut serialized = Vec::new();
    comments
        .dump_to(&mut serialized, WriteOptions::default())
        .map_err(|e| invalid(&e.to_string()))?;
    block_header(out, 4, serialized.len())?;
    out.write_all(&serialized)?;
    for picture in tag.pictures() {
        let info =
            PictureInformation::from_picture(picture).map_err(|e| invalid(&e.to_string()))?;
        let bytes = picture.as_flac_bytes(info, false);
        block_header(out, 6, bytes.len())?;
        out.write_all(&bytes)?;
    }
    // The final padding block alone carries the last-block flag.
    block_header(out, 0x81, 64 * 1024)?;
    out.write_all(&[0; 64 * 1024])?;
    source.seek(SeekFrom::Start(audio_offset))?;
    let expected_size = source.metadata()?.len() - audio_offset;
    let (size, hash) = copy_hash(&mut source, out)?;
    if size != expected_size {
        return Err(invalid("Source changed while copying FLAC"));
    }
    out.flush()?;
    let (_, written_streaminfo, written_offset) = flac_layout(out)?;
    let (written_size, written_hash) = copy_hash(out, &mut io::sink())?;
    if streaminfo != written_streaminfo
        || size != written_size
        || hash != written_hash
        || out.metadata()?.len() != written_offset + size
    {
        return Err(invalid("FLAC audio integrity verification failed"));
    }
    Ok(())
}

fn copy_hash(input: &mut impl Read, out: &mut impl Write) -> io::Result<(u64, [u8; 32])> {
    let mut buffer = vec![0; COPY_BUFFER];
    let mut hash = Sha256::new();
    let mut size = 0;
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        out.write_all(&buffer[..count])?;
        hash.update(&buffer[..count]);
        size += count as u64;
    }
    Ok((size, hash.finalize().into()))
}
