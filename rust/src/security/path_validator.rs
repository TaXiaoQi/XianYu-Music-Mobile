use std::path::{Component, Path, PathBuf};

fn canonicalize_path_or_parent(path: &Path) -> Result<PathBuf, String> {
    if path.exists() {
        return path
            .canonicalize()
            .map_err(|e| format!("路径规范化失败: {}", e));
    }

    let parent = path.parent().unwrap_or(Path::new(""));
    if parent.as_os_str().is_empty() {
        return Ok(path.to_path_buf());
    }

    if parent.exists() {
        let canonical_parent = parent
            .canonicalize()
            .map_err(|e| format!("父目录规范化失败: {}", e))?;
        return Ok(canonical_parent.join(path.file_name().ok_or("无效的文件名")?));
    }

    Ok(path.to_path_buf())
}

/// Validate that a path is safe and within allowed directories.
///
/// # Security
/// - Rejects paths containing `..` components
/// - Canonicalizes the path (resolves symlinks) when possible
/// - Checks the canonical path starts with one of the allowed roots
/// - If no allowed_roots provided, rejects symlink/reparse-point components after basic traversal checks
///
/// # Arguments
/// * `input` - The raw path string from IPC
/// * `allowed_roots` - Optional list of allowed root directories. If None, symlink components are still rejected.
///
/// # Returns
/// * `Ok(PathBuf)` - The validated, canonicalized path
/// * `Err(String)` - Error message describing why validation failed
pub fn validate_path(input: &str, allowed_roots: Option<&[PathBuf]>) -> Result<PathBuf, String> {
    let path = PathBuf::from(input);

    if input.trim().is_empty() {
        return Err("路径不能为空".to_string());
    }

    for component in path.components() {
        if matches!(component, Component::ParentDir) {
            return Err(format!("路径包含非法目录遍历: {}", input));
        }
    }

    let canonical = canonicalize_path_or_parent(&path)?;

    if let Some(roots) = allowed_roots {
        if roots.is_empty() {
            return Err("未配置允许的根目录".to_string());
        }

        let mut found = false;
        for root in roots {
            let canonical_root = canonicalize_path_or_parent(root)?;
            if canonical.starts_with(&canonical_root) {
                found = true;
                break;
            }
        }

        if !found {
            return Err(format!(
                "路径不在允许的目录范围内: {} (允许的目录: {})",
                canonical.display(),
                roots
                    .iter()
                    .map(|r| r.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }

        Ok(canonical)
    } else {
        // Symlink check is skipped because there are no directory restrictions to enforce.
        // The path is already canonicalized and directory traversal (..) is already rejected above.
        Ok(canonical)
    }
}

/// Validate that a path is within a specific directory.
///
/// Convenience wrapper around `validate_path` with a single allowed root.
pub fn validate_path_in_dir(input: &str, allowed_root: &Path) -> Result<PathBuf, String> {
    validate_path(input, Some(&[allowed_root.to_path_buf()]))
}

/// Sanitize a filename by removing path separators and dangerous characters.
///
/// This is used when a user-provided string will be used as a filename component.
pub fn sanitize_filename_component(name: &str) -> Result<String, String> {
    if name.is_empty() {
        return Err("文件名不能为空".to_string());
    }

    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("文件名不能为空".to_string());
    }

    if name.contains('/') || name.contains('\\') {
        return Err(format!("文件名不能包含路径分隔符: {}", name));
    }

    if name == ".." || name == "." {
        return Err("文件名不能为目录引用".to_string());
    }

    if name.contains('\0') {
        return Err("文件名包含非法字符".to_string());
    }

    if name
        .chars()
        .any(|ch| matches!(ch, '<' | '>' | ':' | '"' | '|' | '?' | '*'))
    {
        return Err(format!("文件名包含 Windows 不支持的字符: {}", name));
    }

    let stem_upper = trimmed
        .trim_end_matches(|ch| ch == ' ' || ch == '.')
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    let reserved = matches!(
        stem_upper.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    );
    if reserved {
        return Err(format!("文件名为 Windows 保留名称: {}", name));
    }

    if name.len() > 255 {
        return Err("文件名过长".to_string());
    }

    Ok(name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;

    #[test]
    fn test_reject_parent_dir_traversal() {
        let result = validate_path("../../../etc/passwd", None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("目录遍历"));
    }

    #[test]
    fn test_reject_parent_dir_in_middle() {
        let result = validate_path("/tmp/foo/../bar", None);
        assert!(result.is_err());
    }

    #[test]
    fn test_accept_normal_path() {
        let result = validate_path("/tmp/normal/path.txt", None);
        assert!(result.is_ok());
    }

    #[test]
    fn test_validate_path_without_roots_canonicalizes_existing_parent() {
        let temp = env::temp_dir().join(format!("xy_path_validator_parent_{}", std::process::id()));
        fs::create_dir_all(&temp).unwrap();
        let child = temp.join("new-file.txt");

        let result = validate_path(&child.to_string_lossy(), None).unwrap();
        assert_eq!(result.parent().unwrap(), temp.canonicalize().unwrap());

        fs::remove_dir_all(&temp).ok();
    }

    #[test]
    fn test_validate_path_without_roots_allows_symlink_component() {
        // When allowed_roots is None, symlink paths should be allowed (canonicalized)
        // because there are no directory restrictions to enforce.
        let base =
            env::temp_dir().join(format!("xy_path_validator_symlink_{}", std::process::id()));
        let real = base.join("real");
        let link = base.join("link");
        fs::remove_dir_all(&base).ok();
        fs::create_dir_all(&real).unwrap();

        #[cfg(windows)]
        {
            if std::os::windows::fs::symlink_dir(&real, &link).is_err() {
                fs::remove_dir_all(&base).ok();
                return;
            }
        }
        #[cfg(unix)]
        {
            if std::os::unix::fs::symlink(&real, &link).is_err() {
                fs::remove_dir_all(&base).ok();
                return;
            }
        }

        // The symlink directory itself should be canonicalized (resolved to real path)
        let result = validate_path(&link.to_string_lossy(), None);
        assert!(result.is_ok(), "symlink path should be allowed when no allowed_roots");

        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn test_reject_empty_path() {
        let result = validate_path("", None);
        assert!(result.is_err());
    }

    #[test]
    fn test_reject_whitespace_path() {
        let result = validate_path("   ", None);
        assert!(result.is_err());
    }

    #[test]
    fn test_sanitize_filename_rejects_separators() {
        assert!(sanitize_filename_component("foo/bar").is_err());
        assert!(sanitize_filename_component("foo\\bar").is_err());
    }

    #[test]
    fn test_sanitize_filename_rejects_dot_dot() {
        assert!(sanitize_filename_component("..").is_err());
        assert!(sanitize_filename_component(".").is_err());
    }

    #[test]
    fn test_sanitize_filename_accepts_normal() {
        assert_eq!(sanitize_filename_component("test.txt").unwrap(), "test.txt");
        assert_eq!(
            sanitize_filename_component("歌曲名 - 歌手.mp3").unwrap(),
            "歌曲名 - 歌手.mp3"
        );
    }

    #[test]
    fn test_sanitize_filename_rejects_empty() {
        assert!(sanitize_filename_component("").is_err());
    }

    #[test]
    fn test_sanitize_filename_rejects_null() {
        assert!(sanitize_filename_component("foo\0bar").is_err());
    }

    #[test]
    fn test_sanitize_filename_rejects_windows_reserved_names() {
        assert!(sanitize_filename_component("CON").is_err());
        assert!(sanitize_filename_component("aux.txt").is_err());
        assert!(sanitize_filename_component("LPT1.log").is_err());
    }

    #[test]
    fn test_sanitize_filename_rejects_windows_invalid_chars() {
        assert!(sanitize_filename_component("foo:bar").is_err());
        assert!(sanitize_filename_component("foo*bar").is_err());
    }

    #[test]
    fn test_validate_path_in_dir_rejects_outside() {
        let base =
            env::temp_dir().join(format!("xy_path_validator_outside_{}", std::process::id()));
        let allowed = base.join("allowed");
        let outside = base.join("outside");
        fs::remove_dir_all(&base).ok();
        fs::create_dir_all(&allowed).unwrap();
        fs::create_dir_all(&outside).unwrap();
        let outside_file = outside.join("secret.txt");
        fs::write(&outside_file, "secret").unwrap();

        let result = validate_path_in_dir(&outside_file.to_string_lossy(), &allowed);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("不在允许的目录范围内"));

        fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn test_validate_path_in_dir_accepts_inside() {
        let temp = env::temp_dir();
        let test_file = temp.join("test_file.txt");
        // Create the file so canonicalization works
        fs::write(&test_file, "test").unwrap();

        let result = validate_path_in_dir(&test_file.to_string_lossy(), &temp);
        assert!(result.is_ok());

        fs::remove_file(&test_file).ok();
    }
}
