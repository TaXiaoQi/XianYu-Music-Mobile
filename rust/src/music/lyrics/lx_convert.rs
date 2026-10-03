use super::*;

// ==================== LX 相对逐字格式 → Enhanced LRC 转换 ====================
// 移植自桌面端 lxLyricsBuilder.ts 的 convertLxLyricToEnhancedLrc。
//
// LX 生态音源返回的 lxlyric 逐字标记是 <offset,duration>（相对行首的毫秒偏移 +
// 时长），与 Enhanced LRC 的绝对时间戳 <mm:ss.mmm> 不同；酷我变体还带负值编码
// （需按 [kuwo:xxx] 八进制标签解码系数）。parse_raw_lyrics 只认绝对时间戳，
// 不转换的话逐字标记会被当普通文本，整行退化为行级 LRC，逐字静默丢失。

pub(crate) static LX_WORD_TAG_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static ABS_WORD_TAG_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static LX_LINE_TIME_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static KUWO_TAG_RE: OnceLock<Regex> = OnceLock::new();

pub(crate) fn lx_word_tag_re() -> &'static Regex {
    LX_WORD_TAG_RE.get_or_init(|| Regex::new(r"<(-?\d+),(-?\d+)(?:,-?\d+)?>").unwrap())
}

pub(crate) fn abs_word_tag_re() -> &'static Regex {
    ABS_WORD_TAG_RE.get_or_init(|| Regex::new(r"<\d+:\d{2}(?:\.\d+)?>").unwrap())
}

pub(crate) fn lx_line_time_re() -> &'static Regex {
    LX_LINE_TIME_RE.get_or_init(|| Regex::new(r"^\[(\d+:\d{2}(?:\.\d+)?)](.*)$").unwrap())
}

pub(crate) fn kuwo_tag_re() -> &'static Regex {
    KUWO_TAG_RE.get_or_init(|| Regex::new(r"(?i)^\[kuwo:\s*(\S+)\s*]").unwrap())
}

pub(crate) fn ms_to_timestamp(ms: i64) -> String {
    let safe = ms.max(0);
    let total_seconds = safe / 1000;
    format!(
        "{:0>2}:{:0>2}.{:0>3}",
        total_seconds / 60,
        total_seconds % 60,
        safe % 1000
    )
}

/// 向下取整除法（与 JS Math.floor 语义一致，用于酷我解码）。
pub(crate) fn floor_div(a: i64, b: i64) -> i64 {
    let q = a / b;
    if a % b != 0 && ((a < 0) != (b < 0)) {
        q - 1
    } else {
        q
    }
}

#[derive(Clone, Debug)]
pub(crate) struct LxWordEntry {
    /// 标记在正文中的字节区间（词文本位于标记前或标记后，取决于来源格式）。
    pub(crate) index: usize,
    pub(crate) end_index: usize,
    pub(crate) start_ms: i64,
    pub(crate) end_ms: i64,
}

/// 构建候选时间表并打分：score 越小越优（无效标记/时间倒退/负起点/偏离行首均罚分）。
pub(crate) fn lx_build_candidate(
    word_times: &[(i64, i64, usize, usize)],
    line_start_ms: Option<i64>,
    kuwo_mode: bool,
    kuwo_offset: i64,
    kuwo_offset2: i64,
) -> Option<(Vec<LxWordEntry>, i64)> {
    if !kuwo_mode && line_start_ms.is_none() {
        return None;
    }
    if kuwo_mode && (kuwo_offset <= 0 || kuwo_offset2 <= 0) {
        return None;
    }

    let mut entries = Vec::new();
    let mut invalid_count = 0i64;
    let mut backward_count = 0i64;
    let mut previous_start: Option<i64> = None;

    for &(a, b, index, end_index) in word_times {
        let (word_start_ms, word_end_ms) = if kuwo_mode {
            // 酷我 <a,b> 解码结果是"相对行首"的时间（首字 a+b=0 → 相对 0），
            // 必须叠加行首，否则后续行的逐字时间戳远小于实际播放时间。
            let start = floor_div(a + b, kuwo_offset * 2).abs() + line_start_ms.unwrap_or(0);
            let end = floor_div(a - b, kuwo_offset2 * 2).abs() + start;
            (start, end)
        } else {
            let start = line_start_ms.unwrap_or(0) + a;
            (start, start + b)
        };

        if word_end_ms < word_start_ms {
            invalid_count += 1;
        }
        if previous_start.is_some_and(|prev| word_start_ms < prev) {
            backward_count += 1;
        }
        previous_start = Some(word_start_ms);

        entries.push(LxWordEntry {
            index,
            end_index,
            start_ms: word_start_ms,
            end_ms: word_end_ms,
        });
    }

    if entries.is_empty() {
        return None;
    }

    // 规范化：首词起点钳到 ≥0，词序单调不减，结束不早于开始。
    let mut previous_start = 0i64;
    for (i, entry) in entries.iter_mut().enumerate() {
        let start = if i == 0 {
            entry.start_ms.max(0)
        } else {
            entry.start_ms.max(previous_start)
        };
        entry.end_ms = entry.end_ms.max(start);
        entry.start_ms = start;
        previous_start = start;
    }

    let first_start = entries[0].start_ms;
    let line_distance = line_start_ms.map_or(0, |start| (first_start - start).abs());
    let negative_penalty = if entries.iter().any(|e| e.start_ms < 0) {
        100_000
    } else {
        0
    };
    let score = invalid_count * 1_000_000
        + backward_count * 100_000
        + negative_penalty
        + line_distance;

    Some((entries, score))
}

/// relative / kuwo 双候选打分选优；酷我特征强制 kuwo 解码。
pub(crate) fn lx_select_entries(
    word_times: &[(i64, i64, usize, usize)],
    line_start_ms: Option<i64>,
    force_kuwo: bool,
    kuwo_offset: i64,
    kuwo_offset2: i64,
) -> Vec<LxWordEntry> {
    let kuwo = lx_build_candidate(word_times, line_start_ms, true, kuwo_offset, kuwo_offset2);
    let relative = lx_build_candidate(word_times, line_start_ms, false, kuwo_offset, kuwo_offset2);

    if force_kuwo || line_start_ms.is_none() {
        return kuwo
            .or(relative)
            .map(|(entries, _)| entries)
            .unwrap_or_default();
    }

    let mut candidates: Vec<(Vec<LxWordEntry>, i64)> =
        [relative, kuwo].into_iter().flatten().collect();
    candidates.sort_by_key(|(_, score)| *score);
    candidates
        .into_iter()
        .next()
        .map(|(entries, _)| entries)
        .unwrap_or_default()
}

/// 用绝对时间戳重建正文。LX/KG 常见 <offset,duration>字（时间戳在字前）；
/// 酷我原始格式 字<offset,duration>（时间戳在字后）。两种都归一为 <abs>字 序列，
/// 行尾附结束标记——Enhanced LRC 要求正文以 <绝对时间> 开头，否则解析器
/// 按普通 LRC 处理导致逐字丢失。
pub(crate) fn lx_build_enhanced_body(body: &str, entries: &[LxWordEntry]) -> String {
    if entries.is_empty() {
        return String::new();
    }

    let mut converted = String::new();
    let has_text_before_first_marker = body[..entries[0].index].trim().len() > 0;

    if has_text_before_first_marker {
        // 酷我：字<时间>字<时间>。文本取自上一标记结束到当前标记开始，
        // 时间用当前标记的起点。
        let mut last_end = 0usize;
        for entry in entries {
            let text = &body[last_end..entry.index];
            if !text.is_empty() {
                converted.push_str(&format!("<{}>{}", ms_to_timestamp(entry.start_ms), text));
            }
            last_end = entry.end_index;
        }
        let tail = &body[last_end..];
        converted.push_str(tail);
    } else {
        // 标准 LX：<时间>字<时间>字。文本取自当前标记结束到下一标记开始。
        for (i, entry) in entries.iter().enumerate() {
            let text_end = entries.get(i + 1).map_or(body.len(), |next| next.index);
            let text = &body[entry.end_index..text_end];
            if !text.is_empty() {
                converted.push_str(&format!("<{}>{}", ms_to_timestamp(entry.start_ms), text));
            }
        }
    }

    // 行结束标记：最后一个词的结束时间。
    converted.push_str(&format!(
        "<{}>",
        ms_to_timestamp(entries[entries.len() - 1].end_ms)
    ));
    converted
}

/// 把 LX 相对逐字格式（<offset,duration>字，酷我可带负值编码）转换为
/// 绝对时间戳 Enhanced LRC。返回 None 表示没有可转换的行（调用方保留原文）。
pub(crate) fn convert_lx_relative_to_enhanced(raw: &str) -> Option<String> {
    let lines: Vec<&str> = raw.split('\n').map(str::trim).collect();

    // 酷我是文件级格式（不是逐行格式）：[kuwo:xxx] 八进制标签解码出两组系数；
    // 或全文存在绝对值较大的负 <a,b>（标准 LX 的同步偏移只有 -几 ms）。
    let mut kuwo_offset = 1i64;
    let mut kuwo_offset2 = 1i64;
    let mut has_kuwo_tag = false;
    for line in &lines {
        if let Some(caps) = kuwo_tag_re().captures(line) {
            has_kuwo_tag = true;
            let content = caps[1].split("][").next().unwrap_or("").trim();
            let value = i64::from_str_radix(content, 8).unwrap_or(0);
            kuwo_offset = (value / 10).max(1);
            kuwo_offset2 = if value % 10 == 0 { 1 } else { value % 10 };
        }
    }

    let is_kuwo_source = has_kuwo_tag
        || lines.iter().any(|line| {
            lx_word_tag_re().captures_iter(line).any(|caps| {
                let a: i64 = caps[1].parse().unwrap_or(0);
                let b: i64 = caps[2].parse().unwrap_or(0);
                a < -500 || b < -500
            })
        });

    let mut converted_count = 0usize;
    let mut result: Vec<String> = Vec::new();

    for line in &lines {
        if line.is_empty() || kuwo_tag_re().is_match(line) {
            result.push(String::new());
            continue;
        }

        // 已是绝对时间戳的 Enhanced LRC 行：直接保留。
        if abs_word_tag_re().is_match(line) && !lx_word_tag_re().is_match(line) {
            result.push((*line).to_string());
            converted_count += 1;
            continue;
        }

        let (line_start_str, body) = match lx_line_time_re().captures(line) {
            Some(caps) => (Some(caps[1].to_string()), caps[2].to_string()),
            None => (None, (*line).to_string()),
        };
        let line_start_ms = line_start_str
            .as_deref()
            .and_then(parse_timestamp_to_ms)
            .map(|v| v as i64);

        let word_times: Vec<(i64, i64, usize, usize)> = lx_word_tag_re()
            .captures_iter(&body)
            .filter_map(|caps| {
                let a: i64 = caps[1].parse().ok()?;
                let b: i64 = caps[2].parse().ok()?;
                let m = caps.get(0)?;
                Some((a, b, m.start(), m.end()))
            })
            .collect();

        if word_times.is_empty() {
            if line_start_str.is_some() {
                result.push((*line).to_string());
            }
            continue;
        }

        let entries = lx_select_entries(
            &word_times,
            line_start_ms,
            is_kuwo_source,
            kuwo_offset,
            kuwo_offset2,
        );
        if entries.is_empty() {
            continue;
        }

        let converted_body = lx_build_enhanced_body(&body, &entries);
        if converted_body.is_empty() {
            continue;
        }

        let final_line_start = line_start_ms
            .or_else(|| entries.first().map(|e| e.start_ms))
            .unwrap_or(0);
        result.push(format!(
            "[{}]{}",
            ms_to_timestamp(final_line_start),
            converted_body
        ));
        converted_count += 1;
    }

    if converted_count == 0 {
        return None;
    }
    Some(result.join("\n"))
}

pub fn build_structured_lyrics_payload(raw_lyrics: String) -> StructuredLyricsPayload {
    // LX 相对逐字格式先归一为绝对时间戳 Enhanced LRC，否则逐字静默丢失。
    let raw_lyrics = convert_lx_relative_to_enhanced(&raw_lyrics).unwrap_or(raw_lyrics);
    let parsed_lines = parse_raw_lyrics(&raw_lyrics);
    let meta = extract_lyrics_meta(&raw_lyrics);
    let document = build_lyric_document(&parsed_lines);
    let semantic_lines = document
        .as_ref()
        .map(lyric_document_to_semantic_lines)
        .unwrap_or_default();
    let display_lines = semantic_lines
        .iter()
        .map(semantic_line_to_lyric_line)
        .collect::<Vec<_>>();

    StructuredLyricsPayload {
        raw_lyrics,
        meta,
        document,
        semantic_lines,
        display_lines,
    }
}

