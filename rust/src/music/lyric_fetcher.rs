// lyric_fetcher.rs - 四音源歌词抓取与解密
//
// 将前端 lxLyricFetcher.ts 中的请求构造+解密逻辑迁移到 Rust。
// 支持的音源：
// - kg (酷狗): KRC 加密歌词，包含逐字时间
// - kw (酷我): XOR 加密请求 → zlib 解压 → 逐字歌词解析
// - tx (QQ音乐): QRC 3DES 解密 → 逐字歌词解析
// - wy (网易云): eapi AES-ECB 加密 → yrc/krc 逐字歌词

use base64::Engine;
use serde::{Deserialize, Serialize};

use regex::Regex;
use std::sync::OnceLock;

// ==================== Regex caches (module-level, compiled once) ====================
static KG_ID_HEADER_RE: OnceLock<Regex> = OnceLock::new();
static KG_LANGUAGE_RE: OnceLock<Regex> = OnceLock::new();
static KG_LX_TIME_RE: OnceLock<Regex> = OnceLock::new();
static KG_WORD_TAG_RE: OnceLock<Regex> = OnceLock::new();
static KG_WORD_PLAIN_RE: OnceLock<Regex> = OnceLock::new();
static KW_LRC_TIME_RE: OnceLock<Regex> = OnceLock::new();
static KW_TAG_RE: OnceLock<Regex> = OnceLock::new();
static KW_LYRICX_TAG_RE: OnceLock<Regex> = OnceLock::new();
static KW_WORD_TIME_ALL_RE: OnceLock<Regex> = OnceLock::new();
static KW_TIME_CHECK_RE: OnceLock<Regex> = OnceLock::new();
static TX_LYRIC_CONTENT_OPEN_RE: OnceLock<Regex> = OnceLock::new();
static TX_LYRIC_CONTENT_CLOSE_RE: OnceLock<Regex> = OnceLock::new();
static TX_LINE_TIME_RE: OnceLock<Regex> = OnceLock::new();
static TX_LINE_TIME2_RE: OnceLock<Regex> = OnceLock::new();
static TX_WORD_TIME_GROUP_RE: OnceLock<Regex> = OnceLock::new();
static TX_WORD_TIME_RE: OnceLock<Regex> = OnceLock::new();
static TX_WORD_EXTRACT_RE: OnceLock<Regex> = OnceLock::new();
static WY_YRC_LINE_TIME_RE: OnceLock<Regex> = OnceLock::new();
static WY_YRC_WORD_TAG_RE: OnceLock<Regex> = OnceLock::new();
static WY_YRC_CHECK_RE: OnceLock<Regex> = OnceLock::new();
static WY_FIX_TIME_RE: OnceLock<Regex> = OnceLock::new();
static WY_FIX_ROMA_TIME_RE: OnceLock<Regex> = OnceLock::new();
static WY_FIX_ROMA_TRAIL_RE: OnceLock<Regex> = OnceLock::new();

// ==================== Types ====================

/// 歌词源返回的歌曲信息，作为纯反序列化 DTO。
/// 部分字段只在特定歌词源（酷狗/腾讯/网易）分支被消费，其余随 payload 保留。
#[derive(Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
pub struct LyricSongInfo {
    pub songmid: String,
    pub hash: Option<String>,
    pub name: String,
    pub singer: String,
    pub album_name: Option<String>,
    pub interval: Option<String>,
    #[serde(rename = "_interval")]
    pub interval_ms: Option<u32>,
    pub song_id: Option<serde_json::Value>,
    pub str_media_mid: Option<String>,
    pub album_mid: Option<String>,
    pub album_id: Option<serde_json::Value>,
    pub copyright_id: Option<String>,
    pub source: Option<String>,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct LyricResult {
    pub lyric: String,
    pub tlyric: String,
    pub rlyric: String,
    pub lxlyric: String,
}

// ==================== Utility ====================

fn decode_html_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    let hex = hex.trim();
    (0..hex.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(&hex[i..i + 2], 16).ok())
        .collect()
}

fn is_valid_base64(s: &str) -> bool {
    if s.len() < 4 {
        return false;
    }
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
        && s.len() % 4 == 0
}

fn pad_base64(input: &str) -> String {
    let mut s = input.to_string();
    while s.len() % 4 != 0 {
        s.push('=');
    }
    s
}

// ==================== 3DES / QRC Decryption (QQ Music) ====================

const SBOX: [[u8; 64]; 8] = [
    [
        14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12,
        11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9,
        1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
    ],
    [
        15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1,
        10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15,
        4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
    ],
    [
        10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5,
        14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6,
        9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
    ],
    [
        7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2,
        12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10,
        10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
    ],
    [
        2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15,
        10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14,
        2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
    ],
    [
        12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13,
        14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5,
        15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
    ],
    [
        4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5,
        12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4,
        10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
    ],
    [
        13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6,
        11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10,
        8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
    ],
];

#[inline]
fn bitnum(a: &[u8], b: usize, c: u32) -> u32 {
    let index = (b / 32) * 4 + 3 - (b % 32) / 8;
    let shift = 7 - (b % 8);
    (((a[index] >> shift) & 1) as u32) << c
}

#[inline]
fn bitnum_intr(a: u32, b: u32, c: u32) -> u32 {
    ((a >> (31 - b)) & 1) << c
}

#[inline]
fn bitnum_intl(a: u32, b: u32, c: u32) -> u32 {
    ((a << b) & 0x80000000) >> c
}

#[inline]
fn sbox_bit(a: u32) -> usize {
    ((a & 32) | ((a & 31) >> 1) | ((a & 1) << 4)) as usize
}

fn initial_permutation(input: &[u8]) -> (u32, u32) {
    let s0 = bitnum(input, 57, 31)
        | bitnum(input, 49, 30)
        | bitnum(input, 41, 29)
        | bitnum(input, 33, 28)
        | bitnum(input, 25, 27)
        | bitnum(input, 17, 26)
        | bitnum(input, 9, 25)
        | bitnum(input, 1, 24)
        | bitnum(input, 59, 23)
        | bitnum(input, 51, 22)
        | bitnum(input, 43, 21)
        | bitnum(input, 35, 20)
        | bitnum(input, 27, 19)
        | bitnum(input, 19, 18)
        | bitnum(input, 11, 17)
        | bitnum(input, 3, 16)
        | bitnum(input, 61, 15)
        | bitnum(input, 53, 14)
        | bitnum(input, 45, 13)
        | bitnum(input, 37, 12)
        | bitnum(input, 29, 11)
        | bitnum(input, 21, 10)
        | bitnum(input, 13, 9)
        | bitnum(input, 5, 8)
        | bitnum(input, 63, 7)
        | bitnum(input, 55, 6)
        | bitnum(input, 47, 5)
        | bitnum(input, 39, 4)
        | bitnum(input, 31, 3)
        | bitnum(input, 23, 2)
        | bitnum(input, 15, 1)
        | bitnum(input, 7, 0);

    let s1 = bitnum(input, 56, 31)
        | bitnum(input, 48, 30)
        | bitnum(input, 40, 29)
        | bitnum(input, 32, 28)
        | bitnum(input, 24, 27)
        | bitnum(input, 16, 26)
        | bitnum(input, 8, 25)
        | bitnum(input, 0, 24)
        | bitnum(input, 58, 23)
        | bitnum(input, 50, 22)
        | bitnum(input, 42, 21)
        | bitnum(input, 34, 20)
        | bitnum(input, 26, 19)
        | bitnum(input, 18, 18)
        | bitnum(input, 10, 17)
        | bitnum(input, 2, 16)
        | bitnum(input, 60, 15)
        | bitnum(input, 52, 14)
        | bitnum(input, 44, 13)
        | bitnum(input, 36, 12)
        | bitnum(input, 28, 11)
        | bitnum(input, 20, 10)
        | bitnum(input, 12, 9)
        | bitnum(input, 4, 8)
        | bitnum(input, 62, 7)
        | bitnum(input, 54, 6)
        | bitnum(input, 46, 5)
        | bitnum(input, 38, 4)
        | bitnum(input, 30, 3)
        | bitnum(input, 22, 2)
        | bitnum(input, 14, 1)
        | bitnum(input, 6, 0);

    (s0, s1)
}

fn inverse_permutation(s0: u32, s1: u32) -> [u8; 8] {
    let mut data = [0u8; 8];
    data[3] = (bitnum_intr(s1, 7, 7)
        | bitnum_intr(s0, 7, 6)
        | bitnum_intr(s1, 15, 5)
        | bitnum_intr(s0, 15, 4)
        | bitnum_intr(s1, 23, 3)
        | bitnum_intr(s0, 23, 2)
        | bitnum_intr(s1, 31, 1)
        | bitnum_intr(s0, 31, 0)) as u8;
    data[2] = (bitnum_intr(s1, 6, 7)
        | bitnum_intr(s0, 6, 6)
        | bitnum_intr(s1, 14, 5)
        | bitnum_intr(s0, 14, 4)
        | bitnum_intr(s1, 22, 3)
        | bitnum_intr(s0, 22, 2)
        | bitnum_intr(s1, 30, 1)
        | bitnum_intr(s0, 30, 0)) as u8;
    data[1] = (bitnum_intr(s1, 5, 7)
        | bitnum_intr(s0, 5, 6)
        | bitnum_intr(s1, 13, 5)
        | bitnum_intr(s0, 13, 4)
        | bitnum_intr(s1, 21, 3)
        | bitnum_intr(s0, 21, 2)
        | bitnum_intr(s1, 29, 1)
        | bitnum_intr(s0, 29, 0)) as u8;
    data[0] = (bitnum_intr(s1, 4, 7)
        | bitnum_intr(s0, 4, 6)
        | bitnum_intr(s1, 12, 5)
        | bitnum_intr(s0, 12, 4)
        | bitnum_intr(s1, 20, 3)
        | bitnum_intr(s0, 20, 2)
        | bitnum_intr(s1, 28, 1)
        | bitnum_intr(s0, 28, 0)) as u8;
    data[7] = (bitnum_intr(s1, 3, 7)
        | bitnum_intr(s0, 3, 6)
        | bitnum_intr(s1, 11, 5)
        | bitnum_intr(s0, 11, 4)
        | bitnum_intr(s1, 19, 3)
        | bitnum_intr(s0, 19, 2)
        | bitnum_intr(s1, 27, 1)
        | bitnum_intr(s0, 27, 0)) as u8;
    data[6] = (bitnum_intr(s1, 2, 7)
        | bitnum_intr(s0, 2, 6)
        | bitnum_intr(s1, 10, 5)
        | bitnum_intr(s0, 10, 4)
        | bitnum_intr(s1, 18, 3)
        | bitnum_intr(s0, 18, 2)
        | bitnum_intr(s1, 26, 1)
        | bitnum_intr(s0, 26, 0)) as u8;
    data[5] = (bitnum_intr(s1, 1, 7)
        | bitnum_intr(s0, 1, 6)
        | bitnum_intr(s1, 9, 5)
        | bitnum_intr(s0, 9, 4)
        | bitnum_intr(s1, 17, 3)
        | bitnum_intr(s0, 17, 2)
        | bitnum_intr(s1, 25, 1)
        | bitnum_intr(s0, 25, 0)) as u8;
    data[4] = (bitnum_intr(s1, 0, 7)
        | bitnum_intr(s0, 0, 6)
        | bitnum_intr(s1, 8, 5)
        | bitnum_intr(s0, 8, 4)
        | bitnum_intr(s1, 16, 3)
        | bitnum_intr(s0, 16, 2)
        | bitnum_intr(s1, 24, 1)
        | bitnum_intr(s0, 24, 0)) as u8;
    data
}

fn des_f(state: u32, key: &[u8; 6]) -> u32 {
    let t1 = bitnum_intl(state, 31, 0)
        | ((state & 0xf0000000) >> 1)
        | bitnum_intl(state, 4, 5)
        | bitnum_intl(state, 3, 6)
        | ((state & 0x0f000000) >> 3)
        | bitnum_intl(state, 8, 11)
        | bitnum_intl(state, 7, 12)
        | ((state & 0x00f00000) >> 5)
        | bitnum_intl(state, 12, 17)
        | bitnum_intl(state, 11, 18)
        | ((state & 0x000f0000) >> 7)
        | bitnum_intl(state, 16, 23);

    let t2 = bitnum_intl(state, 15, 0)
        | ((state & 0x0000f000) << 15)
        | bitnum_intl(state, 20, 5)
        | bitnum_intl(state, 19, 6)
        | ((state & 0x00000f00) << 13)
        | bitnum_intl(state, 24, 11)
        | bitnum_intl(state, 23, 12)
        | ((state & 0x000000f0) << 11)
        | bitnum_intl(state, 28, 17)
        | bitnum_intl(state, 27, 18)
        | ((state & 0x0000000f) << 9)
        | bitnum_intl(state, 0, 23);

    let lrgstate: [u8; 6] = [
        ((t1 >> 24) & 0xff) as u8,
        ((t1 >> 16) & 0xff) as u8,
        ((t1 >> 8) & 0xff) as u8,
        ((t2 >> 24) & 0xff) as u8,
        ((t2 >> 16) & 0xff) as u8,
        ((t2 >> 8) & 0xff) as u8,
    ];

    let xor_state: [u8; 6] = [
        lrgstate[0] ^ key[0],
        lrgstate[1] ^ key[1],
        lrgstate[2] ^ key[2],
        lrgstate[3] ^ key[3],
        lrgstate[4] ^ key[4],
        lrgstate[5] ^ key[5],
    ];

    let output_state = (SBOX[0][sbox_bit((xor_state[0] >> 2) as u32)] as u32) << 28
        | (SBOX[1][sbox_bit((((xor_state[0] & 0x03) << 4) | (xor_state[1] >> 4)) as u32)] as u32)
            << 24
        | (SBOX[2][sbox_bit((((xor_state[1] & 0x0f) << 2) | (xor_state[2] >> 6)) as u32)] as u32)
            << 20
        | (SBOX[3][sbox_bit((xor_state[2] & 0x3f) as u32)] as u32) << 16
        | (SBOX[4][sbox_bit((xor_state[3] >> 2) as u32)] as u32) << 12
        | (SBOX[5][sbox_bit((((xor_state[3] & 0x03) << 4) | (xor_state[4] >> 4)) as u32)] as u32)
            << 8
        | (SBOX[6][sbox_bit((((xor_state[4] & 0x0f) << 2) | (xor_state[5] >> 6)) as u32)] as u32)
            << 4
        | SBOX[7][sbox_bit((xor_state[5] & 0x3f) as u32)] as u32;

    bitnum_intl(output_state, 15, 0)
        | bitnum_intl(output_state, 6, 1)
        | bitnum_intl(output_state, 19, 2)
        | bitnum_intl(output_state, 20, 3)
        | bitnum_intl(output_state, 28, 4)
        | bitnum_intl(output_state, 11, 5)
        | bitnum_intl(output_state, 27, 6)
        | bitnum_intl(output_state, 16, 7)
        | bitnum_intl(output_state, 0, 8)
        | bitnum_intl(output_state, 14, 9)
        | bitnum_intl(output_state, 22, 10)
        | bitnum_intl(output_state, 25, 11)
        | bitnum_intl(output_state, 4, 12)
        | bitnum_intl(output_state, 17, 13)
        | bitnum_intl(output_state, 30, 14)
        | bitnum_intl(output_state, 9, 15)
        | bitnum_intl(output_state, 1, 16)
        | bitnum_intl(output_state, 7, 17)
        | bitnum_intl(output_state, 23, 18)
        | bitnum_intl(output_state, 13, 19)
        | bitnum_intl(output_state, 31, 20)
        | bitnum_intl(output_state, 26, 21)
        | bitnum_intl(output_state, 2, 22)
        | bitnum_intl(output_state, 8, 23)
        | bitnum_intl(output_state, 18, 24)
        | bitnum_intl(output_state, 12, 25)
        | bitnum_intl(output_state, 29, 26)
        | bitnum_intl(output_state, 5, 27)
        | bitnum_intl(output_state, 21, 28)
        | bitnum_intl(output_state, 10, 29)
        | bitnum_intl(output_state, 3, 30)
        | bitnum_intl(output_state, 24, 31)
}

fn des_crypt(input: &[u8], key: &[[u8; 6]; 16]) -> [u8; 8] {
    let (mut s0, mut s1) = initial_permutation(input);
    for idx in 0..15 {
        let prev_s1 = s1;
        s1 = des_f(s1, &key[idx]) ^ s0;
        s0 = prev_s1;
    }
    s0 = des_f(s1, &key[15]) ^ s0;
    inverse_permutation(s0, s1)
}

fn des_key_schedule(key: &[u8], mode: u32) -> [[u8; 6]; 16] {
    let mut schedule = [[0u8; 6]; 16];
    let key_rnd_shift = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
    let key_perm_c = [
        56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2,
        59, 51, 43, 35,
    ];
    let key_perm_d = [
        62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12,
        4, 27, 19, 11, 3,
    ];
    let key_compression = [
        13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40,
        51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
    ];

    let mut c: u32 = 0;
    for i in 0..28 {
        c |= bitnum(key, key_perm_c[i], 31 - i as u32);
    }
    let mut d: u32 = 0;
    for i in 0..28 {
        d |= bitnum(key, key_perm_d[i], 31 - i as u32);
    }

    for i in 0..16 {
        let shift = key_rnd_shift[i];
        c = ((c << shift) | (c >> (28 - shift))) & 0x0fffffff;
        d = ((d << shift) | (d >> (28 - shift))) & 0x0fffffff;
        let togen = if mode == 0 { 15 - i } else { i };
        for j in 0..6 {
            schedule[togen][j] = 0;
        }
        for j in 0..24 {
            schedule[togen][j / 8] |=
                (bitnum_intr(c, key_compression[j], 7 - (j % 8) as u32)) as u8;
        }
        for j in 24..48 {
            schedule[togen][j / 8] |=
                (bitnum_intr(d, key_compression[j] - 27, 7 - (j % 8) as u32)) as u8;
        }
    }
    schedule
}

type DesSchedule = [[u8; 6]; 16];

fn triple_des_key_setup(key: &[u8], mode: u32) -> [DesSchedule; 3] {
    let key0 = &key[0..8];
    let key8 = &key[8..16];
    let key16 = &key[16..24];
    if mode == 1 {
        [
            des_key_schedule(key0, 1),
            des_key_schedule(key8, 0),
            des_key_schedule(key16, 1),
        ]
    } else {
        [
            des_key_schedule(key16, 0),
            des_key_schedule(key8, 1),
            des_key_schedule(key0, 0),
        ]
    }
}

fn triple_des_crypt(data: &[u8], key_schedule: &[DesSchedule; 3]) -> [u8; 8] {
    let mut temp = [0u8; 8];
    temp.copy_from_slice(&data[0..8]);
    for i in 0..3 {
        temp = des_crypt(&temp, &key_schedule[i]);
    }
    temp
}

fn qrc_decrypt(encrypted_hex: &str) -> Result<String, String> {
    let encrypted_bytes = hex_to_bytes(encrypted_hex);
    if encrypted_bytes.is_empty() {
        return Err("No data to decrypt".to_string());
    }
    let qrc_key = b"!@#)(*$%123ZXC!@!@#)(NHL";
    let schedule = triple_des_key_setup(qrc_key, 0);

    let mut decrypted_bytes = vec![0u8; encrypted_bytes.len()];
    let mut i = 0;
    while i < encrypted_bytes.len() {
        let block_len = std::cmp::min(8, encrypted_bytes.len() - i);
        let mut block = [0u8; 8];
        block[..block_len].copy_from_slice(&encrypted_bytes[i..i + block_len]);
        let decrypted = triple_des_crypt(&block, &schedule);
        decrypted_bytes[i..i + block_len].copy_from_slice(&decrypted[..block_len]);
        i += 8;
    }

    decompress_deflate_to_string(&decrypted_bytes)
}

// ==================== Deflate/Zlib Decompression ====================

fn decompress_deflate_to_string(bytes: &[u8]) -> Result<String, String> {
    use flate2::read::DeflateDecoder;
    use std::io::Read;
    let mut decoder = DeflateDecoder::new(bytes);
    let mut result = String::new();
    decoder
        .read_to_string(&mut result)
        .map_err(|e| e.to_string())?;
    Ok(result)
}

fn decompress_deflate_to_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::read::DeflateDecoder;
    use std::io::Read;
    let mut decoder = DeflateDecoder::new(bytes);
    let mut result = Vec::new();
    decoder
        .read_to_end(&mut result)
        .map_err(|e| e.to_string())?;
    Ok(result)
}

fn decompress_zlib_to_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::read::ZlibDecoder;
    use std::io::Read;
    let mut decoder = ZlibDecoder::new(bytes);
    let mut result = Vec::new();
    decoder
        .read_to_end(&mut result)
        .map_err(|e| e.to_string())?;
    Ok(result)
}

fn decompress_zlib_to_bytes_skip_header(bytes: &[u8]) -> Result<Vec<u8>, String> {
    // Try normal zlib first
    if let Ok(result) = decompress_zlib_to_bytes(bytes) {
        return Ok(result);
    }
    // Try skipping 2-byte zlib header
    if bytes.len() > 2 {
        if let Ok(result) = decompress_zlib_to_bytes(&bytes[2..]) {
            return Ok(result);
        }
    }
    Err("zlib decompression failed".to_string())
}

fn decompress_gzip_to_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::read::GzDecoder;
    use std::io::Read;
    let mut decoder = GzDecoder::new(bytes);
    let mut result = Vec::new();
    decoder
        .read_to_end(&mut result)
        .map_err(|e| e.to_string())?;
    Ok(result)
}

fn bytes_to_lossy_string(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes).unwrap_or_else(|e| {
        let bytes = e.into_bytes();
        String::from_utf8_lossy(&bytes).into_owned()
    })
}

// ==================== KRC Decryption (Kugou) ====================

const KG_KRC_KEY: [u8; 16] = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

fn decode_kg_krc(base64_data: &str) -> Result<String, String> {
    let b64 = pad_base64(base64_data);
    let buf = base64::engine::general_purpose::STANDARD
        .decode(&b64)
        .map_err(|e| e.to_string())?;
    if buf.len() <= 4 {
        return Err("KRC data too short".to_string());
    }
    let mut data = buf[4..].to_vec();
    for i in 0..data.len() {
        data[i] ^= KG_KRC_KEY[i % 16];
    }

    let mut errors: Vec<String> = Vec::new();
    for (name, attempt) in [
        ("raw deflate", decompress_deflate_to_bytes(&data)),
        ("zlib", decompress_zlib_to_bytes(&data)),
        ("zlib/skip-header", decompress_zlib_to_bytes_skip_header(&data)),
        ("gzip", decompress_gzip_to_bytes(&data)),
    ] {
        match attempt {
            Ok(bytes) if !bytes.is_empty() => return Ok(bytes_to_lossy_string(bytes)),
            Ok(_) => errors.push(format!("{name}: empty")),
            Err(error) => errors.push(format!("{name}: {error}")),
        }
    }

    Err(format!("KRC 解压失败: {}", errors.join(" | ")))
}

// ==================== KW Lyric Encryption/Decryption (Kuwo) ====================

const KW_BUF_KEY: &[u8] = b"yeelion";

fn kw_build_params(id: &str, is_get_lyricx: bool) -> String {
    let mut params = format!(
        "user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_{}",
        id
    );
    if is_get_lyricx {
        params.push_str("&lrcx=1");
    }
    let mut output = vec![0u8; params.len()];
    let mut i = 0;
    while i < params.len() {
        let mut j = 0;
        while j < KW_BUF_KEY.len() && i < params.len() {
            output[i] = KW_BUF_KEY[j] ^ params.as_bytes()[i];
            i += 1;
            j += 1;
        }
    }
    base64::engine::general_purpose::STANDARD.encode(&output)
}

fn decode_kw_lyric(body_base64: &str) -> Result<String, String> {
    let b64 = pad_base64(body_base64);
    let buf = base64::engine::general_purpose::STANDARD
        .decode(&b64)
        .map_err(|e| e.to_string())?;
    if buf.is_empty() {
        return Ok(String::new());
    }

    // Split header and binary data: find \r\n\r\n or \n\n
    let mut binary_start = None;
    for i in 0..buf.len().saturating_sub(3) {
        if buf[i] == 0x0d && buf[i + 1] == 0x0a && buf[i + 2] == 0x0d && buf[i + 3] == 0x0a {
            binary_start = Some(i + 4);
            break;
        }
    }
    if binary_start.is_none() {
        for i in 0..buf.len().saturating_sub(1) {
            if buf[i] == 0x0a && buf[i + 1] == 0x0a {
                binary_start = Some(i + 2);
                break;
            }
        }
    }
    let start = binary_start.ok_or("No header delimiter found")?;
    if start >= buf.len() {
        return Ok(String::new());
    }
    let binary_data = &buf[start..];

    // zlib decompress
    let lrc_data = decompress_zlib_to_bytes_skip_header(binary_data)?;
    if lrc_data.is_empty() {
        return Ok(String::new());
    }

    // Check if plain LRC (starts with '[')
    if lrc_data[0] == 0x5b {
        return Ok(encoding_rs::GB18030.decode(&lrc_data).0.into_owned());
    }

    // Otherwise it's base64-encoded XOR encrypted data
    let lrc_str = String::from_utf8_lossy(&lrc_data);
    let lrc_trimmed = lrc_str.trim();
    if !is_valid_base64(lrc_trimmed) {
        return Ok(String::new());
    }
    let buf_str = base64::engine::general_purpose::STANDARD
        .decode(lrc_trimmed)
        .map_err(|e| e.to_string())?;
    let mut output = vec![0u8; buf_str.len()];
    let mut i = 0;
    while i < buf_str.len() {
        let mut j = 0;
        while j < KW_BUF_KEY.len() && i < buf_str.len() {
            output[i] = KW_BUF_KEY[j] ^ buf_str[i];
            i += 1;
            j += 1;
        }
    }
    Ok(encoding_rs::GB18030.decode(&output).0.into_owned())
}

// ==================== WY eapi Encryption (NetEase) ====================

const WY_EAPI_KEY: &[u8] = b"e82ckenh8dichen8";

fn wy_eapi_encrypt(url: &str, data: &str) -> Result<String, String> {
    use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
    let message = format!("nobody{}use{}md5forencrypt", url, data);
    let digest = md5::compute(message.as_bytes());
    let digest_hex = format!("{:x}", digest);
    let data_str = format!("{}-36cd479b6b5-{}-36cd479b6b5-{}", url, data, digest_hex);

    // AES-ECB encrypt
    let key = GenericArray::from_slice(WY_EAPI_KEY);
    let cipher = aes::Aes128::new(key);

    // PKCS7 pad
    let data_bytes = data_str.as_bytes();
    let pad_len = 16 - (data_bytes.len() % 16);
    let mut padded = data_bytes.to_vec();
    padded.extend(vec![pad_len as u8; pad_len]);

    let mut encrypted = Vec::new();
    for chunk in padded.chunks(16) {
        let mut block = GenericArray::from_slice(chunk).clone();
        cipher.encrypt_block(&mut block);
        encrypted.extend_from_slice(&block);
    }

    let hex_str: String = encrypted.iter().map(|b| format!("{:02X}", b)).collect();
    Ok(hex_str)
}

// ==================== HTTP Fetching ====================

struct HttpResponse {
    status: u16,
    body: String,
    body_bytes: Vec<u8>,
}

async fn http_fetch_text(
    url: &str,
    method: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Result<HttpResponse, String> {
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = match method {
        "POST" => client.post(url),
        _ => client.get(url),
    };

    for (key, value) in headers {
        req = req.header(*key, *value);
    }

    if let Some(body) = body {
        req = req.body(body.to_string());
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body_bytes = resp.bytes().await.map_err(|e| e.to_string())?.to_vec();
    let body = String::from_utf8_lossy(&body_bytes).into_owned();

    Ok(HttpResponse {
        status,
        body,
        body_bytes,
    })
}

async fn http_fetch_binary(
    url: &str,
    method: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Result<HttpResponse, String> {
    http_fetch_text(url, method, headers, body).await
}

// ==================== KG (Kugou) Lyric Fetching ====================

fn kg_parse_lyric(str_in: &str) -> LyricResult {
    let str_in = str_in.replace('\r', "");
    let s = if let Some(stripped) =
        str_in.strip_prefix(|c: char| c.is_ascii() && !c.is_alphanumeric())
    {
        // Remove [id:$...] header
        let re = KG_ID_HEADER_RE.get_or_init(|| Regex::new(r"^.*\[id:\$\w+\]\n").unwrap());
        re.replace(stripped, "").to_string()
    } else {
        let re = KG_ID_HEADER_RE.get_or_init(|| Regex::new(r"^.*\[id:\$\w+\]\n").unwrap());
        re.replace(&str_in, "").to_string()
    };

    let mut result = LyricResult::default();

    // Extract translation
    let trans_re = KG_LANGUAGE_RE.get_or_init(|| Regex::new(r"\[language:([\w=\\/+]+)\]").unwrap());
    let mut work_str = s.clone();
    if let Some(caps) = trans_re.captures(&s) {
        let encoded = &caps[1];
        work_str = trans_re.replace(&s, "").to_string();
        if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(pad_base64(encoded)) {
            if let Ok(json) = serde_json::from_slice::<serde_json::Value>(&decoded) {
                if let Some(content) = json.get("content").and_then(|v| v.as_array()) {
                    let mut rlyric_lines: Vec<String> = Vec::new();
                    let mut tlyric_lines: Vec<String> = Vec::new();
                    for item in content {
                        match item.get("type").and_then(|v| v.as_i64()) {
                            Some(0) => {
                                if let Some(lc) =
                                    item.get("lyricContent").and_then(|v| v.as_array())
                                {
                                    for line in lc {
                                        if let Some(arr) = line.as_array() {
                                            rlyric_lines.push(
                                                arr.iter()
                                                    .filter_map(|v| v.as_str().map(String::from))
                                                    .collect::<Vec<_>>()
                                                    .join(""),
                                            );
                                        }
                                    }
                                }
                            }
                            Some(1) => {
                                if let Some(lc) =
                                    item.get("lyricContent").and_then(|v| v.as_array())
                                {
                                    for line in lc {
                                        if let Some(arr) = line.as_array() {
                                            tlyric_lines.push(
                                                arr.iter()
                                                    .filter_map(|v| v.as_str().map(String::from))
                                                    .collect::<Vec<_>>()
                                                    .join(""),
                                            );
                                        }
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    result.rlyric = decode_html_entities(&rlyric_lines.join("\n"));
                    result.tlyric = decode_html_entities(&tlyric_lines.join("\n"));
                }
            }
        }
    }

    // Parse lxlyric from [time,duration] format
    let time_re = KG_LX_TIME_RE.get_or_init(|| Regex::new(r"\[(\d+),(\d+)\]").unwrap());
    let word_tag_re = KG_WORD_TAG_RE.get_or_init(|| Regex::new(r"<(\d+,\d+),\d+>").unwrap());

    let mut lxlyric = work_str.clone();
    let mut line_idx = 0;
    let mut rlyric_arr: Vec<String> = if result.rlyric.is_empty() {
        Vec::new()
    } else {
        result.rlyric.split('\n').map(String::from).collect()
    };
    let mut tlyric_arr: Vec<String> = if result.tlyric.is_empty() {
        Vec::new()
    } else {
        result.tlyric.split('\n').map(String::from).collect()
    };

    lxlyric = time_re
        .replace_all(&lxlyric, |caps: &regex::Captures| {
            let time: u64 = caps[1].parse().unwrap_or(0);
            let ms = time % 1000;
            let secs = time / 1000;
            let m = (secs / 60).to_string();
            let s = (secs % 60).to_string();
            let time_str = format!("{:0>2}:{:0>2}.{:0>3}", m, s, ms);

            if line_idx < rlyric_arr.len() {
                rlyric_arr[line_idx] = format!("[{}]{}", time_str, rlyric_arr[line_idx]);
            }
            if line_idx < tlyric_arr.len() {
                tlyric_arr[line_idx] = format!("[{}]{}", time_str, tlyric_arr[line_idx]);
            }
            line_idx += 1;
            format!("[{}]", time_str)
        })
        .to_string();

    if !rlyric_arr.is_empty() {
        result.rlyric = decode_html_entities(&rlyric_arr.join("\n"));
    }
    if !tlyric_arr.is_empty() {
        result.tlyric = decode_html_entities(&tlyric_arr.join("\n"));
    }

    // Simplify word tags: <offset,duration,extra> → <offset,duration>
    lxlyric = word_tag_re.replace_all(&lxlyric, "<$1>").to_string();
    lxlyric = decode_html_entities(&lxlyric);

    // Generate plain lyric by removing word tags
    let word_re = KG_WORD_PLAIN_RE.get_or_init(|| Regex::new(r"<\d+,\d+>").unwrap());
    result.lyric = word_re.replace_all(&lxlyric, "").to_string();
    result.lxlyric = lxlyric;

    result
}

fn kg_get_intv(interval: &str) -> u32 {
    if interval.is_empty() {
        return 0;
    }
    let mut intv: u32 = 0;
    let mut unit: u32 = 1;
    for part in interval.split(':').rev() {
        intv += part.parse::<u32>().unwrap_or(0) * unit;
        unit *= 60;
    }
    intv
}

async fn fetch_kg_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let name = &song_info.name;
    let hash = song_info.hash.as_deref().unwrap_or(&song_info.songmid);
    let time = song_info
        .interval_ms
        .unwrap_or_else(|| kg_get_intv(song_info.interval.as_deref().unwrap_or("")) * 1000);

    let search_url = format!(
        "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword={}&hash={}&timelength={}&lrctxt=1",
        urlencoding::encode(name),
        hash,
        time
    );

    let resp = http_fetch_text(
        &search_url,
        "GET",
        &[
            ("KG-RC", "1"),
            ("KG-THash", "expand_search_manager.cpp:852736169:451"),
            ("User-Agent", "KuGou2012-9020-ExpandSearchManager"),
        ],
        None,
    )
    .await?;

    if resp.status != 200 {
        return Ok(None);
    }

    let search_body: serde_json::Value =
        serde_json::from_str(&resp.body).map_err(|e| e.to_string())?;
    let candidates = search_body
        .get("candidates")
        .and_then(|v| v.as_array())
        .ok_or("No candidates")?;
    if candidates.is_empty() {
        return Ok(None);
    }

    async fn download_kg_lyric_content(
        id_value: &str,
        accesskey: &str,
        fmt: &str,
    ) -> Result<Option<(String, String)>, String> {
        let download_url = format!(
            "http://lyrics.kugou.com/download?ver=1&client=pc&id={}&accesskey={}&fmt={}&charset=utf8",
            id_value,
            accesskey,
            fmt
        );
        let resp = http_fetch_text(
            &download_url,
            "GET",
            &[
                ("KG-RC", "1"),
                ("KG-THash", "expand_search_manager.cpp:852736169:451"),
                ("User-Agent", "KuGou2012-9020-ExpandSearchManager"),
            ],
            None,
        )
        .await?;

        if resp.status != 200 {
            return Ok(None);
        }

        let download_body: serde_json::Value =
            serde_json::from_str(&resp.body).map_err(|e| e.to_string())?;
        let dl_fmt = download_body
            .get("fmt")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let content = download_body
            .get("content")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        if content.trim().is_empty() {
            return Ok(None);
        }
        Ok(Some((dl_fmt, content)))
    }

    fn parse_kg_lrc_content(content: &str) -> Result<LyricResult, String> {
        let b64 = pad_base64(content);
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&b64)
            .map_err(|e| e.to_string())?;
        let lyric = String::from_utf8_lossy(&decoded).into_owned();
        Ok(LyricResult {
            lyric: decode_html_entities(&lyric),
            ..Default::default()
        })
    }

    let mut last_error: Option<String> = None;
    for info in candidates {
        let krctype = info.get("krctype").and_then(|v| v.as_i64()).unwrap_or(0);
        let contenttype = info
            .get("contenttype")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let fmt = if krctype == 1 && contenttype != 1 {
            "krc"
        } else {
            "lrc"
        };

        let id_value = info
            .get("id")
            .and_then(|v| {
                if let Some(s) = v.as_str() {
                    Some(s.to_string())
                } else {
                    v.as_i64().map(|n| n.to_string())
                }
            })
            .unwrap_or_default();
        let accesskey = info.get("accesskey").and_then(|v| v.as_str()).unwrap_or("");
        if id_value.is_empty() || accesskey.is_empty() {
            continue;
        }

        let downloaded = match download_kg_lyric_content(&id_value, accesskey, fmt).await {
            Ok(value) => value,
            Err(error) => {
                last_error = Some(error);
                continue;
            }
        };
        let Some((dl_fmt, content)) = downloaded else {
            continue;
        };

        if dl_fmt == "krc" {
            match decode_kg_krc(&content) {
                Ok(decoded) => return Ok(Some(kg_parse_lyric(&decoded))),
                Err(error) => {
                    last_error = Some(error);
                    if let Some((fallback_fmt, fallback_content)) =
                        download_kg_lyric_content(&id_value, accesskey, "lrc").await?
                    {
                        if fallback_fmt == "lrc" {
                            match parse_kg_lrc_content(&fallback_content) {
                                Ok(result) => return Ok(Some(result)),
                                Err(error) => {
                                    last_error = Some(error);
                                }
                            }
                        }
                    }
                }
            }
        } else if dl_fmt == "lrc" {
            match parse_kg_lrc_content(&content) {
                Ok(result) => return Ok(Some(result)),
                Err(error) => {
                    last_error = Some(error);
                }
            }
        }
    }

    if let Some(_error) = last_error {}
    Ok(None)
}

// ==================== KW (Kuwo) Lyric Fetching ====================

fn ms_format(time_ms: u64) -> String {
    let ms = time_ms % 1000;
    let total_secs = time_ms / 1000;
    let m = total_secs / 60;
    let s = total_secs % 60;
    format!("[{:0>2}:{:0>2}.{:0>3}]", m, s, ms)
}

fn kw_parse_lrc(lrc: &str) -> Result<LyricResult, String> {
    let time_re = KW_LRC_TIME_RE.get_or_init(|| Regex::new(r"^\[([\d:.]*)]").unwrap());
    let tag_re =
        KW_TAG_RE.get_or_init(|| Regex::new(r"\[(ver|ti|ar|al|offset|by|kuwo):\s*(\S+(?:\s+\S+)*)\s*]").unwrap());
    let lyricx_tag_re = KW_LYRICX_TAG_RE.get_or_init(|| Regex::new(r"^<-?\d+,-?\d+>").unwrap());

    let mut tags: Vec<String> = Vec::new();
    let mut lrc_arr: Vec<(String, String)> = Vec::new(); // (time, text)

    for line in lrc.split(|c| c == '\r' || c == '\n') {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(caps) = time_re.captures(line) {
            let time = caps[1].to_string();
            let text = time_re.replace(line, "").trim().to_string();
            let mut fixed_time = time.clone();
            // Pad to 3 decimal digits
            if fixed_time.matches('.').count() == 1 {
                let parts: Vec<&str> = fixed_time.split('.').collect();
                if parts.len() == 2 && parts[1].len() == 2 {
                    fixed_time = format!("{}.{}0", parts[0], parts[1]);
                }
            }
            lrc_arr.push((fixed_time, text));
        } else if tag_re.is_match(line) {
            tags.push(line.to_string());
        }
    }

    // Sort and split into lrc and lrcT
    let mut lrc_set = std::collections::HashSet::new();
    let mut lrc: Vec<(String, String)> = Vec::new();
    let mut lrc_t: Vec<(String, String)> = Vec::new();
    let mut is_lyricx = false;

    for item in &lrc_arr {
        if lrc_set.contains(&item.0) {
            if lrc.len() < 2 {
                continue;
            }
            let t_item = lrc.pop().ok_or("lrc pop failed".to_string())?;
            let t_time = if lrc.is_empty() {
                t_item.0.clone()
            } else {
                lrc[lrc.len() - 1].0.clone()
            };
            lrc_t.push((t_time, t_item.1));
            lrc.push(item.clone());
        } else {
            lrc.push(item.clone());
            lrc_set.insert(item.0.clone());
        }
        if !is_lyricx && lyricx_tag_re.is_match(&item.1) {
            is_lyricx = true;
        }
    }

    if !is_lyricx && lrc_t.len() as f64 > lrc.len() as f64 * 0.3 && lrc.len() > lrc_t.len() + 6 {
        return Err("failed".to_string());
    }

    let transform = |tags: &[String], lrclist: &[(String, String)]| -> String {
        let mut result = tags.join("\n");
        result.push('\n');
        if lrclist.is_empty() {
            result.push_str("暂无歌词");
        } else {
            for l in lrclist {
                result.push_str(&format!("[{}]{}\n", l.0, l.1));
            }
        }
        result
    };

    let lyric = decode_html_entities(&transform(&tags, &lrc));
    let tlyric = if !lrc_t.is_empty() {
        decode_html_entities(&transform(&tags, &lrc_t))
    } else {
        String::new()
    };

    Ok(LyricResult {
        lyric,
        tlyric,
        rlyric: String::new(),
        lxlyric: String::new(),
    })
}

async fn fetch_kw_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let url = format!(
        "http://newlyric.kuwo.cn/newlyric.lrc?{}",
        kw_build_params(&song_info.songmid, true)
    );

    let resp = http_fetch_binary(
        &url,
        "GET",
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
            ("Referer", "http://www.kuwo.cn/"),
            ("Accept", "*/*"),
        ],
        None,
    )
    .await?;

    if resp.status != 200 {
        return Ok(None);
    }

    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&resp.body_bytes);
    let decoded = decode_kw_lyric(&body_b64)?;

    let mut lrc_info = match kw_parse_lrc(&decoded) {
        Ok(info) => info,
        Err(_) => return Ok(None),
    };

    let word_time_re = KW_WORD_TIME_ALL_RE.get_or_init(|| Regex::new(r"<(-?\d+),(-?\d+)(?:,-?\d+)?>").unwrap());
    if !lrc_info.tlyric.is_empty() {
        lrc_info.tlyric = word_time_re.replace_all(&lrc_info.tlyric, "").to_string();
    }

    // 与酷狗(kg)处理方式一致：后端直接输出原始歌词（含 [kuwo:] 标签和 <a,b> 加密标签），
    // 前端 convertLxLyricToEnhancedLrc 检测到 [kuwo:] 标签后会对全文统一使用酷我公式解析。
    // 不再在 Rust 侧用 kw_parse_lxlyric 转换，避免转换 bug 导致逐字行丢失。
    if word_time_re.is_match(&lrc_info.lyric) {
        lrc_info.lxlyric = lrc_info.lyric.clone();
    }

    lrc_info.lyric = word_time_re.replace_all(&lrc_info.lyric, "").to_string();

    // Validate lyric has time tags
    let time_check = KW_TIME_CHECK_RE.get_or_init(|| Regex::new(r"\[\d{1,2}:.*\d{1,4}]").unwrap());
    if !time_check.is_match(&lrc_info.lyric) {
        return Ok(None);
    }

    Ok(Some(lrc_info))
}

// ==================== TX (QQ Music) Lyric Fetching ====================

fn tx_remove_tag(s: &str) -> String {
    let re1 = TX_LYRIC_CONTENT_OPEN_RE.get_or_init(|| Regex::new(r#"^[\S\s]*?LyricContent=""#).unwrap());
    let re2 = TX_LYRIC_CONTENT_CLOSE_RE.get_or_init(|| Regex::new(r#""/>[\S\s]*$"#).unwrap());
    re2.replace_all(&re1.replace_all(s, ""), "").to_string()
}

fn tx_parse_lyric(lrc: &str) -> (String, String) {
    let lrc = lrc.trim().replace('\r', "");
    if lrc.is_empty() {
        return (String::new(), String::new());
    }

    let line_time_re = TX_LINE_TIME_RE.get_or_init(|| Regex::new(r"^\[(\d+),\d+]").unwrap());
    let line_time2_re = TX_LINE_TIME2_RE.get_or_init(|| Regex::new(r"^\[([\d:.]+)]").unwrap());
    let word_time_all_re = TX_WORD_TIME_GROUP_RE.get_or_init(|| Regex::new(r"(\(\d+,\d+\))").unwrap());
    let word_time_re = TX_WORD_TIME_RE.get_or_init(|| Regex::new(r"\(\d+,\d+\)").unwrap());
    let word_extract_re = TX_WORD_EXTRACT_RE.get_or_init(|| Regex::new(r"\((\d+),(\d+)\)").unwrap());

    let mut lxlrc_lines: Vec<String> = Vec::new();
    let mut lrc_lines: Vec<String> = Vec::new();

    for raw_line in lrc.split('\n') {
        let line = raw_line.trim();
        if let Some(caps) = line_time_re.captures(line) {
            let start_ms: u64 = caps[1].parse().unwrap_or(0);
            let start_str = ms_format(start_ms);
            if start_str.is_empty() {
                continue;
            }
            let words = line_time_re.replace(line, "");
            lrc_lines.push(format!(
                "{}{}",
                start_str,
                word_time_all_re.replace_all(&words, "")
            ));

            let times: Vec<String> = word_time_all_re
                .captures_iter(&words)
                .filter_map(|c| {
                    let inner = &c[0];
                    if let Some(m) = word_extract_re.captures(inner) {
                        let t1: u64 = m[1].parse().unwrap_or(0);
                        let t2: u64 = m[2].parse().unwrap_or(0);
                        Some(format!(
                            "<{},{}>",
                            std::cmp::max(t1 as i64 - start_ms as i64, 0) as u64,
                            t2
                        ))
                    } else {
                        None
                    }
                })
                .collect();

            if times.is_empty() {
                continue;
            }

            let word_arr: Vec<&str> = word_time_re.split(&words).collect();
            let mut new_words = String::new();
            for (i, time) in times.iter().enumerate() {
                new_words.push_str(time);
                if i < word_arr.len() {
                    new_words.push_str(word_arr[i]);
                }
            }
            lxlrc_lines.push(format!("{}{}", start_str, new_words));
        } else {
            if line.starts_with("[offset") {
                lxlrc_lines.push(line.to_string());
                lrc_lines.push(line.to_string());
            }
            if line_time2_re.is_match(line) {
                lrc_lines.push(line.to_string());
            }
        }
    }

    (lrc_lines.join("\n"), lxlrc_lines.join("\n"))
}

fn tx_parse_rlyric(lrc: &str) -> String {
    let lrc = lrc.trim().replace('\r', "");
    if lrc.is_empty() {
        return String::new();
    }

    let line_time_re = TX_LINE_TIME_RE.get_or_init(|| Regex::new(r"^\[(\d+),\d+]").unwrap());
    let word_time_all_re = TX_WORD_TIME_RE.get_or_init(|| Regex::new(r"\(\d+,\d+\)").unwrap());
    let mut lrc_lines: Vec<String> = Vec::new();

    for raw_line in lrc.split('\n') {
        let line = raw_line.trim();
        if let Some(caps) = line_time_re.captures(line) {
            let start_ms: u64 = caps[1].parse().unwrap_or(0);
            let start_str = ms_format(start_ms);
            if start_str.is_empty() {
                continue;
            }
            let words = line_time_re.replace(line, "");
            lrc_lines.push(format!(
                "{}{}",
                start_str,
                word_time_all_re.replace_all(&words, "")
            ));
        }
    }

    lrc_lines.join("\n")
}

fn tx_get_intv(interval: &str) -> u64 {
    if interval.is_empty() {
        return 0;
    }
    let mut interval = interval.to_string();
    if !interval.contains('.') {
        interval.push_str(".0");
    }
    let arr: Vec<&str> = interval.split(|c| c == ':' || c == '.').collect();
    let mut arr = arr.to_vec();
    while arr.len() < 3 {
        arr.insert(0, "0");
    }
    let m: u64 = arr[0].parse().unwrap_or(0);
    let s: u64 = arr[1].parse().unwrap_or(0);
    let ms: u64 = arr[2].parse().unwrap_or(0);
    m * 3600000 + s * 1000 + ms
}

fn tx_fix_rlrc_time_tag(rlrc: &str, lrc: &str) -> String {
    let line_time2_re = TX_LINE_TIME2_RE.get_or_init(|| Regex::new(r"^\[([\d:.]+)]").unwrap());
    let rlrc_lines: Vec<&str> = rlrc.split('\n').collect();
    let mut lrc_lines: Vec<&str> = lrc.split('\n').collect();
    let mut new_lrc: Vec<String> = Vec::new();

    for line in &rlrc_lines {
        if let Some(caps) = line_time2_re.captures(line) {
            let words = line_time2_re.replace(line, "");
            if words.trim().is_empty() {
                continue;
            }
            let t1 = tx_get_intv(&caps[1]);
            while !lrc_lines.is_empty() {
                let lrc_line = lrc_lines.remove(0);
                if let Some(lrc_caps) = line_time2_re.captures(lrc_line) {
                    let t2 = tx_get_intv(&lrc_caps[1]);
                    if ((t1 as i64) - (t2 as i64)).unsigned_abs() < 100 {
                        new_lrc.push(line.replace(&caps[0], &lrc_caps[0]));
                        break;
                    }
                }
            }
        }
    }
    new_lrc.join("\n")
}

fn tx_fix_tlrc_time_tag(tlrc: &str, lrc: &str) -> String {
    let line_time2_re = TX_LINE_TIME2_RE.get_or_init(|| Regex::new(r"^\[([\d:.]+)]").unwrap());
    let tlrc_lines: Vec<&str> = tlrc.split('\n').collect();
    let mut lrc_lines: Vec<&str> = lrc.split('\n').collect();
    let mut new_lrc: Vec<String> = Vec::new();

    for line in &tlrc_lines {
        if let Some(caps) = line_time2_re.captures(line) {
            let words = line_time2_re.replace(line, "");
            if words.trim().is_empty() {
                continue;
            }
            let mut time = caps[1].to_string();
            if time.contains('.') {
                let parts: Vec<&str> = time.split('.').collect();
                if parts.len() == 2 {
                    let pad = 3usize.saturating_sub(parts[1].len());
                    time = format!("{}.{}{}", parts[0], parts[1], "0".repeat(pad));
                }
            }
            let t1 = tx_get_intv(&time);
            while !lrc_lines.is_empty() {
                let lrc_line = lrc_lines.remove(0);
                if let Some(lrc_caps) = line_time2_re.captures(lrc_line) {
                    let t2 = tx_get_intv(&lrc_caps[1]);
                    if ((t1 as i64) - (t2 as i64)).unsigned_abs() < 100 {
                        new_lrc.push(line.replace(&caps[0], &lrc_caps[0]));
                        break;
                    }
                }
            }
        }
    }
    new_lrc.join("\n")
}

fn tx_parse(lrc: &str, tlrc: &str, rlrc: &str) -> LyricResult {
    let mut info = LyricResult::default();
    if !lrc.is_empty() {
        let cleaned = tx_remove_tag(lrc);
        let (lyric, lxlyric) = tx_parse_lyric(&cleaned);
        info.lyric = lyric;
        info.lxlyric = lxlyric;
    }
    if !rlrc.is_empty() {
        let cleaned = tx_remove_tag(rlrc);
        let parsed = tx_parse_rlyric(&cleaned);
        info.rlyric = tx_fix_rlrc_time_tag(&parsed, &info.lyric);
    }
    if !tlrc.is_empty() {
        info.tlyric = tx_fix_tlrc_time_tag(tlrc, &info.lyric);
    }
    info
}

async fn fetch_tx_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let song_id = song_info
        .song_id
        .as_ref()
        .map(|v| v.as_str().unwrap_or("").to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| Some(song_info.songmid.clone()))
        .unwrap_or_default();
    let songmid = &song_info.songmid;

    let req_body = serde_json::json!({
        "comm": { "uin": "0", "format": "json", "ct": "19", "cv": "1859" },
        "req": {
            "module": "music.musichallSong.PlayLyricInfo",
            "method": "GetPlayLyricInfo",
            "param": {
                "songMID": songmid,
                "songID": song_id.parse::<u64>().unwrap_or(0),
                "songType": 0,
                "qrc": 1,
                "qrc_t": 1,
            },
        },
    });

    let resp = http_fetch_text(
        "https://u.y.qq.com/cgi-bin/musicu.fcg",
        "POST",
        &[
            ("referer", "https://y.qq.com"),
            ("user-agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36"),
            ("Content-Type", "application/json"),
        ],
        Some(&req_body.to_string()),
    )
    .await?;

    let mut lxlyric = String::new();
    let mut lyric = String::new();
    let mut tlyric = String::new();
    let mut rlyric = String::new();

    if resp.status == 200 {
        if let Ok(body) = serde_json::from_str::<serde_json::Value>(&resp.body) {
            if body.get("code").and_then(|v| v.as_i64()) == Some(0) {
                if let Some(data) = body.get("req").and_then(|v| v.get("data")) {
                    if let Some(lyric_hex) = data.get("lyric").and_then(|v| v.as_str()) {
                        if let Ok(decrypted) = qrc_decrypt(lyric_hex) {
                            let parsed = tx_parse(&decrypted, "", "");
                            lyric = parsed.lyric;
                            lxlyric = parsed.lxlyric;
                        }
                    }
                    if let Some(trans_hex) = data.get("trans").and_then(|v| v.as_str()) {
                        if let Ok(decrypted) = qrc_decrypt(trans_hex) {
                            let re1 = TX_LYRIC_CONTENT_OPEN_RE.get_or_init(|| Regex::new(r#"^[\S\s]*?LyricContent=""#).unwrap());
                            let re2 = TX_LYRIC_CONTENT_CLOSE_RE.get_or_init(|| Regex::new(r#""/>[\S\s]*$"#).unwrap());
                            tlyric = re2
                                .replace_all(&re1.replace_all(&decrypted, ""), "")
                                .to_string();
                        }
                    }
                    if let Some(roma_hex) = data.get("roma").and_then(|v| v.as_str()) {
                        if let Ok(decrypted) = qrc_decrypt(roma_hex) {
                            let re1 = TX_LYRIC_CONTENT_OPEN_RE.get_or_init(|| Regex::new(r#"^[\S\s]*?LyricContent=""#).unwrap());
                            let re2 = TX_LYRIC_CONTENT_CLOSE_RE.get_or_init(|| Regex::new(r#""/>[\S\s]*$"#).unwrap());
                            rlyric = re2
                                .replace_all(&re1.replace_all(&decrypted, ""), "")
                                .to_string();
                        }
                    }
                }
            }
        }
    }

    // Fallback to old API
    if lyric.is_empty() && lxlyric.is_empty() {
        let old_url = format!(
            "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid={}&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq",
            songmid
        );
        let old_resp = http_fetch_text(
            &old_url,
            "GET",
            &[
                ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36"),
                ("Referer", "https://y.qq.com/portal/player.html"),
            ],
            None,
        )
        .await?;

        if old_resp.status == 200 {
            if let Ok(body) = serde_json::from_str::<serde_json::Value>(&old_resp.body) {
                if body.get("retcode").and_then(|v| v.as_i64()) == Some(0) {
                    if let Some(lyric_b64) = body.get("lyric").and_then(|v| v.as_str()) {
                        if let Ok(decoded) =
                            base64::engine::general_purpose::STANDARD.decode(pad_base64(lyric_b64))
                        {
                            lyric = String::from_utf8_lossy(&decoded).into_owned();
                        }
                    }
                    if let Some(trans_b64) = body.get("trans").and_then(|v| v.as_str()) {
                        if let Ok(decoded) =
                            base64::engine::general_purpose::STANDARD.decode(pad_base64(trans_b64))
                        {
                            tlyric = String::from_utf8_lossy(&decoded).into_owned();
                        }
                    }
                }
            }
        }
    }

    if lyric.is_empty() && lxlyric.is_empty() {
        return Ok(None);
    }

    Ok(Some(LyricResult {
        lyric,
        tlyric,
        rlyric,
        lxlyric,
    }))
}

// ==================== WY (NetEase) Lyric Fetching ====================

fn parse_yrc(yrc_text: &str) -> String {
    let line_time_re = WY_YRC_LINE_TIME_RE.get_or_init(|| Regex::new(r"^\[(\d+),(\d+)]").unwrap());
    let word_tag_re = WY_YRC_WORD_TAG_RE.get_or_init(|| Regex::new(r"\((\d+),(\d+),\d+\)").unwrap());
    let mut result: Vec<String> = Vec::new();

    for raw_line in yrc_text.split('\n') {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('{') {
            continue;
        }
        if let Some(caps) = line_time_re.captures(line) {
            let start_ms: u64 = caps[1].parse().unwrap_or(0);
            let content = &line[caps[0].len()..];

            // Find all (wordStart,wordDur,0) tags
            let tags: Vec<(u64, u64, usize, usize)> = word_tag_re
                .captures_iter(content)
                .map(|c| {
                    let s: u64 = c[1].parse().unwrap_or(0);
                    let d: u64 = c[2].parse().unwrap_or(0);
                    let (start, end) = c.get(0).map(|m| (m.start(), m.end())).unwrap_or((0, 0));
                    (s, d, start, end)
                })
                .collect();

            if tags.is_empty() {
                continue;
            }

            let time_str = format!(
                "[{:0>2}:{:0>2}.{:0>3}]",
                start_ms / 60000,
                (start_ms % 60000) / 1000,
                start_ms % 1000
            );
            let mut sb = time_str;

            for (i, (tag_start, tag_dur, _match_start, match_end)) in tags.iter().enumerate() {
                let offset = if (*tag_start as i64) - (start_ms as i64) < 0 {
                    0
                } else {
                    *tag_start - start_ms
                };
                let text_start = *match_end;
                let text_end = if i + 1 < tags.len() {
                    tags[i + 1].2
                } else {
                    content.len()
                };
                let text = &content[text_start..text_end];
                sb.push_str(&format!("<{},{}>{}", offset, tag_dur, text));
            }
            result.push(sb);
        }
    }
    result.join("\n")
}

const WYY_KRC_KEY: [u8; 16] = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x66, 0x44, 0x6d, 0x63, 0x71, 0x6f, 0x69, 0x67, 0x41, 0x39, 0x74,
];

fn wyy_decode_krc(encoded: &str) -> Vec<u8> {
    if !is_valid_base64(encoded) {
        return Vec::new();
    }
    let b64 = pad_base64(encoded);
    let data = match base64::engine::general_purpose::STANDARD.decode(&b64) {
        Ok(d) => d,
        Err(_) => return Vec::new(),
    };
    if data.is_empty() {
        return Vec::new();
    }
    let mut result = vec![0u8; data.len()];
    for i in 0..data.len() {
        result[i] = data[i] ^ WYY_KRC_KEY[i % WYY_KRC_KEY.len()];
    }
    result
}

fn read_uint32_le(data: &[u8], pos: usize) -> u32 {
    if pos + 4 > data.len() {
        return 0;
    }
    (data[pos] as u32)
        | ((data[pos + 1] as u32) << 8)
        | ((data[pos + 2] as u32) << 16)
        | ((data[pos + 3] as u32) << 24)
}

struct KrcLine {
    time: u32,
    words: Vec<(u32, u32, String)>, // (start, dur, text)
}

fn wyy_parse_krc(raw: &[u8]) -> Vec<KrcLine> {
    if raw.len() < 4 {
        return Vec::new();
    }
    let header_len = read_uint32_le(raw, 0) as usize;
    if header_len == 0 || header_len >= raw.len() {
        return Vec::new();
    }
    let body = &raw[header_len..];
    if body.len() < 4 {
        return Vec::new();
    }
    let tag_len = read_uint32_le(body, 0) as usize;
    let offset = tag_len + 4;
    if offset >= body.len() {
        return Vec::new();
    }
    let data = &body[offset..];
    let data_len = data.len();
    let mut pos = 0;
    let mut lines: Vec<KrcLine> = Vec::new();

    while pos + 4 <= data_len {
        let line_time = read_uint32_le(data, pos);
        pos += 4;
        if pos + 4 > data_len {
            break;
        }
        let word_count = read_uint32_le(data, pos) as usize;
        pos += 4;

        let mut words: Vec<(u32, u32, String)> = Vec::new();
        let mut prev_end = line_time;

        for _ in 0..word_count {
            if pos + 4 > data_len {
                break;
            }
            let word_dur = read_uint32_le(data, pos);
            pos += 4;
            if pos + 1 > data_len {
                break;
            }
            let str_len = data[pos] as usize;
            pos += 1;
            if pos + str_len > data_len {
                break;
            }
            let text = String::from_utf8_lossy(&data[pos..pos + str_len]).into_owned();
            pos += str_len;

            let start = prev_end;
            let end = start + word_dur;
            words.push((start, end - start, text));
            prev_end = end;
        }
        lines.push(KrcLine {
            time: line_time,
            words,
        });
    }
    lines
}

fn krc_lines_to_lxlyric(lines: &[KrcLine]) -> String {
    let mut result: Vec<String> = Vec::new();
    for line in lines {
        if line.words.is_empty() {
            continue;
        }
        let line_start = line.time;
        let time_str = format!(
            "[{:0>2}:{:0>2}.{:0>3}]",
            line_start / 60000,
            (line_start % 60000) / 1000,
            line_start % 1000
        );
        let mut sb = time_str;
        for (start, dur, text) in &line.words {
            let offset = if (*start as i32) - (line_start as i32) < 0 {
                0
            } else {
                *start - line_start
            };
            sb.push_str(&format!("<{},{}>{}", offset, dur, text));
        }
        result.push(sb);
    }
    result.join("\n")
}

fn try_extract_yrc(body: &serde_json::Value) -> String {
    // 不再强制检查 code==200：eapi 响应可能不包含 code 字段，
    // 只要有 yrc/klyric 字段就尝试提取。

    // Check yrc field
    if let Some(yrc) = body
        .get("yrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
    {
        let result = parse_yrc(yrc);
        if !result.is_empty() {
            return result;
        }
    }

    // Check klyric field for YRC format
    if let Some(klyric) = body.get("klyric") {
        if let Some(lyric) = klyric.get("lyric").and_then(|v| v.as_str()) {
            if lyric.len() > 50 {
                let re = WY_YRC_CHECK_RE.get_or_init(|| Regex::new(r"^\[\d+,\d+]").unwrap());
                if re.is_match(lyric) {
                    let result = parse_yrc(lyric);
                    if !result.is_empty() {
                        return result;
                    }
                }
            }
        }
        if let Some(lyric) = klyric.as_str() {
            if lyric.len() > 50 {
                let re = WY_YRC_CHECK_RE.get_or_init(|| Regex::new(r"^\[\d+,\d+]").unwrap());
                if re.is_match(lyric) {
                    let result = parse_yrc(lyric);
                    if !result.is_empty() {
                        return result;
                    }
                }
            }
        }
    }

    String::new()
}

fn try_extract_krc(body: &serde_json::Value) -> String {
    // 不再强制检查 code==200：同 try_extract_yrc。

    if let Some(klyric) = body.get("klyric") {
        if let Some(lyric) = klyric.as_str() {
            if lyric.len() > 100 && lyric != "null" && is_valid_base64(lyric) {
                let decoded = wyy_decode_krc(lyric);
                if !decoded.is_empty() {
                    let lines = wyy_parse_krc(&decoded);
                    if !lines.is_empty() {
                        return krc_lines_to_lxlyric(&lines);
                    }
                }
            }
        }
        if let Some(lyric) = klyric.get("lyric").and_then(|v| v.as_str()) {
            if lyric.len() > 100 && is_valid_base64(lyric) {
                let decoded = wyy_decode_krc(lyric);
                if !decoded.is_empty() {
                    let lines = wyy_parse_krc(&decoded);
                    if !lines.is_empty() {
                        return krc_lines_to_lxlyric(&lines);
                    }
                }
            }
        }
    }
    String::new()
}

fn wy_fix_time_label(lrc: &str, tlrc: &str, romalrc: &str) -> (String, String, String) {
    if lrc.is_empty() {
        return (lrc.to_string(), tlrc.to_string(), romalrc.to_string());
    }
    let re = WY_FIX_TIME_RE.get_or_init(|| Regex::new(r"\[(\d{2}:\d{2}):(\d{2})]").unwrap());
    let new_lrc = re.replace_all(lrc, "[$1.$2]").to_string();
    let new_tlrc = if !tlrc.is_empty() {
        re.replace_all(tlrc, "[$1.$2]").to_string()
    } else {
        tlrc.to_string()
    };

    if new_lrc != lrc || new_tlrc != tlrc {
        let new_romalrc = if !romalrc.is_empty() {
            let re2 = WY_FIX_ROMA_TIME_RE.get_or_init(|| Regex::new(r"\[(\d{2}:\d{2}):(\d{2,3})]").unwrap());
            let intermediate = re2.replace_all(romalrc, "[$1.$2]").to_string();
            let re3 = WY_FIX_ROMA_TRAIL_RE.get_or_init(|| Regex::new(r"\[(\d{2}:\d{2}\.\d{2})0]").unwrap());
            re3.replace_all(&intermediate, "[$1]").to_string()
        } else {
            romalrc.to_string()
        };
        (new_lrc, new_tlrc, new_romalrc)
    } else {
        (new_lrc, new_tlrc, romalrc.to_string())
    }
}

/// WY eapi POST request helper: encrypts params and sends POST to the given eapi endpoint
async fn wy_eapi_post(
    eapi_path: &str,
    data: serde_json::Value,
    extra_headers: &[(&str, &str)],
) -> Result<Option<serde_json::Value>, String> {
    let data_str = serde_json::to_string(&data).unwrap_or_default();
    let params = wy_eapi_encrypt(eapi_path, &data_str)?;
    let api_url = format!("https://interface3.music.163.com{}", eapi_path);
    let body = format!("params={}", params);

    let mut headers: Vec<(&str, &str)> = vec![
        ("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36"),
        ("origin", "https://music.163.com"),
        ("Content-Type", "application/x-www-form-urlencoded"),
    ];
    headers.extend_from_slice(extra_headers);

    let resp = http_fetch_text(&api_url, "POST", &headers, Some(&body)).await?;
    if resp.status != 200 {
        return Ok(None);
    }
    match serde_json::from_str::<serde_json::Value>(&resp.body) {
        Ok(v) => Ok(Some(v)),
        Err(_) => Ok(None),
    }
}

/// Fallback karaoke lyrics extraction: tries two parameter sets to get YRC/KRC
async fn wyy_get_karaoke(song_id: &str) -> String {
    let song_id_value = song_id
        .parse::<i64>()
        .map(serde_json::Value::from)
        .unwrap_or_else(|_| serde_json::Value::from(song_id.to_string()));
    // First try: same params as main request (kv=0, yv=0)
    let data1 = serde_json::json!({
        "id": song_id_value, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
    });
    if let Ok(Some(body)) = wy_eapi_post("/api/song/lyric/v1", data1, &[]).await {
        let yrc = try_extract_yrc(&body);
        if !yrc.is_empty() {
            return yrc;
        }
        let krc = try_extract_krc(&body);
        if !krc.is_empty() {
            return krc;
        }
    }

    // Second try: Go code params (kv=1, requests klyric binary KRC)
    let id_num: i64 = song_id.parse().unwrap_or(0);
    let data2 = serde_json::json!({
        "cp": -1, "id": id_num, "kv": 1, "lv": -1, "rv": 0, "tv": -1, "yt": false, "yv": 0,
    });
    // Override User-Agent for this request
    let data_str = serde_json::to_string(&data2).unwrap_or_default();
    let params = match wy_eapi_encrypt("/api/song/lyric/v1", &data_str) {
        Ok(p) => p,
        Err(_) => return String::new(),
    };
    let api_url = "https://interface3.music.163.com/api/song/lyric/v1";
    let body = format!("params={}", params);
    let resp = http_fetch_text(
        &api_url,
        "POST",
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/2.10.2.200154"),
            ("Cookie", "os=pc; appver=8.9.75; osver=; deviceId=pyncm!"),
            ("Content-Type", "application/x-www-form-urlencoded"),
        ],
        Some(&body),
    ).await;

    if let Ok(resp) = resp {
        if resp.status == 200 {
            if let Ok(body) = serde_json::from_str::<serde_json::Value>(&resp.body) {
                let yrc = try_extract_yrc(&body);
                if !yrc.is_empty() {
                    return yrc;
                }
                let krc = try_extract_krc(&body);
                if !krc.is_empty() {
                    return krc;
                }
            }
        }
    }

    String::new()
}

async fn fetch_wy_legacy_lyric(song_id: &str) -> Result<Option<LyricResult>, String> {
    let url = format!(
        "https://music.163.com/api/song/lyric?id={}&lv=-1&kv=-1&tv=-1&rv=-1",
        urlencoding::encode(song_id)
    );
    let resp = http_fetch_text(
        &url,
        "GET",
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
            ("Referer", "https://music.163.com/"),
            ("Cookie", "os=pc; appver=8.9.75; osver=; deviceId=pyncm!"),
        ],
        None,
    )
    .await?;

    if resp.status != 200 {
        return Ok(None);
    }
    let body: serde_json::Value = match serde_json::from_str(&resp.body) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };

    let final_lxlyric = {
        let yrc = try_extract_yrc(&body);
        if !yrc.is_empty() {
            yrc
        } else {
            try_extract_krc(&body)
        }
    };
    let lrc = body
        .get("lrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let tlrc = body
        .get("tlyric")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let romalrc = body
        .get("romalrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let (fixed_lrc, fixed_tlrc, fixed_romalrc) = wy_fix_time_label(lrc, tlrc, romalrc);

    if fixed_lrc.is_empty() && final_lxlyric.is_empty() {
        return Ok(None);
    }
    Ok(Some(LyricResult {
        lyric: fixed_lrc,
        tlyric: fixed_tlrc,
        rlyric: fixed_romalrc,
        lxlyric: final_lxlyric,
    }))
}

fn collect_wy_song_ids(song_info: &LyricSongInfo) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    if let Some(value) = &song_info.song_id {
        if let Some(id) = value.as_str() {
            if !id.trim().is_empty() {
                ids.push(id.trim().to_string());
            }
        } else if let Some(id) = value.as_i64() {
            ids.push(id.to_string());
        } else if let Some(id) = value.as_u64() {
            ids.push(id.to_string());
        }
    }
    if !song_info.songmid.trim().is_empty() && !ids.iter().any(|id| id == &song_info.songmid) {
        ids.push(song_info.songmid.clone());
    }
    ids
}

async fn fetch_wy_lyric_by_id(song_id: &str) -> Result<Option<LyricResult>, String> {
    let song_id_value = song_id
        .parse::<i64>()
        .map(serde_json::Value::from)
        .unwrap_or_else(|_| serde_json::Value::from(song_id.to_string()));

    // Use /api/song/lyric/v1 with POST (matching frontend's proven approach)
    // kv=0 + yv=0 lets the API return yrc field for YRC word-by-word lyrics
    let data = serde_json::json!({
        "id": song_id_value, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
    });
    let body = match wy_eapi_post("/api/song/lyric/v1", data, &[]).await? {
        Some(b) => b,
        None => return fetch_wy_legacy_lyric(song_id).await,
    };

    // Try YRC first, then KRC
    let lxlyric = try_extract_yrc(&body);
    let krc_lxlyric = if lxlyric.is_empty() {
        try_extract_krc(&body)
    } else {
        String::new()
    };
    let mut final_lxlyric = if !lxlyric.is_empty() {
        lxlyric
    } else {
        krc_lxlyric
    };

    // If no word-by-word lyrics, try fallback karaoke extraction
    if final_lxlyric.is_empty() {
        final_lxlyric = wyy_get_karaoke(song_id).await;
    }

    // Get plain lyrics
    let lrc = body
        .get("lrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let tlrc = body
        .get("tlyric")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let romalrc = body
        .get("romalrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let (fixed_lrc, fixed_tlrc, fixed_romalrc) = wy_fix_time_label(lrc, tlrc, romalrc);

    if fixed_lrc.is_empty() && final_lxlyric.is_empty() {
        return fetch_wy_legacy_lyric(song_id).await;
    }

    // eapi 返回了普通歌词但没有逐字歌词时，尝试 legacy API 获取 YRC/KRC。
    // 某些歌曲的逐字歌词只在非加密 API 中可用。
    if final_lxlyric.is_empty() && !fixed_lrc.is_empty() {
        if let Ok(Some(legacy)) = fetch_wy_legacy_lyric(song_id).await {
            if !legacy.lxlyric.is_empty() {
                final_lxlyric = legacy.lxlyric;
            }
        }
    }

    Ok(Some(LyricResult {
        lyric: fixed_lrc,
        tlyric: fixed_tlrc,
        rlyric: fixed_romalrc,
        lxlyric: final_lxlyric,
    }))
}

async fn fetch_wy_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let ids = collect_wy_song_ids(song_info);
    if ids.is_empty() {
        return Ok(None);
    }

    let mut last_error: Option<String> = None;
    for song_id in ids {
        match fetch_wy_lyric_by_id(&song_id).await {
            Ok(Some(result)) => return Ok(Some(result)),
            Ok(None) => {
            }
            Err(error) => {
                last_error = Some(error);
            }
        }
    }

    if let Some(_error) = last_error {}
    Ok(None)
}

// ==================== 对外入口 ====================

pub async fn fetch_lyric_from_source(
    source: String,
    song_info: LyricSongInfo,
) -> Result<Option<LyricResult>, String> {
    let result = match source.as_str() {
        "kg" => fetch_kg_lyric(&song_info).await?,
        "kw" => fetch_kw_lyric(&song_info).await?,
        "tx" => fetch_tx_lyric(&song_info).await?,
        "wy" => fetch_wy_lyric(&song_info).await?,
        _ => return Ok(None),
    };
    Ok(result)
}
