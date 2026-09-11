//! Audio format conversion: pure Rust, no FFmpeg needed.
//!
//! Decode: symphonia (mp3/flac/m4a/aac/ogg/wav/aiff/alac) + ape-decoder (APE) +
//! wavicle (WV/WavPack). All inputs unified to PCM float32 interleaved.
//!
//! Encode:
//! - WAV  : manual header + PCM write
//! - FLAC : claxon (pure Rust, no C deps)

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
pub struct ConvertResult {
    pub input_path: String,
    pub output_path: String,
    pub success: bool,
    pub error: Option<String>,
    pub duration_secs: f64,
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertOptions {
    pub target_format: String,
    pub sample_rate: Option<u32>,
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

        let res = tokio::task::spawn_blocking(move || {
            convert_blocking(&in_clone, &out_clone, fmt)
        })
        .await
        .map_err(|e| format!("task dispatch failed: {e}"));

        let duration = start.elapsed().as_secs_f64();
        match res {
            Ok(Ok(())) => results.push(ConvertResult {
                input_path: input.clone(),
                output_path: out_path.to_string_lossy().to_string(),
                success: true,
                error: None,
                duration_secs: duration,
            }),
            Ok(Err(e)) => results.push(ConvertResult {
                input_path: input.clone(),
                output_path: out_path.to_string_lossy().to_string(),
                success: false,
                error: Some(e),
                duration_secs: duration,
            }),
            Err(e) => results.push(ConvertResult {
                input_path: input.clone(),
                output_path: String::new(),
                success: false,
                error: Some(e),
                duration_secs: duration,
            }),
        }
    }
    results
}

fn convert_blocking(src: &Path, out: &Path, fmt: OutputFormat) -> Result<(), String> {
    if !src.is_file() {
        return Err(format!("input not found: {}", src.display()));
    }
    let ext = src
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();

    let (sr, ch, pcm) = match classify_input(&ext) {
        InputClass::Symphonia => decode_via_symphonia(src)?,
        InputClass::Ape => decode_ape_pcm(src)?,
        InputClass::Wv => decode_wv_pcm(src)?,
        InputClass::Unsupported => return Err(format!("unsupported input format: {ext}")),
    };

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
    }
}

enum InputClass { Symphonia, Ape, Wv, Unsupported }

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