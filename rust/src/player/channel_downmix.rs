//! 多声道 → 立体声下混。
//!
//! 与桌面端 `src-tauri/src/player/channel_downmix.rs` 保持同一套系数：
//! 共享模式（系统混音器）下 >2 声道流（如伪 6ch「全景声」FLAC）不做
//! 声道映射会直接破音，在样本层按帧混成立体声后放行，混音系数参考
//! ITU-R BS.775。

/// 单帧下混：交错样本帧 → (左, 右)。输入不足 2 声道时原样返回。
pub fn downmix_frame(frame: &[f32]) -> (f32, f32) {
    let l = frame.first().copied().unwrap_or(0.0);
    let r = frame.get(1).copied().unwrap_or(l);
    match frame.len() {
        0 | 1 | 2 => (l, r),
        3 => {
            // L R C
            let c = frame[2] * std::f32::consts::FRAC_1_SQRT_2;
            (l + c, r + c)
        }
        4 => {
            // FL FR BL BR
            let bl = frame[2] * std::f32::consts::FRAC_1_SQRT_2;
            let br = frame[3] * std::f32::consts::FRAC_1_SQRT_2;
            (l + bl, r + br)
        }
        6 => {
            // 5.1（symphonia 布局：FL FR FC LFE SL SR）
            let c = frame[2] * std::f32::consts::FRAC_1_SQRT_2;
            let lfe = frame[3] * 0.5;
            let sl = frame[4] * std::f32::consts::FRAC_1_SQRT_2;
            let sr = frame[5] * std::f32::consts::FRAC_1_SQRT_2;
            (l + c + sl + lfe, r + c + sr + lfe)
        }
        _ => {
            // 未知布局兜底：前两声道为基，其余按奇偶对称混入
            let mut lm = l;
            let mut rm = r;
            for (i, s) in frame.iter().enumerate().skip(2) {
                if i % 2 == 0 {
                    lm += s * 0.5;
                } else {
                    rm += s * 0.5;
                }
            }
            (lm, rm)
        }
    }
}

/// 把 >2 声道的交错样本块下混为立体声；≤2 声道原样拷贝。
pub fn downmix_block(samples: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 2 {
        return samples.to_vec();
    }
    let ch = channels as usize;
    let frames = samples.len() / ch;
    let mut out = Vec::with_capacity(frames * 2);
    for frame in samples.chunks(ch).take(frames) {
        let (l, r) = downmix_frame(frame);
        out.push(l);
        out.push(r);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_5_1_side_layout() {
        // FL=1.0 FR=0.0 FC=0.5 LFE=0.4 SL=0.6 SR=0.8
        let frame = [1.0, 0.0, 0.5, 0.4, 0.6, 0.8];
        let (l, r) = downmix_frame(&frame);
        let s = std::f32::consts::FRAC_1_SQRT_2;
        assert!((l - (1.0 + 0.5 * s + 0.6 * s + 0.2)).abs() < 1e-6);
        assert!((r - (0.0 + 0.5 * s + 0.8 * s + 0.2)).abs() < 1e-6);
    }

    #[test]
    fn downmix_stereo_passthrough() {
        assert_eq!(downmix_frame(&[0.25, -0.5]), (0.25, -0.5));
    }

    #[test]
    fn block_interleaves_frames_in_order() {
        // 两个 6ch 帧：帧1 = 1..6，帧2 = 0.1..0.6
        let mut samples = Vec::new();
        for base in [0.0f32, 0.1] {
            for i in 0..6u32 {
                samples.push(base + i as f32 * 0.1);
            }
        }
        let out = downmix_block(&samples, 6);
        // 12 输入样本 = 2 个 6ch 帧 → 输出 2 个立体声帧 = 4 样本
        assert_eq!(out.len(), 4);
        // 顺序应为 [L1, R1, L2, R2]
        assert!(out[0] < out[1]);
        assert!(out[2] < out[3]);
    }

    #[test]
    fn block_stereo_passthrough() {
        let samples = [0.1, -0.2, 0.3, -0.4];
        assert_eq!(downmix_block(&samples, 2), samples.to_vec());
    }
}
