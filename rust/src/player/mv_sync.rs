//! MV 音频频谱对齐（对齐桌面端 `mvAutoSync.ts` 的能量包络互相关算法）。
//!
//! 原理：MV 音轨与歌曲音频同源（同一首曲子），即便 MV 时长与歌曲不一致，
//! 两者的能量包络（RMS）波形形状在对应片段上是一致的。把两边解码为
//! 8kHz 单声道 → 计算滑动 RMS 包络 → z-score 归一化 → 在 ±MAX_LAG_SEC
//! 范围内做 Pearson 互相关，峰值处的 lag 即时间偏移。
//!
//! 语义：lag > 0 表示 `mv[t + lag] ↔ song[t]`，即 `videoPos = audioPos + offset`。

use std::path::Path;

/// 分析用采样率（与桌面端一致，8kHz 足够表达能量包络）。
const ANALYSIS_SAMPLE_RATE: u32 = 8000;
/// 包络滑动步长（帧）。
const ENVELOPE_HOP: usize = 512;
/// 包络窗口长度（帧），一帧约 128ms。
const ENVELOPE_WINDOW: usize = 1024;
/// 允许的最大滞后秒数。
const MAX_LAG_SEC: f64 = 15.0;
/// 最多分析前 110 秒（省时省内存，开头对齐已足够）。
const MAX_ANALYSIS_SEC: f64 = 110.0;
/// 全局互相关置信度阈值（低于此值视为不可信，回退 offset=0）。
const MIN_CONFIDENCE: f64 = 0.2;
/// 相关峰值两侧至少需要的重叠帧数（避免边缘伪峰）。
const MIN_OVERLAP_FRAMES: usize = 16;

// ---------- 局部滑动匹配（开机即刻对齐，容忍 MV 片头/花絮） ----------
/// 局部匹配时 MV 解码上限秒数（放宽到能覆盖绝大多数歌曲 MV，
/// 供在整个 MV 时间轴上滑窗找歌曲窗）。原生采样率下这段 mono buffer 较大
/// （约 48kHz×420s×4B≈80MB，短暂峰值，后台执行后即释放）。
const LOCAL_MV_MAX_SEC: f64 = 420.0;
/// 局部匹配滑窗互相关的置信度阈值（比全局更苛刻：局部窗更短更容易出现高相关）。
const LOCAL_MIN_CONFIDENCE: f64 = 0.5;
/// 局部匹配允许的最小重叠帧数（避免卷到 MV 尾部不足一窗）。
const LOCAL_MIN_OVERLAP_FRAMES: usize = 48;
/// 时间轴模糊匹配的半带宽下限（秒）。相对带（0.25×MV 时长）在短 MV 上可能
/// 不足以容纳片头/花絮偏移，此下限保证歌首至少能匹配到 MV 前 60s。
const LOCAL_BAND_MIN_SEC: f64 = 60.0;

/// 局部滑动匹配：取歌曲音频在 [song_pos_sec, song_pos_sec+window_sec] 的短窗，
/// 在整个 MV 音轨上滑窗做能量包络互相关，返回 `(lag_sec, confidence)`。
///
/// `lag_sec = mv_pos - song_pos`，即 `videoPos = audioPos + lag`（沿用全局语义）。
/// 由于只匹配「当前位置附近的一小段」，MV 即便有片头 / 花絮等与歌曲不一致的
/// 内容，只要这段歌在 MV 里出现过一次，就能对准，不会像全局互相关那样被
/// 整段不匹配的开头拖累而给出错误偏移。
/// 全局频谱对齐：分析 MV 音频与歌曲音频的频谱偏移。
/// 成功返回 `(offset_sec, confidence)`；失败返回错误说明（调用方回退 offset=0）。
pub fn analyze(mv_path: &Path, song_path: &Path) -> Result<(f64, f64), String> {
    let (mv_rate, mv_samples) = decode_mono_native(mv_path)?;
    let (song_rate, song_samples) = decode_mono_native(song_path)?;

    let mv8 = resample_linear(&mv_samples, mv_rate, ANALYSIS_SAMPLE_RATE);
    let song8 = resample_linear(&song_samples, song_rate, ANALYSIS_SAMPLE_RATE);
    drop(mv_samples);
    drop(song_samples);

    let mv_env = compute_envelope(&mv8);
    let song_env = compute_envelope(&song8);
    drop(mv8);
    drop(song8);

    estimate_envelope_lag(&mv_env, &song_env).ok_or_else(|| "包络过短，无法互相关".to_string())
}

pub fn analyze_local(
    mv_path: &Path,
    song_path: &Path,
    song_pos_sec: f64,
    window_sec: f64,
    song_dur_sec: f64,
) -> Result<(f64, f64), String> {
    if !song_pos_sec.is_finite() || song_pos_sec < 0.0 || window_sec <= 0.0 {
        return Err("无效的歌曲位置或窗口长度".to_string());
    }

    let (mv_rate, mv_samples) = decode_mono_native_cap(mv_path, LOCAL_MV_MAX_SEC)?;
    let (song_rate, song_samples) = decode_mono_native_cap(
        song_path,
        song_pos_sec + window_sec + 5.0,
    )?;

    let mv8 = resample_linear(&mv_samples, mv_rate, ANALYSIS_SAMPLE_RATE);
    let song8 = resample_linear(&song_samples, song_rate, ANALYSIS_SAMPLE_RATE);
    drop(mv_samples);
    drop(song_samples);

    let mv_env = compute_envelope(&mv8);
    let song_env = compute_envelope(&song8);
    drop(mv8);
    drop(song8);

    let hop_sec = ENVELOPE_HOP as f64 / ANALYSIS_SAMPLE_RATE as f64;
    let win_frames = ((window_sec / hop_sec).round() as usize).max(LOCAL_MIN_OVERLAP_FRAMES);
    if win_frames >= song_env.len() {
        return Err("歌曲音频过短，无法取窗".to_string());
    }
    // 歌曲窗起点对齐到采样帧；位置越过可用音频时往回调，保证能取出整窗。
    let song_start_frame = (song_pos_sec / hop_sec).round().max(0.0) as usize;
    let song_start = song_start_frame.min(song_env.len() - win_frames);
    let song_window = &song_env[song_start..song_start + win_frames];

    // —— 时间轴模糊匹配（前/中/后对应带）——
    // 全轴滑窗的根因缺陷：相似段落（副歌）在时间轴上可以任意远，歌曲开头会
    // 误配到 MV 尾部高潮。约束锚点只能落在「歌曲相对位置 ↔ MV 相对位置」
    // 附近的模糊带内：带心 = f×MV 时长（f = 歌曲位置/歌曲时长），半带宽取
    // max(0.25×MV 时长, 60s)——前中后三段粗对应，同时足以容纳 MV 片头/
    // 片尾造成的刻度偏移。歌曲时长未知（≤0）时退化为全轴搜索。
    let mv_last_start = mv_env.len().saturating_sub(win_frames);
    let (search_lo, search_hi) = if song_dur_sec.is_finite() && song_dur_sec > 0.0 {
        let f = (song_pos_sec / song_dur_sec).clamp(0.0, 1.0);
        let mv_total_sec = mv_env.len() as f64 * hop_sec;
        let half_band = (mv_total_sec * 0.25).max(LOCAL_BAND_MIN_SEC);
        let center = f * mv_total_sec;
        let lo = ((center - half_band) / hop_sec).floor().max(0.0) as usize;
        let hi = (((center + half_band) / hop_sec).ceil() as usize).min(mv_last_start);
        if hi >= lo { (lo, hi) } else { (0, mv_last_start) }
    } else {
        (0, mv_last_start)
    };

    let mv_start = sliding_window_align(&mv_env, song_window, search_lo, search_hi)
        .ok_or("MV 过短，无法滑窗匹配")?;

    let mv_pos_sec = mv_start as f64 * hop_sec;
    let song_pos_sec_actual = song_start as f64 * hop_sec;
    let lag = mv_pos_sec - song_pos_sec_actual;
    Ok((lag, mv_start_confidence(&mv_env, song_window, mv_start)))
}

/// 滑窗互相关：把 [song_win] 当作模板，在 [mv_env] 的 `[lo, hi]` 帧范围内按下标
/// 滑窗求 Pearson 相关，返回最佳 MV 起始帧。窗内各自 z-score 归一化（对齐全局
/// 算法的归一化口径）。步进用 1 帧（≈64ms），对开局对齐精度足够。
fn sliding_window_align(
    mv_env: &[f32],
    song_win: &[f32],
    lo: usize,
    hi: usize,
) -> Option<usize> {
    let w = song_win.len();
    if mv_env.len() < w || lo > hi || hi + w > mv_env.len() {
        return None;
    }
    let song_z = z_normalize(song_win);
    if song_z.iter().all(|v| *v == 0.0) {
        return None;
    }
    let mut best = lo;
    let mut best_score = f64::NEG_INFINITY;
    for start in lo..=hi {
        let slice = &mv_env[start..start + w];
        let slice_z = z_normalize(slice);
        let mut dot = 0.0_f64;
        for i in 0..w {
            dot += song_z[i] * slice_z[i];
        }
        // 两边都已 z 归一化，相关系数 = 点积 / n
        let score = dot / w as f64;
        if score.is_finite() && score > best_score {
            best_score = score;
            best = start;
        }
    }
    Some(best)
}

/// 计算最佳 MV 起始帧处的局部置信度（Pearson 相关系数）。供外部判断是否可信。
fn mv_start_confidence(mv_env: &[f32], song_win: &[f32], mv_start: usize) -> f64 {
    let w = song_win.len();
    if mv_start + w > mv_env.len() {
        return 0.0;
    }
    let song_z = z_normalize(song_win);
    let slice_z = z_normalize(&mv_env[mv_start..mv_start + w]);
    let dot: f64 = song_z
        .iter()
        .zip(slice_z.iter())
        .map(|(a, b)| a * b)
        .sum();
    (dot / w as f64).clamp(-1.0, 1.0)
}

/// 局部匹配是否可信：置信度达标即可，不限制偏移大小——
/// 针对「MV 加了片头」的偏移可能远超全局的 15s 上限，但只要相关足够高就成立。
pub fn is_local_trustworthy(_lag_sec: f64, confidence: f64) -> bool {
    confidence.is_finite() && confidence >= LOCAL_MIN_CONFIDENCE
}

/// 置信度与偏移是否可信（对齐桌面端 isTrustworthyEstimate）。
pub fn is_trustworthy(offset_sec: f64, confidence: f64) -> bool {
    offset_sec.is_finite()
        && confidence >= MIN_CONFIDENCE
        && offset_sec.abs() < MAX_LAG_SEC - 0.5
}

/// 解码音频文件为单声道 f32 采样（原生采样率），超过默认分析时长 + 1s 提前停止。
fn decode_mono_native(path: &Path) -> Result<(u32, Vec<f32>), String> {
    decode_mono_native_cap(path, MAX_ANALYSIS_SEC)
}

/// 解码音频文件为单声道 f32 采样（原生采样率），超过 `max_sec` 提前停止。
/// 局部匹配用更大的上限让 MV 解到整曲，供在整个时间轴上滑窗。
fn decode_mono_native_cap(
    path: &Path,
    max_sec: f64,
) -> Result<(u32, Vec<f32>), String> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let file = std::fs::File::open(path)
        .map_err(|e| format!("打开失败 {}: {e}", path.display()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("probe fail: {e}"))?;

    // 只挑音频轨：视频轨（h264 等）没有 sample_rate，用它过滤 MP4 里的视频流。
    let track = probed
        .format
        .tracks()
        .iter()
        .find(|t| {
            t.codec_params.codec != CODEC_TYPE_NULL
                && t.codec_params.sample_rate.unwrap_or(0) > 0
        })
        .ok_or("no audio track")?;
    let track_id = track.id;
    let sr = track
        .codec_params
        .sample_rate
        .filter(|r| *r > 0)
        .ok_or("invalid sample rate")?;
    let channels = track
        .codec_params
        .channels
        .map(|c| c.count())
        .filter(|c| *c > 0)
        .unwrap_or(1);
    let max_native = ((max_sec + 1.0) * sr as f64) as usize;

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("decoder fail: {e}"))?;
    let mut format = probed.format;

    let mut sb: Option<SampleBuffer<f32>> = None;
    let mut sb_frames = 0_usize;
    let mut mono: Vec<f32> = Vec::new();

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::ResetRequired) => {
                let _ = decoder.reset();
                continue;
            }
            // 截断/损坏文件的结尾按 EOF 处理，拿到多少用多少。
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(symphonia::core::errors::Error::DecodeError(_)) => break,
            Err(e) => {
                if mono.is_empty() {
                    return Err(format!("decode fail: {e}"));
                }
                break;
            }
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(_) => continue,
        };
        let frames = decoded.frames();
        if frames == 0 {
            continue;
        }
        if sb_frames < frames {
            sb = Some(SampleBuffer::<f32>::new(frames as u64, *decoded.spec()));
            sb_frames = frames;
        }
        let buf = match sb.as_mut() {
            Some(b) => b,
            None => return Err("sample buffer init fail".to_string()),
        };
        buf.copy_interleaved_ref(decoded);
        let samples = buf.samples();
        if channels == 1 {
            mono.extend_from_slice(samples);
        } else {
            for chunk in samples.chunks(channels) {
                let sum: f32 = chunk.iter().sum();
                mono.push(sum / channels as f32);
            }
        }
        if mono.len() >= max_native {
            break;
        }
    }

    if mono.is_empty() {
        return Err("no audio samples decoded".to_string());
    }
    Ok((sr, mono))
}

/// 线性插值重采样（包络用途对精度要求不高，够用）。
fn resample_linear(samples: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if samples.is_empty() || from_rate == to_rate {
        return samples.to_vec();
    }
    let ratio = from_rate as f64 / to_rate as f64;
    let out_len = ((samples.len() as f64) / ratio).floor() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let pos = i as f64 * ratio;
        let idx = pos as usize;
        let frac = (pos - idx as f64) as f32;
        let a = samples[idx];
        let b = if idx + 1 < samples.len() { samples[idx + 1] } else { a };
        out.push(a + (b - a) * frac);
    }
    out
}

/// 滑动 RMS 能量包络（对齐桌面端 computeEnvelope）。
fn compute_envelope(samples: &[f32]) -> Vec<f32> {
    if samples.len() < ENVELOPE_WINDOW {
        return Vec::new();
    }
    let frame_count = (samples.len() - ENVELOPE_WINDOW) / ENVELOPE_HOP + 1;
    let mut envelope = Vec::with_capacity(frame_count);
    for frame in 0..frame_count {
        let start = frame * ENVELOPE_HOP;
        let mut sum = 0.0_f32;
        for v in &samples[start..start + ENVELOPE_WINDOW] {
            sum += v * v;
        }
        envelope.push((sum / ENVELOPE_WINDOW as f32).sqrt());
    }
    envelope
}

/// z-score 归一化（对齐桌面端 zNormalize）。
fn z_normalize(envelope: &[f32]) -> Vec<f64> {
    let n = envelope.len();
    let mut out = vec![0.0_f64; n];
    if n == 0 {
        return out;
    }
    let mean = envelope.iter().map(|v| *v as f64).sum::<f64>() / n as f64;
    let variance = envelope
        .iter()
        .map(|v| {
            let d = *v as f64 - mean;
            d * d
        })
        .sum::<f64>()
        / n as f64;
    let std = variance.sqrt();
    if std < 1e-9 {
        return out;
    }
    for (i, v) in envelope.iter().enumerate() {
        out[i] = (*v as f64 - mean) / std;
    }
    out
}

/// 包络互相关估计 lag（对齐桌面端 estimateEnvelopeLag）。
/// 返回 `(offset_sec, confidence)`。
fn estimate_envelope_lag(mv_env: &[f32], song_env: &[f32]) -> Option<(f64, f64)> {
    if mv_env.len() < 4 || song_env.len() < 4 {
        return None;
    }

    let hop_sec = ENVELOPE_HOP as f64 / ANALYSIS_SAMPLE_RATE as f64;
    let max_lag = (MAX_LAG_SEC / hop_sec).floor() as i64;
    let max_frames = (MAX_ANALYSIS_SEC / hop_sec).floor() as usize;
    let mv = z_normalize(&mv_env[..mv_env.len().min(max_frames)]);
    let song = z_normalize(&song_env[..song_env.len().min(max_frames)]);

    let n_scores = (2 * max_lag + 1) as usize;
    let mut scores = vec![f64::NEG_INFINITY; n_scores];
    let mut best_lag: i64 = 0;
    let mut best_score = f64::NEG_INFINITY;

    for lag in -max_lag..=max_lag {
        let mv_start = lag.max(0) as usize;
        let song_start = (-lag).max(0) as usize;
        if mv_start >= mv.len() || song_start >= song.len() {
            continue;
        }
        let overlap = (mv.len() - mv_start).min(song.len() - song_start);
        if overlap < MIN_OVERLAP_FRAMES {
            continue;
        }
        let mut dot = 0.0_f64;
        let mut mv_norm = 0.0_f64;
        let mut song_norm = 0.0_f64;
        for i in 0..overlap {
            let a = mv[mv_start + i];
            let b = song[song_start + i];
            dot += a * b;
            mv_norm += a * a;
            song_norm += b * b;
        }
        let denom = (mv_norm * song_norm).sqrt();
        let score = if denom > 1e-9 { dot / denom } else { f64::NEG_INFINITY };
        scores[(lag + max_lag) as usize] = score;
        if score > best_score {
            best_score = score;
            best_lag = lag;
        }
    }

    if !best_score.is_finite() {
        return None;
    }

    // 抛物线细化，把 lag 精度从 1 帧提升到亚帧级。
    let mut refined = best_lag as f64;
    let idx = (best_lag + max_lag) as usize;
    let left = if idx > 0 { scores[idx - 1] } else { f64::NEG_INFINITY };
    let right = if idx + 1 < n_scores {
        scores[idx + 1]
    } else {
        f64::NEG_INFINITY
    };
    if left.is_finite() && right.is_finite() {
        let denom = left - 2.0 * best_score + right;
        if denom.abs() > 1e-9 {
            let delta = 0.5 * (left - right) / denom;
            if delta.abs() <= 1.0 {
                refined = best_lag as f64 + delta;
            }
        }
    }

    Some((refined * hop_sec, best_score))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trust_boundary() {
        assert!(is_trustworthy(3.2, 0.5));
        assert!(!is_trustworthy(3.2, 0.1));
        assert!(!is_trustworthy(14.9, 0.5));
        assert!(!is_trustworthy(f64::NAN, 0.5));
    }

    #[test]
    fn envelope_length() {
        let samples = vec![0.5_f32; 8000 * 5];
        let env = compute_envelope(&samples);
        // (40000 - 1024) / 512 + 1
        assert_eq!(env.len(), 77);
        assert!((env[0] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn lag_recovers_shift() {
        // 构造 song 包络，mv 包络是 song 右移 20 帧（mv[t+20] = song[t]）。
        let song: Vec<f32> = (0..800).map(|i| ((i as f32) * 0.1).sin().abs() + 0.1).collect();
        let lag_frames = 20_usize;
        let mut mv = vec![0.05_f32; 800 + lag_frames];
        for i in 0..song.len() {
            mv[i + lag_frames] = song[i];
        }
        let (offset, conf) = estimate_envelope_lag(&mv, &song).unwrap();
        let hop_sec = ENVELOPE_HOP as f64 / ANALYSIS_SAMPLE_RATE as f64;
        assert!((offset - lag_frames as f64 * hop_sec).abs() < hop_sec, "offset={offset}");
        assert!(conf > 0.9, "conf={conf}");
    }

    #[test]
    fn local_align_recovers_shift_with_pad() {
        // 模拟「MV 加了片头」：mv 包络前面垫一大段不相关内容，再出现整段歌。
        // 歌曲窗取自歌中间；滑窗匹配应把窗对准到 mv 里歌的对应位置。
        let w = 140_usize; // 歌曲窗长度（帧）
        let song_base: Vec<f32> =
            (0..400).map(|i| ((i as f32) * 0.17).sin().abs() + 0.08).collect();
        let pad = 60_usize; // 片头帧数
        let head_offset = 25_usize; // 歌窗原点到歌曲起点的帧偏移（模拟不在 0 秒开播）
        let song_win: Vec<f32> = song_base[head_offset..head_offset + w].to_vec();
        let mut mv: Vec<f32> = vec![0.03_f32; pad];
        mv.extend_from_slice(&song_base[..song_base.len()]);
        mv.extend_from_slice(&vec![0.04_f32; 60]);

        let mv_start = sliding_window_align(&mv, &song_win, 0, mv.len() - song_win.len()).unwrap();
        let conf = mv_start_confidence(&mv, &song_win, mv_start);
        // 理想位置：mv = pad + song_base，窗在 song_base 内头位移 head_offset
        let expect = pad + head_offset;
        assert_eq!(mv_start, expect, "mv_start={mv_start} expect={expect}");
        assert!(conf > 0.99, "conf={conf}");
        assert!(is_local_trustworthy(3.0, conf));
    }
}
