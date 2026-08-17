use std::fs;

/// 将 i64 钳位到 u32 范围（负值归零，超限取 MAX）
pub(crate) fn clamp_i64_to_u32(v: i64) -> u32 {
    if v <= 0 {
        0
    } else if v > u32::MAX as i64 {
        u32::MAX
    } else {
        v as u32
    }
}

/// 将 Option<i64> 安全转换为 Option<u64>（负值返回 None）
pub(crate) fn i64_to_u64_opt(v: Option<i64>) -> Option<u64> {
    v.filter(|value| *value >= 0).map(|value| value as u64)
}

/// 将 Option<i64> 安全转换为 Option<u8>（超出 0-255 返回 None）
pub(crate) fn i64_to_u8_opt(v: Option<i64>) -> Option<u8> {
    v.filter(|value| *value >= 0 && *value <= u8::MAX as i64)
        .map(|value| value as u8)
}

/// 将 Option<i64> 转换为 bool（None 或 0 为 false）
pub(crate) fn i64_to_bool(v: Option<i64>) -> bool {
    v.unwrap_or(0) != 0
}

pub const SUPPORTED_LIBRARY_EXTENSIONS: &[&str] = &[
    "aac", "aif", "aiff", "flac", "m4a", "m4b", "mp3", "mp4", "oga", "ogg", "wav",
];

pub const CUE_FILE_EXTENSIONS: &[&str] = &["cue"];

pub fn normalize_path(path_str: &str) -> String {
    if let Ok(p) = fs::canonicalize(path_str) {
        let mut s = p.to_string_lossy().into_owned();
        if cfg!(windows) && s.starts_with(r"\\?\") {
            s = s[4..].to_string();
        }
        return s;
    }
    let s = path_str.to_string();
    if cfg!(windows) {
        s.replace("/", "\\")
    } else {
        s
    }
}

/// Escape special characters for SQL LIKE pattern with `ESCAPE '^'`.
pub fn escape_like(input: &str) -> String {
    input
        .replace('^', "^^")
        .replace('%', "^%")
        .replace('_', "^_")
}

/// Build forward/backward descendant LIKE patterns for a folder path.
/// Caller should use:
/// `path = ?1 OR path LIKE ?2 ESCAPE '^' OR path LIKE ?3 ESCAPE '^'`
pub fn descendant_like_patterns(folder_path: &str) -> (String, String) {
    let forward_base = if folder_path.ends_with('/') || folder_path.ends_with('\\') {
        folder_path.to_string()
    } else {
        format!("{folder_path}/")
    };

    let backward_base = if folder_path.ends_with('/') || folder_path.ends_with('\\') {
        folder_path.to_string()
    } else {
        format!("{folder_path}\\")
    };

    (
        format!("{}%", escape_like(&forward_base)),
        format!("{}%", escape_like(&backward_base)),
    )
}

pub fn is_supported_library_extension(ext: &str) -> bool {
    SUPPORTED_LIBRARY_EXTENSIONS.contains(&ext)
}

pub fn is_cue_file_extension(ext: &str) -> bool {
    CUE_FILE_EXTENSIONS.contains(&ext)
}

pub fn is_lossless_audio(codec: Option<&str>, format: &str) -> bool {
    let normalized = codec.unwrap_or(format).to_lowercase();
    matches!(
        normalized.as_str(),
        "aif" | "aiff" | "alac" | "ape" | "dsd" | "flac" | "pcm" | "wav" | "wv"
    )
}

pub fn format_distribution_bucket(
    container: Option<&str>,
    codec: Option<&str>,
    format: &str,
) -> &'static str {
    let codec = codec.unwrap_or_default().to_lowercase();
    let container = container.unwrap_or_default().to_lowercase();
    let format = format.to_lowercase();

    match codec.as_str() {
        "flac" => return "flac",
        "mp3" => return "mp3",
        "alac" => return "alac",
        "aac" => return "aac",
        "vorbis" => return "ogg",
        _ => {}
    }

    match container.as_str() {
        "wav" => "wav",
        "aiff" => "aiff",
        "ogg" => "ogg",
        "mp4" => "aac",
        _ => match format.as_str() {
            "flac" => "flac",
            "mp3" => "mp3",
            "wav" => "wav",
            "alac" => "alac",
            "aif" | "aiff" => "aiff",
            "aac" | "m4a" | "m4b" | "mp4" => "aac",
            "ogg" | "oga" => "ogg",
            _ => "other",
        },
    }
}
