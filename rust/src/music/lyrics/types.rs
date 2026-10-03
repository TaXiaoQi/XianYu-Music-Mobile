use super::*;

pub(crate) const MAX_GROUP_TOLERANCE_MS: u32 = 50;
pub(crate) const ENHANCED_TRAILING_WORD_DURATION_MS: u32 = 400;

// ==================== Regex caches (module-level, compiled once) ====================
pub(crate) static XML_TAG_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static TTML_PARAGRAPH_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static TTML_BEGIN_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static TTML_END_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static TTML_SPAN_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static TTML_ROLE_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static CONTRACTION_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static ENGLISH_DIGRAPH_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static ENGLISH_CONSONANT_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) static ROMANIZATION_RE: OnceLock<Regex> = OnceLock::new();
pub(crate) const MAX_GROUP_SIZE: usize = 3;
pub(crate) const ALIGNMENT_HIGH_WINDOW_MS: u32 = 300;
pub(crate) const ALIGNMENT_MEDIUM_WINDOW_MS: u32 = 800;
pub(crate) const ALIGNMENT_LOW_WINDOW_MS: u32 = 1500;
pub(crate) const MIN_TRACK_MATCH_SCORE: f64 = 2.6;

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ParsedLineSourceFormat {
    Lrc,
    EnhancedLrc,
    Eslrc,
    Yrc,
    Qrc,
    Lys,
    Ttml,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ExplicitLineRole {
    Translation,
    Roman,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ClassificationConfidence {
    Explicit,
    ParserNative,
    Heuristic,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DominantScript {
    Latin,
    Han,
    Kana,
    Hangul,
    Mixed,
    Other,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
#[allow(dead_code)]
pub enum LyricTrackRole {
    Main,
    Translation,
    Romanization,
    Secondary,
    AlternateMain,
    Background,
    Metadata,
    Unknown,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
#[allow(dead_code)]
pub enum LyricTimingMode {
    Line,
    Word,
    Syllable,
    None,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LyricTrackSourceFormat {
    Mixed,
    Lrc,
    EnhancedLrc,
    Eslrc,
    Yrc,
    Qrc,
    Lys,
    Ttml,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ParsedWord {
    pub text: String,
    pub start_ms: u32,
    pub end_ms: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_text: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ParsedLine {
    pub start_ms: u32,
    pub end_ms: u32,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<Vec<ParsedWord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translated_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_text: Option<String>,
    pub source_format: ParsedLineSourceFormat,
    pub source_index: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub explicit_role: Option<ExplicitLineRole>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    pub is_bg: bool,
    pub is_duet: bool,
    pub is_duet_partner: bool,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LineScriptProfile {
    pub latin_count: u32,
    pub han_count: u32,
    pub kana_count: u32,
    pub hangul_count: u32,
    pub dominant_script: DominantScript,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricTrackLine {
    pub id: String,
    pub start_ms: u32,
    pub end_ms: u32,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<Vec<ParsedWord>>,
    pub source_index: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub explicit_role: Option<ExplicitLineRole>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role_source: Option<ClassificationConfidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cluster_index: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slot_index: Option<usize>,
    pub source_format: ParsedLineSourceFormat,
    pub script_profile: LineScriptProfile,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    pub is_bg: bool,
    pub is_duet: bool,
    pub is_duet_partner: bool,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricTrackAttachment {
    pub track_id: String,
    pub role: LyricTrackRole,
    pub confidence: f64,
    pub line_match_ratio: f64,
}

#[derive(Serialize, Clone, Debug)]
pub struct LyricTrackScores {
    pub main: f64,
    pub translation: f64,
    pub romanization: f64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricTrack {
    pub id: String,
    pub role: LyricTrackRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lang: Option<String>,
    pub timing_mode: LyricTimingMode,
    pub source_format: LyricTrackSourceFormat,
    pub confidence: f64,
    pub dominant_script: DominantScript,
    pub lines: Vec<LyricTrackLine>,
    pub attachments: Vec<LyricTrackAttachment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scores: Option<LyricTrackScores>,
}

#[derive(Serialize, Clone, Debug)]
pub struct LyricIssue {
    pub code: String,
    pub message: String,
    pub severity: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricDocumentMetadata {
    pub total_lines: usize,
    pub source_formats: Vec<ParsedLineSourceFormat>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricDocument {
    pub metadata: LyricDocumentMetadata,
    pub tracks: Vec<LyricTrack>,
    pub issues: Vec<LyricIssue>,
    pub confidence: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_track_id: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SemanticLine {
    pub start_ms: u32,
    pub end_ms: u32,
    pub main_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main_words: Option<Vec<ParsedWord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translation_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_words: Option<Vec<ParsedWord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secondary_texts: Option<Vec<String>>,
    pub confidence: ClassificationConfidence,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    pub is_bg: bool,
    pub is_duet: bool,
    pub is_duet_partner: bool,
}

#[derive(Serialize, Clone, Debug)]
pub struct LyricWordPayload {
    pub text: String,
    pub start: f64,
    pub end: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub romaji: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricLinePayload {
    pub time: f64,
    pub end_time: f64,
    pub text: String,
    pub translation: String,
    pub romaji: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<Vec<LyricWordPayload>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub romaji_words: Option<Vec<LyricWordPayload>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secondary: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    pub is_bg: bool,
    pub is_duet: bool,
    pub is_duet_partner: bool,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct LyricsMeta {
    pub offset_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub re: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ve: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct StructuredLyricsPayload {
    pub raw_lyrics: String,
    pub meta: LyricsMeta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document: Option<LyricDocument>,
    pub semantic_lines: Vec<SemanticLine>,
    pub display_lines: Vec<LyricLinePayload>,
}

#[derive(Clone, Debug)]
pub(crate) struct TrackAlignmentPair {
    pub(crate) main_index: usize,
    pub(crate) aux_index: usize,
    pub(crate) drift_ms: i64,
    pub(crate) quality: f64,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct TrackAlignment {
    pub(crate) pairs: Vec<TrackAlignmentPair>,
    pub(crate) main_coverage: f64,
    pub(crate) aux_coverage: f64,
    pub(crate) weighted_score: f64,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct TrackRoleScores {
    pub(crate) main: f64,
    pub(crate) translation: f64,
    pub(crate) romanization: f64,
}

#[derive(Clone, Debug)]
pub(crate) struct ParserCandidate {
    pub(crate) source: ParsedLineSourceFormat,
    pub(crate) lines: Vec<ParsedLine>,
}

#[derive(Clone, Debug)]
pub(crate) struct LayoutTemplateResolution {
    pub(crate) display_track_index: usize,
    pub(crate) track_roles: Vec<Option<LyricTrackRole>>,
}

pub(crate) fn clamp01(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

pub(crate) fn average(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

pub(crate) fn track_word_coverage(track: &LyricTrack) -> f64 {
    track
        .lines
        .iter()
        .filter(|line| {
            line.words
                .as_ref()
                .map(|words| !words.is_empty())
                .unwrap_or(false)
        })
        .count() as f64
        / track.lines.len().max(1) as f64
}

pub(crate) fn sanitize_line_text(text: &str) -> String {
    text.replace('\u{200b}', "").trim().to_string()
}

pub(crate) fn sanitize_word_text(text: &str) -> String {
    text.replace(['\u{200b}', '\u{2063}'], "")
}

/// 相邻两词是否处于拉丁文词边界（仅按 ASCII 判断，中文/日文等文本不受影响）。
pub(crate) fn latin_word_gap_needed(left: &str, right: &str) -> bool {
    let Some(last) = left.chars().next_back() else {
        return false;
    };
    let Some(first) = right.chars().next() else {
        return false;
    };
    let left_ok =
        last.is_ascii_alphanumeric() || matches!(last, ',' | '.' | '!' | '?' | '%' | ')');
    let right_ok = first.is_ascii_alphanumeric() || matches!(first, '(');
    left_ok && right_ok
}

/// 拉丁文逐词源缺少单词间隔（词内无空格且间隔词被丢弃）时，
/// 在相邻两词之间补一个空格，避免英语等歌词单词连在一起。
pub(crate) fn insert_latin_word_gaps(words: &mut [ParsedWord]) {
    if words.len() < 2 {
        return;
    }
    for index in 1..words.len() {
        let (left, right) = (&words[index - 1].text, &words[index].text);
        let needs_gap =
            !left.ends_with(' ') && !right.starts_with(' ') && latin_word_gap_needed(left, right);
        if needs_gap {
            words[index - 1].text.push(' ');
        }
    }
}

