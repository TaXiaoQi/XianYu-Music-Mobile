//! 文件名元数据反解公共能力（声影同款正则）。
//!
//! 「01. 歌名 - 歌手 (feat. X).flac」一类的命名在本地曲库、远程/WebDAV、
//! 网盘三条线上都存在，反解规则统一收口在本模块：前导曲目序号剥离、
//! feat/ft/featuring/with 合作标注括号清理、纯数字段判非歌手、按优先级
//! 分隔符切分「歌名 - 歌手」。各线差异只在回退时机（本地 tag 缺失回退、
//! 远程无 tag 直接反解、网盘按播放上下文反解）。

use regex::Regex;
use std::sync::OnceLock;

/// 去扩展名（无点时原样返回；仅最后一个点视作扩展名分隔）。
pub fn title_from_name(name: &str) -> String {
	name
		.rsplit_once('.')
		.map(|(stem, _)| stem.to_string())
		.unwrap_or_else(|| name.to_string())
}

/// 前导曲目序号（01. / 02 - / 03_ / 01、）——序号残留会污染歌名与排序。
pub fn strip_leading_index(stem: &str) -> String {
	static RE: OnceLock<Regex> = OnceLock::new();
	RE.get_or_init(|| Regex::new(r"^\d{1,3}\s*[.\-–—－、_]\s*").unwrap())
		.replace(stem, "")
		.into_owned()
		.trim()
		.to_string()
}

/// 歌手段剔除 feat/ft/featuring/with 合作标注括号：车机 AVRCP 展示与
/// 搜索匹配用主歌手名即可，完整标注仍在原文件名可查。
pub fn strip_feat_group(artist: &str) -> String {
	static RE: OnceLock<Regex> = OnceLock::new();
	RE.get_or_init(|| {
		Regex::new(r"(?i)\s*[（(][^）)]*(feat|ft|featuring|with)[^）)]*[）)]").unwrap()
	})
	.replace_all(artist, "")
	.trim()
	.to_string()
}

/// 纯数字歌段不算歌手：「晴天 - 123」的 123 是编号不是歌手。
pub fn is_all_digits(s: &str) -> bool {
	!s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

/// 文件名 → (歌名, 歌手)。分隔符优先级「 - 」> - > – > — > ＞－；
/// 从右往左切（rsplit），段1=歌名、段2=歌手（与网盘线约定一致）；
/// 歌段经 feat 清理，全段切不中或歌段无效返回 None。
pub fn split_filename_title_artist(name: &str) -> Option<(String, String)> {
	let stem = strip_leading_index(&title_from_name(name));
	let separators = [" - ", "-", " – ", "–", " — ", "—", "－"];
	for separator in separators {
		let Some((left, right)) = stem.rsplit_once(separator) else {
			continue;
		};
		let title = left.trim();
		let artist = strip_feat_group(right);
		if !title.is_empty() && !artist.is_empty() && !is_all_digits(&artist) {
			return Some((title.to_string(), artist));
		}
	}
	None
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn split_strips_leading_index_and_feat() {
		// 前导序号剥离 + feat 括号清理
		assert_eq!(
			split_filename_title_artist("01. 晴天 - 周杰伦 (feat. 方文山).flac"),
			Some(("晴天".to_string(), "周杰伦".to_string()))
		);
		// 全角破折号分隔
		assert_eq!(
			split_filename_title_artist("07、七里香－周杰伦.mp3"),
			Some(("七里香".to_string(), "周杰伦".to_string()))
		);
		// 无序号无 feat 行为不变
		assert_eq!(
			split_filename_title_artist("7 Years-Lukas Graham.mp3"),
			Some(("7 Years".to_string(), "Lukas Graham".to_string()))
		);
		// 纯数字歌段不算歌手
		assert_eq!(split_filename_title_artist("晴天 - 123.mp3"), None);
		// 普通括号歌手名不动
		assert_eq!(
			split_filename_title_artist("晴天 - 周杰伦 (Live).mp3"),
			Some(("晴天".to_string(), "周杰伦 (Live)".to_string()))
		);
	}

	#[test]
	fn strip_leading_index_variants() {
		assert_eq!(strip_leading_index("01. 晴天"), "晴天");
		assert_eq!(strip_leading_index("7 Years"), "7 Years");
		assert_eq!(strip_leading_index("128. 数字开头歌名"), "数字开头歌名");
		// 超过三位数字不是曲目序号
		assert_eq!(strip_leading_index("1999. 年代歌"), "1999. 年代歌");
	}
}
