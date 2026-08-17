// player/palette.rs - 封面取色（HSL 桶聚类）
//
// 从桌面端集色引擎（前端 Web Worker colorExtraction.worker.ts 迁移）移植：
// 像素采样 → RGB→HSL → 分桶累加 → 候选评分 → 多样性选择 → 抛光/衍生。
// 所有数学运算与桌面端一一对应，保证迁移后调色板视觉一致。
// 移动端由宿主在后台线程调用（纯 CPU 运算）。

use base64::Engine;
use image::imageops::FilterType;
use image::DynamicImage;
use std::collections::HashMap;

const CANVAS_SIZE: u32 = 56;
const SAMPLE_STEP: usize = 2;

const FALLBACK_PALETTE: [&str; 4] = [
    "hsl(220, 28%, 34%)",
    "hsl(196, 58%, 56%)",
    "hsl(340, 52%, 58%)",
    "hsl(42, 72%, 60%)",
];

#[derive(Clone, Copy, Default)]
struct HslColor {
    h: f64,
    s: f64,
    l: f64,
}

struct BucketAccumulator {
    count: usize,
    s_sum: f64,
    l_sum: f64,
    hx_sum: f64,
    hy_sum: f64,
}

impl BucketAccumulator {
    fn new() -> Self {
        Self {
            count: 0,
            s_sum: 0.0,
            l_sum: 0.0,
            hx_sum: 0.0,
            hy_sum: 0.0,
        }
    }
}

#[derive(Clone, Copy)]
struct PaletteCandidate {
    h: f64,
    s: f64,
    l: f64,
    count: usize,
    score: f64,
}

fn clamp(value: f64, min: f64, max: f64) -> f64 {
    value.max(min).min(max)
}

fn lerp(start: f64, end: f64, amount: f64) -> f64 {
    start + (end - start) * amount
}

fn normalize_hue(hue: f64) -> f64 {
    let mut normalized = hue % 360.0;
    if normalized < 0.0 {
        normalized += 360.0;
    }
    normalized
}

fn angular_distance(a: f64, b: f64) -> f64 {
    let diff = (normalize_hue(a) - normalize_hue(b)).abs();
    diff.min(360.0 - diff)
}

fn rgb_to_hsl(r: u8, g: u8, b: u8) -> HslColor {
    let r_norm = r as f64 / 255.0;
    let g_norm = g as f64 / 255.0;
    let b_norm = b as f64 / 255.0;
    let max = r_norm.max(g_norm).max(b_norm);
    let min = r_norm.min(g_norm).min(b_norm);
    let lightness = (max + min) / 2.0;

    if max == min {
        return HslColor {
            h: 0.0,
            s: 0.0,
            l: lightness,
        };
    }

    let delta = max - min;
    let saturation = if lightness > 0.5 {
        delta / (2.0 - max - min)
    } else {
        delta / (max + min)
    };

    let hue = if max == r_norm {
        (g_norm - b_norm) / delta + if g_norm < b_norm { 6.0 } else { 0.0 }
    } else if max == g_norm {
        (b_norm - r_norm) / delta + 2.0
    } else {
        (r_norm - g_norm) / delta + 4.0
    };

    HslColor {
        h: normalize_hue((hue / 6.0) * 360.0),
        s: saturation,
        l: lightness,
    }
}

fn get_bucket_key(color: &HslColor) -> String {
    let light_bucket = (color.l * 4.0).round() as i32;

    if color.s < 0.12 {
        return format!("neutral-{light_bucket}");
    }

    let hue_bucket = (normalize_hue(color.h) / 18.0).round() as i32;
    let sat_bucket = (color.s * 5.0).round() as i32;
    format!("{hue_bucket}-{sat_bucket}-{light_bucket}")
}

fn create_candidate(bucket: &BucketAccumulator) -> PaletteCandidate {
    let average_hue =
        normalize_hue(bucket.hy_sum.atan2(bucket.hx_sum) * 180.0 / std::f64::consts::PI);
    let average_saturation = bucket.s_sum / bucket.count as f64;
    let average_lightness = bucket.l_sum / bucket.count as f64;
    let midtone_affinity = 1.0 - ((average_lightness - 0.5).abs() / 0.5).min(1.0) * 0.45;
    let saturation_weight = 0.78 + average_saturation * 1.4;
    let neutral_penalty = if average_saturation < 0.12 { 0.52 } else { 1.0 };
    let extreme_penalty = if average_lightness < 0.08 || average_lightness > 0.92 {
        0.3
    } else {
        1.0
    };

    PaletteCandidate {
        h: average_hue,
        s: average_saturation,
        l: average_lightness,
        count: bucket.count,
        score: bucket.count as f64
            * saturation_weight
            * midtone_affinity
            * neutral_penalty
            * extreme_penalty,
    }
}

fn select_palette(candidates: &mut Vec<PaletteCandidate>, count: usize) -> Vec<PaletteCandidate> {
    if candidates.is_empty() {
        return Vec::new();
    }

    candidates.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut remaining: Vec<PaletteCandidate> = candidates.drain(..).collect();
    let mut selected: Vec<PaletteCandidate> = vec![remaining.remove(0)];

    while selected.len() < count && !remaining.is_empty() {
        let mut best_index = 0;
        let mut best_score = f64::NEG_INFINITY;

        for (index, candidate) in remaining.iter().enumerate() {
            let mut min_gap = f64::INFINITY;
            for current in &selected {
                let hue_gap = angular_distance(candidate.h, current.h) / 180.0;
                let saturation_gap = (candidate.s - current.s).abs();
                let lightness_gap = (candidate.l - current.l).abs();
                let distance = hue_gap * 0.65 + saturation_gap * 0.2 + lightness_gap * 0.15;
                if distance < min_gap {
                    min_gap = distance;
                }
            }

            let diversified_score = candidate.score * (0.8 + min_gap * 1.85);
            if diversified_score > best_score {
                best_score = diversified_score;
                best_index = index;
            }
        }

        selected.push(remaining.remove(best_index));
    }

    selected.truncate(count);
    selected
}

fn polish_color(candidate: &HslColor, role: usize, color_boost: f64, depth: f64) -> String {
    let hue = normalize_hue(candidate.h).round() as i32;
    let saturation = candidate.s * 100.0;
    let lightness = candidate.l * 100.0;
    let boost = clamp(color_boost / 100.0, 0.0, 1.0);
    let depth_factor = clamp(depth / 100.0, 0.0, 1.0);

    let (refined_saturation, refined_lightness) = if role == 0 {
        let rs = if saturation < 14.0 {
            lerp(18.0, 30.0, boost)
        } else {
            clamp(
                saturation * lerp(0.84, 1.02, boost) + lerp(8.0, 18.0, boost),
                24.0,
                lerp(50.0, 68.0, boost),
            )
        };
        let rl = clamp(
            lightness * lerp(0.84, 0.58, depth_factor) + lerp(10.0, 4.0, depth_factor),
            lerp(32.0, 18.0, depth_factor),
            lerp(54.0, 38.0, depth_factor),
        );
        (rs, rl)
    } else {
        let rs = if saturation < 14.0 {
            lerp(24.0 + role as f64 * 6.0, 36.0 + role as f64 * 5.0, boost)
        } else {
            clamp(
                saturation * lerp(0.9, 1.08, boost) + lerp(12.0, 22.0, boost),
                lerp(34.0, 42.0, boost),
                lerp(66.0, 82.0, boost),
            )
        };
        let rl = clamp(
            lightness * lerp(0.9, 0.7, depth_factor)
                + lerp(12.0 + role as f64 * 2.0, 8.0 + role as f64, depth_factor),
            lerp(46.0, 34.0, depth_factor),
            lerp(72.0, 58.0, depth_factor),
        );
        (rs, rl)
    };

    format!(
        "hsl({}, {}%, {}%)",
        hue,
        refined_saturation.round() as i32,
        refined_lightness.round() as i32
    )
}

fn create_derived_accent(anchor: &HslColor, role: usize, color_boost: f64, depth: f64) -> String {
    const HUE_SHIFTS: [f64; 4] = [24.0, -28.0, 52.0, -58.0];
    const LIGHTNESS_SHIFTS: [f64; 4] = [10.0, 4.0, 14.0, 8.0];
    let shift = HUE_SHIFTS[(role - 1) % 4];
    let lightness_shift = LIGHTNESS_SHIFTS[(role - 1) % 4];
    let saturation_base = anchor.s * 100.0;
    let lightness_base = anchor.l * 100.0;
    let boost = clamp(color_boost / 100.0, 0.0, 1.0);
    let depth_factor = clamp(depth / 100.0, 0.0, 1.0);

    let hue = normalize_hue(anchor.h + shift).round() as i32;
    let saturation = if saturation_base < 12.0 {
        lerp(30.0 + role as f64 * 4.0, 40.0 + role as f64 * 4.0, boost)
    } else {
        clamp(
            saturation_base * lerp(0.88, 1.02, boost) + lerp(16.0, 26.0, boost),
            40.0,
            lerp(68.0, 84.0, boost),
        )
    };
    let lightness = clamp(
        lightness_base * lerp(0.92, 0.74, depth_factor)
            + lerp(lightness_shift, lightness_shift - 6.0, depth_factor),
        lerp(48.0, 34.0, depth_factor),
        lerp(70.0, 56.0, depth_factor),
    );

    format!(
        "hsl({}, {}%, {}%)",
        hue,
        saturation.round() as i32,
        lightness.round() as i32
    )
}

fn fallback_palette(count: usize) -> Vec<String> {
    FALLBACK_PALETTE
        .iter()
        .take(count)
        .map(|s| (*s).to_string())
        .collect()
}

fn process_pixel_data(rgba: &[u8], count: usize, color_boost: f64, depth: f64) -> Vec<String> {
    let mut buckets: HashMap<String, BucketAccumulator> = HashMap::new();
    let size = CANVAS_SIZE as usize;

    let mut y = 0;
    while y < size {
        let mut x = 0;
        while x < size {
            let offset = (y * size + x) * 4;
            let alpha = rgba[offset + 3];
            if alpha >= 160 {
                let red = rgba[offset];
                let green = rgba[offset + 1];
                let blue = rgba[offset + 2];
                let hsl = rgb_to_hsl(red, green, blue);

                if !(hsl.l < 0.02 || hsl.l > 0.98) {
                    let key = get_bucket_key(&hsl);
                    let bucket = buckets.entry(key).or_insert_with(BucketAccumulator::new);
                    bucket.count += 1;
                    bucket.s_sum += hsl.s;
                    bucket.l_sum += hsl.l;
                    bucket.hx_sum += (hsl.h * std::f64::consts::PI / 180.0).cos();
                    bucket.hy_sum += (hsl.h * std::f64::consts::PI / 180.0).sin();
                }
            }
            x += SAMPLE_STEP;
        }
        y += SAMPLE_STEP;
    }

    let mut candidates: Vec<PaletteCandidate> = buckets
        .values()
        .map(create_candidate)
        .filter(|candidate| candidate.count > 3)
        .collect();

    if candidates.is_empty() {
        return fallback_palette(count);
    }

    let selected = select_palette(&mut candidates, count);
    let anchor = selected
        .first()
        .map(|c| HslColor {
            h: c.h,
            s: c.s,
            l: c.l,
        })
        .unwrap_or(HslColor {
            h: 220.0,
            s: 0.35,
            l: 0.38,
        });

    let mut polished: Vec<String> = selected
        .iter()
        .enumerate()
        .map(|(index, candidate)| {
            polish_color(
                &HslColor {
                    h: candidate.h,
                    s: candidate.s,
                    l: candidate.l,
                },
                index,
                color_boost,
                depth,
            )
        })
        .collect();

    while polished.len() < count {
        let role = polished.len();
        polished.push(create_derived_accent(&anchor, role, color_boost, depth));
    }

    polished.truncate(count);
    polished
}

fn extract_palette_from_image(
    img: &DynamicImage,
    count: usize,
    color_boost: f64,
    depth: f64,
) -> Vec<String> {
    let resized = img.resize_exact(CANVAS_SIZE, CANVAS_SIZE, FilterType::Triangle);
    let rgba = resized.to_rgba8();
    process_pixel_data(rgba.as_raw(), count, color_boost, depth)
}

fn load_image_bytes(source: &str) -> Result<Vec<u8>, String> {
    if let Some(rest) = source.strip_prefix("data:") {
        let comma = rest
            .find(',')
            .ok_or_else(|| "invalid data URI".to_string())?;
        let meta = &rest[..comma];
        let data = &rest[comma + 1..];
        if meta.contains("base64") {
            base64::engine::general_purpose::STANDARD
                .decode(data)
                .map_err(|e| e.to_string())
        } else {
            let decoded = percent_decode(data);
            Ok(decoded)
        }
    } else if source.starts_with("http://") || source.starts_with("https://") {
        let client = reqwest::blocking::Client::builder()
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
            .build()
            .map_err(|e| e.to_string())?;
        let bytes = client
            .get(source)
            .send()
            .map_err(|e| e.to_string())?
            .bytes()
            .map_err(|e| e.to_string())?;
        Ok(bytes.to_vec())
    } else {
        std::fs::read(source).map_err(|e| e.to_string())
    }
}

fn percent_decode(input: &str) -> Vec<u8> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) =
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""), 16)
            {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

/// 从封面提取主色调调色板。
///
/// `source` 可为：本地文件路径、`http(s)://` 直链、`data:` URI。
/// 失败时返回静态回退调色板，保证前端始终可拿到非空结果（与原 Worker 行为一致）。
/// 纯 CPU 运算，移动端由宿主在后台线程调用。
pub fn extract_palette(
    source: String,
    count: usize,
    color_boost: f64,
    depth: f64,
) -> Result<Vec<String>, String> {
    let count = if count == 0 { 4 } else { count };

    let bytes = match load_image_bytes(&source) {
        Ok(bytes) => bytes,
        Err(_) => {
            return Ok(fallback_palette(count));
        }
    };

    let img = match image::load_from_memory(&bytes) {
        Ok(img) => img,
        Err(_) => {
            return Ok(fallback_palette(count));
        }
    };

    Ok(extract_palette_from_image(&img, count, color_boost, depth))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid_color_rgba(r: u8, g: u8, b: u8) -> Vec<u8> {
        let mut buf = Vec::with_capacity((CANVAS_SIZE as usize) * (CANVAS_SIZE as usize) * 4);
        for _ in 0..(CANVAS_SIZE as usize) * (CANVAS_SIZE as usize) {
            buf.push(r);
            buf.push(g);
            buf.push(b);
            buf.push(255);
        }
        buf
    }

    #[test]
    fn returns_four_colors_for_solid_image() {
        let rgba = solid_color_rgba(200, 40, 40);
        let palette = process_pixel_data(&rgba, 4, 56.0, 58.0);
        assert_eq!(palette.len(), 4);
        for color in &palette {
            assert!(color.starts_with("hsl("));
        }
    }

    #[test]
    fn fallback_when_image_too_dark() {
        // 近乎纯黑的像素全部被 l<0.02 过滤，应回退到静态调色板。
        let rgba = solid_color_rgba(1, 1, 1);
        let palette = process_pixel_data(&rgba, 4, 56.0, 58.0);
        assert_eq!(palette.len(), 4);
        assert_eq!(palette[0], FALLBACK_PALETTE[0]);
    }

    #[test]
    fn fallback_palette_respects_count() {
        assert_eq!(fallback_palette(2).len(), 2);
        assert_eq!(fallback_palette(10).len(), 4);
    }
}