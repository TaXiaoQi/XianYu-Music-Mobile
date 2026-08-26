//! CENC (Common Encryption) decryption for MP4/M4A files.
//!
//! 汽水音乐等音源返回 CENC 加密的 M4A：音频样本用 AES-128-CTR 加密，
//! 密钥(CEK)由插件从 PlayAuth 解密得到。文件内 moov/stbl 携带加密元数据：
//! - stsd 中的 enca 样本条目（含 sinf → tenc：per_sample_iv_size、KID）
//! - stbl 中的 senc 盒（每个样本的 IV）
//! - stsc/stco/stsz 用于计算样本在 mdat 中的绝对偏移
//!
//! 移植自桌面端 `player/cenc.rs`，纯逻辑无 Tauri 依赖。
//!
//! 解密策略（后处理，文件已完整下载到本地缓存）：
//! 1. 解析盒结构，定位 enca/senc/stsc/stco/stsz
//! 2. 计算每个样本在 mdat 中的绝对偏移
//! 3. 用 CEK + 每样本 IV 做 AES-128-CTR 解密（就地修改 mdat，长度不变）
//! 4. 将 enca 补丁为 mp4a：symphonia 按 mp4a 解析音频样本条目，
//!    对 sinf/senc 等未知盒直接跳过，无需重写文件结构。

use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockEncrypt, KeyInit};
use aes::Aes128;

/// 从插件返回的 cek 字符串构造 AES-128 密钥。
/// 兼容 hex(32 字符) / base64(24 字符) / 原始 16 字节三种编码。
pub fn cek_to_key(cek: &str) -> Result<Vec<u8>, String> {
    let trimmed = cek.trim();
    // 原始 16 字节
    if trimmed.len() == 16 {
        return Ok(trimmed.as_bytes().to_vec());
    }
    // hex
    if trimmed.len() == 32 && trimmed.chars().all(|c| c.is_ascii_hexdigit()) {
        let mut key = Vec::with_capacity(16);
        for i in (0..32).step_by(2) {
            key.push(
                u8::from_str_radix(&trimmed[i..i + 2], 16)
                    .map_err(|e| format!("CEK hex 解析失败: {}", e))?,
            );
        }
        return Ok(key);
    }
    // base64
    if trimmed.len() == 24 {
        use base64::Engine;
        if let Ok(key) = base64::engine::general_purpose::STANDARD.decode(trimmed) {
            if key.len() == 16 {
                return Ok(key);
            }
        }
    }
    Err(format!(
        "CEK 长度必须为 16 字节 (hex/base64/raw)，实际: {}",
        trimmed.len()
    ))
}

/// 单个 MP4 盒的信息（偏移基于整个文件缓冲区）。
struct BoxInfo {
    start: usize,
    data_start: usize,
    data_end: usize,
    typ: [u8; 4],
}

impl BoxInfo {
    fn is(&self, typ: &[u8; 4]) -> bool {
        &self.typ == typ
    }
}

fn read_u16(data: &[u8], off: usize) -> u16 {
    ((data[off] as u16) << 8) | (data[off + 1] as u16)
}

fn read_u32(data: &[u8], off: usize) -> u32 {
    ((data[off] as u32) << 24)
        | ((data[off + 1] as u32) << 16)
        | ((data[off + 2] as u32) << 8)
        | (data[off + 3] as u32)
}

fn read_u64(data: &[u8], off: usize) -> u64 {
    ((data[off] as u64) << 56)
        | ((data[off + 1] as u64) << 48)
        | ((data[off + 2] as u64) << 40)
        | ((data[off + 3] as u64) << 32)
        | ((data[off + 4] as u64) << 24)
        | ((data[off + 5] as u64) << 16)
        | ((data[off + 6] as u64) << 8)
        | (data[off + 7] as u64)
}

/// 读取 off 处的盒头。返回 None 表示越界或非法。
fn read_box_header(data: &[u8], off: usize) -> Option<BoxInfo> {
    if off + 8 > data.len() {
        return None;
    }
    let mut size = read_u32(data, off) as usize;
    let mut header_len = 8usize;
    let typ = [data[off + 4], data[off + 5], data[off + 6], data[off + 7]];
    if size == 1 {
        // largesize: 64 位大小
        if off + 16 > data.len() {
            return None;
        }
        size = ((read_u32(data, off + 8) as usize) << 32) | read_u32(data, off + 12) as usize;
        header_len = 16;
    } else if size == 0 {
        // 延伸到文件末尾
        size = data.len() - off;
    }
    if size < header_len || off + size > data.len() {
        return None;
    }
    Some(BoxInfo {
        start: off,
        data_start: off + header_len,
        data_end: off + size,
        typ,
    })
}

/// 在 parent 盒内查找第一个指定类型的子盒。
fn find_child_box(data: &[u8], parent: &BoxInfo, typ: &[u8; 4]) -> Option<BoxInfo> {
    let mut off = parent.data_start;
    while off + 8 <= parent.data_end {
        let child = read_box_header(data, off)?;
        if child.is(typ) {
            return Some(child);
        }
        off = child.data_end;
    }
    None
}

/// 在 parent 盒内查找所有指定类型的子盒。
fn find_child_boxes(data: &[u8], parent: &BoxInfo, typ: &[u8; 4]) -> Vec<BoxInfo> {
    let mut out = Vec::new();
    let mut off = parent.data_start;
    while off + 8 <= parent.data_end {
        if let Some(child) = read_box_header(data, off) {
            let data_end = child.data_end;
            if child.is(typ) {
                out.push(child);
            }
            off = data_end;
        } else {
            break;
        }
    }
    out
}

/// 解析 stsc（sample-to-chunk）：(first_chunk, samples_per_chunk, sample_desc)
fn parse_stsc(data: &[u8]) -> Vec<(u32, u32, u32)> {
    if data.len() < 8 {
        return Vec::new();
    }
    let count = read_u32(data, 4) as usize;
    let mut out = Vec::with_capacity(count);
    let mut off = 8;
    for _ in 0..count {
        if off + 12 > data.len() {
            break;
        }
        out.push((
            read_u32(data, off),
            read_u32(data, off + 4),
            read_u32(data, off + 8),
        ));
        off += 12;
    }
    out
}

/// 解析 stco（chunk offsets，32 位）
fn parse_stco(data: &[u8]) -> Vec<u64> {
    if data.len() < 8 {
        return Vec::new();
    }
    let count = read_u32(data, 4) as usize;
    let mut out = Vec::with_capacity(count);
    let mut off = 8;
    for _ in 0..count {
        if off + 4 > data.len() {
            break;
        }
        out.push(read_u32(data, off) as u64);
        off += 4;
    }
    out
}

/// 解析 co64（chunk offsets，64 位）
fn parse_co64(data: &[u8]) -> Vec<u64> {
    if data.len() < 8 {
        return Vec::new();
    }
    let count = read_u32(data, 4) as usize;
    let mut out = Vec::with_capacity(count);
    let mut off = 8;
    for _ in 0..count {
        if off + 8 > data.len() {
            break;
        }
        out.push(read_u64(data, off));
        off += 8;
    }
    out
}

/// 解析 stsz（sample sizes）
fn parse_stsz(data: &[u8]) -> Vec<u32> {
    if data.len() < 12 {
        return Vec::new();
    }
    let sample_size = read_u32(data, 4);
    let count = read_u32(data, 8) as usize;
    if sample_size != 0 {
        return vec![sample_size; count];
    }
    let mut out = Vec::with_capacity(count);
    let mut off = 12;
    for _ in 0..count {
        if off + 4 > data.len() {
            break;
        }
        out.push(read_u32(data, off));
        off += 4;
    }
    out
}

/// 解析 senc（sample encryption）得到每个样本的 IV。
///
/// 兼容两种布局：
/// - 标准布局：每样本 = IV(iv_size) + num_subsamples(2) + subsamples(6 each)
/// - 汽水变体：每样本仅 IV(iv_size)（无子样本信息，整样本加密）
/// 通过 body 长度是否恰好等于 sample_count * iv_size 来区分。
fn parse_senc_ivs(data: &[u8], iv_size: usize) -> Result<Vec<Vec<u8>>, String> {
    if data.len() < 8 {
        return Err("senc 盒过小".to_string());
    }
    let flags = ((data[1] as u32) << 16) | ((data[2] as u32) << 8) | (data[3] as u32);
    let sample_count = read_u32(data, 4) as usize;
    let body = &data[8..];

    // 常量 IV：所有样本共用 tenc 中的 constant_iv（由调用方处理）
    if flags & 0x2 != 0 {
        return Ok(Vec::new());
    }

    if iv_size == 0 {
        return Err("senc 无 IV 且未使用常量 IV".to_string());
    }

    let mut ivs = Vec::with_capacity(sample_count);
    if body.len() == sample_count * iv_size {
        // 汽水变体：每样本仅 IV
        for i in 0..sample_count {
            ivs.push(body[i * iv_size..(i + 1) * iv_size].to_vec());
        }
    } else {
        // 标准布局
        let mut off = 0usize;
        for _ in 0..sample_count {
            if off + iv_size + 2 > body.len() {
                return Err("senc 标准布局数据不完整".to_string());
            }
            ivs.push(body[off..off + iv_size].to_vec());
            off += iv_size;
            let num_sub = read_u16(body, off) as usize;
            off += 2;
            off += num_sub * 6;
            if off > body.len() {
                return Err("senc 子样本数据越界".to_string());
            }
        }
    }
    Ok(ivs)
}

/// tenc 解析结果：每样本 IV 大小 + 可选常量 IV（per_sample_iv_size==0 时使用）。
struct TencInfo {
    iv_size: usize,
    constant_iv: Option<Vec<u8>>,
}

/// 从 enca 样本条目中解析 tenc，返回加密参数。
///
/// 样本条目结构：盒头(8) + SampleEntry 固定字段(8) + AudioSampleEntry 固定字段(20)，
/// 之后才是子盒（sinf/esds 等）。因此不能直接用 find_child_box 从 data_start 扫描，
/// 否则固定字段会被误读为盒头（reserved=0 → size=0 → 吞掉整个文件）。
/// tenc 的常规位置是 sinf > schi > tenc。
fn parse_tenc(data: &[u8], entry: &BoxInfo) -> Option<TencInfo> {
    let child_start = entry.data_start + 28;
    if child_start >= entry.data_end {
        return None;
    }
    let mut off = child_start;
    while off + 8 <= entry.data_end {
        let child = read_box_header(data, off)?;
        if child.is(b"sinf") {
            return read_tenc_from_sinf(data, &child);
        }
        off = child.data_end;
    }
    None
}

fn read_tenc_from_sinf(data: &[u8], sinf: &BoxInfo) -> Option<TencInfo> {
    // tenc 通常在 schi 内：sinf > schi > tenc
    if let Some(schi) = find_child_box(data, sinf, b"schi") {
        if let Some(tenc) = find_child_box(data, &schi, b"tenc") {
            return read_tenc(data, &tenc);
        }
    }
    // 兼容 tenc 直接位于 sinf 下
    if let Some(tenc) = find_child_box(data, sinf, b"tenc") {
        return read_tenc(data, &tenc);
    }
    None
}

fn read_tenc(data: &[u8], tenc: &BoxInfo) -> Option<TencInfo> {
    // tenc: FullBox(4) + reserved(1) + pattern(1) + isProtected(1) + per_sample_iv_size(1) + KID(16)
    if tenc.data_end - tenc.data_start < 24 {
        return None;
    }
    let is_protected = data[tenc.data_start + 6];
    let iv_size = data[tenc.data_start + 7] as usize;
    let mut constant_iv = None;
    if is_protected == 1 && iv_size == 0 {
        // 常量 IV：isProtected==1 && per_sample_iv_size==0 时，KID 后跟 constant_iv_size + constant_iv
        let base = tenc.data_start + 24;
        if base < tenc.data_end {
            let c_iv_size = data[base] as usize;
            if base + 1 + c_iv_size <= tenc.data_end {
                constant_iv = Some(data[base + 1..base + 1 + c_iv_size].to_vec());
            }
        }
    }
    Some(TencInfo {
        iv_size,
        constant_iv,
    })
}

/// 计算每个样本在文件中的绝对偏移。
fn compute_sample_offsets(
    stsc: &[(u32, u32, u32)],
    stco: &[u64],
    stsz: &[u32],
) -> Vec<u64> {
    let mut offsets = Vec::with_capacity(stsz.len());
    let mut sample_idx = 0usize;
    for (i, &(first_chunk, samples_per_chunk, _desc)) in stsc.iter().enumerate() {
        if first_chunk == 0 {
            continue;
        }
        let last_chunk = if i + 1 < stsc.len() {
            stsc[i + 1].0.saturating_sub(1)
        } else {
            stco.len() as u32
        };
        for chunk in first_chunk..=last_chunk {
            let chunk_offset = match stco.get((chunk - 1) as usize) {
                Some(&o) => o,
                None => break,
            };
            let mut offset_in_chunk = 0u64;
            for _ in 0..samples_per_chunk {
                if sample_idx >= stsz.len() {
                    break;
                }
                let size = stsz[sample_idx] as u64;
                offsets.push(chunk_offset + offset_in_chunk);
                offset_in_chunk += size;
                sample_idx += 1;
            }
        }
    }
    offsets
}

/// AES-128-CTR 解密一段数据。
/// 计数器块 = IV(前 iv_len 字节，不足补零) + 块计数器(大端，从 0 递增)。
fn aes_ctr_decrypt(cek: &[u8], iv: &[u8], data: &mut [u8]) {
    let cipher = match Aes128::new_from_slice(cek) {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut counter = [0u8; 16];
    let iv_len = iv.len().min(16);
    counter[..iv_len].copy_from_slice(&iv[..iv_len]);

    let mut pos = 0usize;
    while pos < data.len() {
        let mut keystream = GenericArray::clone_from_slice(&counter);
        cipher.encrypt_block(&mut keystream);
        let n = (data.len() - pos).min(16);
        for i in 0..n {
            data[pos + i] ^= keystream[i];
        }
        // 大端递增计数器
        for i in (0..16).rev() {
            counter[i] = counter[i].wrapping_add(1);
            if counter[i] != 0 {
                break;
            }
        }
        pos += n;
    }
}

/// 对 CENC 加密的 M4A 文件做就地解密：
/// - 解密 mdat 中所有样本（AES-128-CTR）
/// - 将 enca 样本条目类型补丁为 mp4a
///
/// 返回 true 表示检测到 CENC 并完成解密；false 表示文件不是 CENC 加密。
pub fn decrypt_cenc_in_place(data: &mut [u8], cek: &[u8]) -> Result<bool, String> {
    // 快速预检：文件头必须是 ftyp
    if data.len() < 12 || &data[4..8] != b"ftyp" {
        return Ok(false);
    }

    // 定位 moov
    let mut moov: Option<BoxInfo> = None;
    let mut off = 0usize;
    while off + 8 <= data.len() {
        if let Some(box_info) = read_box_header(data, off) {
            if box_info.is(b"moov") {
                moov = Some(box_info);
                break;
            }
            off = box_info.data_end;
        } else {
            break;
        }
    }
    let moov = match moov {
        Some(m) => m,
        None => return Ok(false),
    };

    // 遍历所有 trak，处理含 enca 样本条目的音频轨
    let mut decrypted_any = false;
    for trak in find_child_boxes(data, &moov, b"trak") {
        let mdia = match find_child_box(data, &trak, b"mdia") {
            Some(m) => m,
            None => continue,
        };
        let minf = match find_child_box(data, &mdia, b"minf") {
            Some(m) => m,
            None => continue,
        };
        let stbl = match find_child_box(data, &minf, b"stbl") {
            Some(m) => m,
            None => continue,
        };

        // stsd 中的样本条目必须是 enca
        let stsd = match find_child_box(data, &stbl, b"stsd") {
            Some(s) => s,
            None => continue,
        };
        let entry = match read_box_header(data, stsd.data_start + 8) {
            Some(e) => e,
            None => continue,
        };
        if !entry.is(b"enca") {
            continue;
        }

        // 解析加密参数
        let tenc = match parse_tenc(data, &entry) {
            Some(t) => t,
            None => return Err("CENC 加密但未找到 tenc 盒".to_string()),
        };
        if tenc.iv_size == 0 && tenc.constant_iv.is_none() {
            return Err("CENC 加密但 tenc 中 per_sample_iv_size 为 0 且无常量 IV".to_string());
        }

        // 解析样本表
        let stsc = match find_child_box(data, &stbl, b"stsc") {
            Some(b) => parse_stsc(&data[b.data_start..b.data_end]),
            None => return Err("CENC 文件缺少 stsc".to_string()),
        };
        let stco = match find_child_box(data, &stbl, b"stco") {
            Some(b) => parse_stco(&data[b.data_start..b.data_end]),
            None => match find_child_box(data, &stbl, b"co64") {
                Some(b) => parse_co64(&data[b.data_start..b.data_end]),
                None => return Err("CENC 文件缺少 stco/co64".to_string()),
            },
        };
        let stsz = match find_child_box(data, &stbl, b"stsz") {
            Some(b) => parse_stsz(&data[b.data_start..b.data_end]),
            None => return Err("CENC 文件缺少 stsz".to_string()),
        };

        // 确定每个样本的 IV：常量 IV 复用同一值，否则从 senc 读取
        let ivs: Vec<Vec<u8>> = if let Some(ref c_iv) = tenc.constant_iv {
            vec![c_iv.clone(); stsz.len()]
        } else {
            let senc = match find_child_box(data, &stbl, b"senc") {
                Some(b) => b,
                None => return Err("CENC 文件缺少 senc".to_string()),
            };
            let ivs = parse_senc_ivs(&data[senc.data_start..senc.data_end], tenc.iv_size)?;
            if ivs.len() != stsz.len() {
                return Err(format!(
                    "senc IV 数量({})与样本数量({})不一致",
                    ivs.len(),
                    stsz.len()
                ));
            }
            ivs
        };

        // 计算样本偏移并解密
        let offsets = compute_sample_offsets(&stsc, &stco, &stsz);
        if offsets.len() != stsz.len() {
            return Err(format!(
                "样本偏移计算数量({})与样本数量({})不一致",
                offsets.len(),
                stsz.len()
            ));
        }

        for (i, &offset) in offsets.iter().enumerate() {
            let size = stsz[i] as usize;
            if offset as usize + size > data.len() {
                return Err(format!("样本 {} 越界 (offset={}, size={})", i, offset, size));
            }
            aes_ctr_decrypt(cek, &ivs[i], &mut data[offset as usize..offset as usize + size]);
        }

        // 将 enca 补丁为 mp4a
        data[entry.start + 4..entry.start + 8].copy_from_slice(b"mp4a");
        decrypted_any = true;
    }

    Ok(decrypted_any)
}

// ---------------------------------------------------------------------------
// 流式 CENC 解密：当 moov 盒位于文件头部时，可在下载部分字节后即开始播放
// ---------------------------------------------------------------------------

use std::io::{Read, Seek, SeekFrom};

/// 单个加密样本的元信息（绝对文件偏移、大小、IV）
#[derive(Clone)]
pub struct CencSampleInfo {
    pub offset: u64,
    pub size: u32,
    pub iv: Vec<u8>,
}

/// 从已下载的字节片段中解析 CENC 元数据。
///
/// 若 moov 盒完整存在于 `data` 中，返回样本表 + enca 补丁偏移；
/// 若 moov 不在 `data` 范围内（位于文件尾部），返回 `Ok(None)`。
pub fn parse_cenc_metadata(data: &[u8], cek: &[u8]) -> Result<Option<CencMetadata>, String> {
    if data.len() < 12 || &data[4..8] != b"ftyp" {
        return Ok(None);
    }

    // 定位 moov（只在 data 范围内查找）
    let mut moov_box: Option<BoxInfo> = None;
    let mut off = 0usize;
    while off + 8 <= data.len() {
        if let Some(box_info) = read_box_header(data, off) {
            if box_info.is(b"moov") {
                moov_box = Some(box_info);
                break;
            }
            off = box_info.data_end;
        } else {
            break;
        }
    }
    let moov = match moov_box {
        Some(m) => m,
        None => return Ok(None), // moov 不在已下载范围内
    };

    let mut samples = Vec::new();
    let mut enca_patch_offset: Option<u64> = None;

    for trak in find_child_boxes(data, &moov, b"trak") {
        let mdia = match find_child_box(data, &trak, b"mdia") { Some(m) => m, None => continue };
        let minf = match find_child_box(data, &mdia, b"minf") { Some(m) => m, None => continue };
        let stbl = match find_child_box(data, &minf, b"stbl") { Some(m) => m, None => continue };

        let stsd = match find_child_box(data, &stbl, b"stsd") { Some(s) => s, None => continue };
        let entry = match read_box_header(data, stsd.data_start + 8) { Some(e) => e, None => continue };
        if !entry.is(b"enca") { continue; }

        let tenc = match parse_tenc(data, &entry) {
            Some(t) => t,
            None => return Err("CENC 加密但未找到 tenc 盒".to_string()),
        };
        if tenc.iv_size == 0 && tenc.constant_iv.is_none() {
            return Err("CENC tenc 中 per_sample_iv_size=0 且无常量 IV".to_string());
        }

        let stsc = match find_child_box(data, &stbl, b"stsc") {
            Some(b) => parse_stsc(&data[b.data_start..b.data_end]),
            None => return Err("CENC 文件缺少 stsc".to_string()),
        };
        let stco = match find_child_box(data, &stbl, b"stco") {
            Some(b) => parse_stco(&data[b.data_start..b.data_end]),
            None => match find_child_box(data, &stbl, b"co64") {
                Some(b) => parse_co64(&data[b.data_start..b.data_end]),
                None => return Err("CENC 文件缺少 stco/co64".to_string()),
            },
        };
        let stsz = match find_child_box(data, &stbl, b"stsz") {
            Some(b) => parse_stsz(&data[b.data_start..b.data_end]),
            None => return Err("CENC 文件缺少 stsz".to_string()),
        };

        let ivs: Vec<Vec<u8>> = if let Some(ref c_iv) = tenc.constant_iv {
            vec![c_iv.clone(); stsz.len()]
        } else {
            let senc = match find_child_box(data, &stbl, b"senc") {
                Some(b) => b,
                None => return Err("CENC 文件缺少 senc".to_string()),
            };
            parse_senc_ivs(&data[senc.data_start..senc.data_end], tenc.iv_size)?
        };

        let offsets = compute_sample_offsets(&stsc, &stco, &stsz);
        for (i, &offset) in offsets.iter().enumerate() {
            samples.push(CencSampleInfo {
                offset,
                size: stsz[i],
                iv: ivs[i].clone(),
            });
        }

        // 记录 enca 类型字段的文件偏移（用于 reader 中虚拟补丁为 mp4a）
        enca_patch_offset = Some(entry.start as u64 + 4);
    }

    if samples.is_empty() {
        return Ok(None);
    }

    let _ = cek; // CEK 在 reader 中使用，此处仅验证可解析
    Ok(Some(CencMetadata {
        samples,
        enca_patch_offset: enca_patch_offset.unwrap_or(0),
    }))
}

/// CENC 流式解密所需的元数据
#[derive(Clone)]
pub struct CencMetadata {
    /// 所有加密样本的偏移/大小/IV，按文件偏移排序
    pub samples: Vec<CencSampleInfo>,
    /// enca 类型字段在文件中的绝对偏移（reader 读取时虚拟替换为 mp4a）
    pub enca_patch_offset: u64,
}

/// 对样本内指定偏移开始的数据做 AES-CTR 解密。
///
/// `byte_offset_in_sample` 是这段数据在样本中的起始字节偏移（可能非 16 对齐）。
fn decrypt_range_in_sample(
    cek: &[u8],
    iv: &[u8],
    data: &mut [u8],
    byte_offset_in_sample: usize,
) {
    let cipher = match Aes128::new_from_slice(cek) {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut counter = [0u8; 16];
    let iv_len = iv.len().min(16);
    counter[..iv_len].copy_from_slice(&iv[..iv_len]);

    // 将计数器推进到起始块
    let start_block = byte_offset_in_sample / 16;
    for _ in 0..start_block {
        for i in (0..16).rev() {
            counter[i] = counter[i].wrapping_add(1);
            if counter[i] != 0 { break; }
        }
    }

    let skip = byte_offset_in_sample % 16;
    let mut pos = 0usize;

    // 处理首个不完整块
    if skip > 0 && pos < data.len() {
        let mut keystream = GenericArray::clone_from_slice(&counter);
        cipher.encrypt_block(&mut keystream);
        let n = (16 - skip).min(data.len());
        for i in 0..n {
            data[pos + i] ^= keystream[skip + i];
        }
        pos += n;
        for i in (0..16).rev() {
            counter[i] = counter[i].wrapping_add(1);
            if counter[i] != 0 { break; }
        }
    }

    // 解密剩余完整块
    while pos < data.len() {
        let mut keystream = GenericArray::clone_from_slice(&counter);
        cipher.encrypt_block(&mut keystream);
        let n = (data.len() - pos).min(16);
        for i in 0..n {
            data[pos + i] ^= keystream[i];
        }
        pos += n;
        for i in (0..16).rev() {
            counter[i] = counter[i].wrapping_add(1);
            if counter[i] != 0 { break; }
        }
    }
}

/// 流式 CENC 解密 Reader：包装 StreamingTempFileReader，在读取时按样本解密 + 虚拟 enca→mp4a 补丁。
///
/// 仅当 moov 盒位于文件头部（parse_cenc_metadata 成功）时可用。
/// 若 moov 在文件尾部，必须回退到整文件就地解密。
pub struct CencDecryptReader<R: Read + Seek> {
    inner: R,
    cek: Vec<u8>,
    samples: Vec<CencSampleInfo>,
    enca_patch_offset: u64,
    pos: u64,
}

impl<R: Read + Seek> CencDecryptReader<R> {
    pub fn new(inner: R, cek: Vec<u8>, metadata: CencMetadata) -> Self {
        Self {
            inner,
            cek,
            samples: metadata.samples,
            enca_patch_offset: metadata.enca_patch_offset,
            pos: 0,
        }
    }
}

impl<R: Read + Seek> Read for CencDecryptReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        if n == 0 { return Ok(0); }

        let read_start = self.pos;
        let read_end = self.pos + n as u64;

        // 虚拟 enca → mp4a 补丁：在读取到 stsd 中 enca 类型字段时替换字节
        let patch_start = self.enca_patch_offset;
        let patch_end = patch_start + 4;
        if patch_start < read_end && patch_end > read_start {
            let buf_off = patch_start.saturating_sub(read_start) as usize;
            let patch_len = (4_usize).min(n.saturating_sub(buf_off));
            let patch = b"mp4a";
            for i in 0..patch_len {
                buf[buf_off + i] = patch[i];
            }
        }

        // 解密与读取范围重叠的样本
        for sample in &self.samples {
            let sample_start = sample.offset;
            let sample_end = sample.offset + sample.size as u64;
            if sample_end <= read_start || sample_start >= read_end {
                continue;
            }
            let overlap_start = sample_start.max(read_start);
            let overlap_end = sample_end.min(read_end);
            let buf_start = (overlap_start - read_start) as usize;
            let buf_len = (overlap_end - overlap_start) as usize;
            let byte_offset_in_sample = (overlap_start - sample_start) as usize;
            decrypt_range_in_sample(
                &self.cek,
                &sample.iv,
                &mut buf[buf_start..buf_start + buf_len],
                byte_offset_in_sample,
            );
        }

        self.pos += n as u64;
        Ok(n)
    }
}

impl<R: Read + Seek> Seek for CencDecryptReader<R> {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let new_pos = self.inner.seek(pos)?;
        self.pos = new_pos;
        Ok(new_pos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cek_hex() {
        let key = cek_to_key("00112233445566778899aabbccddeeff").unwrap();
        assert_eq!(key.len(), 16);
        assert_eq!(key[0], 0x00);
        assert_eq!(key[15], 0xff);
    }

    #[test]
    fn test_cek_raw() {
        let key = cek_to_key("0123456789abcdef").unwrap();
        assert_eq!(key.len(), 16);
    }

    #[test]
    fn test_cek_invalid() {
        assert!(cek_to_key("short").is_err());
        assert!(cek_to_key("zz").is_err());
    }

    #[test]
    fn test_aes_ctr_roundtrip() {
        let cek = [0x2b; 16];
        let iv = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
        let original = b"hello world, this is a test of AES-128-CTR decryption!";
        let mut encrypted = original.to_vec();
        aes_ctr_decrypt(&cek, &iv, &mut encrypted);
        // 再解密一次应还原（CTR 是对称的）
        aes_ctr_decrypt(&cek, &iv, &mut encrypted);
        assert_eq!(&encrypted, original);
    }

    fn make_box(typ: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::with_capacity(8 + payload.len());
        v.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
        v.extend_from_slice(typ);
        v.extend_from_slice(payload);
        v
    }

    fn make_fullbox(typ: &[u8; 4], flags: u32, payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::with_capacity(12 + payload.len());
        v.extend_from_slice(&((12 + payload.len()) as u32).to_be_bytes());
        v.extend_from_slice(typ);
        v.extend_from_slice(&flags.to_be_bytes()); // version(1) + flags(3)
        v.extend_from_slice(payload);
        v
    }

    /// 构造一个最小 CENC M4A：ftyp + mdat(4 样本) + moov(enca 轨 + stsc/stco/stsz/senc)。
    /// samples 为明文样本，返回 (文件字节, 各样本绝对偏移)。
    #[allow(dead_code)]
    fn build_cenc_m4a(samples: &[Vec<u8>], ivs: &[Vec<u8>]) -> Vec<u8> {
        let ftyp = make_box(b"ftyp", &[0u8; 8]);

        let mdat_payload: Vec<u8> = samples.iter().flatten().copied().collect();
        let mdat = make_box(b"mdat", &mdat_payload);

        // 样本绝对偏移 = ftyp 末尾 + mdat 盒头(8) + 前面样本累计大小
        let mdat_data_start = ftyp.len() + 8;
        let mut chunk_offsets = Vec::new();
        let mut acc = mdat_data_start;
        for s in samples {
            chunk_offsets.push(acc as u32);
            acc += s.len();
        }

        // stsd：FullBox + 1 个 enca 样本条目
        let mut enca_payload = Vec::new();
        enca_payload.extend_from_slice(&[0u8; 8]); // SampleEntry reserved + data_reference_index
        enca_payload.extend_from_slice(&[0u8; 20]); // AudioSampleEntry 固定字段
        // sinf > schi > tenc
        let mut tenc_payload = Vec::new();
        tenc_payload.extend_from_slice(&[0u8; 4]); // FullBox version+flags
        tenc_payload.push(0); // reserved
        tenc_payload.push(0); // pattern
        tenc_payload.push(1); // isProtected
        tenc_payload.push(ivs[0].len() as u8); // per_sample_iv_size
        tenc_payload.extend_from_slice(&[0u8; 16]); // KID
        let tenc = make_box(b"tenc", &tenc_payload);
        let schi = make_box(b"schi", &tenc);
        let sinf = make_box(b"sinf", &schi);
        enca_payload.extend_from_slice(&sinf);
        let enca = make_box(b"enca", &enca_payload);

        let mut stsd_payload = Vec::new();
        stsd_payload.extend_from_slice(&1u32.to_be_bytes()); // entry_count
        stsd_payload.extend_from_slice(&enca);
        let stsd = make_fullbox(b"stsd", 0, &stsd_payload);

        // stsc：1 条记录，每 chunk 1 个样本
        let mut stsc_payload = Vec::new();
        stsc_payload.extend_from_slice(&1u32.to_be_bytes()); // entry_count
        stsc_payload.extend_from_slice(&1u32.to_be_bytes()); // first_chunk
        stsc_payload.extend_from_slice(&1u32.to_be_bytes()); // samples_per_chunk
        stsc_payload.extend_from_slice(&1u32.to_be_bytes()); // sample_description_index
        let stsc = make_fullbox(b"stsc", 0, &stsc_payload);

        // stco
        let mut stco_payload = Vec::new();
        stco_payload.extend_from_slice(&(chunk_offsets.len() as u32).to_be_bytes());
        for o in &chunk_offsets {
            stco_payload.extend_from_slice(&o.to_be_bytes());
        }
        let stco = make_fullbox(b"stco", 0, &stco_payload);

        // stsz
        let mut stsz_payload = Vec::new();
        stsz_payload.extend_from_slice(&0u32.to_be_bytes()); // sample_size=0（每样本不同）
        stsz_payload.extend_from_slice(&(samples.len() as u32).to_be_bytes());
        for s in samples {
            stsz_payload.extend_from_slice(&(s.len() as u32).to_be_bytes());
        }
        let stsz = make_fullbox(b"stsz", 0, &stsz_payload);

        // senc：每样本 IV
        let mut senc_payload = Vec::new();
        senc_payload.extend_from_slice(&(samples.len() as u32).to_be_bytes());
        for iv in ivs {
            senc_payload.extend_from_slice(iv);
        }
        let senc = make_fullbox(b"senc", 0, &senc_payload);

        let stbl = make_box(b"stbl", &[stsd, stsc, stco, stsz, senc].concat());
        let minf = make_box(b"minf", &stbl);
        let mdia = make_box(b"mdia", &minf);
        let trak = make_box(b"trak", &mdia);
        let moov = make_box(b"moov", &trak);

        [ftyp, mdat, moov].concat()
    }

    #[test]
    fn test_decrypt_cenc_full_flow() {
        let cek = [0x2b; 16];
        let ivs: Vec<Vec<u8>> = (0..4)
            .map(|i| vec![0x10 + i as u8; 8])
            .collect();
        let plain: Vec<Vec<u8>> = (0..4)
            .map(|i| vec![0x40 + i as u8; 16])
            .collect();

        // 先用 CTR 加密样本（对称），构造加密文件
        let mut encrypted_samples: Vec<Vec<u8>> = Vec::new();
        for (i, p) in plain.iter().enumerate() {
            let mut e = p.clone();
            aes_ctr_decrypt(&cek, &ivs[i], &mut e);
            encrypted_samples.push(e);
        }
        let mut file = build_cenc_m4a(&encrypted_samples, &ivs);

        // 解密前应检测到 enca
        assert!(file.windows(4).any(|w| w == b"enca"));

        let key = cek_to_key("2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b").unwrap();
        let decrypted = decrypt_cenc_in_place(&mut file, &key).unwrap();
        assert!(decrypted);

        // enca 已补丁为 mp4a
        assert!(!file.windows(4).any(|w| w == b"enca"));
        assert!(file.windows(4).any(|w| w == b"mp4a"));

        // 样本已还原为明文（ftyp 16 字节 + mdat 盒头 8 字节 = 24）
        let mdat_data_start = 24;
        for (i, p) in plain.iter().enumerate() {
            let off = mdat_data_start + i * 16;
            assert_eq!(&file[off..off + 16], p.as_slice(), "样本 {} 解密结果不符", i);
        }
    }

    #[test]
    fn test_decrypt_non_cenc_noop() {
        // 普通 mp4a（无 enca）应返回 Ok(false) 且不修改
        let mut file = make_box(b"ftyp", &[0u8; 8]);
        let mut mp4a_payload = vec![0u8; 28];
        mp4a_payload.extend_from_slice(&make_box(b"esds", &[0u8; 8]));
        let mut stsd_payload = Vec::new();
        stsd_payload.extend_from_slice(&1u32.to_be_bytes());
        stsd_payload.extend_from_slice(&make_box(b"mp4a", &mp4a_payload));
        let stsd = make_fullbox(b"stsd", 0, &stsd_payload);
        let stbl = make_box(b"stbl", &stsd);
        let minf = make_box(b"minf", &stbl);
        let mdia = make_box(b"mdia", &minf);
        let trak = make_box(b"trak", &mdia);
        let moov = make_box(b"moov", &trak);
        file.extend_from_slice(&moov);

        let before = file.clone();
        let key = cek_to_key("00112233445566778899aabbccddeeff").unwrap();
        let decrypted = decrypt_cenc_in_place(&mut file, &key).unwrap();
        assert!(!decrypted);
        assert_eq!(file, before);
    }
}