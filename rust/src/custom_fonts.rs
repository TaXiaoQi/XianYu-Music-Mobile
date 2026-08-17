//! 歌词自定义字体导入与读取。

use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{engine::general_purpose, Engine as _};
use serde::Serialize;
use uuid::Uuid;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportedLyricsFont {
    id: String,
    name: String,
    family: String,
    file_path: String,
    imported_at: u64,
    format: String,
}

fn normalize_font_extension(path: &Path) -> Result<(&'static str, &'static str), String> {
    match path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .as_deref()
    {
        Some("ttf") => Ok(("ttf", "truetype")),
        Some("otf") => Ok(("otf", "opentype")),
        _ => Err("Only .ttf and .otf font files are supported".to_string()),
    }
}

fn display_name_from_path(path: &Path) -> String {
    path.file_stem()
        .and_then(|stem| stem.to_str())
        .map(|stem| stem.trim())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("Custom Lyrics Font")
        .to_string()
}

fn imported_at_millis() -> Result<u64, String> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| error.to_string())?;

    Ok(duration.as_millis() as u64)
}

fn custom_fonts_dir(data_root: &Path) -> Result<PathBuf, String> {
    let dir = data_root.join("custom-lyrics-fonts");
    fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    Ok(dir)
}

/// 导入歌词字体（复制到 `{data_root}/custom-lyrics-fonts`）。
pub fn import_lyrics_font(data_root: &Path, source_path: String) -> Result<ImportedLyricsFont, String> {
    let source = PathBuf::from(source_path);
    if !source.is_file() {
        return Err("Selected font file does not exist".to_string());
    }

    let (extension, format) = normalize_font_extension(&source)?;
    let id = Uuid::new_v4().to_string();
    let file_name = format!("{id}.{extension}");
    let target_path = custom_fonts_dir(data_root)?.join(file_name);

    fs::copy(&source, &target_path).map_err(|error| error.to_string())?;

    Ok(ImportedLyricsFont {
        id: id.clone(),
        name: display_name_from_path(&source),
        family: format!("XianYu Imported Lyrics Font {id}"),
        file_path: target_path.to_string_lossy().to_string(),
        imported_at: imported_at_millis()?,
        format: format.to_string(),
    })
}

/// 读取已导入歌词字体为 data URL（限制在自定义字体目录内）。
pub fn read_lyrics_font_data_url(data_root: &Path, font_path: String) -> Result<String, String> {
    let source = PathBuf::from(font_path);
    if !source.is_file() {
        return Err("Imported font file does not exist".to_string());
    }

    let (_, format) = normalize_font_extension(&source)?;
    let custom_dir =
        fs::canonicalize(custom_fonts_dir(data_root)?).map_err(|error| error.to_string())?;
    let source = fs::canonicalize(&source).map_err(|error| error.to_string())?;

    if !source.starts_with(&custom_dir) {
        return Err("Imported font file is outside the custom lyrics fonts directory".to_string());
    }

    let mime_type = match format {
        "opentype" => "font/otf",
        _ => "font/ttf",
    };
    let bytes = fs::read(source).map_err(|error| error.to_string())?;
    let encoded = general_purpose::STANDARD.encode(bytes);

    Ok(format!("data:{mime_type};base64,{encoded}"))
}