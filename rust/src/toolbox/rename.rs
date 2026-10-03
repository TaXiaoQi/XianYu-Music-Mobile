//! 文件重命名：标签模板/规则模式批量重命名预览与执行。

use super::*;

pub(crate) static TRACK_PREFIX_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static SOURCE_PREFIX_RE: OnceLock<Regex> = OnceLock::new();

#[derive(Deserialize, Serialize, Debug)]
pub struct RenameConfig { // RenameConfig
	pub mode: String,
	pub template: String,
	pub remove_track_prefix: bool,
	pub remove_source_prefix: bool,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct RenamePreview { // RenamePreview
	pub original_path: String,
	pub original_name: String,
	pub new_name: String,
	pub status: String,
	pub error: Option<String>,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct RenameOperation { // RenameOperation
	pub original_path: String,
	pub new_name: String,
}

pub(crate) fn sanitize_filename(name: &str) -> String { // sanitize_filename
	let invalid_chars = ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];
	let mut sanitized = String::new();
	for c in name.chars() {
		if invalid_chars.contains(&c) {
			sanitized.push('_');
		} else {
			sanitized.push(c);
		}
	}
	sanitized.trim().to_string()
}

pub(crate) fn process_file(path: &Path, config: &RenameConfig) -> RenamePreview { // process_file
	let original_name = path
		.file_name()
		.unwrap_or_default()
		.to_string_lossy()
		.to_string();
	let original_path_str = path.to_string_lossy().to_string();
	let ext = path
		.extension()
		.unwrap_or_default()
		.to_string_lossy()
		.to_string();

	if config.mode == "tags" || config.mode == "auto" {
		if let Ok(tagged_file) = read_tagged_file_from_path(path) {
			let metadata = extract_text_metadata(&tagged_file);
			let title = metadata.title.unwrap_or_default();
			let artist = metadata.artist.unwrap_or_default();
			let album = metadata.album.unwrap_or_default();

			let year = tagged_file
				.primary_tag()
				.and_then(|tag| tag.year())
				.map(|y| y.to_string())
				.unwrap_or_default();
			let track = tagged_file
				.primary_tag()
				.and_then(|tag| tag.track())
				.map(|t| format!("{:02}", t))
				.unwrap_or_default();

			if !title.is_empty() {
				let mut new_name_base = config.template.clone();
				new_name_base = new_name_base.replace("{title}", &title);
				new_name_base = new_name_base.replace("{artist}", &artist);
				new_name_base = new_name_base.replace("{album}", &album);
				new_name_base = new_name_base.replace("{year}", &year);
				new_name_base = new_name_base.replace("{track}", &track);

				let new_name = format!("{}.{}", sanitize_filename(&new_name_base), ext);

				if new_name != original_name {
					return RenamePreview {
						original_path: original_path_str,
						original_name,
						new_name,
						status: "tags".to_string(),
						error: None,
					};
				} else if config.mode == "tags" {
					return RenamePreview {
						original_path: original_path_str,
						original_name: original_name.clone(),
						new_name: original_name,
						status: "skipped".to_string(),
						error: Some("Already named correctly".to_string()),
					};
				}
			}
		}

		if config.mode == "tags" {
			return RenamePreview {
				original_path: original_path_str,
				original_name: original_name.clone(),
				new_name: original_name,
				status: "skipped".to_string(),
				error: Some("Missing tags".to_string()),
			};
		}
	}

	if config.mode == "rules" || config.mode == "auto" {
		let mut cleaned_name = original_name.clone();

		if let Some(stem) = path.file_stem() {
			let mut stem_str = stem.to_string_lossy().to_string();

			if config.remove_track_prefix {
				let re = TRACK_PREFIX_RE.get_or_init(|| Regex::new(r"^\d+[\.\-\s]+").unwrap());
				stem_str = re.replace(&stem_str, "").to_string();
			}

			if config.remove_source_prefix {
				let re = SOURCE_PREFIX_RE.get_or_init(|| Regex::new(r"^\s*\[.*?\]\s*").unwrap());
				stem_str = re.replace(&stem_str, "").to_string();
			}

			cleaned_name = format!("{}.{}", stem_str.trim(), ext);
		}

		if cleaned_name != original_name {
			return RenamePreview {
				original_path: original_path_str,
				original_name,
				new_name: cleaned_name,
				status: "rules".to_string(),
				error: None,
			};
		}
	}

	RenamePreview {
		original_path: original_path_str,
		original_name: original_name.clone(),
		new_name: original_name,
		status: "skipped".to_string(),
		error: Some("No rules matched or missing tags".to_string()),
	}
}

pub fn preview_rename( // preview_rename
	root_path: String,
	config: RenameConfig,
) -> Result<Vec<RenamePreview>, String> { 
	let validated_root = path_validator::validate_path(&root_path, None)?;
	let root_path = validated_root.to_string_lossy().to_string();
	let mut results = Vec::new();

	for entry in WalkDir::new(root_path)
		.max_depth(1)
		.into_iter()
		.filter_map(|e| e.ok())
	{
		let path = entry.path();
		if path.is_file() {
			if let Some(ext) = path.extension() {
				let ext = ext.to_string_lossy().to_lowercase();
				if is_supported_library_extension(&ext) {
					results.push(process_file(path, &config));
				}
			}
		}
	}

	results.sort_by(|a, b| {
		let a_changed = a.status != "skipped";
		let b_changed = b.status != "skipped";
		if a_changed && !b_changed {
			std::cmp::Ordering::Less
		} else if !a_changed && b_changed {
			std::cmp::Ordering::Greater
		} else {
			a.original_name.cmp(&b.original_name)
		}
	});

	Ok(results)
}

pub fn apply_rename(operations: Vec<RenameOperation>) -> Result<u32, String> {
	let mut success_count = 0;

	for mut op in operations {
		let validated_path = path_validator::validate_path(&op.original_path, None)?;
		op.original_path = validated_path.to_string_lossy().to_string();
		op.new_name = path_validator::sanitize_filename_component(&op.new_name)?;
		let src = PathBuf::from(&op.original_path);
		if let Some(parent) = src.parent() {
			let dest = parent.join(&op.new_name);
			if fs::rename(&src, &dest).is_ok() {
				success_count += 1;
			}
		}
	}

	Ok(success_count)
}
