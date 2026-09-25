//! Audio format conversion & trimming: pure Rust, no FFmpeg needed.
//!
//! Decode: symphonia (mp3/flac/m4a/aac/ogg/wav/aiff/alac) + ape-decoder (APE) +
//! wavicle (WV/WavPack). All inputs unified to PCM float32 interleaved.
//!
//! Encode:
//! - WAV  : manual header + PCM write
//! - FLAC : flacenc (pure Rust, no C deps)
//! - MP3  : rusty_mp3 (192 kbps)
//!
//! Tags/cover: carried over from the source via lofty (unified TaggedFile IO).
//! Resampling: rubato FftFixedIn when a target sample rate is requested.

use std::fs;
use std::io::{Seek, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Wav,
    Flac,
    Mp3,
}

impl OutputFormat {
    pub fn from_ext(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "wav" => Some(OutputFormat::Wav),
            "flac" => Some(OutputFormat::Flac),
            "mp3" => Some(OutputFormat::Mp3),
            _ => None,
        }
    }
    pub fn ext(self) -> &'static str {
        match self {
            OutputFormat::Wav => "wav",
            OutputFormat::Flac => "flac",
            OutputFormat::Mp3 => "mp3",
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertResult {
    pub input_path: String,
    pub output_path: String,
    pub success: bool,
    pub error: Option<String>,
    pub duration_secs: f64,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertOptions {
    pub target_format: String,
    pub sample_rate: Option<u32>,
    #[serde(default = "default_true")]
    pub keep_cover: bool,
    #[serde(default = "default_true")]
    pub keep_lyrics: bool,
}

fn default_true() -> bool {
    true
}

/// 剪辑参数：按 [startSecs, endSecs) 截取解码后的 PCM 再重编码。
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrimOptions {
    pub target_format: String,
    pub sample_rate: Option<u32>,
    pub start_secs: f64,
    pub end_secs: f64,
    #[serde(default = "default_true")]
    pub keep_cover: bool,
    #[serde(default = "default_true")]
    pub keep_lyrics: bool,
    /// 输出文件名主干（不含扩展名），缺省沿用输入文件名主干。
    #[serde(default)]
    pub out_stem: Option<String>,
}

pub async fn convert_audio(
    input_paths: Vec<String>,
    out_dir: String,
    opts: ConvertOptions,
) -> Vec<ConvertResult> {
    let out_dir = PathBuf::from(&out_dir);
    let mut results = Vec::with_capacity(input_paths.len());

    for input in &input_paths {
        let stem = Path::new(input)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "output".to_string());
        let fmt = match OutputFormat::from_ext(&opts.target_format) {
            Some(f) => f,
            None => {
                results.push(ConvertResult {
                    input_path: input.clone(),
                    output_path: String::new(),
                    success: false,
                    error: Some(format!("unsupported target format: {}", opts.target_format)),
                    duration_secs: 0.0,
                });
                continue;
            }
        };
        if !out_dir.exists() {
            if let Err(e) = fs::create_dir_all(&out_dir) {
                results.push(ConvertResult {
                    input_path: input.clone(),
                    output_path: String::new(),
                    success: false,
                    error: Some(format!("out_dir create failed: {e}")),
                    duration_secs: 0.0,
                });
                continue;
            }
        }
        let out_path = out_dir.join(format!("{}.{}", stem, fmt.ext()));
        let start = std::time::Instant::now();
        let in_clone = PathBuf::from(input);
        let out_clone = out_path.clone();
        let opts_clone = opts.clone();

        let res = tokio::task::spawn_blocking(move || {
            convert_blocking(&in_clone, &out_clone, fmt, &opts_clone)
        })
        .await
        .map_err(|e| format!("task dispatch failed: {e}"));

        let duration = start.elapsed().as_secs_f64();
        push_result(&mut results, input, &out_path, res, duration);
    }
    results
}

fn push_result(
    results: &mut Vec<ConvertResult>,
    input: &str,
    out_path: &Path,
    res: Result<Result<(), String>, String>,
    duration: f64,
) {
    let out_str = out_path.to_string_lossy().to_string();
    match res {
        Ok(Ok(())) => results.push(ConvertResult {
            input_path: input.to_string(),
            output_path: out_str,
            success: true,
            error: None,
            duration_secs: duration,
        }),
        Ok(Err(e)) => results.push(ConvertResult {
            input_path: input.to_string(),
            output_path: out_str,
            success: false,
            error: Some(e),
            duration_secs: duration,
        }),
        Err(e) => results.push(ConvertResult {
            input_path: input.to_string(),
            output_path: String::new(),
            success: false,
            error: Some(e),
            duration_secs: duration,
        }),
    }
}

/// 音频剪辑：解码 → 按 [startSecs, endSecs) 截取 → 可选重采样 → 重编码。
pub async fn trim_audio(input_path: String, out_dir: String, opts: TrimOptions) -> ConvertResult {
    let out_dir = PathBuf::from(&out_dir);
    let fallback_stem = Path::new(&input_path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "output".to_string());
    let stem = opts.out_stem.clone().unwrap_or(fallback_stem);

    let fmt = match OutputFormat::from_ext(&opts.target_format) {
        Some(f) => f,
        None => {
            return ConvertResult {
                input_path: input_path.clone(),
                output_path: String::new(),
                success: false,
                error: Some(format!("unsupported target format: {}", opts.target_format)),
                duration_secs: 0.0,
            };
        }
    };
    if let Err(e) = fs::create_dir_all(&out_dir) {
        return ConvertResult {
            input_path: input_path.clone(),
            output_path: String::new(),
            success: false,
            error: Some(format!("out_dir create failed: {e}")),
            duration_secs: 0.0,
        };
    }

    let out_path = out_dir.join(format!("{}.{}", stem, fmt.ext()));
    let start = std::time::Instant::now();
    let in_clone = PathBuf::from(&input_path);
    let out_clone = out_path.clone();

    let res = tokio::task::spawn_blocking(move || trim_blocking(&in_clone, &out_clone, fmt, &opts))
        .await
        .map_err(|e| format!("task dispatch failed: {e}"));

    let duration = start.elapsed().as_secs_f64();
    let mut results = Vec::with_capacity(1);
    push_result(&mut results, &input_path, &out_path, res, duration);
    results.remove(0)
}

/// 探测音频时长（秒）。容器/头信息可估算时直接返回，否则完整解码统计（APE/WV/OGG 等）。
pub async fn audio_probe_duration(path: String) -> Result<f64, String> {
    tokio::task::spawn_blocking(move || probe_duration_blocking(PathBuf::from(&path)))
        .await
        .map_err(|e| format!("task dispatch failed: {e}"))?
}

fn probe_duration_blocking(src: PathBuf) -> Result<f64, String> {
    if let Some(dur) = probe_symphonia_duration(&src) {
        if dur > 0.0 {
            return Ok(dur);
        }
    }
    let (sr, ch, pcm) = match classify_input(&extension_of(&src)) {
        InputClass::Symphonia => decode_via_symphonia(&src)?,
        InputClass::Ape => decode_ape_pcm(&src)?,
        InputClass::Wv => decode_wv_pcm(&src)?,
        InputClass::Unsupported => return Err(format!("unsupported input format: {}", extension_of(&src))),
    };
    let frames = pcm.len() / ch.max(1) as usize;
    if sr == 0 {
        return Err("invalid sample rate".into());
    }
    Ok(frames as f64 / sr as f64)
}

fn probe_symphonia_duration(src: &Path) -> Option<f64> {
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let file = fs::File::open(src).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = src.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .ok()?;
    let track = probed.format.tracks().first()?;
    let sr = track.codec_params.sample_rate.filter(|r| *r > 0)?;
    let frames = track.codec_params.n_frames?;
    Some(frames as f64 / sr as f64)
}

fn extension_of(src: &Path) -> String {
    src.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default()
}

fn convert_blocking(src: &Path, out: &Path, fmt: OutputFormat, opts: &ConvertOptions) -> Result<(), String> {
    if !src.is_file() {
        return Err(format!("input not found: {}", src.display()));
    }
    let (sr, ch, pcm) = decode_input(src)?;
    render_output(src, out, fmt, sr, ch, pcm, opts.sample_rate, opts.keep_cover, opts.keep_lyrics)
}

fn trim_blocking(src: &Path, out: &Path, fmt: OutputFormat, opts: &TrimOptions) -> Result<(), String> {
    if !src.is_file() {
        return Err(format!("input not found: {}", src.display()));
    }
    let (sr, ch, pcm) = decode_input(src)?;
    let nch = ch.max(1) as usize;
    let frames = pcm.len() / nch;
    if frames == 0 {
        return Err("音频解码结果为空".into());
    }
    let begin = ((opts.start_secs * sr as f64).round() as i64).clamp(0, frames as i64) as usize;
    let end = ((opts.end_secs * sr as f64).round() as i64).clamp(begin as i64, frames as i64) as usize;
    if end <= begin {
        return Err(format!(
            "选区为空：{:.3}s ~ {:.3}s",
            opts.start_secs, opts.end_secs
        ));
    }
    let sliced = pcm[begin * nch..end * nch].to_vec();
    render_output(src, out, fmt, sr, ch, sliced, opts.sample_rate, opts.keep_cover, opts.keep_lyrics)
}

/// 解码 + 可选重采样 + 编码 + 标签迁移的公共尾部。
#[allow(clippy::too_many_arguments)]
fn render_output(
    src: &Path,
    out: &Path,
    fmt: OutputFormat,
    mut sr: u32,
    ch: u16,
    mut pcm: Vec<f32>,
    want_sr: Option<u32>,
    keep_cover: bool,
    keep_lyrics: bool,
) -> Result<(), String> {
    let meta = read_source_meta(src);
    let mut target_sr = want_sr.unwrap_or(sr);
    // MP3（MPEG-1 Layer III）仅支持 ≤48kHz 的采样率，超限时钳制到 48kHz
    if fmt == OutputFormat::Mp3 && target_sr > 48000 {
        target_sr = 48000;
    }
    if target_sr != sr {
        pcm = resample_f32(&pcm, ch, sr, target_sr)?;
        sr = target_sr;
    }

    fs::create_dir_all(out.parent().ok_or("out_dir missing")?)
        .map_err(|e| e.to_string())?;
    let tmp = out.with_extension("part");
    let res = match fmt {
        OutputFormat::Wav => encode_wav_f32(&tmp, sr, ch, &pcm),
        OutputFormat::Flac => encode_flac_f32(&tmp, sr, ch, &pcm),
        OutputFormat::Mp3 => encode_mp3_f32(&tmp, sr, ch, &pcm),
    };
    match res {
        Ok(()) => fs::rename(&tmp, out).map_err(|e| e.to_string()),
        Err(e) => { let _ = fs::remove_file(&tmp); Err(e) }
    }?;

    // 标签/封面迁移为尽力而为：失败不影响已生成的音频文件
    if let Some(meta) = &meta {
        let _ = write_output_tags(out, meta, keep_cover, keep_lyrics);
    }
    Ok(())
}

fn decode_input(src: &Path) -> Result<(u32, u16, Vec<f32>), String> {
    match classify_input(&extension_of(src)) {
        InputClass::Symphonia => decode_via_symphonia(src),
        InputClass::Ape => decode_ape_pcm(src),
        InputClass::Wv => decode_wv_pcm(src),
        InputClass::Unsupported => Err(format!("unsupported input format: {}", extension_of(src))),
    }
}

enum InputClass { Symphonia, Ape, Wv, Unsupported }

// ===== 标签/封面迁移（lofty，统一 TaggedFile IO） =====

#[derive(Default)]
struct SourceMeta {
    /// 源标签里的全部文本项（ItemKey, value），写输出时按 key 重建。
    text_items: Vec<(lofty::tag::ItemKey, String)>,
    /// (mime, data)。
    pictures: Vec<(Option<lofty::picture::MimeType>, Vec<u8>)>,
}

fn read_source_meta(src: &Path) -> Option<SourceMeta> {
    use lofty::file::TaggedFileExt;
    use lofty::tag::ItemValue;

    let tagged = lofty::probe::Probe::open(src).ok()?.read().ok()?;
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag())?;

    let mut meta = SourceMeta::default();
    for item in tag.items() {
        if let ItemValue::Text(s) = item.value() {
            meta.text_items.push((item.key().clone(), s.clone()));
        }
    }
    meta.pictures = tag
        .pictures()
        .iter()
        .map(|p| (p.mime_type().cloned(), p.data().to_vec()))
        .collect();
    if meta.text_items.is_empty() && meta.pictures.is_empty() {
        return None;
    }
    Some(meta)
}

fn write_output_tags(
    out: &Path,
    meta: &SourceMeta,
    keep_cover: bool,
    keep_lyrics: bool,
) -> Result<(), String> {
    use lofty::config::WriteOptions;
    use lofty::file::{AudioFile, TaggedFileExt};
    use lofty::picture::{Picture, PictureType};
    use lofty::tag::{ItemKey, Tag};

    if (!keep_lyrics || meta.text_items.is_empty())
        && (!keep_cover || meta.pictures.is_empty())
    {
        return Ok(());
    }

    let mut tagged = lofty::probe::Probe::open(out)
        .map_err(|e| format!("tag probe: {e}"))?
        .read()
        .map_err(|e| format!("tag read: {e}"))?;
    let tag_type = tagged.primary_tag_type();
    if tagged.tag_mut(tag_type).is_none() {
        tagged.insert_tag(Tag::new(tag_type));
    }
    let tag = tagged
        .tag_mut(tag_type)
        .ok_or_else(|| "当前输出格式不支持写入标签".to_string())?;

    if keep_lyrics {
        for (key, value) in &meta.text_items {
            // Unknown key（私有帧/无法映射的帧）跳过，避免写入失败
            if matches!(key, ItemKey::Unknown(_)) {
                continue;
            }
            let _ = tag.insert_text(key.clone(), value.clone());
        }
    }
    if keep_cover {
        for (mime, data) in &meta.pictures {
            tag.push_picture(Picture::new_unchecked(
                PictureType::CoverFront,
                mime.clone(),
                None,
                data.clone(),
            ));
        }
    }

    tagged
        .save_to_path(out, WriteOptions::default())
        .map_err(|e| format!("tag save: {e}"))
}

// ===== 重采样（rubato FftFixedIn） =====

/// f32 交错 PCM 重采样。FFT 同步重采样：整块喂入，尾部补零冲刷，
/// 去掉前端 output_delay 帧的群延迟后按期望帧数截断。
fn resample_f32(pcm: &[f32], ch: u16, sr_in: u32, sr_out: u32) -> Result<Vec<f32>, String> {
    use rubato::{FftFixedIn, Resampler};

    if sr_in == sr_out || pcm.is_empty() || ch == 0 {
        return Ok(pcm.to_vec());
    }
    let nch = ch as usize;
    let frames = pcm.len() / nch;

    // 交错 → 分声道
    let mut chan: Vec<Vec<f32>> = vec![Vec::with_capacity(frames); nch];
    for f in 0..frames {
        for c in 0..nch {
            chan[c].push(pcm[f * nch + c]);
        }
    }

    let mut rs = FftFixedIn::<f32>::new(sr_in as usize, sr_out as usize, 4096, 2, nch)
        .map_err(|e| format!("重采样器初始化失败: {e}"))?;
    let in_need = rs.input_frames_next();
    let mut out_buf = rs.output_buffer_allocate(true);
    let delay = rs.output_delay();

    let expected = ((frames as u64 * sr_out as u64) + sr_in as u64 / 2) / sr_in as u64;
    let expected = expected as usize;
    let mut out_all: Vec<f32> = Vec::with_capacity((expected + delay + 64) * nch);

    // 输入喂完后继续补零块，直到冲刷出预期帧数（或连续静默兜底退出）
    let mut sent: usize = 0;
    let mut produced: usize = 0;
    let mut silent_flush = 0usize;
    loop {
        let take_end = (sent + in_need).min(frames);
        let mut input: Vec<Vec<f32>> = Vec::with_capacity(nch);
        for c in 0..nch {
            let mut seg = Vec::with_capacity(in_need);
            if sent < frames {
                let lo = sent.min(frames);
                seg.extend_from_slice(&chan[c][lo..take_end]);
            }
            seg.resize(in_need, 0.0);
            input.push(seg);
        }
        let (_, out_gen) = rs
            .process_into_buffer(&input, &mut out_buf, None)
            .map_err(|e| format!("重采样失败: {e}"))?;
        for f in 0..out_gen {
            for c in 0..nch {
                out_all.push(out_buf[c][f]);
            }
        }
        produced += out_gen;
        sent += in_need;
        if produced >= expected + delay {
            break;
        }
        if sent >= frames {
            silent_flush += if out_gen == 0 { 1 } else { 0 };
            if silent_flush >= 2 || sent >= frames + in_need * 8 {
                break;
            }
        }
    }

    // 去掉前端群延迟，截断到期望帧数
    let drop = (delay * nch).min(out_all.len());
    out_all.drain(0..drop);
    let keep_frames = (expected as usize).min(out_all.len() / nch);
    out_all.truncate(keep_frames * nch);
    Ok(out_all)
}

fn classify_input(ext: &str) -> InputClass {
    match ext {
        "mp3"|"flac"|"m4a"|"aac"|"ogg"|"wav"|"aif"|"aiff"|"alac" => InputClass::Symphonia,
        "ape" => InputClass::Ape,
        "wv" => InputClass::Wv,
        _ => InputClass::Unsupported,
    }
}

fn decode_via_symphonia(src: &Path) -> Result<(u32, u16, Vec<f32>), String> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let file = fs::File::open(src).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = src.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("probe fail: {e}"))?;

    let track = probed.format.tracks().iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or("no audio track")?;
    let track_id = track.id;
    let sr = track.codec_params.sample_rate.filter(|r| *r > 0).ok_or("invalid sr")?;
    let ch = track.codec_params.channels.map(|c| c.count()).filter(|c| *c > 0)
        .ok_or("invalid channels")? as u16;

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("decoder fail: {e}"))?;
    let mut format = probed.format;

    let mut sb: Option<SampleBuffer<f32>> = None;
    let mut sb_frames = 0;
    let mut all: Vec<f32> = Vec::new();

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::ResetRequired) => { decoder.reset(); continue; }
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(format!("decode fail: {e}")),
        };
        if packet.track_id() != track_id { continue; }
        let dec = match decoder.decode(&packet) { Ok(d) => d, Err(_) => continue };
        let frames = dec.frames();
        if frames == 0 { continue; }
        if sb_frames < frames {
            sb = Some(SampleBuffer::<f32>::new(frames as u64, *dec.spec()));
            sb_frames = frames;
        }
        let buf = sb.as_mut().ok_or("sb init fail")?;
        buf.copy_interleaved_ref(dec);
        all.extend_from_slice(buf.samples());
    }
    Ok((sr, ch, all))
}

fn decode_ape_pcm(src: &Path) -> Result<(u32, u16, Vec<f32>), String> {
    let mut file = fs::File::open(src).map_err(|e| e.to_string())?;
    let start = file.stream_position().map_err(|e| e.to_string())?;
    let parsed = ape_decoder::format::parse(&mut file).map_err(|e| e.to_string())?;
    file.seek(std::io::SeekFrom::Start(start)).map_err(|e| e.to_string())?;
    let ch = parsed.header.channels as u16;
    let sr = parsed.header.sample_rate;
    let bits = parsed.header.bits_per_sample;
    if sr == 0 || ch == 0 || bits == 0 { return Err("APE header invalid".into()); }
    let mut decoder = ape_decoder::ApeDecoder::new(file).map_err(|e| e.to_string())?;
    let info = decoder.info();
    let mut all: Vec<f32> = Vec::new();
    for frame in 0..info.total_frames {
        let pcm = decoder.decode_frame(frame)
            .map_err(|e| format!("APE frame {frame}: {e}"))?;
        if bits == 16 {
            for chunk in pcm.chunks_exact(2) {
                let v = i16::from_le_bytes([chunk[0], chunk[1]]);
                all.push(v as f32 / 32768.0);
            }
        } else if bits == 24 {
            for chunk in pcm.chunks_exact(3) {
                let mut b = [0u8; 4]; b[..3].copy_from_slice(chunk);
                let v = i32::from_le_bytes(b) >> 8;
                all.push(v as f32 / 8388608.0);
            }
        } else if bits == 32 {
            for chunk in pcm.chunks_exact(4) {
                let v = i32::from_le_bytes([chunk[0],chunk[1],chunk[2],chunk[3]]);
                all.push(v as f32 / 2147483648.0);
            }
        } else { return Err(format!("unsupported APE bits: {bits}")); }
    }
    Ok((sr, ch, all))
}

fn decode_wv_pcm(src: &Path) -> Result<(u32, u16, Vec<f32>), String> {
    let bytes = fs::read(src).map_err(|e| e.to_string())?;
    let decoded = wavicle::decode_stream(&bytes).map_err(|e| format!("WV fail: {e}"))?;
    let ch = decoded.channels.max(1) as u16;
    let sr = decoded.sample_rate;
    if sr == 0 || decoded.samples.is_empty() { return Err("WV invalid".into()); }
    let mut all: Vec<f32> = Vec::with_capacity(decoded.samples.len());
    if decoded.is_float {
        for v in &decoded.samples {
            all.push(f32::from_le_bytes(v.to_le_bytes()));
        }
    } else {
        let bits = decoded.bits_per_sample;
        let div = match bits {
            16 => 32768.0, 24 => 8388608.0, 32 => 2147483648.0,
            _ => return Err(format!("unsupported WV bits: {bits}")),
        };
        for v in &decoded.samples { all.push(*v as f32 / div); }
    }
    Ok((sr, ch, all))
}

fn encode_wav_f32(out: &Path, sr: u32, ch: u16, f32: &[f32]) -> Result<(), String> {
    fs::create_dir_all(out.parent().ok_or("out_dir missing")?)
        .map_err(|e| e.to_string())?;
    let mut file = fs::File::create(out).map_err(|e| e.to_string())?;
    let bits = 16u16;
    let block_align = ch as u32 * (bits as u32 / 8);
    let byte_rate = sr * block_align;
    let n_frames = (f32.len() as u64 / ch as u64).min(u32::MAX as u64);
    let data_len = n_frames.saturating_mul(block_align as u64)
        .min(u32::MAX as u64 - 64) as u32;
    file.write_all(b"RIFF").map_err(|e| e.to_string())?;
    file.write_all(&data_len.saturating_add(36).to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(b"WAVE").map_err(|e| e.to_string())?;
    file.write_all(b"fmt ").map_err(|e| e.to_string())?;
    file.write_all(&16u32.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&1u16.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&ch.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&sr.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&byte_rate.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&block_align.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&bits.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(b"data").map_err(|e| e.to_string())?;
    file.write_all(&data_len.to_le_bytes()).map_err(|e| e.to_string())?;
    let clamped: Vec<i16> = f32.iter().map(|&s| {
        (s * 32767.0).clamp(-32768.0, 32767.0).round() as i16
    }).collect();
    let bytes: Vec<u8> = clamped.iter().flat_map(|v| v.to_le_bytes()).collect();
    file.write_all(&bytes).map_err(|e| e.to_string())?;
    file.flush().map_err(|e| e.to_string())?;
    Ok(())
}

fn encode_flac_f32(out: &Path, sr: u32, ch: u16, f32: &[f32]) -> Result<(), String> {
    fs::create_dir_all(out.parent().ok_or("out_dir missing")?)
        .map_err(|e| e.to_string())?;
    // f32 -> i16
    let pcm: Vec<i32> = f32.iter().map(|&s| {
        (s * 32767.0).clamp(-32768.0, 32767.0).round() as i32
    }).collect();
    use flacenc::component::BitRepr;
    use flacenc::error::Verify;
    let source = flacenc::source::MemSource::from_samples(&pcm, ch as usize, 16, sr as usize);
    let config = flacenc::config::Encoder::default();
    let verified = config.into_verified()
        .map_err(|(_, e)| format!("config verify: {e:?}"))?;
    let stream = flacenc::encode_with_fixed_block_size(
        &verified, source, 4096,
    ).map_err(|e| format!("FLAC encode: {e}"))?;
    let mut file = fs::File::create(out).map_err(|e| e.to_string())?;
    let mut sink = flacenc::bitsink::MemSink::<u8>::with_capacity(8192);
    stream.write(&mut sink).map_err(|e| format!("FLAC encode: {e}"))?;
    file.write_all(sink.as_slice()).map_err(|e| format!("FLAC write: {e}"))?;
    Ok(())
}

fn encode_mp3_f32(out: &Path, sr: u32, ch: u16, f32: &[f32]) -> Result<(), String> {
    fs::create_dir_all(out.parent().ok_or("out_dir missing")?)
        .map_err(|e| e.to_string())?;
    use rusty_mp3::{Error, Mp3Encoder, Mp3EncoderConfig};

    let mut enc = Mp3Encoder::new(Mp3EncoderConfig {
        bitrate_kbps: 192,
        vbr_quality: None,
    });
    enc.push_pcm_f32(f32, ch, sr)
        .map_err(|e| format!("MP3 push PCM: {e:?}"))?;
    enc.finish();

    let mut all_bytes: Vec<u8> = Vec::new();
    loop {
        match enc.next_packet() {
            Ok(pkt) => all_bytes.extend_from_slice(&pkt),
            Err(Error::Eof) => break,
            Err(Error::Again) => break,
            Err(e) => return Err(format!("MP3 encode: {e:?}")),
        }
    }

    fs::write(out, &all_bytes).map_err(|e| e.to_string())?;
    Ok(())
}