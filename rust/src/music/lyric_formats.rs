//! 自研逐字歌词格式解析器（QRC / YRC / LYS / ESLRC）与 EQRC 解密封装。
//!
//! 依据各格式的公开文法原创实现（不依赖第三方歌词解析库）：
//!
//! - **QRC**（QQ 音乐逐字）：行 `[行起,行时长]词(词起,词长)词(词起,词长)...`，
//!   词文本位于其时间元组之前。QQ 服务器密文（hex → 3DES 级联 → zlib）解密后
//!   即此格式；也常见整份内容嵌在 `<Lyric_1 LyricContent="...">` 属性中的 XML
//!   壳（属性值含换行），逐行扫描时天然只命中属性内的内容行。
//! - **YRC**（网易逐字）：行 `[行起,行时长](词起,词长,0)词(词起,词长,0)词...`，
//!   时间元组位于词文本之前，第三段固定为 0。
//! - **LYS**（Lyricify Syllable）：行 `[属性位]词(词起,词长)词(词起,词长)...`，
//!   词文本位于时间元组之前；属性位数字：2/5=对唱、6/7=背景、8=两者兼有。
//! - **ESLRC**（Foobar ESLyric 插件逐字）：行 `[分:秒.毫秒]词[词止]词[词止]...`，
//!   词止时间戳在词文本之后，词起时间继承自上一个时间戳（首词=行时间戳）。
//!
//! 行级时间戳统一由词元组推导（首词起 / 末词止），并按首词起始时间稳定排序；
//! 时间单位毫秒，上限 999:99.999。

use std::borrow::Cow;

/// 时间戳上限（999:99.999），与管线内 `to_safe_ms` 的钳制口径一致。
const MAX_TIME_MS: u64 = 60_039_999;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct LyricWord<'a> {
    pub start_time: u64,
    pub end_time: u64,
    pub word: Cow<'a, str>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct LyricLine<'a> {
    pub words: Vec<LyricWord<'a>>,
    pub translated_lyric: Cow<'a, str>,
    pub roman_lyric: Cow<'a, str>,
    pub is_bg: bool,
    pub is_duet: bool,
    pub start_time: u64,
    pub end_time: u64,
}

/// 解析收尾：按首词起始时间稳定排序，并把行级时间戳补齐为首词起 / 末词止，
/// 词与行时间统一钳制到 `MAX_TIME_MS`。
fn finish_lines(mut lines: Vec<LyricLine>) -> Vec<LyricLine> {
    lines.sort_by(|left, right| {
        let left_start = left.words.first().map(|word| word.start_time);
        let right_start = right.words.first().map(|word| word.start_time);
        left_start.cmp(&right_start)
    });

    for line in lines.iter_mut() {
        line.start_time = line
            .words
            .first()
            .map(|word| word.start_time)
            .unwrap_or(0)
            .min(MAX_TIME_MS);
        line.end_time = line
            .words
            .last()
            .map(|word| word.end_time)
            .unwrap_or(0)
            .min(MAX_TIME_MS);
        for word in line.words.iter_mut() {
            word.start_time = word.start_time.min(MAX_TIME_MS);
            word.end_time = word.end_time.min(MAX_TIME_MS);
        }
    }

    lines
}

/// 解析行首 `[起,时长]` 时间头，返回头之后的剩余文本。数字段须为非空 ASCII 数字。
fn parse_line_header(src: &str) -> Option<&str> {
    let rest = src.strip_prefix('[')?;
    let comma = rest.find(',')?;
    rest[..comma].parse::<u64>().ok()?;
    let after = &rest[comma + 1..];
    let close = after.find(']')?;
    after[..close].parse::<u64>().ok()?;
    Some(&after[close + 1..])
}

/// 从 `src` 位置解析 `(起,时长)` 二段式词时间元组（QRC / LYS），返回元组后的剩余文本。
fn parse_two_part_tuple(src: &str) -> Option<(&str, u64, u64)> {
    let rest = src.strip_prefix('(')?;
    let comma = rest.find(',')?;
    let start = rest[..comma].parse::<u64>().ok()?;
    let after = &rest[comma + 1..];
    let close = after.find(')')?;
    let duration = after[..close].parse::<u64>().ok()?;
    Some((&after[close + 1..], start, duration))
}

/// 从 `src` 位置解析 `(起,时长,0)` 三段式词时间元组（YRC），返回元组后的剩余文本。
fn parse_three_part_tuple(src: &str) -> Option<(&str, u64, u64)> {
    let rest = src.strip_prefix('(')?;
    let first = rest.find(',')?;
    let start = rest[..first].parse::<u64>().ok()?;
    let after = &rest[first + 1..];
    let second = after.find(',')?;
    let duration = after[..second].parse::<u64>().ok()?;
    let tail = after[second + 1..].strip_prefix("0)")?;
    Some((tail, start, duration))
}

/// 解析「词文本在时间元组之前」的行内容（QRC / LYS）：
/// 从头扫描，第一个能完整解析出时间元组的位置之前的内容即为该词文本。
fn parse_words_before_time<'a>(
    src: &'a str,
    parse_tuple: fn(&'a str) -> Option<(&'a str, u64, u64)>,
) -> Vec<LyricWord<'a>> {
    let mut words = Vec::new();
    let mut rest = src;

    loop {
        let mut found = None;
        for (index, _) in rest.char_indices() {
            if let Some((after, start, duration)) = parse_tuple(&rest[index..]) {
                found = Some((index, after, start, duration));
                break;
            }
        }
        let Some((index, after, start, duration)) = found else {
            break;
        };

        words.push(LyricWord {
            start_time: start,
            end_time: start + duration,
            word: Cow::Borrowed(&rest[..index]),
        });
        rest = after;
    }

    words
}

/// 解析「时间元组在词文本之前」的行内容（YRC）：逐个消费 `(起,时长,0)` 元组，
/// 元组后到下一个 `(` 之前的文本即为该词文本（可为空）。
fn parse_words_after_time(src: &str) -> Vec<LyricWord<'_>> {
    let mut words = Vec::new();
    let mut rest = src;

    while let Some((after, start, duration)) = parse_three_part_tuple(rest) {
        let stop = after.find(['(', '\n', '\r']).unwrap_or(after.len());
        words.push(LyricWord {
            start_time: start,
            end_time: start + duration,
            word: Cow::Borrowed(&after[..stop]),
        });
        rest = &after[stop..];
    }

    words
}

/// 解析 LRC 风格时间戳 `[分:秒.毫秒]`（秒后的分隔符也接受 `:`），
/// 毫秒段取 1-3 位数字，按位数补齐为毫秒。返回时间戳之后的剩余文本。
fn parse_lrc_time(src: &str) -> Option<(&str, u64)> {
    let rest = src.strip_prefix('[')?;
    let colon = rest.find(':')?;
    let minutes = rest[..colon].parse::<u64>().ok()?;
    let after_minutes = &rest[colon + 1..];

    let stop = after_minutes.find([':', '.'])?;
    let seconds = after_minutes[..stop].parse::<u64>().ok()?;
    let after_seconds = &after_minutes[stop + 1..];

    let mut digits = 0usize;
    let mut fraction = 0u64;
    for ch in after_seconds.chars() {
        if digits == 3 || !ch.is_ascii_digit() {
            break;
        }
        fraction = fraction * 10 + u64::from(ch as u8 - b'0');
        digits += 1;
    }
    if digits == 0 {
        return None;
    }

    let tail = after_seconds[digits..].strip_prefix(']')?;
    let millis = match digits {
        1 => fraction * 100,
        2 => fraction * 10,
        _ => fraction,
    };
    let total = minutes
        .saturating_mul(60_000)
        .saturating_add(seconds.saturating_mul(1_000))
        .saturating_add(millis);
    Some((tail, total))
}

/// QRC：逐行扫描 `[起,时长]` 开头的行，行内按「词文本在前、`(起,时长)` 元组在后」
/// 解析逐字时间。XML 壳与 LRC 元数据行不含合法行头，会被自然跳过。
pub fn parse_qrc(src: &str) -> Vec<LyricLine<'_>> {
    let mut lines = Vec::new();
    for raw in src.lines() {
        let Some(remainder) = parse_line_header(raw) else {
            continue;
        };
        lines.push(LyricLine {
            words: parse_words_before_time(remainder, parse_two_part_tuple),
            ..LyricLine::default()
        });
    }
    finish_lines(lines)
}

/// YRC：逐行扫描 `[起,时长]` 开头的行，行内按「`(起,时长,0)` 元组在前、词文本在后」
/// 解析逐字时间。
pub fn parse_yrc(src: &str) -> Vec<LyricLine<'_>> {
    let mut lines = Vec::new();
    for raw in src.lines() {
        let Some(remainder) = parse_line_header(raw) else {
            continue;
        };
        lines.push(LyricLine {
            words: parse_words_after_time(remainder),
            ..LyricLine::default()
        });
    }
    finish_lines(lines)
}

/// LYS：逐行扫描 `[属性位]` 开头的行，行内按「词文本在前、`(起,时长)` 元组在后」
/// 解析逐字时间。属性位映射背景/对唱标注，其余属性值视为普通行。
pub fn parse_lys(src: &str) -> Vec<LyricLine<'_>> {
    let mut lines = Vec::new();
    for raw in src.lines() {
        let Some(rest) = raw.strip_prefix('[') else {
            continue;
        };
        let Some(close) = rest.find(']') else {
            continue;
        };
        // 属性位必须是纯数字（否则是 LRC 元数据行等非 LYS 内容，整行放弃），
        // 数字含义：2/5=对唱、6/7=背景、8=两者兼有，其余视为普通行。
        let (is_bg, is_duet) = match rest[..close].parse::<u8>() {
            Ok(2) | Ok(5) => (false, true),
            Ok(6) | Ok(7) => (true, false),
            Ok(8) => (true, true),
            _ => (false, false),
        };
        let remainder = &rest[close + 1..];
        lines.push(LyricLine {
            words: parse_words_before_time(remainder, parse_two_part_tuple),
            is_bg,
            is_duet,
            ..LyricLine::default()
        });
    }
    finish_lines(lines)
}

/// 解析单行 ESLRC：行时间戳后循环「至少 1 字符的词文本 + `[词止时间戳]`」，
/// 词起时间继承上一个时间戳。行未以时间戳收尾或中段时间戳非法时整行放弃。
fn parse_eslrc_line(line: &str) -> Option<Vec<LyricWord<'_>>> {
    let (mut rest, mut cursor) = parse_lrc_time(line)?;
    let mut words = Vec::new();

    while !rest.trim().is_empty() {
        let open = rest.find('[')?;
        if open == 0 {
            return None;
        }
        let (next, end) = parse_lrc_time(&rest[open..])?;
        words.push(LyricWord {
            start_time: cursor,
            end_time: end,
            word: Cow::Borrowed(&rest[..open]),
        });
        cursor = end;
        rest = next;
    }

    Some(words)
}

/// ESLRC：逐行扫描 `行时间戳 + 词文本/词止时间戳交替` 的逐字行，空行跳过。
pub fn parse_eslrc(src: &str) -> Vec<LyricLine<'_>> {
    let mut lines = Vec::new();
    for raw in src.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(words) = parse_eslrc_line(line) {
            lines.push(LyricLine {
                words,
                ..LyricLine::default()
            });
        }
    }
    finish_lines(lines)
}

/// 解密 QQ QRC 加密歌词密文（hex）。算法复用 lyric_fetcher 中与 BakaMusic
/// 对齐的 3DES 级联 + zlib 实现；解密失败时返回空串（由上游候选评分自然淘汰）。
pub fn decrypt_qrc_hex(encrypted_hex: &str) -> String {
    crate::music::lyric_fetcher::qrc_decrypt(encrypted_hex).unwrap_or_default()
}
