// 自研逐字歌词格式解析器（QRC / YRC / LYS / ESLRC）。
// 与桌面端 XianYu-Music-Desktop 的 native_parse.rs 同源统一：三端共用同一套
// 解析文法与后处理规则（行排序、时间钳制、宽松容错一致）。
// 解密层各端自有：本端 delegate 到 lyric_fetcher::qrc_decrypt
// （QQ 魔改 3DES 级联 + zlib，API 层共用），桌面端为 qq_des.rs。
// 本模块自带单元测试；跨端回归以既有 fixture 测试为准。

/// 行/词时间统一上限：999:99.999。
const MAX_TIME_MS: u64 = 60_039_999;

// ---------- 数据结构 ----------

#[derive(Debug, Clone, PartialEq, Default)]
pub struct LyricWord {
    pub start_time: u64,
    pub end_time: u64,
    pub word: String,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct LyricLine {
    pub words: Vec<LyricWord>,
    pub translated_lyric: String,
    pub roman_lyric: String,
    pub is_bg: bool,
    pub is_duet: bool,
    pub start_time: u64,
    pub end_time: u64,
}

/// 共享后处理：按首词起始时间稳定排序；行时间取首词 start / 尾词 end 并钳制。
fn process_lyrics(lines: &mut Vec<LyricLine>) {
    lines.sort_by(|a, b| {
        a.words
            .first()
            .map(|x| x.start_time)
            .cmp(&b.words.first().map(|x| x.start_time))
    });
    for line in lines.iter_mut() {
        line.start_time = line
            .words
            .first()
            .map(|x| x.start_time)
            .unwrap_or(0)
            .clamp(0, MAX_TIME_MS);
        line.end_time = line
            .words
            .last()
            .map(|x| x.end_time)
            .unwrap_or(0)
            .clamp(0, MAX_TIME_MS);
        for word in line.words.iter_mut() {
            word.start_time = word.start_time.clamp(0, MAX_TIME_MS);
            word.end_time = word.end_time.clamp(0, MAX_TIME_MS);
        }
    }
}

// ---------- 行级时间戳头 `[start,duration]`（QRC / YRC 共用） ----------

/// `[整数,整数]`；两侧都必须是非负十进制整数（≥1 位）。
fn parse_span_header(src: &str) -> Option<(&str, u64, u64)> {
    let rest = src.strip_prefix('[')?;
    let comma = rest.find(',')?;
    if comma == 0 {
        return None;
    }
    let start_time: u64 = rest[..comma].parse().ok()?;
    let rest = &rest[comma + 1..];
    let close = rest.find(']')?;
    if close == 0 {
        return None;
    }
    let duration: u64 = rest[..close].parse().ok()?;
    Some((&rest[close + 1..], start_time, duration))
}

// ---------- 词级时间戳 `(start,duration)`（QRC / LYS 共用） ----------

fn parse_word_time_paren(src: &str) -> Option<(&str, u64, u64)> {
    let rest = src.strip_prefix('(')?;
    let comma = rest.find(',')?;
    if comma == 0 {
        return None;
    }
    let start_time: u64 = rest[..comma].parse().ok()?;
    let rest = &rest[comma + 1..];
    let close = rest.find(')')?;
    if close == 0 {
        return None;
    }
    let duration: u64 = rest[..close].parse().ok()?;
    Some((&rest[close + 1..], start_time, duration))
}

/// QRC/LYS 的词扫描：从当前位置起逐字符尝试，第一个能接上合法
/// `(start,duration)` 的位置之前的所有文本即为一个词。
fn next_word_paren(src: &str) -> Option<(&str, LyricWord)> {
    for (i, _) in src.char_indices() {
        if let Some((rest, start_time, duration)) = parse_word_time_paren(&src[i..]) {
            return Some((
                rest,
                LyricWord {
                    start_time,
                    end_time: start_time + duration,
                    word: src[..i].to_string(),
                },
            ));
        }
    }
    None
}

fn parse_words_paren(src: &str) -> Vec<LyricWord> {
    let mut words = Vec::new();
    let mut cur = src;
    while let Some((rest, word)) = next_word_paren(cur) {
        words.push(word);
        cur = rest;
    }
    words
}

// ---------- QRC ----------

fn parse_qrc_line(line: &str) -> Option<LyricLine> {
    let (content, _, _) = parse_span_header(line)?;
    Some(LyricLine {
        words: parse_words_paren(content),
        ..Default::default()
    })
}

pub fn parse_qrc(src: &str) -> Vec<LyricLine> {
    let mut result: Vec<LyricLine> = src.lines().filter_map(parse_qrc_line).collect();
    process_lyrics(&mut result);
    result
}

// ---------- YRC ----------

/// YRC 词时间是三段式 `(start,duration,0)`，第三段固定字面 `0`。
fn parse_word_time_yrc(src: &str) -> Option<(&str, u64, u64)> {
    let rest = src.strip_prefix('(')?;
    let comma = rest.find(',')?;
    if comma == 0 {
        return None;
    }
    let start_time: u64 = rest[..comma].parse().ok()?;
    let rest = &rest[comma + 1..];
    let comma = rest.find(',')?;
    if comma == 0 {
        return None;
    }
    let duration: u64 = rest[..comma].parse().ok()?;
    let rest = rest[comma + 1..].strip_prefix("0)")?;
    Some((rest, start_time, duration))
}

fn parse_yrc_line(line: &str) -> Option<LyricLine> {
    let (content, _, _) = parse_span_header(line)?;
    let mut words = Vec::new();
    let mut cur = content;
    while let Some((rest, start_time, duration)) = parse_word_time_yrc(cur) {
        // 词文本 = 该时间戳之后直到下一个 `(` 之前的所有内容（可为空）。
        let end = rest.find('(').unwrap_or(rest.len());
        words.push(LyricWord {
            start_time,
            end_time: start_time + duration,
            word: rest[..end].to_string(),
        });
        cur = &rest[end..];
    }
    Some(LyricLine {
        words,
        ..Default::default()
    })
}

pub fn parse_yrc(src: &str) -> Vec<LyricLine> {
    let mut result: Vec<LyricLine> = src.lines().filter_map(parse_yrc_line).collect();
    process_lyrics(&mut result);
    result
}

// ---------- LYS ----------

/// LYS 行首属性 `[n]`：2/5 → 对唱标记，6/7 → 背景词，8 → 二者兼有。
/// 属性位必须是纯数字（否则是 LRC 元数据行等非 LYS 内容，整行放弃）；
/// 超大数值原实现会 panic，这里宽松降级为无标记。
fn parse_lys_property(src: &str) -> Option<(&str, bool, bool)> {
    let rest = src.strip_prefix('[')?;
    let close = rest.find(']')?;
    if close == 0 || !rest[..close].bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let prop = rest[..close].parse::<u64>().ok()?;
    let (is_bg, is_duet) = match prop {
        2 | 5 => (false, true),
        6 | 7 => (true, false),
        8 => (true, true),
        _ => (false, false),
    };
    Some((&rest[close + 1..], is_bg, is_duet))
}

fn parse_lys_line(line: &str) -> Option<LyricLine> {
    let (content, is_bg, is_duet) = parse_lys_property(line)?;
    Some(LyricLine {
        words: parse_words_paren(content),
        is_bg,
        is_duet,
        ..Default::default()
    })
}

pub fn parse_lys(src: &str) -> Vec<LyricLine> {
    let mut result: Vec<LyricLine> = src.lines().filter_map(parse_lys_line).collect();
    process_lyrics(&mut result);
    result
}

// ---------- ESLRC ----------

/// `分:秒.毫秒` 时间戳（`[mm:ss.xx]`）；毫秒段取 1-3 位数字，按位数补齐为毫秒。
/// 秒分隔符也接受 `:`（如 `[168:10:254]`），且必须真实存在；
/// 多于 3 位毫秒时整行失败（由尾部 `]` 校验兜住）。
fn parse_lrc_clock(src: &str) -> Option<(&str, u64)> {
    let rest = src.strip_prefix('[')?;
    let colon = rest.find(':')?;
    if colon == 0 {
        return None;
    }
    let min: u64 = rest[..colon].parse().ok()?;
    let rest = &rest[colon + 1..];
    // 秒读到下一个 `:` 或 `.`（取先出现者）；缺失分隔符时整行非法。
    let sec_end = rest.find(|c| c == ':' || c == '.')?;
    if sec_end == 0 {
        return None;
    }
    let sec: u64 = rest[..sec_end].parse().ok()?;
    let rest = &rest[sec_end + 1..];
    // 毫秒必须紧跟 1-3 位数字。
    let ms_len = rest
        .bytes()
        .take(3)
        .take_while(|b| b.is_ascii_digit())
        .count() as usize;
    if ms_len == 0 {
        return None;
    }
    let mut ms: u64 = rest[..ms_len].parse().ok()?;
    match ms_len {
        1 => ms *= 100,
        2 => ms *= 10,
        _ => {}
    }
    let rest = rest[ms_len..].strip_prefix(']')?;
    // saturating：超长分钟位等异常输入不应触发溢出 panic（后续钳制会归一）。
    let total = min
        .saturating_mul(60 * 1000)
        .saturating_add(sec.saturating_mul(1000))
        .saturating_add(ms);
    Some((rest, total))
}

fn parse_eslrc_line(line: &str) -> Option<LyricLine> {
    let (mut src, mut start_time) = parse_lrc_clock(line)?;
    let mut result = LyricLine::default();
    while !src.trim().is_empty() {
        // 每个词的文本读到下一个 `[`；紧邻的 `][` 视为非法整行失败。
        let open = src.find('[')?;
        if open == 0 {
            return None;
        }
        let (rest, end_time) = parse_lrc_clock(&src[open..])?;
        result.words.push(LyricWord {
            start_time,
            end_time,
            word: src[..open].to_string(),
        });
        src = rest;
        start_time = end_time;
    }
    Some(result)
}

pub fn parse_eslrc(src: &str) -> Vec<LyricLine> {
    let mut result: Vec<LyricLine> = Vec::new();
    for line in src.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if let Some(parsed) = parse_eslrc_line(line.trim()) {
            result.push(parsed);
        }
    }
    process_lyrics(&mut result);
    result
}

// ---------- 加密 QRC（QQ 魔改 3DES + zlib，复用 lyric_fetcher 实现） ----------

/// 解密十六进制密文 QRC；解密失败按空串处理（由上游候选评分自然淘汰）。
pub fn decrypt_qrc_hex(encrypted_hex: &str) -> String {
    crate::music::lyric_fetcher::qrc_decrypt(encrypted_hex).unwrap_or_default()
}

#[cfg(test)]
mod lyric_formats_tests {
    use super::*;

    #[test]
    fn qrc_word_scan_absorbs_literal_text_before_tuple() {
        let words = parse_words_paren("Counting(0,18) (18,18)Stars(36,18)");
        assert_eq!(words.len(), 3);
        assert_eq!(words[0].word, "Counting");
        assert_eq!(words[0].start_time, 0);
        assert_eq!(words[0].end_time, 18);
        assert_eq!(words[1].word, " ");
        assert_eq!(words[2].word, "Stars");
    }

    #[test]
    fn qrc_header_requires_two_integers() {
        assert!(parse_qrc_line("[1,2]a(3,4)").is_some());
        assert!(parse_qrc_line("[,2]a(3,4)").is_none());
        assert!(parse_qrc_line("[1,]a(3,4)").is_none());
        assert!(parse_qrc_line("1,2]a(3,4)").is_none());
    }

    #[test]
    fn yrc_third_param_must_be_literal_zero() {
        assert!(parse_word_time_yrc("(1,2,0)").is_some());
        assert!(parse_word_time_yrc("(1,2,3)").is_none());
        assert!(parse_word_time_yrc("(1,2)").is_none());
    }

    #[test]
    fn lys_property_maps_flags() {
        assert_eq!(parse_lys_property("[0]x"), Some(("x", false, false)));
        assert_eq!(parse_lys_property("[2]x"), Some(("x", false, true)));
        assert_eq!(parse_lys_property("[6]x"), Some(("x", true, false)));
        assert_eq!(parse_lys_property("[8]x"), Some(("x", true, true)));
        assert_eq!(parse_lys_property("[999]x"), Some(("x", false, false)));
        assert_eq!(parse_lys_property("[]x"), None);
        assert_eq!(parse_lys_property("[0a]x"), None);
    }

    #[test]
    fn lrc_clock_accepts_one_to_three_digit_ms() {
        assert_eq!(parse_lrc_clock("[00:01.12]"), Some(("", 1120)));
        assert_eq!(parse_lrc_clock("[00:10.254]"), Some(("", 10254)));
        assert_eq!(parse_lrc_clock("[01:10.1]"), Some(("", 70100)));
        assert_eq!(parse_lrc_clock("[168:10:254]"), Some(("", 10090254)));
        assert_eq!(parse_lrc_clock("[168:10.254233]"), None);
        // 无毫秒分隔符的残缺行不得 panic。
        assert_eq!(parse_lrc_clock("[00:10"), None);
    }

    #[test]
    fn eslrc_chains_word_end_to_next_word_start() {
        let lines = parse_eslrc("[00:10.82]Test[00:10.97] Word[00:12.62]");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].word, "Test");
        assert_eq!(lines[0].words[0].start_time, 10820);
        assert_eq!(lines[0].words[0].end_time, 10970);
        assert_eq!(lines[0].words[1].word, " Word");
        assert_eq!(lines[0].words[1].end_time, 12620);
        assert_eq!(lines[0].start_time, 10820);
        assert_eq!(lines[0].end_time, 12620);
    }

    #[test]
    fn process_lyrics_sorts_by_first_word_and_derives_line_times() {
        let mut lines = vec![
            LyricLine {
                words: vec![LyricWord { start_time: 200, end_time: 300, word: "b".into() }],
                ..Default::default()
            },
            LyricLine {
                words: vec![
                    LyricWord { start_time: 100, end_time: 150, word: "a".into() },
                    LyricWord { start_time: 150, end_time: 180, word: "c".into() },
                ],
                start_time: 999,
                end_time: 0,
                ..Default::default()
            },
        ];
        process_lyrics(&mut lines);
        assert_eq!(lines[0].words[0].word, "a");
        assert_eq!(lines[0].start_time, 100);
        assert_eq!(lines[0].end_time, 180);
        assert_eq!(lines[1].start_time, 200);
        assert_eq!(lines[1].end_time, 300);
    }

    #[test]
    fn decrypt_qrc_hex_on_garbage_yields_empty() {
        assert_eq!(decrypt_qrc_hex("zz zz"), "");
        assert_eq!(decrypt_qrc_hex("abc"), "");
    }
}
