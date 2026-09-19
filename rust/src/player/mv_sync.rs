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
/// 互相关置信度阈值（低于此值视为不可信，回退 offset=0）。
const MIN_CONFIDENCE: f64 = 0.2;
/// 相关峰值两侧至少需要的重叠帧数（避免边缘伪峰）。
const MIN_OVERLAP_FRAMES: usize = 16;

/// 分析 MV 音频与歌曲音频的频谱偏移。
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

/// 置信度与偏移是否可信（对齐桌面端 isTrustworthyEstimate）。
pub fn is_trustworthy(offset_sec: f64, confidence: f64) -> bool {
    offset_sec.is_finite()
        && confidence >= MIN_CONFIDENCE
        && offset_sec.abs() < MAX_LAG_SEC - 0.5
}

/// 解码音频文件为单声道 f32 采样（原生采样率），超过 MAX_ANALYSIS_SEC + 1s 提前停止。
fn decode_mono_native(path: &Path) -> Result<(u32, Vec<f32>), String> {
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
    let max_native = ((MAX_ANALYSIS_SEC + 1.0) * sr as f64) as usize;

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
}
