use super::*;

pub(crate) fn resolve_semantic_confidence(lines: &[Option<&LyricTrackLine>]) -> ClassificationConfidence {
    if lines.iter().any(|line| {
        line.and_then(|value| value.role_source.clone()) == Some(ClassificationConfidence::Explicit)
    }) {
        ClassificationConfidence::Explicit
    } else if lines.iter().any(|line| {
        line.and_then(|value| value.role_source.clone())
            == Some(ClassificationConfidence::ParserNative)
    }) {
        ClassificationConfidence::ParserNative
    } else {
        ClassificationConfidence::Heuristic
    }
}

pub(crate) fn should_attach_aligned_pair(
    main_track: &LyricTrack,
    aux_track: &LyricTrack,
    alignment: &TrackAlignment,
    pair: &TrackAlignmentPair,
) -> bool {
    let main_line = &main_track.lines[pair.main_index];
    let aux_line = &aux_track.lines[pair.aux_index];

    if pair.drift_ms.unsigned_abs() as u32 <= MAX_GROUP_TOLERANCE_MS {
        return true;
    }
    if main_line.cluster_index.is_some() && main_line.cluster_index == aux_line.cluster_index {
        return true;
    }
    if matches!(
        aux_line.role_source,
        Some(ClassificationConfidence::Explicit | ClassificationConfidence::ParserNative)
    ) {
        return true;
    }

    alignment.main_coverage >= 0.75
        && alignment.aux_coverage >= 0.75
        && pair.drift_ms.unsigned_abs() as u32 <= ALIGNMENT_HIGH_WINDOW_MS
}

pub(crate) fn build_aligned_roman_words(
    main_line: &LyricTrackLine,
    roman_line: Option<&LyricTrackLine>,
) -> Option<Vec<ParsedWord>> {
    if let Some(main_words) = &main_line.words {
        if main_words.iter().any(|word| {
            word.roman_text
                .as_ref()
                .map(|text| !text.is_empty())
                .unwrap_or(false)
        }) {
            let roman_words = main_words
                .iter()
                .filter_map(|word| {
                    word.roman_text
                        .as_ref()
                        .filter(|text| !text.is_empty())
                        .map(|text| ParsedWord {
                            text: text.clone(),
                            start_ms: word.start_ms,
                            end_ms: word.end_ms,
                            roman_text: None,
                        })
                })
                .collect::<Vec<_>>();
            if !roman_words.is_empty() {
                return Some(roman_words);
            }
        }
    }

    let main_words = main_line.words.as_ref()?;
    let roman_words = roman_line?.words.as_ref()?;
    if main_words.len() != roman_words.len() {
        return Some(roman_words.clone());
    }

    let aligned = main_words
        .iter()
        .zip(roman_words.iter())
        .all(|(main_word, roman_word)| {
            main_word.start_ms.abs_diff(roman_word.start_ms) <= 120
                && main_word.end_ms.abs_diff(roman_word.end_ms) <= 120
        });

    if aligned {
        Some(roman_words.clone())
    } else {
        Some(roman_words.clone())
    }
}

pub(crate) fn push_secondary_text(secondary_texts: &mut Option<Vec<String>>, text: String) {
    if text.is_empty() {
        return;
    }
    let values = secondary_texts.get_or_insert_with(Vec::new);
    if !values.iter().any(|value| value == &text) {
        values.push(text);
    }
}

pub(crate) fn should_use_line_as_romaji(
    main_line: &LyricTrackLine,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
) -> bool {
    if matches!(
        candidate_track.role,
        LyricTrackRole::Romanization | LyricTrackRole::Secondary
    ) && candidate_line.explicit_role == Some(ExplicitLineRole::Roman)
    {
        return true;
    }
    if candidate_track.role == LyricTrackRole::Romanization {
        return true;
    }
    if candidate_line.script_profile.dominant_script != DominantScript::Latin {
        return false;
    }
    if main_line.script_profile.dominant_script == DominantScript::Latin
        && !is_japanese_like(&main_line.script_profile)
    {
        return false;
    }

    let englishness = score_englishness(&candidate_line.text);
    let romanization = score_romanized_latin_text(&candidate_line.text);

    romanization >= englishness
        || (candidate_line.source_index < main_line.source_index
            && romanization + 0.08 >= englishness)
}

pub(crate) fn is_auxiliary_role_repair_track(track: &LyricTrack) -> bool {
    matches!(
        track.role,
        LyricTrackRole::Unknown | LyricTrackRole::Secondary | LyricTrackRole::AlternateMain
    )
}

pub(crate) fn should_use_line_as_translation(
    main_line: &LyricTrackLine,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
) -> bool {
    if matches!(
        candidate_track.role,
        LyricTrackRole::Translation | LyricTrackRole::Secondary
    ) && candidate_line.explicit_role == Some(ExplicitLineRole::Translation)
    {
        return true;
    }
    if candidate_track.role == LyricTrackRole::Translation {
        return true;
    }
    if main_line.script_profile.dominant_script == DominantScript::Latin {
        return candidate_line.script_profile.dominant_script != DominantScript::Latin
            || (candidate_line.source_index > main_line.source_index
                && has_han_translation_content(&candidate_line.script_profile));
    }
    if candidate_line.script_profile.dominant_script == DominantScript::Latin {
        return false;
    }
    if candidate_line.source_index > main_line.source_index {
        return true;
    }

    candidate_line.script_profile.dominant_script == DominantScript::Han
        && is_japanese_like(&main_line.script_profile)
}

pub(crate) fn should_promote_japanese_auxiliary_as_main(
    current_main_line: &LyricTrackLine,
    candidate_line: &LyricTrackLine,
) -> bool {
    current_main_line.script_profile.dominant_script == DominantScript::Latin
        && is_japanese_like(&candidate_line.script_profile)
        && current_main_line.cluster_index.is_some()
        && current_main_line.cluster_index == candidate_line.cluster_index
}

pub(crate) fn merge_auxiliary_line_into_semantic(
    semantic_line: &mut SemanticLine,
    main_line: &LyricTrackLine,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
) {
    if candidate_line.text == semantic_line.main_text {
        return;
    }

    if semantic_line.roman_text.is_none()
        && should_use_line_as_romaji(main_line, candidate_track, candidate_line)
    {
        semantic_line.roman_text = Some(candidate_line.text.clone());
        semantic_line.roman_words = build_aligned_roman_words(main_line, Some(candidate_line));
        return;
    }

    if semantic_line.translation_text.is_none()
        && should_use_line_as_translation(main_line, candidate_track, candidate_line)
    {
        semantic_line.translation_text = Some(candidate_line.text.clone());
        return;
    }

    push_secondary_text(
        &mut semantic_line.secondary_texts,
        candidate_line.text.clone(),
    );
}

pub(crate) fn score_cluster_main_candidate(
    document: &LyricDocument,
    main_track: &LyricTrack,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
    group: &[(usize, usize, LyricTrackLine)],
) -> f64 {
    let mut sorted_source_indexes = group
        .iter()
        .map(|(_, _, line)| line.source_index)
        .collect::<Vec<_>>();
    sorted_source_indexes.sort_by(|left, right| compare_source_index(*left, *right));
    let median_source_index = sorted_source_indexes[sorted_source_indexes.len() / 2];

    let englishness = score_englishness(&candidate_line.text);
    let romanization = score_romanized_latin_text(&candidate_line.text);
    let has_japanese_like_peer = group
        .iter()
        .any(|(_, _, line)| is_japanese_like(&line.script_profile));
    let has_latin_peer = group
        .iter()
        .any(|(_, _, line)| line.script_profile.dominant_script == DominantScript::Latin);
    let has_han_peer = group
        .iter()
        .any(|(_, _, line)| line.script_profile.dominant_script == DominantScript::Han);
    let has_non_romaji_english_latin_peer = group.iter().any(|(_, _, line)| {
        line.script_profile.dominant_script == DominantScript::Latin
            && looks_like_non_romaji_english_latin_text(&line.text)
    });
    let first_non_latin_source_index = group
        .iter()
        .filter(|(_, _, line)| line.script_profile.dominant_script != DominantScript::Latin)
        .map(|(_, _, line)| line.source_index)
        .min_by(|left, right| compare_source_index(*left, *right));

    let mut score = 0.0;
    score += (2.8 - ((candidate_line.source_index - median_source_index).abs() * 2.2)).max(-1.4);
    score += if candidate_line.explicit_role.is_none() {
        1.0
    } else {
        -1.0
    };
    score += if candidate_line
        .words
        .as_ref()
        .map(|words| !words.is_empty())
        .unwrap_or(false)
    {
        0.8
    } else {
        0.0
    };
    score += if same_script_family(
        &candidate_line.script_profile.dominant_script,
        &main_track.dominant_script,
    ) {
        0.9
    } else {
        0.0
    };

    match candidate_track.role {
        LyricTrackRole::Main | LyricTrackRole::AlternateMain => score += 1.2,
        LyricTrackRole::Unknown | LyricTrackRole::Secondary => score += 0.4,
        LyricTrackRole::Translation | LyricTrackRole::Romanization => score -= 0.6,
        LyricTrackRole::Background | LyricTrackRole::Metadata => score -= 2.4,
    }

    if track_has_japanese_like_lines(main_track) && is_japanese_like(&candidate_line.script_profile)
    {
        score += 2.2;
    }
    if has_japanese_like_peer {
        if is_japanese_like(&candidate_line.script_profile) {
            score += 2.2;
        } else if candidate_line.script_profile.dominant_script == DominantScript::Han {
            score -= 2.2;
        }
    }
    if candidate_line.script_profile.dominant_script == DominantScript::Latin {
        if englishness >= romanization + 0.12 {
            score += 1.8;
        } else if romanization >= englishness + 0.08 {
            score -= 1.4;
        }
        if has_han_peer && looks_like_english_phrase(&candidate_line.text) {
            score += 3.2;
        }
        if has_han_peer
            && !has_japanese_like_peer
            && looks_like_non_romaji_english_latin_text(&candidate_line.text)
        {
            score += 4.2;
        }
    } else if has_latin_peer {
        if let Some(first_non_latin_source_index) = first_non_latin_source_index {
            if (candidate_line.source_index - first_non_latin_source_index).abs() < 0.01 {
                score += 2.4;
            } else {
                score -= 1.4;
            }
        }
        if candidate_line.script_profile.dominant_script == DominantScript::Han
            && !has_japanese_like_peer
            && has_non_romaji_english_latin_peer
        {
            score -= 2.4;
        }
    }
    if candidate_line.script_profile.dominant_script == DominantScript::Han
        && track_has_japanese_like_lines(main_track)
        && has_japanese_like_peer
    {
        score -= 0.8;
    }
    if document
        .display_track_id
        .as_ref()
        .map(|track_id| track_id == &candidate_track.id)
        .unwrap_or(false)
    {
        score += 0.8;
    }

    score
}

pub(crate) fn build_semantic_line_from_orphan_group(
    document: &LyricDocument,
    main_track: &LyricTrack,
    group: &[(usize, usize, LyricTrackLine)],
) -> SemanticLine {
    let main_candidate = group
        .iter()
        .max_by(|left, right| {
            score_cluster_main_candidate(
                document,
                main_track,
                &document.tracks[left.0],
                &left.2,
                group,
            )
            .partial_cmp(&score_cluster_main_candidate(
                document,
                main_track,
                &document.tracks[right.0],
                &right.2,
                group,
            ))
            .unwrap_or(Ordering::Equal)
        })
        .cloned();

    let (main_track_index, _main_line_index, main_line) = match main_candidate {
        Some(v) => v,
        None => {
            return SemanticLine {
                start_ms: 0,
                end_ms: 0,
                main_text: String::new(),
                main_words: None,
                translation_text: None,
                roman_text: None,
                roman_words: None,
                secondary_texts: None,
                confidence: ClassificationConfidence::Heuristic,
                speaker: None,
                is_bg: false,
                is_duet: false,
                is_duet_partner: false,
            }
        }
    };

    let mut semantic_line = SemanticLine {
        start_ms: main_line.start_ms,
        end_ms: main_line.end_ms,
        main_text: main_line.text.clone(),
        main_words: main_line.words.clone(),
        translation_text: None,
        roman_text: None,
        roman_words: None,
        secondary_texts: None,
        confidence: resolve_semantic_confidence(&[Some(&main_line)]),
        speaker: main_line.speaker.clone(),
        is_bg: main_line.is_bg,
        is_duet: main_line.is_duet,
        is_duet_partner: main_line.is_duet_partner,
    };

    for (track_index, _line_index, candidate_line) in group.iter() {
        if *track_index == main_track_index && candidate_line.id == main_line.id {
            continue;
        }
        merge_auxiliary_line_into_semantic(
            &mut semantic_line,
            &main_line,
            &document.tracks[*track_index],
            candidate_line,
        );
    }

    semantic_line.confidence = resolve_semantic_confidence(
        &group
            .iter()
            .map(|(_, _, line)| Some(line))
            .collect::<Vec<_>>(),
    );
    semantic_line
}

pub(crate) fn resolve_display_line_roles<'a>(
    main_line: &'a LyricTrackLine,
    translation_line: Option<&'a LyricTrackLine>,
    roman_line: Option<&'a LyricTrackLine>,
) -> (
    &'a LyricTrackLine,
    Option<&'a LyricTrackLine>,
    Option<&'a LyricTrackLine>,
) {
    if let Some(translation_line) = translation_line {
        if translation_line.script_profile.dominant_script == DominantScript::Latin
            && main_line.script_profile.dominant_script != DominantScript::Latin
            && looks_like_english_phrase(&translation_line.text)
        {
            return (translation_line, Some(main_line), None);
        }
    }

    if let Some(roman_line) = roman_line {
        if roman_line.script_profile.dominant_script == DominantScript::Latin
            && main_line.script_profile.dominant_script != DominantScript::Latin
            && looks_like_english_phrase(&roman_line.text)
        {
            return (roman_line, Some(main_line), None);
        }
    }

    if main_line.script_profile.dominant_script == DominantScript::Han {
        if let Some(translation_line) = translation_line {
            if is_japanese_like(&translation_line.script_profile) {
                return (translation_line, Some(main_line), roman_line);
            }
        }
    }

    (main_line, translation_line, roman_line)
}

pub(crate) fn normalize_semantic_line_display_roles(mut line: SemanticLine) -> SemanticLine {
    let main_is_latin =
        get_line_script_profile(&line.main_text).dominant_script == DominantScript::Latin;
    let translation_is_missing = line
        .translation_text
        .as_ref()
        .map(|text| text.trim().is_empty())
        .unwrap_or(true);
    let romaji_is_english_phrase = line
        .roman_text
        .as_ref()
        .map(|text| looks_like_english_phrase(text))
        .unwrap_or(false);

    if !main_is_latin && translation_is_missing && romaji_is_english_phrase {
        if let Some(english_text) = line.roman_text.take() {
            line.translation_text = Some(line.main_text.clone());
            line.main_text = english_text;
            line.main_words = line.roman_words.take();
        }
    }

    line
}

pub(crate) fn is_han_only_line(line: &LyricTrackLine) -> bool {
    line.script_profile.han_count > 0
        && line.script_profile.latin_count == 0
        && line.script_profile.kana_count == 0
        && line.script_profile.hangul_count == 0
}

pub(crate) fn is_han_latin_mixed_line(line: &LyricTrackLine) -> bool {
    line.script_profile.han_count > 0
        && line.script_profile.latin_count > 0
        && line.script_profile.kana_count == 0
        && line.script_profile.hangul_count == 0
}

pub(crate) fn is_latin_only_line(line: &LyricTrackLine) -> bool {
    line.script_profile.latin_count > 0
        && line.script_profile.han_count == 0
        && line.script_profile.kana_count == 0
        && line.script_profile.hangul_count == 0
}

pub(crate) fn build_hard_role_semantic_line(
    main_line: &LyricTrackLine,
    translation_line: Option<&LyricTrackLine>,
    roman_line: Option<&LyricTrackLine>,
) -> SemanticLine {
    SemanticLine {
        start_ms: main_line.start_ms,
        end_ms: main_line.end_ms,
        main_text: main_line.text.clone(),
        main_words: main_line.words.clone(),
        translation_text: translation_line.map(|line| line.text.clone()),
        roman_text: roman_line.map(|line| line.text.clone()),
        roman_words: build_aligned_roman_words(main_line, roman_line),
        secondary_texts: None,
        confidence: resolve_semantic_confidence(&[Some(main_line), translation_line, roman_line]),
        speaker: main_line.speaker.clone(),
        is_bg: main_line.is_bg,
        is_duet: main_line.is_duet,
        is_duet_partner: main_line.is_duet_partner,
    }
}

pub(crate) fn build_hard_role_semantic_line_from_cluster(
    group: &[(usize, usize, LyricTrackLine)],
) -> Option<SemanticLine> {
    let mut lines = group
        .iter()
        .map(|(_, _, line)| line)
        .collect::<Vec<&LyricTrackLine>>();
    lines.sort_by(|left, right| {
        left.slot_index
            .unwrap_or(usize::MAX)
            .cmp(&right.slot_index.unwrap_or(usize::MAX))
            .then_with(|| compare_source_index(left.source_index, right.source_index))
            .then_with(|| left.start_ms.cmp(&right.start_ms))
    });

    match lines.as_slice() {
        [main_line] => Some(build_hard_role_semantic_line(main_line, None, None)),
        [first_line, second_line] => {
            let (main_line, translation_line) =
                if is_han_only_line(first_line) && !is_han_only_line(second_line) {
                    (*second_line, *first_line)
                } else if is_han_only_line(second_line) && !is_han_only_line(first_line) {
                    (*first_line, *second_line)
                } else if is_han_latin_mixed_line(first_line) && is_latin_only_line(second_line) {
                    (*second_line, *first_line)
                } else if is_han_latin_mixed_line(second_line) && is_latin_only_line(first_line) {
                    (*first_line, *second_line)
                } else {
                    (*first_line, *second_line)
                };

            // [修复] 落雪歌词中 lyric 与 tlyric 可能内容完全相同（如源未提供翻译，
            // tlyric 复用了 lyric），此时不应把同一句再当翻译显示，避免主副词重复。
            if sanitize_line_text(&main_line.text) == sanitize_line_text(&translation_line.text) {
                Some(build_hard_role_semantic_line(main_line, None, None))
            } else {
                Some(build_hard_role_semantic_line(
                    main_line,
                    Some(translation_line),
                    None,
                ))
            }
        }
        [roman_line, main_line, translation_line] => {
            // [修复] 同理：若主词与翻译文本完全相同，则丢弃重复翻译，仅保留主词+罗马音
            let translation = if sanitize_line_text(&main_line.text)
                == sanitize_line_text(&translation_line.text)
            {
                None
            } else {
                Some(*translation_line)
            };
            Some(build_hard_role_semantic_line(
                main_line,
                translation,
                Some(roman_line),
            ))
        }
        _ => None,
    }
}

pub(crate) fn try_build_hard_role_semantic_lines(document: &LyricDocument) -> Option<Vec<SemanticLine>> {
    let mut grouped_lines = BTreeMap::<usize, Vec<(usize, usize, LyricTrackLine)>>::new();
    let mut clustered_line_count = 0usize;
    let total_line_count = document
        .tracks
        .iter()
        .map(|track| track.lines.len())
        .sum::<usize>();

    for (track_index, track) in document.tracks.iter().enumerate() {
        for (line_index, line) in track.lines.iter().enumerate() {
            let Some(cluster_index) = line.cluster_index else {
                continue;
            };
            clustered_line_count += 1;
            grouped_lines.entry(cluster_index).or_default().push((
                track_index,
                line_index,
                line.clone(),
            ));
        }
    }

    if grouped_lines.is_empty()
        || clustered_line_count != total_line_count
        || !grouped_lines
            .values()
            .any(|group| matches!(group.len(), 2 | 3))
        || grouped_lines.values().any(|group| group.len() > 3)
    {
        return None;
    }

    let mut semantic_lines = grouped_lines
        .values()
        .map(|group| build_hard_role_semantic_line_from_cluster(group))
        .collect::<Option<Vec<_>>>()?;

    semantic_lines.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });
    Some(semantic_lines)
}

pub fn build_lyric_document(parsed_lines: &[ParsedLine]) -> Option<LyricDocument> {
    let candidate_lines = build_candidate_lines(parsed_lines);
    if candidate_lines.is_empty() {
        return None;
    }

    let groups = group_candidate_lines(&candidate_lines);
    let mut tracks = build_tracks(groups);
    if tracks.is_empty() {
        return None;
    }

    let alignments = (0..tracks.len())
        .map(|main_index| {
            (0..tracks.len())
                .map(|aux_index| {
                    if main_index == aux_index {
                        TrackAlignment::default()
                    } else {
                        compute_track_alignment(&tracks[main_index], &tracks[aux_index])
                    }
                })
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();

    let template_resolution = detect_layout_template(&tracks, &alignments);
    let display_track_index = template_resolution
        .as_ref()
        .map(|resolution| resolution.display_track_index)
        .unwrap_or_else(|| {
            let mut best_track_index = 0usize;
            let mut best_track_score = f64::NEG_INFINITY;

            for (track_index, track) in tracks.iter().enumerate() {
                let score = score_main_track(track, &tracks, &alignments, track_index);
                if score > best_track_score {
                    best_track_score = score;
                    best_track_index = track_index;
                }
            }

            best_track_index
        });

    for track_index in 0..tracks.len() {
        let main_score = score_main_track(&tracks[track_index], &tracks, &alignments, track_index);
        let template_role = template_resolution
            .as_ref()
            .and_then(|resolution| resolution.track_roles[track_index].clone());
        if track_index == display_track_index {
            let scores = TrackRoleScores {
                main: main_score,
                translation: 0.0,
                romanization: 0.0,
            };
            tracks[track_index].role = LyricTrackRole::Main;
            tracks[track_index].confidence = track_confidence(&LyricTrackRole::Main, &scores);
            tracks[track_index].scores = Some(LyricTrackScores {
                main: scores.main,
                translation: scores.translation,
                romanization: scores.romanization,
            });
            continue;
        }

        let alignment = &alignments[display_track_index][track_index];
        let mut scores = score_track_roles(
            &tracks[display_track_index],
            &tracks[track_index],
            alignment,
        );
        scores.main = main_score;

        let role = if let Some(role) = template_role {
            role
        } else if alignment.weighted_score < 0.25 {
            if tracks[track_index].lines.len() as f64
                >= tracks[display_track_index].lines.len() as f64 * 0.6
                && tracks[track_index].dominant_script
                    == tracks[display_track_index].dominant_script
            {
                LyricTrackRole::AlternateMain
            } else {
                LyricTrackRole::Unknown
            }
        } else if scores.translation >= 0.58 || scores.romanization >= 0.58 {
            if scores.translation >= scores.romanization {
                LyricTrackRole::Translation
            } else {
                LyricTrackRole::Romanization
            }
        } else {
            LyricTrackRole::Secondary
        };

        tracks[track_index].role = role.clone();
        tracks[track_index].confidence = track_confidence(&role, &scores);
        tracks[track_index].scores = Some(LyricTrackScores {
            main: scores.main,
            translation: scores.translation,
            romanization: scores.romanization,
        });
    }

    let display_track_id = tracks[display_track_index].id.clone();
    let attachments = tracks
        .iter()
        .enumerate()
        .filter(|(track_index, track)| {
            *track_index != display_track_index
                && matches!(
                    track.role,
                    LyricTrackRole::Translation
                        | LyricTrackRole::Romanization
                        | LyricTrackRole::Secondary
                )
        })
        .map(|(track_index, track)| LyricTrackAttachment {
            track_id: track.id.clone(),
            role: track.role.clone(),
            confidence: track.confidence,
            line_match_ratio: alignments[display_track_index][track_index].main_coverage,
        })
        .collect::<Vec<_>>();

    tracks[display_track_index].attachments = attachments.clone();

    let issues = if tracks.len() > 1 && attachments.is_empty() {
        vec![LyricIssue {
            code: "lyrics.unattached_tracks".to_string(),
            message: "Detected multiple lyric tracks but could not confidently attach any secondary track to the display main track.".to_string(),
            severity: "warning".to_string(),
        }]
    } else {
        Vec::new()
    };

    let mut source_formats = candidate_lines
        .iter()
        .map(|line| line.source_format.clone())
        .collect::<Vec<_>>();
    source_formats.sort_by(|left, right| format!("{left:?}").cmp(&format!("{right:?}")));
    source_formats.dedup();

    let document_confidence = average(
        &tracks
            .iter()
            .map(|track| track.confidence)
            .collect::<Vec<_>>(),
    );

    Some(LyricDocument {
        metadata: LyricDocumentMetadata {
            total_lines: candidate_lines.len(),
            source_formats,
        },
        tracks,
        issues,
        confidence: document_confidence,
        display_track_id: Some(display_track_id),
    })
}

pub fn lyric_document_to_semantic_lines(document: &LyricDocument) -> Vec<SemanticLine> {
    if let Some(semantic_lines) = try_build_hard_role_semantic_lines(document) {
        return semantic_lines;
    }

    let Some(main_track) = document
        .tracks
        .iter()
        .find(|track| track.id == document.display_track_id.clone().unwrap_or_default())
        .or_else(|| {
            document
                .tracks
                .iter()
                .find(|track| track.role == LyricTrackRole::Main)
        })
    else {
        return Vec::new();
    };

    let alignments = document
        .tracks
        .iter()
        .map(|track| compute_track_alignment(main_track, track))
        .collect::<Vec<_>>();

    let translation_tracks = document
        .tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| track.role == LyricTrackRole::Translation)
        .collect::<Vec<_>>();
    let roman_tracks = document
        .tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| track.role == LyricTrackRole::Romanization)
        .collect::<Vec<_>>();
    let secondary_tracks = document
        .tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| is_auxiliary_role_repair_track(track))
        .collect::<Vec<_>>();

    let mut attached_line_keys: Vec<(usize, usize)> = Vec::new();
    let mut semantic_lines = Vec::new();
    let mut semantic_line_clusters = Vec::new();

    for (main_index, main_line) in main_track.lines.iter().enumerate() {
        let translation_entry = translation_tracks.iter().find_map(|(track_index, track)| {
            alignments[*track_index]
                .pairs
                .iter()
                .find(|pair| {
                    pair.main_index == main_index
                        && should_attach_aligned_pair(
                            main_track,
                            track,
                            &alignments[*track_index],
                            pair,
                        )
                })
                .map(|pair| (*track_index, pair.aux_index))
        });
        let roman_entry = roman_tracks.iter().find_map(|(track_index, track)| {
            alignments[*track_index]
                .pairs
                .iter()
                .find(|pair| {
                    pair.main_index == main_index
                        && should_attach_aligned_pair(
                            main_track,
                            track,
                            &alignments[*track_index],
                            pair,
                        )
                })
                .map(|pair| (*track_index, pair.aux_index))
        });

        let translation_line = translation_entry.and_then(|(track_index, aux_index)| {
            attached_line_keys.push((track_index, aux_index));
            document.tracks[track_index].lines.get(aux_index)
        });
        let roman_line = roman_entry.and_then(|(track_index, aux_index)| {
            attached_line_keys.push((track_index, aux_index));
            document.tracks[track_index].lines.get(aux_index)
        });
        let (mut display_main_line, display_translation_line, mut display_roman_line) =
            resolve_display_line_roles(main_line, translation_line, roman_line);

        let mut fallback_translation_line: Option<&LyricTrackLine> = None;
        let mut secondary_texts = Vec::new();
        for (track_index, track) in &secondary_tracks {
            let Some(pair) = alignments[*track_index].pairs.iter().find(|pair| {
                pair.main_index == main_index
                    && should_attach_aligned_pair(
                        main_track,
                        track,
                        &alignments[*track_index],
                        pair,
                    )
            }) else {
                continue;
            };
            attached_line_keys.push((*track_index, pair.aux_index));

            let Some(line) = track.lines.get(pair.aux_index) else {
                continue;
            };

            if display_translation_line.is_none()
                && fallback_translation_line.is_none()
                && line.script_profile.dominant_script == DominantScript::Han
                && should_use_line_as_translation(display_main_line, track, line)
            {
                fallback_translation_line = Some(line);
            } else if should_promote_japanese_auxiliary_as_main(display_main_line, line) {
                display_roman_line = Some(display_main_line);
                display_main_line = line;
            } else if display_roman_line.is_none()
                && should_use_line_as_romaji(display_main_line, track, line)
            {
                display_roman_line = Some(line);
            } else {
                secondary_texts.push(line.text.clone());
            }
        }
        let resolved_translation_line = display_translation_line.or(fallback_translation_line);

        semantic_lines.push(normalize_semantic_line_display_roles(SemanticLine {
            start_ms: display_main_line.start_ms,
            end_ms: display_main_line.end_ms,
            main_text: display_main_line.text.clone(),
            main_words: display_main_line.words.clone(),
            translation_text: resolved_translation_line.map(|line| line.text.clone()),
            roman_text: display_roman_line.map(|line| line.text.clone()),
            roman_words: build_aligned_roman_words(display_main_line, display_roman_line),
            secondary_texts: if secondary_texts.is_empty() {
                None
            } else {
                Some(secondary_texts)
            },
            confidence: resolve_semantic_confidence(&[
                Some(display_main_line),
                resolved_translation_line,
                display_roman_line,
            ]),
            speaker: display_main_line.speaker.clone(),
            is_bg: display_main_line.is_bg,
            is_duet: display_main_line.is_duet,
            is_duet_partner: display_main_line.is_duet_partner,
        }));
        semantic_line_clusters.push(main_line.cluster_index);
    }

    let mut orphan_groups = BTreeMap::<Option<usize>, Vec<(usize, usize, LyricTrackLine)>>::new();
    for (track_index, track) in document.tracks.iter().enumerate() {
        if track.id == main_track.id {
            continue;
        }

        for (line_index, line) in track.lines.iter().enumerate() {
            if attached_line_keys.contains(&(track_index, line_index)) {
                continue;
            }

            orphan_groups.entry(line.cluster_index).or_default().push((
                track_index,
                line_index,
                line.clone(),
            ));
        }
    }

    for (cluster_index, group) in orphan_groups {
        if let Some(existing_index) = cluster_index.and_then(|cluster| {
            semantic_line_clusters
                .iter()
                .position(|value| *value == Some(cluster))
        }) {
            let existing_main_text = semantic_lines[existing_index].main_text.clone();
            let existing_main_line = document
                .tracks
                .iter()
                .flat_map(|track| track.lines.iter())
                .find(|line| line.cluster_index == cluster_index && line.text == existing_main_text)
                .cloned();

            if let Some(existing_main_line) = existing_main_line {
                for (track_index, _line_index, line) in group {
                    merge_auxiliary_line_into_semantic(
                        &mut semantic_lines[existing_index],
                        &existing_main_line,
                        &document.tracks[track_index],
                        &line,
                    );
                }
                continue;
            }
        }

        semantic_lines.push(normalize_semantic_line_display_roles(
            build_semantic_line_from_orphan_group(document, main_track, &group),
        ));
    }

    semantic_lines.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });
    semantic_lines
        .into_iter()
        .fold(Vec::<SemanticLine>::new(), |mut acc, line| {
            let is_duplicate = acc
                .last()
                .map(|previous| {
                    previous.start_ms == line.start_ms
                        && previous.end_ms == line.end_ms
                        && previous.main_text == line.main_text
                })
                .unwrap_or(false);
            if !is_duplicate {
                acc.push(line);
            }
            acc
        })
}

pub(crate) fn build_romaji_text(line: &SemanticLine) -> String {
    if let Some(text) = line.roman_text.as_ref() {
        return text.clone();
    }
    line.roman_words
        .as_ref()
        .map(|words| {
            words
                .iter()
                .map(|word| word.text.clone())
                .collect::<String>()
        })
        .unwrap_or_default()
}

pub fn semantic_line_to_lyric_line(line: &SemanticLine) -> LyricLinePayload {
    let words = line
        .main_words
        .as_ref()
        .map(|main_words| {
            main_words
                .iter()
                .map(|word| {
                    let timed_romaji = line.roman_words.as_ref().and_then(|roman_words| {
                        roman_words.iter().find(|roman_word| {
                            roman_word.start_ms == word.start_ms && roman_word.end_ms == word.end_ms
                        })
                    });

                    LyricWordPayload {
                        text: word.text.clone(),
                        start: word.start_ms as f64 / 1000.0,
                        end: word.end_ms as f64 / 1000.0,
                        romaji: timed_romaji
                            .map(|roman_word| roman_word.text.clone())
                            .or_else(|| word.roman_text.clone())
                            .filter(|text| !text.is_empty()),
                    }
                })
                .collect::<Vec<_>>()
        })
        .filter(|words| !words.is_empty());

    LyricLinePayload {
        time: line.start_ms as f64 / 1000.0,
        end_time: line.end_ms as f64 / 1000.0,
        text: line.main_text.clone(),
        translation: line.translation_text.clone().unwrap_or_default(),
        romaji: build_romaji_text(line),
        words,
        romaji_words: line
            .roman_words
            .as_ref()
            .map(|roman_words| {
                roman_words
                    .iter()
                    .map(|word| LyricWordPayload {
                        text: word.text.clone(),
                        start: word.start_ms as f64 / 1000.0,
                        end: word.end_ms as f64 / 1000.0,
                        romaji: None,
                    })
                    .collect::<Vec<_>>()
            })
            .filter(|words| !words.is_empty()),
        secondary: line.secondary_texts.clone(),
        speaker: line.speaker.clone(),
        is_bg: line.is_bg,
        is_duet: line.is_duet,
        is_duet_partner: line.is_duet_partner,
    }
}

