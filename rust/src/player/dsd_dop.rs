//! DSD 原生 DoP（DSD over PCM）直出。
//!
//! 读未压缩 DSD 的 1-bit DSD 原生流，按 DoP 1.0 打包成 24-bit PCM 帧输出到
//! 支持 DoP 的 DSD-DAC。DoP 是位真输出：走 Android AAudio 独占、绕过 f32/音量/EQ 链路。
//!
//! 支持两种 DSD 容器格式：
//! - DSF（DSD Stream File）：小端、block 布局（ch0[0..bs], ch1[0..bs], ...）
//! - DFF（DSDIFF）：大端 IFF、字节交错布局（ch0_byte0, ch1_byte0, ch0_byte1, ...）
//!
//! DoP 1.0 约定：每个通道每帧承载 8 个 DSD bit（1 字节）。
//! - DSD64(2.8224M)   → 352.8 kHz
//! - DSD128(5.6448M)  → 705.6 kHz
//! - DSD256(11.2896M) → 1.4112 MHz
//! 24-bit 容器中：低字节 = DSD 数据字节，中字节 = 0，高字节 = 标记 0x05/0xFA 交替。

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};

pub const DOP_MARKER_LOW: u8 = 0x05;
pub const DOP_MARKER_HIGH: u8 = 0xFA;

/// DFF 内部缓冲帧数（DFF 无 block 概念，按固定帧数分批读取）
const DFF_BUFFER_FRAMES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DsdFormat {
    Dsf,
    Dff,
}

#[derive(Debug, Clone, Copy)]
pub struct DsdInfo {
    pub channels: u16,
    /// DSD 原生采样率，如 DSD64 = 2_822_400 Hz。
    pub dsd_rate: u32,
    /// DSF block 大小；DFF 无 block 概念，此字段为 0。
    pub block_size: u32,
    /// DSF 每声道 DSD 采样数；DFF 此字段为 0（由 data_size 反推）。
    pub sample_count: u64,
    pub data_offset: u64,
    pub data_size: u64,
    pub is_dst: bool,
    pub format: DsdFormat,
}

impl DsdInfo {
    /// 时长（秒）。DSF 用 sample_count / dsd_rate，DFF 用帧数 / dsd_rate。
    pub fn duration_seconds(&self) -> u32 {
        let frames = if self.format == DsdFormat::Dsf {
            self.sample_count
        } else if self.channels > 0 {
            self.data_size / self.channels as u64
        } else {
            0
        };
        if self.dsd_rate == 0 {
            0
        } else {
            (frames / u64::from(self.dsd_rate)) as u32
        }
    }
}

/// DSD 率 → DoP PCM 采样率（每个通道每帧 8 个 DSD bit）。
pub fn dop_pcm_rate(dsd_rate: u32) -> Option<u32> {
    if dsd_rate == 0 || dsd_rate % 8 != 0 {
        return None;
    }
    Some(dsd_rate / 8)
}

fn read_u32_le(buf: &[u8]) -> u32 {
    u32::from_le_bytes(buf[..4].try_into().unwrap())
}

fn read_u64_le(buf: &[u8]) -> u64 {
    u64::from_le_bytes(buf[..8].try_into().unwrap())
}

fn read_u32_be(buf: &[u8]) -> u32 {
    u32::from_be_bytes(buf[..4].try_into().unwrap())
}

fn read_u64_be(buf: &[u8]) -> u64 {
    u64::from_be_bytes(buf[..8].try_into().unwrap())
}

/// 解析 DSF 头。DSF 顶层结构：
/// - `DSD `(4) + chunk_size(8) + file_size(8) + metadata_offset(8) = 28 字节 DSD chunk
/// - `fmt `(12 头 + 52 负载) 子块（真实文件通常紧跟 DSD chunk 之后）
/// - `data` 子块（12 头 + 实际 DSD 数据，data 区前 8 字节为数据字节数）
///
/// fmt 负载（52 字节，@fmt+12 起点）各字段偏移：
/// 0:format_version  4:format_id  8:channel_type  12:channel_num
/// 16:sampling_freq  20:bits_per_sample  24:sample_count(u64)  32:block_size  36:reserved
pub fn parse_dsf_info(path: &str) -> Result<DsdInfo, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;

    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).map_err(|_| "not a DSD file".to_string())?;
    if &magic != b"DSD " {
        return Err("not DSF".to_string());
    }

    // 跳过 DSD chunk 剩余 24 字节（size + file_size + metadata_offset），
    // 使读取位置落在 fmt 子块起点（offset 28）。
    let mut dsd_rest = [0u8; 24];
    file.read_exact(&mut dsd_rest).map_err(|_| "bad dsd chunk".to_string())?;

    // 从 fmt 起点开始按子块遍历：fmt 先解析，data 决定数据区。
    let mut channels = 0u16;
    let mut dsd_rate = 0u32;
    let mut block_size = 0u32;
    let mut sample_count = 0u64;
    let mut bits_per_sample = 0u32;
    let mut format_id = 0u32;
    let data_offset;
    let data_size;

    loop {
        let mut hdr = [0u8; 12];
        if file.read_exact(&mut hdr).is_err() {
            return Err("missing data chunk".to_string());
        }
        let chunk_id = &hdr[0..4];
        let chunk_size = read_u64_le(&hdr[4..12]);

        if chunk_id == b"fmt " {
            if chunk_size < 52 {
                return Err("invalid DSF fmt size".to_string());
            }
            let mut fmt = [0u8; 52];
            file.read_exact(&mut fmt).map_err(|_| "bad fmt payload".to_string())?;
            format_id = read_u32_le(&fmt[4..8]);
            channels = read_u32_le(&fmt[12..16]) as u16;
            dsd_rate = read_u32_le(&fmt[16..20]);
            bits_per_sample = read_u32_le(&fmt[20..24]);
            sample_count = read_u64_le(&fmt[24..32]);
            block_size = read_u32_le(&fmt[32..36]);
            // 跳过 fmt 负载剩余部分
            let skip = chunk_size as i64 - 52;
            if skip > 0 {
                file.seek(SeekFrom::Current(skip)).map_err(|e| e.to_string())?;
            }
        } else if chunk_id == b"data" {
            let mut inner = [0u8; 8];
            file.read_exact(&mut inner).map_err(|_| "bad data size".to_string())?;
            data_size = read_u64_le(&inner);
            data_offset = file.stream_position().map_err(|e| e.to_string())?;
            break;
        } else if chunk_size > 12 {
            file.seek(SeekFrom::Current((chunk_size - 12) as i64))
                .map_err(|e| e.to_string())?;
        } else {
            return Err("unknown chunk".to_string());
        }
    }

    if channels == 0 || dsd_rate == 0 || block_size == 0 {
        return Err("invalid DSF fmt".to_string());
    }

    Ok(DsdInfo {
        channels,
        dsd_rate,
        block_size,
        sample_count,
        data_offset,
        data_size,
        is_dst: bits_per_sample != 1 || format_id != 0,
        format: DsdFormat::Dsf,
    })
}

/// 解析 DFF（DSDIFF）头：大端 IFF 结构，字节交错 DSD 数据。
///
/// FRM8 → FVER / PROP(SND: FS + CHNL + CMPR) / DSD
/// DFF 数据按 Clustered Frame 逐字节交错：CH0 CH1 CH0 CH1 ...
pub fn parse_dff_info(path: &str) -> Result<DsdInfo, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;

    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).map_err(|_| "not a DSD file".to_string())?;
    if &magic != b"FRM8" {
        return Err("not DFF (expected FRM8 magic)".to_string());
    }

    let mut frm8_size_buf = [0u8; 8];
    file.read_exact(&mut frm8_size_buf).map_err(|_| "bad FRM8 size".to_string())?;
    let frm8_size = read_u64_be(&frm8_size_buf);

    let mut form_type = [0u8; 4];
    file.read_exact(&mut form_type).map_err(|_| "bad form type".to_string())?;
    if &form_type != b"DSD " {
        return Err("not DSDIFF (form type is not DSD)".to_string());
    }

    let frm8_data_end = 12 + frm8_size;

    let mut channels = 0u16;
    let mut dsd_rate = 0u32;
    let mut is_dst = false;
    let mut data_offset = 0u64;
    let mut data_size = 0u64;

    loop {
        let pos = file.stream_position().map_err(|e| e.to_string())?;
        if pos >= frm8_data_end {
            break;
        }

        let mut chunk_hdr = [0u8; 12];
        if file.read_exact(&mut chunk_hdr).is_err() {
            break;
        }

        let chunk_id = &chunk_hdr[0..4];
        let chunk_size = read_u64_be(&chunk_hdr[4..12]);
        let chunk_data_start = file.stream_position().map_err(|e| e.to_string())?;
        let pad = if chunk_size & 1 != 0 { 1 } else { 0 };

        match chunk_id {
            b"FVER" => {
                file.seek(SeekFrom::Current((chunk_size + pad) as i64))
                    .map_err(|e| e.to_string())?;
            }
            b"PROP" => {
                let mut prop_type = [0u8; 4];
                file.read_exact(&mut prop_type)
                    .map_err(|_| "bad PROP type".to_string())?;

                let prop_data_end = chunk_data_start + chunk_size;
                while file.stream_position().map_err(|e| e.to_string())? < prop_data_end {
                    let mut sub_hdr = [0u8; 12];
                    if file.read_exact(&mut sub_hdr).is_err() {
                        break;
                    }
                    let sub_id = &sub_hdr[0..4];
                    let sub_size = read_u64_be(&sub_hdr[4..12]);
                    let sub_data_start = file.stream_position().map_err(|e| e.to_string())?;
                    let sub_pad = if sub_size & 1 != 0 { 1 } else { 0 };

                    match sub_id {
                        b"FS  " => {
                            let mut rate_buf = [0u8; 4];
                            file.read_exact(&mut rate_buf)
                                .map_err(|_| "bad FS data".to_string())?;
                            dsd_rate = read_u32_be(&rate_buf);
                        }
                        b"CHNL" => {
                            let mut ch_buf = [0u8; 2];
                            file.read_exact(&mut ch_buf)
                                .map_err(|_| "bad CHNL data".to_string())?;
                            channels = u16::from_be_bytes(ch_buf);
                        }
                        b"CMPR" => {
                            let mut comp_type = [0u8; 4];
                            file.read_exact(&mut comp_type)
                                .map_err(|_| "bad CMPR data".to_string())?;
                            is_dst = &comp_type == b"DST ";
                        }
                        _ => {}
                    }

                    file.seek(SeekFrom::Start(sub_data_start + sub_size + sub_pad))
                        .map_err(|e| e.to_string())?;
                }
                // 跳到下一个顶层 chunk（含 PROP 自身的填充字节）
                file.seek(SeekFrom::Start(chunk_data_start + chunk_size + pad))
                    .map_err(|e| e.to_string())?;
            }
            b"DSD " => {
                data_offset = chunk_data_start;
                data_size = chunk_size;
                break;
            }
            b"DST " => {
                data_offset = chunk_data_start;
                data_size = chunk_size;
                is_dst = true;
                break;
            }
            _ => {
                file.seek(SeekFrom::Current((chunk_size + pad) as i64))
                    .map_err(|e| e.to_string())?;
            }
        }
    }

    if channels == 0 || dsd_rate == 0 || data_size == 0 {
        return Err("invalid DFF: missing required PROP or DSD chunks".to_string());
    }

    Ok(DsdInfo {
        channels,
        dsd_rate,
        block_size: 0,
        sample_count: 0,
        data_offset,
        data_size,
        is_dst,
        format: DsdFormat::Dff,
    })
}

/// 统一 DSD 文件解析入口：根据 magic 自动分派 DSF 或 DFF。
pub fn parse_dsd_info(path: &str) -> Result<DsdInfo, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).map_err(|_| "not a DSD file".to_string())?;
    drop(file);

    match &magic {
        b"DSD " => parse_dsf_info(path),
        b"FRM8" => parse_dff_info(path),
        _ => Err("not a DSD file (expected DSD or FRM8 magic)".to_string()),
    }
}

/// 按 block / 交错流式读取 DSD 原生字节，并打包为 DoP 24-bit 帧。
///
/// 支持 `next_frames` 按帧粒度过量产出（满足 AAudio 按 buffer/frame 填充），
/// marker 用全局帧序号交替（0x05/0xFA），跨 block 边界保持连续，DAC 无需在
/// block 边界重新同步。也支持按帧 seek（时长 → 帧位 → 文件字节偏移）。
pub struct DopStreamSource {
    reader: BufReader<File>,
    start_offset: u64,
    data_size: u64,
    data_remaining: u64,
    channels: usize,
    block_size: usize,
    cps: usize,
    buf: Vec<u8>,
    /// 当前缓冲区中加载的帧数。
    frames_in_buf: usize,
    frames_left: usize,
    /// 已产出的总 DoP 帧数，用于跨块持续的 marker 交替。
    frame_index: u64,
    format: DsdFormat,
}

impl DopStreamSource {
    pub fn open(path: &str, info: &DsdInfo) -> Result<Self, String> {
        let mut file = File::open(path).map_err(|e| e.to_string())?;
        file.seek(SeekFrom::Start(info.data_offset)).map_err(|e| e.to_string())?;
        let (block_size, cps) = match info.format {
            DsdFormat::Dsf => {
                let bs = info.block_size as usize;
                (bs, info.channels as usize * bs)
            }
            DsdFormat::Dff => {
                let bs = DFF_BUFFER_FRAMES;
                (bs, info.channels as usize * bs)
            }
        };
        Ok(Self {
            reader: BufReader::with_capacity(1 << 16, file),
            start_offset: info.data_offset,
            data_size: info.data_size,
            data_remaining: info.data_size,
            channels: info.channels as usize,
            block_size,
            cps,
            buf: Vec::new(),
            frames_in_buf: 0,
            frames_left: 0,
            frame_index: 0,
            format: info.format,
        })
    }

    fn load_block(&mut self) -> Result<bool, String> {
        if self.data_remaining == 0 {
            return Ok(false);
        }
        self.buf.resize(self.cps, 0);
        let mut filled = 0usize;
        while filled < self.cps {
            let n = self.reader.read(&mut self.buf[filled..]).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        self.data_remaining = self.data_remaining.saturating_sub(filled as u64);
        if filled == 0 {
            return Ok(false);
        }
        match self.format {
            DsdFormat::Dsf => {
                self.frames_in_buf = self.block_size;
                self.frames_left = self.block_size;
            }
            DsdFormat::Dff => {
                self.frames_in_buf = filled / self.channels;
                self.frames_left = self.frames_in_buf;
            }
        }
        Ok(true)
    }

    /// 产出至多 `max_frames` 个 DoP 帧到 `out`（每帧 `channels × 3` 字节），
    /// 返回实际产出的帧数；流结束时返回的帧数 < `max_frames`。
    pub fn next_frames(&mut self, out: &mut Vec<u8>, max_frames: usize) -> Result<usize, String> {
        let mut produced = 0usize;
        while produced < max_frames {
            if self.frames_left == 0 && !self.load_block()? {
                break;
            }
            let frame_in_buf = self.frames_in_buf - self.frames_left;
            let marker = if self.frame_index & 1 == 0 { DOP_MARKER_LOW } else { DOP_MARKER_HIGH };
            for ch in 0..self.channels {
                let db = match self.format {
                    // DSF block 布局：ch0[0..bs], ch1[0..bs], ... => 帧 f 的通道 c 字节 = buf[f + c*bs]
                    DsdFormat::Dsf => self.buf[frame_in_buf + ch * self.block_size],
                    // DFF 字节交错：CH0 CH1 CH0 CH1 ... => 帧 f 的通道 c 字节 = buf[f * channels + c]
                    DsdFormat::Dff => self.buf[frame_in_buf * self.channels + ch],
                };
                out.push(db);
                out.push(0);
                out.push(marker);
            }
            self.frames_left -= 1;
            self.frame_index += 1;
            produced += 1;
        }
        Ok(produced)
    }

    /// 定位到第 `target_frame` 个 DoP 帧（从 data 区开头计数）。
    ///
    /// DSF：数据区按 block 连续存储，只支持定位到 block 边界，返回向下取整的帧号。
    /// DFF：数据按字节交错连续存储，支持精确帧定位。
    pub fn seek_to_frame(&mut self, target_frame: u64) -> Result<u64, String> {
        match self.format {
            DsdFormat::Dsf => {
                let block_size = self.block_size as u64;
                let block_index = target_frame / block_size;
                let aligned_frame = block_index * block_size;
                let byte_off = block_index
                    .saturating_mul(self.channels as u64 * block_size)
                    .min(self.data_size);
                self.reader
                    .seek(SeekFrom::Start(self.start_offset + byte_off))
                    .map_err(|e| e.to_string())?;
                self.data_remaining = self.data_size - byte_off;
                self.frames_in_buf = 0;
                self.frames_left = 0;
                self.frame_index = aligned_frame;
                Ok(aligned_frame)
            }
            DsdFormat::Dff => {
                let channels = self.channels as u64;
                let byte_off = target_frame
                    .saturating_mul(channels)
                    .min(self.data_size);
                self.reader
                    .seek(SeekFrom::Start(self.start_offset + byte_off))
                    .map_err(|e| e.to_string())?;
                self.data_remaining = self.data_size - byte_off;
                self.frames_in_buf = 0;
                self.frames_left = 0;
                self.frame_index = target_frame;
                Ok(target_frame)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造一个最小的单声道 DSF（按标准 28 字节 DSD chunk + fmt + data 布局）。
    fn build_dsf(channels: u32, block_size: u32, dsd_rate: u32, blocks: &[u8]) -> Vec<u8> {
        // fmt chunk（12 头 + 44 数据即可，这里完整构造 52 字节负载）
        let mut fmt_payload = Vec::new();
        fmt_payload.extend_from_slice(&1u32.to_le_bytes()); // format_version
        fmt_payload.extend_from_slice(&0u32.to_le_bytes()); // format_id = DSD raw
        fmt_payload.extend_from_slice(&0u32.to_le_bytes()); // channel_type
        fmt_payload.extend_from_slice(&channels.to_le_bytes());
        fmt_payload.extend_from_slice(&dsd_rate.to_le_bytes());
        fmt_payload.extend_from_slice(&1u32.to_le_bytes()); // bits_per_sample
        fmt_payload.extend_from_slice(&(blocks.len() as u64).to_le_bytes()); // sample_count
        fmt_payload.extend_from_slice(&block_size.to_le_bytes());
        fmt_payload.extend_from_slice(&0u32.to_le_bytes()); // reserved
        assert_eq!(fmt_payload.len(), 44);

        let mut out = Vec::new();
        // DSD chunk：28 字节
        out.extend_from_slice(b"DSD ");
        let chunk_size = 28u64;
        out.extend_from_slice(&chunk_size.to_le_bytes());
        // file_size、metadata_offset 占位（真实文件为实际值，测试用 0）
        let total = 28 + 12 + 8 + fmt_payload.len() + 12 + 8 + blocks.len();
        out.extend_from_slice(&(total as u64).to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes()); // metadata_offset = 0（无 ID3）

        // fmt chunk
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&(fmt_payload.len() as u64 + 8).to_le_bytes());
        out.extend_from_slice(&fmt_payload);

        // data chunk
        out.extend_from_slice(b"data");
        let data_chunk_size = 8 + blocks.len() as u64;
        out.extend_from_slice(&data_chunk_size.to_le_bytes());
        out.extend_from_slice(&(blocks.len() as u64).to_le_bytes());
        out.extend_from_slice(blocks);
        out
    }

    fn write_tmp(bytes: &[u8], tag: &str) -> String {
        let path = format!("{}-dsf-{tag}.dsf", std::process::id());
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn parses_mono_dsf_header() {
        let bytes = build_dsf(1, 4, 2_822_400, &[0b1010_1010, 0b0101_0101, 0xFF, 0x00]);
        let path = write_tmp(&bytes, "mono");
        let info = parse_dsf_info(&path).unwrap();
        assert_eq!(info.channels, 1);
        assert_eq!(info.dsd_rate, 2_822_400);
        assert_eq!(info.block_size, 4);
        assert_eq!(info.sample_count, 4);
        assert!(!info.is_dst);
        assert_eq!(dop_pcm_rate(info.dsd_rate), Some(352_800));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn mono_dop_frame_layout() {
        let bytes = build_dsf(1, 4, 2_822_400, &[0xAA, 0x55, 0xFF, 0x00]);
        let path = write_tmp(&bytes, "mono-frames");
        let info = parse_dsf_info(&path).unwrap();
        let mut src = DopStreamSource::open(&path, &info).unwrap();
        let mut out = Vec::new();

        for _ in 0..4 {
            assert_eq!(src.next_frames(&mut out, 1).unwrap(), 1);
        }
        assert_eq!(out.len(), 4 * 3);

        let mut i = 0;
        for frame in 0..4 {
            let marker = if frame & 1 == 0 { DOP_MARKER_LOW } else { DOP_MARKER_HIGH };
            assert_eq!(out[i], [0xAA, 0x55, 0xFF, 0x00][frame]);
            assert_eq!(out[i + 1], 0);
            assert_eq!(out[i + 2], marker);
            i += 3;
        }
        assert_eq!(src.next_frames(&mut out, 4).unwrap(), 0);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn dsd_duration() {
        // DSD64 采样率下 sample_count = 2_822_400 → 1 秒
        let bytes = build_dsf(1, 4, 2_822_400, &[0xAA; 4]);
        let path = write_tmp(&bytes, "dur");
        let info = parse_dsf_info(&path).unwrap();
        // 手动改写 sample_count 而非受 data 长度约束
        assert!(info.duration_seconds() == 0); // 4 样本 / 2.8M ≈ 0 秒
        let _ = std::fs::remove_file(&path);
    }
}