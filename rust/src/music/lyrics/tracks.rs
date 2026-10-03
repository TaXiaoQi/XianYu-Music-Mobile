use super::*;

pub(crate) fn track_source_format(lines: &[LyricTrackLine]) -> LyricTrackSourceFormat {
    let mut formats = lines
        .iter()
        .map(|line| map_track_source_format(&line.source_format))
        .collect::<Vec<_>>();
    formats.dedup();

    if formats.len() == 1 {
        formats[0].clone()
    } else {
        LyricTrackSourceFormat::Mixed
    }
}

pub(crate) fn track_timing_mode(lines: &[LyricTrackLine]) -> LyricTimingMode {
    if lines.iter().any(|line| {
        line.words
            .as_ref()
            .map(|words| !words.is_empty())
            .unwrap_or(false)
    }) {
        return LyricTimingMode::Word;
    }
    if !lines.is_empty() {
        return LyricTimingMode::Line;
    }
    LyricTimingMode::None
}

pub(crate) fn track_dominant_script(lines: &[LyricTrackLine]) -> DominantScript {
    let latin_count = lines
        .iter()
        .map(|line| line.script_profile.latin_count)
        .sum::<u32>();
    let han_count = lines
        .iter()
        .map(|line| line.script_profile.han_count)
        .sum::<u32>();
    let kana_count = lines
        .iter()
        .map(|line| line.script_profile.kana_count)
        .sum::<u32>();
    let hangul_count = lines
        .iter()
        .map(|line| line.script_profile.hangul_count)
        .sum::<u32>();
    resolve_dominant_script(latin_count, han_count, kana_count, hangul_count)
}

pub(crate) fn build_candidate_lines(lines: &[ParsedLine]) -> Vec<LyricTrackLine> {
    let mut candidates = Vec::new();

    for (index, line) in lines.iter().enumerate() {
        if !line.text.is_empty() {
            candidates.push(LyricTrackLine {
                id: format!("parsed:{index}:main"),
                start_ms: line.start_ms,
                end_ms: line.end_ms.max(line.start_ms),
                text: line.text.clone(),
                words: line.words.clone(),
                source_index: line.source_index,
                explicit_role: line.explicit_role.clone(),
                role_source: Some(if line.explicit_role.is_some() {
                    ClassificationConfidence::Explicit
                } else {
                    ClassificationConfidence::Heuristic
                }),
                cluster_index: None,
                slot_index: None,
                source_format: line.source_format.clone(),
                script_profile: get_line_script_profile(&line.text),
                speaker: line.speaker.clone(),
                is_bg: line.is_bg,
                is_duet: line.is_duet,
                is_duet_partner: line.is_duet_partner,
            });
        }

        if let Some(translation) = line
            .translated_text
            .as_ref()
            .filter(|text| !text.trim().is_empty())
        {
            candidates.push(LyricTrackLine {
                id: format!("parsed:{index}:translation"),
                start_ms: line.start_ms,
                end_ms: line.end_ms.max(line.start_ms),
                text: sanitize_line_text(translation),
                words: None,
                source_index: line.source_index + 0.1,
                explicit_role: Some(ExplicitLineRole::Translation),
                role_source: Some(ClassificationConfidence::ParserNative),
                cluster_index: None,
                slot_index: None,
                source_format: line.source_format.clone(),
                script_profile: get_line_script_profile(translation),
                speaker: None,
                is_bg: false,
                is_duet: false,
                is_duet_partner: false,
            });
        }

        let roman_from_words = line.words.as_ref().and_then(|words| {
            let roman_words = words
                .iter()
                .filter_map(|word| {
                    word.roman_text
                        .as_ref()
                        .filter(|text| !text.trim().is_empty())
                        .map(|text| ParsedWord {
                            text: text.clone(),
                            start_ms: word.start_ms,
                            end_ms: word.end_ms,
                            roman_text: None,
                        })
                })
                .collect::<Vec<_>>();
            if roman_words.is_empty() {
                None
            } else {
                Some(roman_words)
            }
        });

        let roman_text = line
            .roman_text
            .clone()
            .filter(|text| !text.trim().is_empty())
            .or_else(|| {
                roman_from_words.as_ref().map(|words| {
                    words
                        .iter()
                        .map(|word| word.text.clone())
                        .collect::<String>()
                })
            });

        if let Some(roman_text) = roman_text.filter(|text| !text.trim().is_empty()) {
            candidates.push(LyricTrackLine {
                id: format!("parsed:{index}:roman"),
                start_ms: line.start_ms,
                end_ms: line.end_ms.max(line.start_ms),
                text: sanitize_line_text(&roman_text),
                words: roman_from_words.clone(),
                source_index: line.source_index + 0.2,
                explicit_role: Some(ExplicitLineRole::Roman),
                role_source: Some(ClassificationConfidence::ParserNative),
                cluster_index: None,
                slot_index: None,
                source_format: line.source_format.clone(),
                script_profile: get_line_script_profile(&roman_text),
                speaker: None,
                is_bg: false,
                is_duet: false,
                is_duet_partner: false,
            });
        }
    }

    candidates.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| compare_source_index(left.source_index, right.source_index))
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });

    candidates
}

pub(crate) fn get_effective_tolerance(
    current_start_ms: u32,
    prev_start_ms: Option<u32>,
    next_start_ms: Option<u32>,
) -> u32 {
    let prev_gap = prev_start_ms
        .map(|start| current_start_ms.abs_diff(start))
        .unwrap_or(u32::MAX);
    let next_gap = next_start_ms
        .map(|start| current_start_ms.abs_diff(start))
        .unwrap_or(u32::MAX);

    MAX_GROUP_TOLERANCE_MS.min(prev_gap / 4).min(next_gap / 4)
}

pub(crate) fn find_context_start(
    lines: &[LyricTrackLine],
    origin_index: usize,
    direction: isize,
) -> Option<u32> {
    let origin_start_ms = lines[origin_index].start_ms;
    let mut index = origin_index as isize + direction;

    while index >= 0 && index < lines.len() as isize {
        let candidate = &lines[index as usize];
        if candidate.start_ms.abs_diff(origin_start_ms) > MAX_GROUP_TOLERANCE_MS {
            return Some(candidate.start_ms);
        }
        index += direction;
    }

    None
}

pub(crate) fn should_keep_separate_for_script_similarity(
    group: &[LyricTrackLine],
    candidate: &LyricTrackLine,
) -> bool {
    if candidate.start_ms
        == group
            .first()
            .map(|line| line.start_ms)
            .unwrap_or(candidate.start_ms)
    {
        return false;
    }
    if group.iter().any(|line| line.explicit_role.is_some()) || candidate.explicit_role.is_some() {
        return false;
    }

    if is_japanese_like(&candidate.script_profile) {
        return group
            .iter()
            .any(|line| is_japanese_like(&line.script_profile));
    }

    if matches!(
        candidate.script_profile.dominant_script,
        DominantScript::Mixed | DominantScript::Other
    ) {
        return false;
    }

    group
        .iter()
        .any(|line| line.script_profile.dominant_script == candidate.script_profile.dominant_script)
}

pub(crate) fn group_candidate_lines(lines: &[LyricTrackLine]) -> Vec<Vec<LyricTrackLine>> {
    if lines.is_empty() {
        return Vec::new();
    }

    let mut groups: Vec<Vec<LyricTrackLine>> = Vec::new();
    let mut group_start_index = 0usize;

    for (index, line) in lines.iter().enumerate() {
        if groups.is_empty() {
            groups.push(vec![line.clone()]);
            group_start_index = index;
            continue;
        }

        let current_group = match groups.last_mut() {
            Some(g) => g,
            None => {
                groups.push(vec![line.clone()]);
                group_start_index = index;
                continue;
            }
        };
        if current_group.len() >= MAX_GROUP_SIZE {
            groups.push(vec![line.clone()]);
            group_start_index = index;
            continue;
        }

        let tolerance = get_effective_tolerance(
            lines[group_start_index].start_ms,
            find_context_start(lines, group_start_index, -1),
            find_context_start(lines, group_start_index, 1),
        );
        let within_tolerance = line.start_ms.abs_diff(current_group[0].start_ms) <= tolerance;

        if within_tolerance && !should_keep_separate_for_script_similarity(current_group, line) {
            current_group.push(line.clone());
            continue;
        }

        groups.push(vec![line.clone()]);
        group_start_index = index;
    }

    groups
}

pub(crate) fn track_role_hint(track: &LyricTrack) -> Option<LyricTrackRole> {
    let translation_count = track
        .lines
        .iter()
        .filter(|line| line.explicit_role == Some(ExplicitLineRole::Translation))
        .count();
    let romanization_count = track
        .lines
        .iter()
        .filter(|line| line.explicit_role == Some(ExplicitLineRole::Roman))
        .count();

    if translation_count == 0 && romanization_count == 0 {
        return None;
    }

    if translation_count >= romanization_count {
        Some(LyricTrackRole::Translation)
    } else {
        Some(LyricTrackRole::Romanization)
    }
}

pub(crate) fn score_script_compatibility(track: &LyricTrack, candidate: &LyricTrackLine) -> f64 {
    if track.dominant_script == candidate.script_profile.dominant_script {
        return 4.0;
    }
    if track.dominant_script == DominantScript::Han
        && has_han_translation_content(&candidate.script_profile)
    {
        return 2.8;
    }
    if matches!(
        track.dominant_script,
        DominantScript::Mixed | DominantScript::Other
    ) || matches!(
        candidate.script_profile.dominant_script,
        DominantScript::Mixed | DominantScript::Other
    ) {
        return 1.2;
    }

    let family = |script: &DominantScript| match script {
        DominantScript::Latin => "latin",
        DominantScript::Han | DominantScript::Kana | DominantScript::Mixed => "cjk",
        DominantScript::Hangul => "hangul",
        DominantScript::Other => "other",
    };

    if family(&track.dominant_script) == family(&candidate.script_profile.dominant_script) {
        return 0.8;
    }

    -2.2
}

pub(crate) fn score_track_match(
    track: &LyricTrack,
    candidate: &LyricTrackLine,
    cluster_index: usize,
    slot_index: usize,
) -> f64 {
    let Some(last_line) = track.lines.last() else {
        return 0.0;
    };

    if last_line.cluster_index == Some(cluster_index) || candidate.start_ms <= last_line.start_ms {
        return f64::NEG_INFINITY;
    }

    let track_role_hint = track_role_hint(track);
    let candidate_role_hint = match candidate.explicit_role {
        Some(ExplicitLineRole::Translation) => Some(LyricTrackRole::Translation),
        Some(ExplicitLineRole::Roman) => Some(LyricTrackRole::Romanization),
        None => None,
    };
    if track_role_hint.is_some()
        && candidate_role_hint.is_some()
        && track_role_hint != candidate_role_hint
    {
        return f64::NEG_INFINITY;
    }

    let mut score = 0.0;
    if track_role_hint.is_some() && track_role_hint == candidate_role_hint {
        score += 6.0;
    }
    if track_role_hint.is_none() && candidate_role_hint.is_some() {
        score += 1.2;
    }

    score += score_script_compatibility(track, candidate);

    let average_slot = average(
        &track
            .lines
            .iter()
            .map(|line| line.slot_index.unwrap_or(0) as f64)
            .collect::<Vec<_>>(),
    );
    score += (-1.8f64).max(2.2 - ((average_slot - slot_index as f64).abs() * 1.35));

    let average_source_index = average(
        &track
            .lines
            .iter()
            .map(|line| line.source_index)
            .collect::<Vec<_>>(),
    );
    score += (-1.0f64).max(1.4 - ((average_source_index - candidate.source_index).abs() * 0.35));

    let cluster_gap =
        cluster_index.saturating_sub(last_line.cluster_index.unwrap_or(cluster_index));
    score += if cluster_gap == 1 { 1.2 } else { 0.4 };

    let time_gap = candidate.start_ms.saturating_sub(last_line.start_ms);
    if time_gap < 120
        && track.dominant_script == candidate.script_profile.dominant_script
        && candidate.explicit_role.is_none()
    {
        score -= 1.4;
    }

    score
}

pub(crate) fn build_tracks(groups: Vec<Vec<LyricTrackLine>>) -> Vec<LyricTrack> {
    let mut tracks: Vec<LyricTrack> = Vec::new();

    for (cluster_index, group) in groups.into_iter().enumerate() {
        let mut used_track_ids: Vec<String> = Vec::new();

        for (slot_index, candidate) in group.into_iter().enumerate() {
            let mut best_track_index = None;
            let mut best_score = f64::NEG_INFINITY;

            for (track_index, track) in tracks.iter().enumerate() {
                if used_track_ids.iter().any(|id| id == &track.id) {
                    continue;
                }

                let score = score_track_match(track, &candidate, cluster_index, slot_index);
                if score > best_score {
                    best_score = score;
                    best_track_index = Some(track_index);
                }
            }

            if best_track_index.is_none() || best_score < MIN_TRACK_MATCH_SCORE {
                let mut line = candidate.clone();
                line.cluster_index = Some(cluster_index);
                line.slot_index = Some(slot_index);

                let track = LyricTrack {
                    id: format!("track:{}", tracks.len()),
                    role: LyricTrackRole::Unknown,
                    lang: None,
                    timing_mode: track_timing_mode(&[line.clone()]),
                    source_format: map_track_source_format(&line.source_format),
                    confidence: 0.0,
                    dominant_script: line.script_profile.dominant_script.clone(),
                    lines: vec![line],
                    attachments: Vec::new(),
                    scores: None,
                };

                used_track_ids.push(track.id.clone());
                tracks.push(track);
                continue;
            }

            let track = match best_track_index.and_then(|idx| tracks.get_mut(idx)) {
                Some(t) => t,
                None => continue,
            };
            let mut line = candidate.clone();
            line.cluster_index = Some(cluster_index);
            line.slot_index = Some(slot_index);
            track.lines.push(line);
            track.dominant_script = track_dominant_script(&track.lines);
            track.source_format = track_source_format(&track.lines);
            track.timing_mode = track_timing_mode(&track.lines);
            used_track_ids.push(track.id.clone());
        }
    }

    tracks
}

pub(crate) fn score_pair_alignment(drift_ms: i64) -> f64 {
    let abs_drift = drift_ms.unsigned_abs() as u32;
    if abs_drift <= ALIGNMENT_HIGH_WINDOW_MS {
        1.0
    } else if abs_drift <= ALIGNMENT_MEDIUM_WINDOW_MS {
        0.72
    } else if abs_drift <= ALIGNMENT_LOW_WINDOW_MS {
        0.42
    } else {
        0.0
    }
}

pub(crate) fn compute_track_alignment(main_track: &LyricTrack, aux_track: &LyricTrack) -> TrackAlignment {
    let main_lines = &main_track.lines;
    let aux_lines = &aux_track.lines;
    let mut pairs = Vec::new();
    let mut main_index = 0usize;
    let mut aux_index = 0usize;

    while main_index < main_lines.len() && aux_index < aux_lines.len() {
        let main_line = &main_lines[main_index];
        let mut best_aux_index = None;
        let mut best_drift = i64::MAX;

        for index in aux_index..aux_lines.len() {
            let drift = aux_lines[index].start_ms as i64 - main_line.start_ms as i64;
            if drift.unsigned_abs() as u32 > ALIGNMENT_LOW_WINDOW_MS
                && aux_lines[index].start_ms > main_line.start_ms
            {
                break;
            }
            if drift.unsigned_abs() as u32 > ALIGNMENT_LOW_WINDOW_MS {
                continue;
            }
            if drift.abs() < best_drift.abs() {
                best_drift = drift;
                best_aux_index = Some(index);
            }
        }

        if let Some(found_index) = best_aux_index {
            pairs.push(TrackAlignmentPair {
                main_index,
                aux_index: found_index,
                drift_ms: best_drift,
                quality: score_pair_alignment(best_drift),
            });
            main_index += 1;
            aux_index = found_index + 1;
            continue;
        }

        if aux_lines[aux_index].start_ms + ALIGNMENT_LOW_WINDOW_MS < main_line.start_ms {
            aux_index += 1;
        } else {
            main_index += 1;
        }
    }

    let main_coverage = pairs.len() as f64 / main_lines.len().max(1) as f64;
    let aux_coverage = pairs.len() as f64 / aux_lines.len().max(1) as f64;
    let weighted_score = average(&pairs.iter().map(|pair| pair.quality).collect::<Vec<_>>())
        * main_coverage.min(aux_coverage);

    TrackAlignment {
        pairs,
        main_coverage,
        aux_coverage,
        weighted_score,
    }
}

pub(crate) fn tokenize_latin_words(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();

    for ch in text.chars().flat_map(|ch| ch.to_lowercase()) {
        if ch.is_ascii_alphabetic() || (ch == '\'' && !current.is_empty()) {
            current.push(ch);
        } else if !current.is_empty() {
            tokens.push(current.clone());
            current.clear();
        }
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}

pub(crate) fn looks_like_english_phrase(text: &str) -> bool {
    let tokens = tokenize_latin_words(text);
    if tokens.len() < 4 {
        return false;
    }

    let average_token_length =
        tokens.iter().map(|token| token.len() as f64).sum::<f64>() / tokens.len() as f64;
    let english_phrase_words = [
        "can", "give", "hey", "i", "kiss", "last", "love", "me", "more", "one", "than", "you",
        "your",
    ];
    let keyword_hits = tokens
        .iter()
        .filter(|token| english_phrase_words.contains(&token.as_str()))
        .count();

    average_token_length >= 3.0 && keyword_hits >= 2 && score_romanized_latin_text(text) < 0.42
}

pub(crate) fn looks_like_non_romaji_english_latin_text(text: &str) -> bool {
    let profile = get_line_script_profile(text);
    if profile.dominant_script != DominantScript::Latin {
        return false;
    }

    let tokens = tokenize_latin_words(text);
    if tokens.is_empty() {
        return false;
    }

    let lower = text.to_lowercase();
    let romanization = score_romanized_latin_text(text);
    let englishness = score_englishness(text);
    let english_hint_words = [
        "be", "believe", "but", "dream", "dreamt", "i", "leave", "need", "needing", "so", "still",
        "wait", "you", "yet",
    ];
    let hint_matches = tokens
        .iter()
        .filter(|token| english_hint_words.contains(&token.as_str()))
        .count();

    if CONTRACTION_RE
        .get_or_init(|| Regex::new(r"(?i)\b(i'm|you're|we're|it's|i'll|don't|can't)\b").unwrap())
        .is_match(text)
    {
        return true;
    }

    if tokens.iter().any(|token| token.contains('v')) {
        return true;
    }

    if ENGLISH_DIGRAPH_RE
        .get_or_init(|| Regex::new(r"(th|gh|ph|wh|ck|ee|oo)").unwrap())
        .is_match(&lower)
    {
        return romanization < 0.52 || hint_matches > 0;
    }

    if ENGLISH_CONSONANT_RE
        .get_or_init(|| Regex::new(r"(str|scr|dr|st|mp?t)").unwrap())
        .is_match(&lower)
    {
        return romanization < 0.52 || hint_matches > 0;
    }

    let has_english_word_ending = tokens.iter().any(|token| {
        token.len() > 1
            && token
                .chars()
                .last()
                .map(|last| {
                    matches!(
                        last,
                        'd' | 't' | 'l' | 'p' | 'm' | 'k' | 'g' | 'f' | 's' | 'z' | 'r'
                    )
                })
                .unwrap_or(false)
    });

    has_english_word_ending && (hint_matches >= 2 || englishness >= romanization + 0.12)
}

pub(crate) fn score_englishness(text: &str) -> f64 {
    let tokens = tokenize_latin_words(text);
    if tokens.is_empty() {
        return 0.0;
    }

    let english_hint_words = [
        "a", "all", "am", "and", "are", "be", "care", "do", "for", "had", "have", "hello", "i",
        "in", "is", "it", "know", "love", "me", "my", "not", "of", "on", "that", "the", "there",
        "to", "want", "we", "with", "you", "your",
    ];
    let hint_matches = tokens
        .iter()
        .filter(|token| english_hint_words.contains(&token.as_str()))
        .count() as f64;
    let contraction_bonus = if CONTRACTION_RE
        .get_or_init(|| Regex::new(r"(?i)\b(i'm|you're|we're|it's|i'll|don't|can't)\b").unwrap())
        .is_match(text)
    {
        0.15
    } else {
        0.0
    };

    clamp01((hint_matches / tokens.len() as f64) * 0.85 + contraction_bonus)
}

pub(crate) fn score_romanized_latin_text(text: &str) -> f64 {
    let profile = get_line_script_profile(text);
    if profile.dominant_script != DominantScript::Latin {
        return 0.0;
    }

    let tokens = tokenize_latin_words(text);
    if tokens.is_empty() {
        return 0.0;
    }

    let roman_re = ROMANIZATION_RE.get_or_init(|| Regex::new(
        r"(?i)(shi|chi|tsu?|kyo|ryo|ryu|nya|hya|gya|sha|sya|jya|ja|yeo|gye|sarang|geudae|uri|nani|kimo|kimi|watashi|boku|anata|kara|made|desu|xiang|zh|ch|sh|ang|eng|ing|ong|iao|ian|uan|uang|yuan|yin|ying|xin|meng)",
    ).unwrap());
    let roman_pattern_ratio = tokens
        .iter()
        .filter(|token| roman_re.is_match(token))
        .count() as f64
        / tokens.len() as f64;
    let short_token_ratio =
        tokens.iter().filter(|token| token.len() <= 4).count() as f64 / tokens.len() as f64;
    let syllable_ending_ratio = tokens
        .iter()
        .filter(|token| {
            token.ends_with(['a', 'e', 'i', 'o', 'u'])
                || token.ends_with('n')
                || token.ends_with("ng")
        })
        .count() as f64
        / tokens.len() as f64;
    let vowel_ratio = average(
        &tokens
            .iter()
            .map(|token| {
                let vowels = token
                    .chars()
                    .filter(|ch| matches!(ch, 'a' | 'e' | 'i' | 'o' | 'u'))
                    .count() as f64;
                if token.is_empty() {
                    0.0
                } else {
                    vowels / token.len() as f64
                }
            })
            .collect::<Vec<_>>(),
    );
    let token_count_penalty = if tokens.len() == 1 {
        0.25
    } else if tokens.len() == 2 {
        0.1
    } else {
        0.0
    };
    let englishness = score_englishness(text);

    clamp01(
        (roman_pattern_ratio * 0.45)
            + (short_token_ratio * 0.2)
            + (syllable_ending_ratio * if tokens.len() >= 3 { 0.14 } else { 0.06 })
            + (vowel_ratio * 0.22)
            + if tokens.iter().any(|token| token.len() == 1) {
                0.08
            } else {
                0.0
            }
            - token_count_penalty
            - (englishness * 0.62),
    )
}

pub(crate) fn score_track_englishness(track: &LyricTrack) -> f64 {
    average(
        &track
            .lines
            .iter()
            .map(|line| score_englishness(&line.text))
            .collect::<Vec<_>>(),
    )
}

pub(crate) fn score_track_romanization(track: &LyricTrack) -> f64 {
    average(
        &track
            .lines
            .iter()
            .map(|line| score_romanized_latin_text(&line.text))
            .collect::<Vec<_>>(),
    )
}

pub(crate) fn score_track_roles(
    main_track: &LyricTrack,
    candidate_track: &LyricTrack,
    alignment: &TrackAlignment,
) -> TrackRoleScores {
    let role_hint = track_role_hint(candidate_track);
    let englishness = score_track_englishness(candidate_track);
    let romanization = score_track_romanization(candidate_track);

    let mut translation = alignment.weighted_score * 0.6;
    let mut roman = alignment.weighted_score * 0.6;

    if candidate_track.dominant_script != main_track.dominant_script {
        translation += 0.16;
    }
    if candidate_track.dominant_script == DominantScript::Han
        && main_track.dominant_script != DominantScript::Han
    {
        translation += 0.18;
    }
    if candidate_track.dominant_script == DominantScript::Latin && englishness > 0.28 {
        translation += 0.18;
    }
    translation += englishness * 0.22;
    translation -= romanization * 0.3;
    if candidate_track.dominant_script == main_track.dominant_script {
        translation -= 0.18;
    }

    if main_track.dominant_script != DominantScript::Latin
        && candidate_track.dominant_script == DominantScript::Latin
    {
        roman += 0.32;
    } else if main_track.dominant_script == DominantScript::Latin {
        roman -= 0.55;
    } else {
        roman -= 0.15;
    }
    roman += romanization * 0.38;
    roman -= englishness * 0.38;
    if candidate_track.dominant_script != DominantScript::Latin {
        roman -= 0.28;
    }

    if role_hint == Some(LyricTrackRole::Translation) {
        translation += 0.85;
    }
    if role_hint == Some(LyricTrackRole::Romanization) {
        roman += 0.85;
    }

    let has_direct_grouped_pair = alignment.pairs.iter().any(|pair| {
        main_track.lines[pair.main_index].cluster_index.is_some()
            && main_track.lines[pair.main_index].cluster_index
                == candidate_track.lines[pair.aux_index].cluster_index
    });
    if alignment.pairs.len() == 1 && !has_direct_grouped_pair && role_hint.is_none() {
        translation *= 0.5;
        roman *= 0.4;
    }

    TrackRoleScores {
        main: 0.0,
        translation: clamp01(translation),
        romanization: clamp01(roman),
    }
}

pub(crate) fn shared_source_origin_match_ratio(
    main_track: &LyricTrack,
    aux_track: &LyricTrack,
    alignment: &TrackAlignment,
    role_source: Option<ClassificationConfidence>,
) -> f64 {
    if alignment.pairs.is_empty() {
        return 0.0;
    }

    let matched_pairs = alignment
        .pairs
        .iter()
        .filter(|pair| {
            let main_line = &main_track.lines[pair.main_index];
            let aux_line = &aux_track.lines[pair.aux_index];
            if role_source.is_some() && aux_line.role_source != role_source {
                return false;
            }

            main_line.source_index.floor() as i64 == aux_line.source_index.floor() as i64
        })
        .count();

    matched_pairs as f64 / alignment.pairs.len() as f64
}

pub(crate) fn score_main_track(
    candidate_track: &LyricTrack,
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
    track_index: usize,
) -> f64 {
    let max_line_count = tracks
        .iter()
        .map(|track| track.lines.len())
        .max()
        .unwrap_or(1) as f64;
    let max_slot = tracks
        .iter()
        .flat_map(|track| track.lines.iter().map(|line| line.slot_index.unwrap_or(0)))
        .max()
        .unwrap_or(0) as f64;
    let role_hint = track_role_hint(candidate_track);
    let average_slot = average(
        &candidate_track
            .lines
            .iter()
            .map(|line| line.slot_index.unwrap_or(0) as f64)
            .collect::<Vec<_>>(),
    );
    let average_source_index = average(
        &candidate_track
            .lines
            .iter()
            .map(|line| line.source_index)
            .collect::<Vec<_>>(),
    );
    let word_coverage = candidate_track
        .lines
        .iter()
        .filter(|line| {
            line.words
                .as_ref()
                .map(|words| !words.is_empty())
                .unwrap_or(false)
        })
        .count() as f64
        / candidate_track.lines.len().max(1) as f64;

    let mut score = 0.0;
    score += (candidate_track.lines.len() as f64 / max_line_count) * 3.0;
    score += word_coverage * 1.4;
    score += if max_slot > 0.0 {
        (1.0 - (average_slot / max_slot)) * 1.2
    } else {
        1.0
    };

    if matches!(
        role_hint,
        Some(LyricTrackRole::Translation | LyricTrackRole::Romanization)
    ) {
        score -= 4.0;
    }

    let has_romanized_latin_sibling = tracks.iter().enumerate().any(|(other_index, track)| {
        if other_index == track_index {
            return false;
        }
        let alignment = &alignments[track_index][other_index];
        alignment.weighted_score >= 0.35
            && track.dominant_script == DominantScript::Latin
            && score_track_romanization(track) >= 0.35
    });
    let has_japanese_like_sibling = tracks.iter().enumerate().any(|(other_index, track)| {
        other_index != track_index
            && alignments[track_index][other_index].weighted_score >= 0.35
            && track_has_japanese_like_lines(track)
    });
    let has_any_romanized_latin_track = tracks.iter().any(|track| {
        track.dominant_script == DominantScript::Latin && score_track_romanization(track) >= 0.35
    });
    let has_any_japanese_like_track = tracks
        .iter()
        .any(|track| track_has_japanese_like_lines(track));

    let mut attachment_support = 0.0;
    for (other_index, track) in tracks.iter().enumerate() {
        if other_index == track_index {
            continue;
        }
        let alignment = &alignments[track_index][other_index];
        if alignment.weighted_score < 0.28 {
            continue;
        }
        let role_scores = score_track_roles(candidate_track, track, alignment);
        attachment_support += role_scores.translation.max(role_scores.romanization);
    }
    score += attachment_support.min(3.0);

    score += tracks
        .iter()
        .enumerate()
        .filter(|(other_index, _)| *other_index != track_index)
        .map(|(other_index, track)| {
            let alignment = &alignments[track_index][other_index];
            if alignment.weighted_score < 0.28 {
                0.0
            } else {
                shared_source_origin_match_ratio(
                    candidate_track,
                    track,
                    alignment,
                    Some(ClassificationConfidence::ParserNative),
                ) * 3.2
            }
        })
        .sum::<f64>()
        .min(2.0);

    if candidate_track.dominant_script != DominantScript::Latin && has_romanized_latin_sibling {
        score += 3.2;
    }

    if (has_japanese_like_sibling && has_romanized_latin_sibling)
        || (has_any_japanese_like_track && has_any_romanized_latin_track)
    {
        score += (1.2 - average_slot) * 1.8;
        if track_has_japanese_like_lines(candidate_track) {
            score += 4.8;
        } else if candidate_track.dominant_script == DominantScript::Han {
            score -= 5.2;
            if average_source_index > 1.15 {
                score -= 1.2;
            }
        }
    }

    if candidate_track.dominant_script == DominantScript::Latin
        && score_track_englishness(candidate_track) < 0.28
        && score_track_romanization(candidate_track) >= 0.28
        && tracks.iter().enumerate().any(|(other_index, track)| {
            other_index != track_index
                && alignments[track_index][other_index].weighted_score >= 0.45
                && track.dominant_script != DominantScript::Latin
        })
    {
        score -= 4.2;
    }

    score
}

pub(crate) fn track_confidence(role: &LyricTrackRole, scores: &TrackRoleScores) -> f64 {
    match role {
        LyricTrackRole::Main => clamp01(scores.main / 6.0),
        LyricTrackRole::Translation => scores.translation,
        LyricTrackRole::Romanization => scores.romanization,
        LyricTrackRole::Secondary => scores.translation.max(scores.romanization) * 0.7,
        LyricTrackRole::AlternateMain => clamp01(scores.main / 6.0),
        _ => 0.25,
    }
}

pub(crate) fn is_han_translation_track(track: &LyricTrack) -> bool {
    track.dominant_script == DominantScript::Han && !track_has_japanese_like_lines(track)
}

pub(crate) fn has_han_translation_content(profile: &LineScriptProfile) -> bool {
    profile.han_count > 0 && profile.kana_count == 0 && profile.hangul_count == 0
}

pub(crate) fn looks_like_romanization_track(track: &LyricTrack) -> bool {
    track.dominant_script == DominantScript::Latin
        && score_track_romanization(track) >= (score_track_englishness(track) + 0.05).max(0.34)
}

pub(crate) fn detect_japanese_with_romaji_translation_template(
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
) -> Option<LayoutTemplateResolution> {
    let japanese_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| track_has_japanese_like_lines(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    let han_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| is_han_translation_track(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    let latin_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| looks_like_romanization_track(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();

    let mut best_resolution = None;
    let mut best_score = f64::NEG_INFINITY;

    for japanese_index in japanese_candidates {
        for han_index in &han_candidates {
            if *han_index == japanese_index {
                continue;
            }
            let translation_alignment = &alignments[japanese_index][*han_index];
            if translation_alignment.weighted_score < 0.42 {
                continue;
            }

            for latin_index in &latin_candidates {
                if *latin_index == japanese_index || *latin_index == *han_index {
                    continue;
                }
                let roman_alignment = &alignments[japanese_index][*latin_index];
                if roman_alignment.weighted_score < 0.42 {
                    continue;
                }

                let latin_track = &tracks[*latin_index];
                let score = translation_alignment.weighted_score
                    + roman_alignment.weighted_score
                    + (tracks[japanese_index].lines.len() as f64
                        / latin_track.lines.len().max(1) as f64)
                        .min(1.0)
                    + track_word_coverage(&tracks[japanese_index]) * 0.4
                    + if track_role_hint(latin_track) == Some(LyricTrackRole::Romanization) {
                        0.35
                    } else {
                        0.0
                    };

                if score > best_score {
                    let mut track_roles = vec![None; tracks.len()];
                    track_roles[japanese_index] = Some(LyricTrackRole::Main);
                    track_roles[*han_index] = Some(LyricTrackRole::Translation);
                    track_roles[*latin_index] = Some(LyricTrackRole::Romanization);
                    best_score = score;
                    best_resolution = Some(LayoutTemplateResolution {
                        display_track_index: japanese_index,
                        track_roles,
                    });
                }
            }
        }
    }

    best_resolution
}

pub(crate) fn detect_main_with_translation_template(
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
) -> Option<LayoutTemplateResolution> {
    let translation_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| is_han_translation_track(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();

    let mut best_resolution = None;
    let mut best_score = f64::NEG_INFINITY;

    for (main_index, main_track) in tracks.iter().enumerate() {
        let has_japanese_like_sibling = tracks.iter().enumerate().any(|(other_index, track)| {
            other_index != main_index
                && alignments[main_index][other_index].weighted_score >= 0.4
                && track_has_japanese_like_lines(track)
        });

        if is_han_translation_track(main_track)
            || (has_japanese_like_sibling && looks_like_romanization_track(main_track))
        {
            continue;
        }

        for translation_index in &translation_candidates {
            if *translation_index == main_index {
                continue;
            }
            let alignment = &alignments[main_index][*translation_index];
            if alignment.weighted_score < 0.42 {
                continue;
            }

            let score = alignment.weighted_score
                + (main_track.lines.len() as f64
                    / tracks[*translation_index].lines.len().max(1) as f64)
                    .min(1.0)
                + track_word_coverage(main_track) * 0.35
                + if track_role_hint(&tracks[*translation_index])
                    == Some(LyricTrackRole::Translation)
                {
                    0.2
                } else {
                    0.0
                };

            if score > best_score {
                let mut track_roles = vec![None; tracks.len()];
                track_roles[main_index] = Some(LyricTrackRole::Main);
                track_roles[*translation_index] = Some(LyricTrackRole::Translation);
                best_score = score;
                best_resolution = Some(LayoutTemplateResolution {
                    display_track_index: main_index,
                    track_roles,
                });
            }
        }
    }

    best_resolution
}

pub(crate) fn detect_layout_template(
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
) -> Option<LayoutTemplateResolution> {
    if tracks.is_empty() {
        return None;
    }

    if tracks.len() == 1 {
        return Some(LayoutTemplateResolution {
            display_track_index: 0,
            track_roles: vec![Some(LyricTrackRole::Main)],
        });
    }

    detect_japanese_with_romaji_translation_template(tracks, alignments)
        .or_else(|| detect_main_with_translation_template(tracks, alignments))
}

