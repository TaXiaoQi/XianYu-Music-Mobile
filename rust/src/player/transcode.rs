//! APE/WV 转码 + QMC 解密缓存：把 ExoPlayer 不认识的格式在本地缓存成
//! 可直接播放的文件，交给 ExoPlayer 播放。
//!
//! - APE/WV：纯 Rust 解码 crate（`ape-decoder` / `wavicle`，与桌面端 vendor
//!   rodio 同源）解码为标准 WAV
//! - AIFF：symphonia（已启用 aiff 特性）解码为 float32 WAV
//! - QMC 加密（mflac/mgg/qmc* 等）：整文件解密为内部音频格式，流式写缓存
//!
//! 转码一次后缓存命中即可直接本地播放，缓存文件受远程缓存 LRU 统一管理。

use std::fs;
use std::io::{Seek, Write};
use std::path::Path;

/// 转码结果：`path` = 可播放文件路径；`decoded_now` = 本次是否实际执行解码。
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscodeOutcome {
    pub path: String,
    pub decoded_now: bool,
}

const TRANSCODED_DIR: &str = "transcoded";

/// ExoPlayer 不支持、需要转码/解密后才能播放的格式处理类别。
enum TranscodeJob {
    /// APE / WV → 解码为 WAV
    DecodeApeWv(&'static str),
    /// AIFF → symphonia 解码为 float32 WAV
    DecodeAiff,
    /// QMC 加密 → 整文件解密为内部格式（`&'static str` = 解密后扩展名）
    DecryptQmc(&'static str),
}

fn classify(ext: &str) -> Option<TranscodeJob> {
    match ext {
        "ape" => Some(TranscodeJob::DecodeApeWv("ape")),
        "wv" => Some(TranscodeJob::DecodeApeWv("wv")),
        "aif" | "aiff" => Some(TranscodeJob::DecodeAiff),
        other => crate::player::qmc2::inner_audio_extension(other)
            .filter(|_| crate::player::qmc2::is_qmc_extension(other))
            .map(TranscodeJob::DecryptQmc),
    }
}

/// 把 `src_path`（本地路径或 `remote://` URI）转成 ExoPlayer 可播放的缓存文件并返回路径。
/// 不需要处理的输入原样返回（`decoded_now = false`），不改动播放行为。
pub async fn transcode_to_wav(
    db_path: &str,
    cache_root: &Path,
    src_path: &str,
) -> Result<TranscodeOutcome, String> {
    // 1) 解析出本地源文件：remote:// 先下载进远程缓存
    let local_path: String = if crate::remote::cache::is_remote_uri(src_path) {
        let conn = std::sync::Arc::new(std::sync::Mutex::new(
            crate::api::open_scan_conn(db_path)?,
        ));
        crate::remote::cache::ensure_cached_path(cache_root, conn, src_path).await?
    } else {
        src_path.to_string()
    };

    let ext = Path::new(&local_path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let job = match classify(&ext) {
        Some(job) => job,
        None => {
            return Ok(TranscodeOutcome {
                path: local_path,
                decoded_now: false,
            })
        }
    };

    // 2) 缓存命中：目标文件已存在且不旧于源文件 → 直接复用
    let out_dir = cache_root.join(TRANSCODED_DIR);
    let src_meta = fs::metadata(&local_path).map_err(|e| e.to_string())?;
    let hash = cache_key(&local_path, src_meta.len());
    let out_path = match &job {
        TranscodeJob::DecryptQmc(inner) => out_dir.join(format!("{hash}.{inner}")),
        _ => out_dir.join(format!("{hash}.wav")),
    };
    if let (Ok(out_meta), Ok(src_modified)) = (fs::metadata(&out_path), src_meta.modified()) {
        if out_meta.modified().is_ok_and(|m| m >= src_modified) {
            return Ok(TranscodeOutcome {
                path: out_path.to_string_lossy().to_string(),
                decoded_now: false,
            });
        }
    }

    // 3) 转码/解密（阻塞型 CPU/IO 任务放 blocking 线程，避免卡 FRB worker）
    let src = local_path.clone();
    let out = out_path.clone();
    tokio::task::spawn_blocking(move || match job {
        TranscodeJob::DecodeApeWv(kind) => decode_to_wav_file(Path::new(&src), &out, kind),
        TranscodeJob::DecodeAiff => decode_aiff_to_wav(Path::new(&src), &out),
        TranscodeJob::DecryptQmc(_) => decrypt_qmc_to_file(Path::new(&src), &out),
    })
    .await
    .map_err(|e| e.to_string())??;

    Ok(TranscodeOutcome {
        path: out_path.to_string_lossy().to_string(),
        decoded_now: true,
    })
}

/// 单文件解码：按扩展名分派 APE / WV 解码器，边解边写 WAV。
fn decode_to_wav_file(src: &Path, wav: &Path, kind: &str) -> Result<(), String> {
    fs::create_dir_all(wav.parent().ok_or("目标目录缺失")?)
        .map_err(|e| e.to_string())?;
    // 先写临时文件再改名，避免中断留下半个 WAV 被误命中缓存
    let tmp = wav.with_extension("wav.part");

    let result = match kind {
        "ape" => decode_ape(src, &tmp),
        "wv" => decode_wv(src, &tmp),
        _ => Err("不支持的转码格式".to_string()),
    };
    match result {
        Ok(()) => {
            fs::rename(&tmp, wav).map_err(|e| e.to_string())?;
            Ok(())
        }
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// QMC 加密文件解密为内部音频格式（流式字节解密，不重编码）。
fn decrypt_qmc_to_file(src: &Path, out: &Path) -> Result<(), String> {
    let crypto =
        crate::player::qmc2::detect_qmc_crypto(src).ok_or("未识别 QMC 加密密钥（缺少 ekey）")?;
    fs::create_dir_all(out.parent().ok_or("目标目录缺失")?)
        .map_err(|e| e.to_string())?;
    let tmp = out.with_extension("qmc.part");
    let result = (|| {
        let file = fs::File::open(src).map_err(|e| e.to_string())?;
        let mut reader = crate::player::qmc2::QmcDecryptReader::new(file, crypto);
        let mut tmp_file = fs::File::create(&tmp).map_err(|e| e.to_string())?;
        std::io::copy(&mut reader, &mut tmp_file).map_err(|e| e.to_string())?;
        tmp_file.flush().map_err(|e| e.to_string())
    })();
    match result {
        Ok(()) => {
            fs::rename(&tmp, out).map_err(|e| e.to_string())?;
            Ok(())
        }
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// AIFF → float32 WAV：symphonia 解码（移动端 ExoPlayer 无 AIFF 解码器）。
fn decode_aiff_to_wav(src: &Path, out: &Path) -> Result<(), String> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    fs::create_dir_all(out.parent().ok_or("目标目录缺失")?)
        .map_err(|e| e.to_string())?;
    let tmp = out.with_extension("aiff.part");
    let result = (|| {
        let file = fs::File::open(src).map_err(|e| e.to_string())?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        hint.with_extension("aiff");
        let probed = symphonia::default::get_probe()
            .format(
                &hint,
                mss,
                &FormatOptions::default(),
                &MetadataOptions::default(),
            )
            .map_err(|e| format!("AIFF 探测失败：{e}"))?;

        let track = probed
            .format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or("AIFF 未找到音频轨道")?;
        let track_id = track.id;
        let sample_rate = track
            .codec_params
            .sample_rate
            .filter(|r| *r > 0)
            .ok_or("AIFF 采样率无效")?;
        let channels = track
            .codec_params
            .channels
            .map(|c| c.count())
            .filter(|c| *c > 0)
            .ok_or("AIFF 声道数无效")? as u16;
        let mut decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .map_err(|e| format!("AIFF 解码器创建失败：{e}"))?;
        let mut format = probed.format;

        let mut out_file = fs::File::create(&tmp).map_err(|e| e.to_string())?;
        // 先写占位头，流式写完数据后回写真实长度
        write_wav_header(&mut out_file, channels, sample_rate, 32, true, 0)
            .map_err(|e| e.to_string())?;

        let mut total_samples: u64 = 0;
        let mut sample_buf: Option<SampleBuffer<f32>> = None;
        let mut sample_buf_frames: usize = 0;
        loop {
            let packet = match format.next_packet() {
                Ok(p) => p,
                Err(symphonia::core::errors::Error::ResetRequired) => {
                    decoder.reset();
                    continue;
                }
                Err(symphonia::core::errors::Error::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    break;
                }
                Err(e) => return Err(format!("AIFF 解码失败：{e}")),
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
            if sample_buf_frames < frames {
                sample_buf = Some(SampleBuffer::<f32>::new(
                    frames as u64,
                    *decoded.spec(),
                ));
                sample_buf_frames = frames;
            }
            let buf = sample_buf.as_mut().ok_or("AIFF 样本缓冲初始化失败")?;
            buf.copy_interleaved_ref(decoded);
            let samples = buf.samples();
            total_samples = total_samples.saturating_add(samples.len() as u64);
            let mut bytes = Vec::with_capacity(samples.len() * 4);
            for s in samples {
                bytes.extend_from_slice(&s.to_le_bytes());
            }
            out_file.write_all(&bytes).map_err(|e| e.to_string())?;
        }
        out_file.flush().map_err(|e| e.to_string())?;

        let data_len = total_samples
            .saturating_mul(4)
            .min(u32::MAX as u64 - 64);
        out_file
            .seek(std::io::SeekFrom::Start(0))
            .map_err(|e| e.to_string())?;
        write_wav_header(&mut out_file, channels, sample_rate, 32, true, data_len)
            .map_err(|e| e.to_string())?;
        out_file.flush().map_err(|e| e.to_string())
    })();
    match result {
        Ok(()) => {
            fs::rename(&tmp, out).map_err(|e| e.to_string())?;
            Ok(())
        }
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// APE（Monkey's Audio）：逐帧解码为交错 LE PCM 字节，直接写入 WAV。
fn decode_ape(src: &Path, out: &Path) -> Result<(), String> {
    let mut file = fs::File::open(src).map_err(|e| e.to_string())?;
    let start = file
        .stream_position()
        .map_err(|e| e.to_string())?;
    let parsed = ape_decoder::format::parse(&mut file).map_err(|e| e.to_string())?;
    file.seek(std::io::SeekFrom::Start(start))
        .map_err(|e| e.to_string())?;

    let channels = parsed.header.channels;
    let sample_rate = parsed.header.sample_rate;
    let bits = parsed.header.bits_per_sample;
    let bytes_per_sample = parsed.bytes_per_sample as usize;
    let block_align = parsed.block_align as usize;
    if channels == 0 || sample_rate == 0 || bits == 0 || bytes_per_sample == 0 || block_align == 0 {
        return Err("APE 头信息无效".to_string());
    }

    let mut decoder = ape_decoder::ApeDecoder::new(file).map_err(|e| e.to_string())?;
    let info = decoder.info();
    let mut out_file = fs::File::create(out).map_err(|e| e.to_string())?;
    write_wav_header(
        &mut out_file,
        channels,
        sample_rate,
        bits,
        false,
        info.total_samples.saturating_mul(block_align as u64),
    )
    .map_err(|e| e.to_string())?;

    for frame in 0..info.total_frames {
        let pcm = decoder
            .decode_frame(frame)
            .map_err(|e| format!("APE 帧解码失败（帧 {frame}）：{e}"))?;
        out_file.write_all(&pcm).map_err(|e| e.to_string())?;
    }
    out_file.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// WV（WavPack）：wavicle 整流解码（float 输出已归一，int 输出按位深截写）。
fn decode_wv(src: &Path, out: &Path) -> Result<(), String> {
    let bytes = fs::read(src).map_err(|e| e.to_string())?;
    let decoded = wavicle::decode_stream(&bytes).map_err(|e| format!("WV 解码失败：{e}"))?;
    let channels = decoded.channels.max(1);
    let sample_rate = decoded.sample_rate;
    let bits = decoded.bits_per_sample;
    if sample_rate == 0 || bits == 0 || decoded.samples.is_empty() {
        return Err("WV 流信息无效".to_string());
    }

    let bytes_per_sample = (bits as usize / 8).max(1);
    let total_bytes = decoded
        .samples
        .len()
        .saturating_mul(bytes_per_sample) as u64;
    let mut out_file = fs::File::create(out).map_err(|e| e.to_string())?;
    write_wav_header(
        &mut out_file,
        channels as u16,
        sample_rate,
        bits as u16,
        decoded.is_float,
        total_bytes,
    )
    .map_err(|e| e.to_string())?;

    // wavicle 样本统一放 i32：整型流为按位深的原始值（可能带符号扩展），
    // 浮点流为 f32 的位模式。
    let mut buf = Vec::with_capacity(decoded.samples.len() * bytes_per_sample);
    for v in &decoded.samples {
        let le = v.to_le_bytes();
        match (decoded.is_float, bytes_per_sample) {
            (true, _) | (_, 4) => buf.extend_from_slice(&le),
            (_, 3) => buf.extend_from_slice(&le[..3]),
            (_, 2) => buf.extend_from_slice(&le[..2]),
            _ => buf.push(le[0]),
        }
    }
    out_file.write_all(&buf).map_err(|e| e.to_string())?;
    out_file.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// 写 44 字节标准 WAV 头（PCM=1 / IEEE float=3）。
fn write_wav_header<W: Write>(
    w: &mut W,
    channels: u16,
    sample_rate: u32,
    bits: u16,
    is_float: bool,
    data_len: u64,
) -> std::io::Result<()> {
    let data_len = data_len.min(u32::MAX as u64 - 64) as u32;
    let format_tag: u16 = if is_float { 3 } else { 1 };
    let block_align = channels * (bits / 8);
    let byte_rate = sample_rate * block_align as u32;
    let file_len = 36u32.saturating_add(data_len);

    w.write_all(b"RIFF")?;
    w.write_all(&file_len.to_le_bytes())?;
    w.write_all(b"WAVE")?;
    w.write_all(b"fmt ")?;
    w.write_all(&16u32.to_le_bytes())?;
    w.write_all(&format_tag.to_le_bytes())?;
    w.write_all(&channels.to_le_bytes())?;
    w.write_all(&sample_rate.to_le_bytes())?;
    w.write_all(&byte_rate.to_le_bytes())?;
    w.write_all(&block_align.to_le_bytes())?;
    w.write_all(&bits.to_le_bytes())?;
    w.write_all(b"data")?;
    w.write_all(&data_len.to_le_bytes())?;
    Ok(())
}

/// 缓存键：FNV-1a 64 位（路径 + 文件长度），十六进制。
fn cache_key(path: &str, len: u64) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in path.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    for byte in len.to_le_bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_header_fields() {
        let mut buf = Vec::new();
        write_wav_header(&mut buf, 2, 44100, 16, false, 1000).unwrap();
        assert_eq!(&buf[0..4], b"RIFF");
        assert_eq!(&buf[8..12], b"WAVE");
        assert_eq!(&buf[12..16], b"fmt ");
        assert_eq!(&buf[20..22], &1u16.to_le_bytes()); // PCM
        assert_eq!(&buf[22..24], &2u16.to_le_bytes()); // channels
        assert_eq!(u32::from_le_bytes(buf[24..28].try_into().unwrap()), 44100);
        assert_eq!(u32::from_le_bytes(buf[28..32].try_into().unwrap()), 44100 * 4);
        assert_eq!(&buf[32..34], &4u16.to_le_bytes()); // block align
        assert_eq!(&buf[34..36], &16u16.to_le_bytes()); // bits
        assert_eq!(&buf[36..40], b"data");
        assert_eq!(u32::from_le_bytes(buf[40..44].try_into().unwrap()), 1000);
    }

    #[test]
    fn wav_header_float_format() {
        let mut buf = Vec::new();
        write_wav_header(&mut buf, 2, 44100, 32, true, 1000).unwrap();
        assert_eq!(&buf[20..22], &3u16.to_le_bytes()); // IEEE float
    }

    #[test]
    fn cache_key_is_stable_hex() {
        let a = cache_key("/music/a.ape", 123);
        let b = cache_key("/music/a.ape", 123);
        let c = cache_key("/music/a.ape", 456);
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 16);
    }

    #[test]
    fn fnv_reference_vector() {
        // FNV-1a 64 标准测试向量
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in b"a" {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        assert_eq!(format!("{hash:016x}"), "af63dc4c8601ec8c");
    }
}
