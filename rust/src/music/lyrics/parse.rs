use super::*;

// ==================== 演唱者/和声标注（移植自桌面端 BakaMusic 体系） ====================
pub(crate) static CREDIT_LINE_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static NON_SPEAKER_LABEL_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static SPEAKER_PREFIX_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static PARENTHETICAL_VOCAL_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static LQE_LIKE_MARKER_RE: OnceLock<Regex> = OnceLock::new();

/// 制作信息行（作词/作曲/编曲/演唱/混音等），不是可演唱歌词，应排除出主歌词。
pub(crate) fn is_credit_line(text: &str) -> bool {
    let re = CREDIT_LINE_RE.get_or_init(|| {
        Regex::new(r"^(?:(?:作)?词|(?:作)?詞|曲|作曲|编曲|編曲|词曲|詞曲|原唱|演唱|歌手|制作(?:人)?|製作(?:人)?|出品|发行|發行|策划|策劃|统筹|統籌|监制|監製|导演|導演|混音|母带|母帶|录音|錄音|和声|和聲|翻唱|原曲|歌名|歌曲|专辑|專輯|标题|標題|调教|調教|调声|調聲|曲绘|曲繪|曲絵|绘图|繪圖|画师|畫師|视频|視頻|映像|动画|動畫|written\s+by|vocal|lyrics?|lyricist|composer|music|arrange(?:r|ment)?|producer|produced\s+by|mix|master(?:ing)?|recording|staff|pv|mv|movie|video|animation|illustration|illustrator)\s*[:：]").unwrap()
    });
    re.is_match(text.trim())
}

/// 检测演唱者标签前缀（`A:`、`男:`、`v1:` 等），返回 (演唱者名, 去除前缀后的文本)。
/// 排除制作信息行与 `http:` 等非演唱者标签。
pub(crate) fn detect_speaker_prefix(text: &str) -> (Option<String>, String) {
    let trimmed = text.trim();
    if trimmed.is_empty() || is_credit_line(trimmed) {
        return (None, trimmed.to_string());
    }

    let re = SPEAKER_PREFIX_RE
        .get_or_init(|| Regex::new(r"^\s*([^:：\r\n]{1,24}?)\s*[:：]\s*").unwrap());
    let Some(caps) = re.captures(trimmed) else {
        return (None, trimmed.to_string());
    };
    let name = caps.get(1).map(|m| m.as_str().trim()).unwrap_or("");
    if name.is_empty() || name.eq_ignore_ascii_case("http") || name.eq_ignore_ascii_case("https") {
        return (None, trimmed.to_string());
    }

    let non_speaker = NON_SPEAKER_LABEL_RE.get_or_init(|| {
        Regex::new(r"^(?:制作|出品|发行|發行|策划|策劃|监制|監製|混音|母带|母帶|录音|錄音|和声|和聲|翻唱|原曲|歌名|歌曲|专辑|專輯|标题|標題|调教|調教|调声|調聲|曲绘|曲繪|曲絵|绘图|繪圖|画师|畫師|视频|視頻|映像|动画|動畫|artist|album|title|producer|produced\s+by|mix|master(?:ing)?|staff|pv|mv|movie|video|animation|illustration|illustrator)$").unwrap()
    });
    if non_speaker.is_match(name) {
        return (None, trimmed.to_string());
    }

    let consumed = caps.get(0).map(|m| m.len()).unwrap_or(0);
    let rest = trimmed[consumed..].trim().to_string();
    (Some(name.to_string()), rest)
}

/// 整行被 `()` 或 `[]` 整体包裹 → 背景和声行，返回去除包裹后的文本。
pub(crate) fn strip_whole_wrapped(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let inner = if trimmed.starts_with('(') && trimmed.ends_with(')') {
        &trimmed[1..trimmed.len() - 1]
    } else if trimmed.starts_with('[') && trimmed.ends_with(']') {
        &trimmed[1..trimmed.len() - 1]
    } else {
        return None;
    };
    let inner = inner.trim();
    if inner.is_empty() {
        return None;
    }
    Some(inner.to_string())
}

pub(crate) fn contains_kana(text: &str) -> bool {
    text.chars().any(is_kana_char)
}

pub(crate) fn contains_hangul(text: &str) -> bool {
    text.chars().any(is_hangul_char)
}

/// 判断括号内容是否为和声段（含明确和声标记，或为短内容且非已知标签）。
pub(crate) fn is_vocal_parenthetical(content: &str) -> bool {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return false;
    }
    let lower = trimmed.to_lowercase();
    if lower.contains("和声")
        || lower.contains("伴唱")
        || lower.contains("合唱")
        || lower.contains("合声")
        || lower.contains("backup")
        || lower.contains("background")
        || lower.contains("harmony")
    {
        return true;
    }
    let known_labels = [
        "翻译", "译文", "注音", "罗马音", "罗马字", "音译", "旁白", "独白", "对白", "白",
        "男", "女", "合", "主", "伴", "os", "intro", "outro", "间奏", "前奏", "尾奏",
    ];
    if trimmed.chars().count() <= 6 && !known_labels.contains(&lower.as_str()) {
        return true;
    }
    false
}

/// 拆分主行内嵌的括号和声：`主唱 啦啦啦 (和声 哦哦哦)` → (主唱 啦啦啦, 和声 哦哦哦)。
/// 假名/谚文括号通常是注音，跳过。
pub(crate) fn split_parenthetical_vocal(text: &str) -> Option<(String, String)> {
    let re = PARENTHETICAL_VOCAL_RE
        .get_or_init(|| Regex::new(r"[（(]([^()（）\r\n]+)[)）]").unwrap());
    let mut main_parts = Vec::new();
    let mut duet_parts = Vec::new();
    let mut last_end = 0usize;
    let mut found = false;

    for caps in re.captures_iter(text) {
        let full = caps.get(0).unwrap();
        let content = caps.get(1).unwrap().as_str().trim();
        if content.is_empty() {
            continue;
        }
        if !is_vocal_parenthetical(content) {
            continue;
        }
        if contains_kana(content) || contains_hangul(content) {
            continue;
        }
        found = true;
        main_parts.push(&text[last_end..full.start()]);
        duet_parts.push(content);
        last_end = full.end();
    }
    if !found {
        return None;
    }
    main_parts.push(&text[last_end..]);

    let main_text = main_parts
        .concat()
        .replace('\u{a0}', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let duet_text = duet_parts.join(" ");
    if main_text.trim().is_empty() || duet_text.trim().is_empty() {
        return None;
    }
    Some((main_text, duet_text))
}

/// 判断歌词是否呈现对唱/和声证据：存在演唱者标签前缀，或出现多个不同的括号和声段。
/// 近似 BakaMusic 的"双歌手"门控——无对唱证据时不拆分括号，避免误伤普通括号歌词。
pub(crate) fn has_duet_vocal_evidence(lines: &[ParsedLine]) -> bool {
    let mut speaker_count = 0;
    let mut vocal_contents = HashSet::new();
    let re = PARENTHETICAL_VOCAL_RE
        .get_or_init(|| Regex::new(r"[（(]([^()（）\r\n]+)[)）]").unwrap());
    for line in lines {
        if line.speaker.is_some() {
            speaker_count += 1;
        }
        for caps in re.captures_iter(&line.text) {
            let content = caps.get(1).unwrap().as_str().trim();
            if is_vocal_parenthetical(content)
                && !contains_kana(content)
                && !contains_hangul(content)
            {
                vocal_contents.insert(content.to_string());
            }
        }
    }
    speaker_count >= 2 || vocal_contents.len() >= 2
}

/// 对解析出的行做演唱者/和声标注：整行背景和声、演唱者前缀、括号和声拆分。
pub(crate) fn annotate_line_vocals(lines: &mut Vec<ParsedLine>) {
    let mut expanded = Vec::with_capacity(lines.len());
    for mut line in lines.drain(..) {
        if let Some(inner) = strip_whole_wrapped(&line.text) {
            line.is_bg = true;
            line.text = inner;
        }

        let (speaker, rest) = detect_speaker_prefix(&line.text);
        if let Some(speaker) = speaker {
            line.speaker = Some(speaker);
            line.text = rest;
            line.is_duet = true;
        }

        expanded.push(line);
    }
    *lines = expanded;

    // 括号和声拆分仅在歌词存在对唱证据时进行（近似 BakaMusic 的双歌手门控）。
    if !has_duet_vocal_evidence(lines) {
        return;
    }
    let mut split = Vec::with_capacity(lines.len());
    for mut line in lines.drain(..) {
        if !line.is_bg {
            if let Some((main_text, duet_text)) = split_parenthetical_vocal(&line.text) {
                line.text = main_text;
                let mut partner = line.clone();
                partner.text = duet_text;
                partner.is_bg = true;
                partner.is_duet_partner = true;
                partner.is_duet = false;
                partner.speaker = None;
                split.push(line);
                split.push(partner);
                continue;
            }
        }
        split.push(line);
    }
    *lines = split;
}

/// 解析 LRC 头部元数据标签：`[offset:±ms]`、`[ti:标题]`、`[ar:歌手]`、`[al:专辑]`、
/// `[by:编辑者]`、`[re:制作]`、`[ve:版本]`。`offset` 为正表示歌词整体延后，负表示提前。
pub(crate) fn extract_lyrics_meta(raw: &str) -> LyricsMeta {
    let mut meta = LyricsMeta::default();
    for line in raw.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with('[') {
            continue;
        }
        let Some(close) = trimmed.find(']') else {
            continue;
        };
        let tag = &trimmed[1..close];
        let value = trimmed[close + 1..].trim();
        let lower = tag.to_ascii_lowercase();
        if let Some(offset) = lower.strip_prefix("offset:") {
            if let Ok(ms) = offset.trim().parse::<i64>() {
                meta.offset_ms = ms;
            }
        } else if let Some(title) = lower.strip_prefix("ti:") {
            if !title.trim().is_empty() {
                meta.title = Some(value.to_string());
            }
        } else if let Some(artist) = lower.strip_prefix("ar:") {
            if !artist.trim().is_empty() {
                meta.artist = Some(value.to_string());
            }
        } else if let Some(album) = lower.strip_prefix("al:") {
            if !album.trim().is_empty() {
                meta.album = Some(value.to_string());
            }
        } else if let Some(by) = lower.strip_prefix("by:") {
            if !by.trim().is_empty() {
                meta.by = Some(value.to_string());
            }
        } else if let Some(re) = lower.strip_prefix("re:") {
            if !re.trim().is_empty() {
                meta.re = Some(value.to_string());
            }
        } else if let Some(ve) = lower.strip_prefix("ve:") {
            if !ve.trim().is_empty() {
                meta.ve = Some(value.to_string());
            }
        }
    }
    meta
}

/// 对解析出的行应用 `[offset:]` 时间偏移（含逐字词时间）。
pub(crate) fn apply_lyrics_offset(lines: &mut [ParsedLine], offset_ms: i64) {
    if offset_ms == 0 {
        return;
    }
    for line in lines.iter_mut() {
        line.start_ms = (line.start_ms as i64 + offset_ms).max(0) as u32;
        line.end_ms = (line.end_ms as i64 + offset_ms).max(0) as u32;
        if let Some(words) = &mut line.words {
            for word in words.iter_mut() {
                word.start_ms = (word.start_ms as i64 + offset_ms).max(0) as u32;
                word.end_ms = (word.end_ms as i64 + offset_ms).max(0) as u32;
            }
        }
    }
}

/// LRC 里的空时间行可能是上一句的收尾标记，也可能只是音源用来和翻译、罗马音
/// 逐行对齐的占位。只有后面确实接着一段静默（≥4s）时才当作收尾采信，否则上一句
/// 会在还在演唱时就被截断淡出。空行本身不进入渲染。
pub(crate) fn finalize_lrc_blank_lines(lines: Vec<ParsedLine>) -> Vec<ParsedLine> {
    const BLANK_LINE_INTERLUDE_MS: u32 = 4000;
    let mut meaningful: Vec<ParsedLine> = Vec::with_capacity(lines.len());
    for (index, line) in lines.iter().enumerate() {
        if !line.text.trim().is_empty() {
            meaningful.push(line.clone());
            continue;
        }
        let Some(previous) = meaningful.last_mut() else {
            continue;
        };
        // 上一句已有显式结束时间（非 LRC 默认 start+5000）则跳过
        if previous.end_ms != previous.start_ms.saturating_add(5000) {
            continue;
        }
        if line.start_ms <= previous.start_ms {
            continue;
        }
        let next_lyric = lines[index + 1..]
            .iter()
            .find(|candidate| !candidate.text.trim().is_empty());
        if let Some(next) = next_lyric {
            if next.start_ms.saturating_sub(line.start_ms) < BLANK_LINE_INTERLUDE_MS {
                continue;
            }
        }
        previous.end_ms = line.start_ms;
    }
    meaningful
}

/// 解析前的文本预处理：统一换行、解码 HTML 实体、还原转义换行、过滤注释行。
pub(crate) fn preprocess_lyrics_text(raw: &str) -> String {
    let mut normalized = raw
        .replace('\u{FEFF}', "")
        .replace("\r\n", "\n")
        .replace('\r', "\n");

    normalized = crate::music::lyric_fetcher::decode_html_entities(&normalized);

    // 部分来源（如 JSON 内嵌歌词）会把多行用字面量 \n 拼在单行里，还原为真实换行。
    normalized = normalized.replace("\\n", "\n");

    // 过滤注释行：以 //、#、; 开头且不含时间戳的行属于注释/说明，直接丢弃。
    // # 开头的十六进制颜色（如 #ffffff）不视为注释。
    let mut filtered = String::with_capacity(normalized.len());
    for line in normalized.split('\n') {
        let trimmed = line.trim_start();
        let is_hex_color = trimmed
            .strip_prefix('#')
            .is_some_and(|rest| {
                (rest.len() == 3 || rest.len() == 6) && rest.chars().all(|c| c.is_ascii_hexdigit())
            });
        let is_comment = trimmed.starts_with("//")
            || (trimmed.starts_with('#') && !is_hex_color && !trimmed.contains('['))
            || (trimmed.starts_with(';') && !trimmed.contains('['));
        if is_comment {
            continue;
        }
        filtered.push_str(line);
        filtered.push('\n');
    }
    filtered
}

/// 纯文本兜底：无任何时间戳时，按非空文本行合成均匀时间戳（每行 3 秒）。
pub(crate) fn synthesize_plain_text_lines(raw: &str) -> Vec<ParsedLine> {
    let mut lines = Vec::new();
    let mut start_ms = 0u32;
    for (index, line) in raw.lines().enumerate() {
        let trimmed = sanitize_line_text(line);
        if trimmed.is_empty() {
            continue;
        }
        let (explicit_role, text) = detect_explicit_role(&trimmed);
        if text.is_empty() {
            continue;
        }
        lines.push(ParsedLine {
            start_ms,
            end_ms: start_ms.saturating_add(3000),
            text,
            words: None,
            translated_text: None,
            roman_text: None,
            source_format: ParsedLineSourceFormat::Lrc,
            source_index: index as f64,
            explicit_role,
            speaker: None,
            is_bg: false,
            is_duet: false,
            is_duet_partner: false,
        });
        start_ms = start_ms.saturating_add(3000);
    }
    lines
}

/// 网易云逐字歌词 JSON 格式：`[{"t":1234,"c":[{"tx":"你"},{"tx":"好"}]}, ...]`。
/// 每行含 `t`（起始毫秒）、`c`（逐字数组，`tx` 为文本），部分行带 `x`（结束毫秒）。
pub(crate) fn parse_netease_json_word_lrc(raw: &str) -> Vec<ParsedLine> {
    let value: serde_json::Value = match serde_json::from_str(raw.trim()) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    let serde_json::Value::Array(lines) = value else {
        return Vec::new();
    };

    let mut result = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        let Some(start_ms) = line.get("t").and_then(|v| v.as_i64()) else {
            continue;
        };
        let Some(chars) = line.get("c").and_then(|v| v.as_array()) else {
            continue;
        };
        if chars.is_empty() {
            continue;
        }

        let mut words = Vec::new();
        let mut text = String::new();
        for char_obj in chars {
            let Some(tx) = char_obj.get("tx").and_then(|v| v.as_str()) else {
                continue;
            };
            if tx.is_empty() {
                continue;
            }
            text.push_str(tx);
            words.push(ParsedWord {
                text: tx.to_string(),
                start_ms: start_ms.max(0) as u32,
                end_ms: start_ms.max(0) as u32,
                roman_text: None,
            });
        }
        if text.trim().is_empty() {
            continue;
        }
        insert_latin_word_gaps(&mut words);
        text = words
            .iter()
            .map(|word| word.text.as_str())
            .collect::<String>();

        let end_ms = line
            .get("x")
            .and_then(|v| v.as_i64())
            .map(|v| v.max(0) as u32)
            .unwrap_or(start_ms.max(0) as u32);
        let (explicit_role, normalized_text) = detect_explicit_role(&text);
        result.push(ParsedLine {
            start_ms: start_ms.max(0) as u32,
            end_ms: end_ms.max(start_ms.max(0) as u32),
            text: normalized_text,
            words: Some(words),
            translated_text: None,
            roman_text: None,
            source_format: ParsedLineSourceFormat::Yrc,
            source_index: index as f64,
            explicit_role,
            speaker: None,
            is_bg: false,
            is_duet: false,
            is_duet_partner: false,
        });
    }
    result
}

/// Lyricify Quick Export（LQE）与 LyricifyLines（LYL）共用行格式：`[start,end,type]text`。
/// start/end 为毫秒，type 为演唱者类型（0 主唱、1 背景等）。头部行（如 `[Lyricify Quick Export]`）不含数字参数，自动跳过。
pub(crate) fn parse_lqe_like(raw: &str) -> Vec<ParsedLine> {
    let marker_re = LQE_LIKE_MARKER_RE
        .get_or_init(|| Regex::new(r"^\[(\d+),(\d+)(?:,(\d+))?\]").unwrap());
    let mut result = Vec::new();
    for (index, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        let Some(caps) = marker_re.captures(trimmed) else {
            continue;
        };
        let full = caps.get(0).unwrap();
        let Some(start) = caps.get(1).and_then(|s| s.as_str().parse::<i64>().ok()) else {
            continue;
        };
        let Some(end) = caps.get(2).and_then(|s| s.as_str().parse::<i64>().ok()) else {
            continue;
        };
        let _vocal_type: i64 = caps
            .get(3)
            .and_then(|s| s.as_str().parse().ok())
            .unwrap_or(0);
        let text = trimmed[full.end()..].trim();
        if text.is_empty() {
            continue;
        }

        let start_ms = start.max(0) as u32;
        let end_ms = end.max(start) as u32;
        let (explicit_role, normalized_text) = detect_explicit_role(text);
        result.push(ParsedLine {
            start_ms,
            end_ms: end_ms.max(start_ms),
            text: normalized_text,
            words: None,
            translated_text: None,
            roman_text: None,
            source_format: ParsedLineSourceFormat::Lrc,
            source_index: index as f64,
            explicit_role,
            speaker: None,
            is_bg: false,
            is_duet: false,
            is_duet_partner: false,
        });
    }
    result
}

pub(crate) fn consume_square_timestamp_block(source: &str) -> Option<(usize, String)> {
    if !source.starts_with('[') {
        return None;
    }

    let end = source.find(']')?;
    let block = &source[..=end];
    parse_timestamp_to_ms(&source[1..end])?;
    Some((end + 1, block.to_string()))
}

pub(crate) fn normalize_eslrc_source(source: &str) -> String {
    source
        .lines()
        .map(|line| {
            let mut normalized = String::with_capacity(line.len());
            let mut index = 0usize;

            while index < line.len() {
                let slice = &line[index..];
                if slice.starts_with('[') {
                    let mut cursor = index;
                    let mut blocks = Vec::new();

                    while cursor < line.len() {
                        let Some((consumed, block)) =
                            consume_square_timestamp_block(&line[cursor..])
                        else {
                            break;
                        };
                        blocks.push(block);
                        cursor += consumed;
                    }

                    if blocks.len() > 1 {
                        let next_char = line[cursor..].chars().next();
                        if matches!(next_char, Some(ch) if ch != '[' && ch != ']') {
                            for (block_index, block) in blocks.iter().enumerate() {
                                normalized.push_str(block);
                                if block_index + 1 != blocks.len() {
                                    normalized.push('\u{2063}');
                                }
                            }
                            index = cursor;
                            continue;
                        }
                    }
                }

                if let Some(ch) = slice.chars().next() {
                    normalized.push(ch);
                    index += ch.len_utf8();
                } else {
                    break;
                }
            }

            normalized
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) fn parse_timestamp_to_ms(raw: &str) -> Option<u32> {
    let trimmed = raw.trim();
    let mut parts = trimmed.split(':');
    let minutes = parts.next()?.parse::<u32>().ok()?;
    let seconds_part = parts.next()?;
    if parts.next().is_some() {
        return None;
    }

    let mut second_parts = seconds_part.split('.');
    let seconds = second_parts.next()?.parse::<u32>().ok()?;
    if seconds >= 60 {
        return None;
    }

    let milliseconds = second_parts
        .next()
        .map(|fraction| {
            let mut padded = fraction.to_string();
            while padded.len() < 3 {
                padded.push('0');
            }
            padded
                .chars()
                .take(3)
                .collect::<String>()
                .parse::<u32>()
                .ok()
        })
        .flatten()
        .unwrap_or(0);

    Some(minutes * 60_000 + seconds * 1_000 + milliseconds)
}

pub(crate) fn parse_ttml_clock_to_ms(raw: &str) -> Option<u32> {
    if let Some(milliseconds) = raw.strip_suffix("ms") {
        return milliseconds.trim().parse::<u32>().ok();
    }

    if let Some(seconds) = raw.strip_suffix('s') {
        let parsed = seconds.trim().parse::<f64>().ok()?;
        return Some((parsed * 1000.0).round().max(0.0) as u32);
    }

    if raw.contains(':') {
        return parse_timestamp_to_ms(raw);
    }

    None
}

pub(crate) fn is_latin_char(ch: char) -> bool {
    ch.is_ascii_alphabetic()
        || matches!(
            ch as u32,
            0x00C0..=0x00FF | 0x0100..=0x017F | 0x0180..=0x024F | 0x1E00..=0x1EFF
        )
}

pub(crate) fn is_kana_char(ch: char) -> bool {
    matches!(ch as u32, 0x3040..=0x30FF | 0x31F0..=0x31FF | 0xFF66..=0xFF9F)
}

pub(crate) fn is_hangul_char(ch: char) -> bool {
    matches!(ch as u32, 0xAC00..=0xD7AF | 0x1100..=0x11FF | 0x3130..=0x318F)
}

pub(crate) fn is_han_char(ch: char) -> bool {
    matches!(ch as u32, 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF)
}

pub(crate) fn resolve_dominant_script(
    latin_count: u32,
    han_count: u32,
    kana_count: u32,
    hangul_count: u32,
) -> DominantScript {
    let total = latin_count + han_count + kana_count + hangul_count;
    if total == 0 {
        return DominantScript::Other;
    }

    let mut counts = vec![
        (DominantScript::Latin, latin_count),
        (DominantScript::Han, han_count),
        (DominantScript::Kana, kana_count),
        (DominantScript::Hangul, hangul_count),
    ];
    counts.sort_by(|left, right| right.1.cmp(&left.1));

    let dominant = counts[0].0.clone();
    let dominant_count = counts[0].1;
    let secondary_count = counts.get(1).map(|item| item.1).unwrap_or(0);

    if secondary_count > 0 && (dominant_count as f64 / total as f64) < 0.7 {
        return DominantScript::Mixed;
    }

    dominant
}

pub(crate) fn get_line_script_profile(text: &str) -> LineScriptProfile {
    let mut latin_count = 0;
    let mut han_count = 0;
    let mut kana_count = 0;
    let mut hangul_count = 0;

    for ch in text.chars() {
        if is_latin_char(ch) {
            latin_count += 1;
        } else if is_kana_char(ch) {
            kana_count += 1;
        } else if is_hangul_char(ch) {
            hangul_count += 1;
        } else if is_han_char(ch) {
            han_count += 1;
        }
    }

    let dominant_script = resolve_dominant_script(latin_count, han_count, kana_count, hangul_count);

    LineScriptProfile {
        latin_count,
        han_count,
        kana_count,
        hangul_count,
        dominant_script,
    }
}

pub(crate) fn is_japanese_like(profile: &LineScriptProfile) -> bool {
    profile.kana_count > 0 && profile.hangul_count == 0
}

pub(crate) fn same_script_family(left: &DominantScript, right: &DominantScript) -> bool {
    let family = |script: &DominantScript| match script {
        DominantScript::Latin => "latin",
        DominantScript::Han | DominantScript::Kana | DominantScript::Mixed => "cjk",
        DominantScript::Hangul => "hangul",
        DominantScript::Other => "other",
    };

    family(left) == family(right)
}

pub(crate) fn track_has_japanese_like_lines(track: &LyricTrack) -> bool {
    track
        .lines
        .iter()
        .any(|line| is_japanese_like(&line.script_profile))
}

pub(crate) fn map_track_source_format(source_format: &ParsedLineSourceFormat) -> LyricTrackSourceFormat {
    match source_format {
        ParsedLineSourceFormat::Lrc => LyricTrackSourceFormat::Lrc,
        ParsedLineSourceFormat::EnhancedLrc => LyricTrackSourceFormat::EnhancedLrc,
        ParsedLineSourceFormat::Eslrc => LyricTrackSourceFormat::Eslrc,
        ParsedLineSourceFormat::Yrc => LyricTrackSourceFormat::Yrc,
        ParsedLineSourceFormat::Qrc => LyricTrackSourceFormat::Qrc,
        ParsedLineSourceFormat::Lys => LyricTrackSourceFormat::Lys,
        ParsedLineSourceFormat::Ttml => LyricTrackSourceFormat::Ttml,
    }
}

pub(crate) fn compare_source_index(left: f64, right: f64) -> Ordering {
    left.partial_cmp(&right).unwrap_or(Ordering::Equal)
}

pub(crate) fn sort_parsed_lines(lines: &mut [ParsedLine]) {
    lines.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| compare_source_index(left.source_index, right.source_index))
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });
}

pub(crate) fn normalize_end_times(lines: &mut [ParsedLine]) {
    sort_parsed_lines(lines);

    for index in 0..lines.len() {
        let current_start = lines[index].start_ms;
        let next_start = lines.get(index + 1).map(|line| line.start_ms);
        let fallback_end = next_start.unwrap_or(current_start.saturating_add(5000));
        lines[index].end_ms = lines[index].end_ms.max(current_start.max(fallback_end));
    }
}

pub(crate) fn parser_priority(source_format: &ParsedLineSourceFormat) -> i32 {
    match source_format {
        ParsedLineSourceFormat::EnhancedLrc => 6,
        ParsedLineSourceFormat::Ttml => 5,
        ParsedLineSourceFormat::Yrc => 4,
        ParsedLineSourceFormat::Qrc => 3,
        ParsedLineSourceFormat::Lys => 2,
        ParsedLineSourceFormat::Eslrc => 1,
        ParsedLineSourceFormat::Lrc => 0,
    }
}

pub(crate) fn score_prepared_lines(lines: &[ParsedLine]) -> i32 {
    lines.iter().fold(0, |score, line| {
        score
            + if line
                .words
                .as_ref()
                .map(|words| !words.is_empty())
                .unwrap_or(false)
            {
                2
            } else {
                0
            }
            + if line
                .translated_text
                .as_ref()
                .map(|text| !text.is_empty())
                .unwrap_or(false)
            {
                1
            } else {
                0
            }
            + if line
                .roman_text
                .as_ref()
                .map(|text| !text.is_empty())
                .unwrap_or(false)
            {
                1
            } else {
                0
            }
    })
}

pub(crate) fn compare_parser_candidates(left: &ParserCandidate, right: &ParserCandidate) -> Ordering {
    score_prepared_lines(&right.lines)
        .cmp(&score_prepared_lines(&left.lines))
        .then_with(|| right.lines.len().cmp(&left.lines.len()))
        .then_with(|| parser_priority(&right.source).cmp(&parser_priority(&left.source)))
}

pub(crate) fn detect_explicit_role(text: &str) -> (Option<ExplicitLineRole>, String) {
    let trimmed = sanitize_line_text(text);
    if trimmed.is_empty() {
        return (None, trimmed);
    }

    let lowered = trimmed.to_lowercase();
    let translation_prefixes = [
        "[tr]",
        "[trans]",
        "[translation]",
        "翻译:",
        "翻译：",
        "译文:",
        "译文：",
        "【翻译】",
        "【译文】",
    ];
    for prefix in translation_prefixes {
        if lowered.starts_with(&prefix.to_lowercase()) {
            let normalized = sanitize_line_text(&trimmed[prefix.len()..]);
            return (Some(ExplicitLineRole::Translation), normalized);
        }
    }

    let roman_prefixes = [
        "[roma]",
        "[romaji]",
        "[roman]",
        "罗马音:",
        "罗马音：",
        "罗马字:",
        "罗马字：",
        "音译:",
        "音译：",
        "【罗马音】",
        "【罗马字】",
        "【音译】",
    ];
    for prefix in roman_prefixes {
        if lowered.starts_with(&prefix.to_lowercase()) {
            let normalized = sanitize_line_text(&trimmed[prefix.len()..]);
            return (Some(ExplicitLineRole::Roman), normalized);
        }
    }

    (None, trimmed)
}

pub(crate) fn to_safe_ms(value: u64, fallback: u32) -> u32 {
    value
        .try_into()
        .ok()
        .filter(|value| *value <= 60_039_999)
        .unwrap_or(fallback)
}

pub(crate) fn prepare_source_line(
    line: &SourceLine,
    source_format: ParsedLineSourceFormat,
    source_index: usize,
) -> Option<ParsedLine> {
    let fallback_start_ms = to_safe_ms(line.start_time, 0);
    let fallback_end_ms = to_safe_ms(
        line.end_time,
        fallback_start_ms
            .saturating_add(500)
            .max(fallback_start_ms + 80),
    )
    .max(fallback_start_ms);

    let mut words = line
        .words
        .iter()
        .filter_map(|word| {
            let text = sanitize_word_text(word.word.as_str());
            if text.is_empty() {
                return None;
            }

            let start_ms = to_safe_ms(word.start_time, fallback_start_ms);
            let end_ms = to_safe_ms(word.end_time, fallback_end_ms).max(start_ms);

            Some(ParsedWord {
                text,
                start_ms,
                end_ms,
                roman_text: None,
            })
        })
        .collect::<Vec<_>>();
    words.sort_by(|left, right| left.start_ms.cmp(&right.start_ms));
    insert_latin_word_gaps(&mut words);

    let raw_text = sanitize_line_text(
        &words
            .iter()
            .map(|word| word.text.as_str())
            .collect::<String>(),
    );
    let (explicit_role, text) = detect_explicit_role(&raw_text);
    let translated_text = sanitize_line_text(line.translated_lyric.as_str());
    let roman_text = sanitize_line_text(line.roman_lyric.as_str());

    if text.is_empty() && translated_text.is_empty() && roman_text.is_empty() && words.is_empty() {
        return None;
    }

    let first_word_start_ms = words
        .first()
        .map(|word| word.start_ms)
        .unwrap_or(fallback_start_ms);
    let last_word_end_ms = words
        .last()
        .map(|word| word.end_ms)
        .unwrap_or(fallback_end_ms);

    Some(ParsedLine {
        start_ms: to_safe_ms(line.start_time, first_word_start_ms),
        end_ms: to_safe_ms(line.end_time, last_word_end_ms)
            .max(first_word_start_ms)
            .max(last_word_end_ms),
        text,
        words: if words.is_empty() { None } else { Some(words) },
        translated_text: if translated_text.is_empty() {
            None
        } else {
            Some(translated_text)
        },
        roman_text: if roman_text.is_empty() {
            None
        } else {
            Some(roman_text)
        },
        source_format,
        source_index: source_index as f64,
        explicit_role,
        speaker: None,
        is_bg: false,
        is_duet: false,
        is_duet_partner: false,
    })
}

pub(crate) fn collect_markers(text: &str, open: char, close: char) -> Vec<(usize, usize, u32)> {
    let mut result = Vec::new();
    let mut index = 0usize;

    while index < text.len() {
        if text[index..].starts_with(open) {
            if let Some(relative_end) = text[index + open.len_utf8()..].find(close) {
                let end = index + open.len_utf8() + relative_end;
                let raw = &text[index + open.len_utf8()..end];
                if let Some(timestamp) = parse_timestamp_to_ms(raw) {
                    result.push((index, end + close.len_utf8(), timestamp));
                    index = end + close.len_utf8();
                    continue;
                }
            }
        }

        if let Some(ch) = text[index..].chars().next() {
            index += ch.len_utf8();
        } else {
            break;
        }
    }

    result
}

pub(crate) fn parse_inline_square_timed_line(line: &str, source_index: usize) -> Option<ParsedLine> {
    let markers = collect_markers(line, '[', ']');
    if markers.len() < 2 {
        return None;
    }

    let mut words = markers
        .windows(2)
        .filter_map(|window| {
            let (_, current_end, current_start_ms) = window[0];
            let (next_start, _, next_start_ms) = window[1];
            let segment = &line[current_end..next_start];
            if segment.is_empty() {
                return None;
            }

            let text = sanitize_word_text(segment);
            if text.is_empty() {
                return None;
            }

            Some(ParsedWord {
                text,
                start_ms: current_start_ms,
                end_ms: next_start_ms.max(current_start_ms),
                roman_text: None,
            })
        })
        .collect::<Vec<_>>();

    if words.is_empty() {
        return None;
    }
    insert_latin_word_gaps(&mut words);

    let text = sanitize_line_text(
        &words
            .iter()
            .map(|word| word.text.clone())
            .collect::<String>(),
    );
    if text.is_empty() {
        return None;
    }

    let (explicit_role, normalized_text) = detect_explicit_role(&text);
    let first_start = words.first()?.start_ms;
    let last_end = markers.last().map(|marker| marker.2).unwrap_or(first_start);

    Some(ParsedLine {
        start_ms: first_start,
        end_ms: last_end.max(first_start),
        text: normalized_text,
        words: Some(words),
        translated_text: None,
        roman_text: None,
        source_format: ParsedLineSourceFormat::Eslrc,
        source_index: source_index as f64,
        explicit_role,
        speaker: None,
        is_bg: false,
        is_duet: false,
        is_duet_partner: false,
    })
}

/// 判定词内尖括号时间是否为相对行首的偏移（与桌面端同规则）：
/// 首词几乎为 0，或全部词时间远小于行起点时视为相对偏移。
pub(crate) fn should_use_relative_angle_word_time(line_start_ms: u32, word_times: &[u32]) -> bool {
    if line_start_ms == 0 || word_times.is_empty() {
        return false;
    }
    let first = word_times[0];
    let last = *word_times.last().unwrap();
    first <= 10 || (first + 500 < line_start_ms && last < line_start_ms + 500)
}

pub(crate) fn parse_enhanced_lrc_line(line: &str, source_index: usize) -> Option<ParsedLine> {
    let leading = collect_markers(line, '[', ']');
    let (_, body_start, line_start_ms) = *leading.first()?;
    let body = &line[body_start..];
    let mut markers = collect_markers(body, '<', '>');
    if markers.is_empty() {
        return None;
    }

    // lrc-a2（anime 等源）的词内尖括号时间可能是相对行首的偏移（如 <00:00.16>），
    // 误当绝对时间会把整行词时间塌缩到歌曲开头，导致歌词整体错位。
    // 与桌面端同规则：词时间远小于行起点时按相对偏移加回行起点。
    let word_times = markers.iter().map(|marker| marker.2).collect::<Vec<_>>();
    if should_use_relative_angle_word_time(line_start_ms, &word_times) {
        for marker in markers.iter_mut() {
            marker.2 = marker.2.saturating_add(line_start_ms);
        }
    }

    if !body[..markers[0].0].trim().is_empty() {
        return None;
    }

    let mut words = Vec::new();
    for window in markers.windows(2) {
        let (_, current_end, current_start_ms) = window[0];
        let (next_start, _, next_start_ms) = window[1];
        let segment = &body[current_end..next_start];
        if segment.is_empty() {
            continue;
        }

        let text = sanitize_word_text(segment);
        if text.is_empty() {
            continue;
        }

        words.push(ParsedWord {
            text,
            start_ms: current_start_ms,
            end_ms: next_start_ms.max(current_start_ms),
            roman_text: None,
        });
    }

    // kw/wy 等源转换的 Enhanced LRC 末 marker 之后仍带最后一个词的文本
    // （如 …<00:24.52>咖<00:24.61>啡），windows(2) 覆盖不到它，须单独补收。
    if let Some((_, last_marker_end, last_start_ms)) = markers.last().copied() {
        let trailing_text = sanitize_word_text(&body[last_marker_end..]);
        if !trailing_text.is_empty() {
            words.push(ParsedWord {
                text: trailing_text,
                start_ms: last_start_ms,
                end_ms: last_start_ms + ENHANCED_TRAILING_WORD_DURATION_MS,
                roman_text: None,
            });
        }
    }

    if words.is_empty() {
        return None;
    }

    insert_latin_word_gaps(&mut words);

    let text = sanitize_line_text(
        &words
            .iter()
            .map(|word| word.text.clone())
            .collect::<String>(),
    );
    let (explicit_role, normalized_text) = detect_explicit_role(&text);
    let last_word_end = words
        .last()
        .map(|word| word.end_ms)
        .unwrap_or(line_start_ms);
    let end_ms = markers
        .last()
        .map(|marker| marker.2)
        .unwrap_or(line_start_ms)
        .max(last_word_end);

    Some(ParsedLine {
        start_ms: line_start_ms,
        end_ms: end_ms.max(line_start_ms),
        text: normalized_text,
        words: Some(words),
        translated_text: None,
        roman_text: None,
        source_format: ParsedLineSourceFormat::EnhancedLrc,
        source_index: source_index as f64,
        explicit_role,
        speaker: None,
        is_bg: false,
        is_duet: false,
        is_duet_partner: false,
    })
}

pub(crate) fn parse_plain_lrc_line(line: &str, source_index: usize) -> Vec<ParsedLine> {
    let markers = collect_markers(line, '[', ']');
    if markers.is_empty() {
        return Vec::new();
    }

    let mut leading = Vec::new();
    let mut current_expected = 0usize;
    for marker in &markers {
        if marker.0 != current_expected {
            break;
        }
        leading.push(*marker);
        current_expected = marker.1;
    }

    if leading.is_empty() {
        return Vec::new();
    }

    let body = &line[current_expected..];
    if body.contains('<') && body.contains('>') {
        if let Some(parsed) = parse_enhanced_lrc_line(line, source_index) {
            return vec![parsed];
        }
    }

    if body.contains('[') && body.contains(']') {
        if let Some(parsed) = parse_inline_square_timed_line(line, source_index) {
            return vec![parsed];
        }
    }

    let (explicit_role, normalized_text) = detect_explicit_role(body);
    if normalized_text.is_empty() {
        return Vec::new();
    }

    leading
        .into_iter()
        .enumerate()
        .map(|(offset, (_, _, start_ms))| ParsedLine {
            start_ms,
            end_ms: start_ms.saturating_add(5000),
            text: normalized_text.clone(),
            words: None,
            translated_text: None,
            roman_text: None,
            source_format: ParsedLineSourceFormat::Lrc,
            source_index: source_index as f64 + (offset as f64 * 0.001),
            explicit_role: explicit_role.clone(),
            speaker: None,
            is_bg: false,
            is_duet: false,
            is_duet_partner: false,
        })
        .collect()
}

pub(crate) fn strip_xml_tags(raw: &str) -> String {
    let re = XML_TAG_RE.get_or_init(|| Regex::new(r"(?s)<[^>]+>").unwrap());
    sanitize_line_text(&re.replace_all(raw, "").to_string())
}

pub(crate) fn parse_ttml(raw: &str) -> Vec<ParsedLine> {
    let paragraph_re = TTML_PARAGRAPH_RE.get_or_init(|| Regex::new(r#"(?s)<p\b([^>]*)>(.*?)</p>"#).unwrap());
    let begin_re = TTML_BEGIN_RE.get_or_init(|| Regex::new(r#"(?i)\bbegin="([^"]+)""#).unwrap());
    let end_re = TTML_END_RE.get_or_init(|| Regex::new(r#"(?i)\bend="([^"]+)""#).unwrap());
    let span_re = TTML_SPAN_RE.get_or_init(|| Regex::new(r#"(?s)<span\b([^>]*)>(.*?)</span>"#).unwrap());
    let role_re = TTML_ROLE_RE.get_or_init(|| Regex::new(r#"(?i)\bttm:role="([^"]+)""#).unwrap());

    let mut lines = Vec::new();

    for (index, captures) in paragraph_re.captures_iter(raw).enumerate() {
        let attrs = captures
            .get(1)
            .map(|value| value.as_str())
            .unwrap_or_default();
        let body = captures
            .get(2)
            .map(|value| value.as_str())
            .unwrap_or_default();
        let begin = begin_re
            .captures(attrs)
            .and_then(|caps| caps.get(1).map(|value| value.as_str().to_string()))
            .and_then(|value| parse_ttml_clock_to_ms(&value));
        let Some(start_ms) = begin else {
            continue;
        };
        let end_ms = end_re
            .captures(attrs)
            .and_then(|caps| caps.get(1).map(|value| value.as_str().to_string()))
            .and_then(|value| parse_ttml_clock_to_ms(&value))
            .unwrap_or(start_ms.saturating_add(5000));

        let mut translation_text = None;
        let mut roman_text = None;
        for span in span_re.captures_iter(body) {
            let span_attrs = span.get(1).map(|value| value.as_str()).unwrap_or_default();
            let span_body = span.get(2).map(|value| value.as_str()).unwrap_or_default();
            let role = role_re
                .captures(span_attrs)
                .and_then(|caps| caps.get(1).map(|value| value.as_str().to_lowercase()));
            let content = strip_xml_tags(span_body);

            match role.as_deref() {
                Some("x-translation") | Some("translation") => {
                    if !content.is_empty() {
                        translation_text = Some(content);
                    }
                }
                Some("x-roman")
                | Some("roman")
                | Some("romanization")
                | Some("transliteration") => {
                    if !content.is_empty() {
                        roman_text = Some(content);
                    }
                }
                _ => {}
            }
        }

        let mut main_body = body.to_string();
        for span in span_re.captures_iter(body) {
            if let Some(full) = span.get(0) {
                let replacement = match role_re
                    .captures(span.get(1).map(|value| value.as_str()).unwrap_or_default())
                    .and_then(|caps| caps.get(1).map(|value| value.as_str().to_lowercase()))
                    .as_deref()
                {
                    Some("x-translation")
                    | Some("translation")
                    | Some("x-roman")
                    | Some("roman")
                    | Some("romanization")
                    | Some("transliteration") => String::new(),
                    _ => {
                        strip_xml_tags(span.get(2).map(|value| value.as_str()).unwrap_or_default())
                    }
                };
                main_body = main_body.replacen(full.as_str(), &replacement, 1);
            }
        }

        let (explicit_role, text) = detect_explicit_role(&strip_xml_tags(&main_body));
        if text.is_empty() && translation_text.is_none() && roman_text.is_none() {
            continue;
        }

        lines.push(ParsedLine {
            start_ms,
            end_ms,
            text,
            words: None,
            translated_text: translation_text,
            roman_text,
            source_format: ParsedLineSourceFormat::Ttml,
            source_index: index as f64,
            explicit_role,
            speaker: None,
            is_bg: false,
            is_duet: false,
            is_duet_partner: false,
        });
    }

    lines
}

pub(crate) fn parse_manual_lrc_like(raw: &str) -> Vec<ParsedLine> {
    let mut lines = Vec::new();
    for (index, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(parsed) = parse_enhanced_lrc_line(trimmed, index) {
            lines.push(parsed);
            continue;
        }

        lines.extend(parse_plain_lrc_line(trimmed, index));
    }

    finalize_lrc_blank_lines(lines)
}

/// 把主歌词 XML 尾部的译文 LRC 行按时间戳就近关联到主行 translated_text
/// （QQ/Baka 链路：解密 QRC XML + 插件译文 LRC 拼成一份 raw）。仅填空位不
/// 覆盖已有翻译；时间差超过 2s 视为对不上、丢弃。
pub(crate) fn attach_lrc_translation_lines(lines: &mut [ParsedLine], tail: &str) {
    let translation_lines = parse_manual_lrc_like(tail);
    if translation_lines.is_empty() || lines.is_empty() {
        return;
    }
    for translation in &translation_lines {
        let text = translation.text.trim();
        if text.is_empty() {
            continue;
        }
        let mut best: Option<(usize, i64)> = None;
        for (index, line) in lines.iter().enumerate() {
            let delta = (line.start_ms as i64 - translation.start_ms as i64).abs();
            if delta > 2000 {
                continue;
            }
            if best.map(|(_, best_delta)| delta < best_delta).unwrap_or(true) {
                best = Some((index, delta));
            }
        }
        if let Some((index, _)) = best {
            let line = &mut lines[index];
            let is_empty = line
                .translated_text
                .as_deref()
                .map(str::trim)
                .map(str::is_empty)
                .unwrap_or(true);
            if is_empty {
                line.translated_text = Some(text.to_string());
            }
        }
    }
}

pub(crate) fn collect_candidate(
    candidates: &mut Vec<ParserCandidate>,
    source: ParsedLineSourceFormat,
    mut lines: Vec<ParsedLine>,
) {
    if lines.is_empty() {
        return;
    }

    normalize_end_times(&mut lines);
    let candidate_source = if lines
        .iter()
        .any(|line| line.source_format == ParsedLineSourceFormat::EnhancedLrc)
    {
        // parse_manual_lrc_like 可以同时解析普通 LRC 与 LX 构建出的 Enhanced LRC。
        // 只要其中包含逐字 Enhanced LRC 行，候选排序就应按 EnhancedLrc 优先级参与竞争，
        // 否则可能被 eslrc/lrc 候选抢走，导致前端拿不到稳定的 words。
        ParsedLineSourceFormat::EnhancedLrc
    } else {
        source
    };
    candidates.push(ParserCandidate {
        source: candidate_source,
        lines,
    });
}

pub(crate) fn parse_raw_lyrics(raw: &str) -> Vec<ParsedLine> {
    let normalized = preprocess_lyrics_text(raw);

    let mut candidates = Vec::new();

    if normalized.contains("<tt") {
        collect_candidate(
            &mut candidates,
            ParsedLineSourceFormat::Ttml,
            parse_ttml(&normalized),
        );
    }

    let lower = normalized.to_ascii_lowercase();
    if lower.contains("[lyricify quick export]") || lower.contains("[type:lyricifylines]") {
        collect_candidate(
            &mut candidates,
            ParsedLineSourceFormat::Lrc,
            parse_lqe_like(&normalized),
        );
    }

    let compact_hex = normalized.split_whitespace().collect::<String>();
    if compact_hex.len() > 64
        && compact_hex.len() % 2 == 0
        && compact_hex.chars().all(|ch| ch.is_ascii_hexdigit())
    {
        collect_candidate(
            &mut candidates,
            ParsedLineSourceFormat::Qrc,
            parse_qrc(&decrypt_qrc_hex(&compact_hex))
                .iter()
                .enumerate()
                .filter_map(|(index, line)| {
                    prepare_source_line(line, ParsedLineSourceFormat::Qrc, index)
                })
                .collect(),
        );
    }

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Yrc,
        parse_netease_json_word_lrc(&normalized),
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Yrc,
        parse_yrc(&normalized)
            .iter()
            .enumerate()
            .filter_map(|(index, line)| prepare_source_line(line, ParsedLineSourceFormat::Yrc, index))
            .collect(),
    );

    let mut qrc_candidate = parse_qrc(&normalized)
        .iter()
        .enumerate()
        .filter_map(|(index, line)| prepare_source_line(line, ParsedLineSourceFormat::Qrc, index))
        .collect::<Vec<_>>();
    // Baka/插件链路把解密 QRC XML 与插件译文 LRC 拼成一份 raw（同桌面组合）。
    // parse_qrc 只消费 XML，尾部译文 LRC 会被静默丢弃——这里按时间戳把译文
    // 行关联回主行 translated_text（±2s 内就近），译文解析复用行级 LRC 解析
    if !qrc_candidate.is_empty() {
        if let Some(end) = normalized.find("</QrcInfos>") {
            let tail = &normalized[end + "</QrcInfos>".len()..];
            attach_lrc_translation_lines(&mut qrc_candidate, tail);
        }
    }
    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Qrc,
        qrc_candidate,
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Lys,
        parse_lys(&normalized)
            .iter()
            .enumerate()
            .filter_map(|(index, line)| prepare_source_line(line, ParsedLineSourceFormat::Lys, index))
            .collect(),
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Eslrc,
        parse_eslrc(&normalize_eslrc_source(&normalized))
            .iter()
            .enumerate()
            .filter_map(|(index, line)| {
                prepare_source_line(line, ParsedLineSourceFormat::Eslrc, index)
            })
            .collect(),
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Lrc,
        parse_manual_lrc_like(&normalized),
    );

    candidates.sort_by(compare_parser_candidates);
    let mut lines = candidates
        .into_iter()
        .next()
        .map(|candidate| candidate.lines)
        .unwrap_or_default();

    // 若没有任何带时间戳的候选，兜底按纯文本逐行合成均匀时间戳，保证歌词仍可展示。
    if lines.is_empty() {
        lines = synthesize_plain_text_lines(&normalized);
    }

    annotate_line_vocals(&mut lines);
    apply_lyrics_offset(&mut lines, extract_lyrics_meta(&normalized).offset_ms);
    lines
}

