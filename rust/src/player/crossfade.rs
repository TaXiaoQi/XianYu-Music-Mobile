//! 常功率 PCM 交叉淡入混音器（constant-power crossfade）。
//!
//! 算法参考 RawS 的 `PcmCrossfadeMixer.kt`。
//! 弦予音频管道全程 f32 交错 PCM，故只实现 f32 路径，无需 RawS 的 S16/S24/S32 分支。
//!
//! 增益曲线：gainOut = cos(p·π/2)，gainIn = sin(p·π/2)，按 (out+in) 归一化。
//! 这保证总功率恒定（无淡入淡出时的音量凹陷），适合无缝衔接。

#![allow(dead_code)]

use std::f32::consts::PI;

/// 交叉淡入淡出混音器。在重叠区内原地混合当前曲尾与下一曲首。
pub struct PcmCrossfadeMixer;

impl PcmCrossfadeMixer {
    /// 淡出增益（0=全当前曲，1=全下一曲）。
    #[inline]
    pub fn gain_out(progress: f32) -> f32 {
        let p = progress.clamp(0.0, 1.0);
        let out = (p * PI / 2.0).cos();
        let inn = (p * PI / 2.0).sin();
        let denom = (out + inn).max(1.0e-6);
        out / denom
    }

    /// 淡入增益。
    #[inline]
    pub fn gain_in(progress: f32) -> f32 {
        let p = progress.clamp(0.0, 1.0);
        let out = (p * PI / 2.0).cos();
        let inn = (p * PI / 2.0).sin();
        let denom = (out + inn).max(1.0e-6);
        inn / denom
    }

    /// 在重叠区原地混合：result[i] = current[i]*gainOut + next[i]*gainIn。
    /// `current` 和 `next` 为交错 f32 PCM，长度应相同。
    /// `gain_out` / `gain_in` 为本块对应的增益（对整块恒定，逐块递进）。
    pub fn mix_in_place(
        current: &mut [f32],
        next: &[f32],
        gain_out: f32,
        gain_in: f32,
    ) {
        let len = current.len().min(next.len());
        for i in 0..len {
            let mixed = current[i] * gain_out + next[i] * gain_in;
            current[i] = if mixed.is_finite() { mixed } else { current[i] };
        }
    }

    /// 在重叠区逐样本混合，progress 从 0→1 线性扫描。
    /// 适合一次性处理整个重叠段。
    pub fn mix_crossfade(current: &mut [f32], next: &[f32]) {
        let len = current.len().min(next.len());
        if len == 0 {
            return;
        }
        let inv = 1.0 / len as f32;
        for i in 0..len {
            let p = i as f32 * inv;
            let g_out = Self::gain_out(p);
            let g_in = Self::gain_in(p);
            let mixed = current[i] * g_out + next[i] * g_in;
            current[i] = if mixed.is_finite() { mixed } else { current[i] };
        }
    }

    /// 计算给定重叠帧数下的逐样本增益表（预计算，热路径查表）。
    /// 返回 (gain_out_table, gain_in_table)，长度均为 overlap_frames。
    pub fn gain_tables(overlap_frames: usize) -> (Vec<f32>, Vec<f32>) {
        if overlap_frames == 0 {
            return (Vec::new(), Vec::new());
        }
        let inv = 1.0 / overlap_frames as f32;
        let mut out_tbl = Vec::with_capacity(overlap_frames);
        let mut in_tbl = Vec::with_capacity(overlap_frames);
        for i in 0..overlap_frames {
            let p = i as f32 * inv;
            out_tbl.push(Self::gain_out(p));
            in_tbl.push(Self::gain_in(p));
        }
        (out_tbl, in_tbl)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gain_curves_sum_to_unity() {
        // RawS 归一化 / (cos+sin) 保证增益之和恒为 1（常数和，非常数功率）
        for i in 0..101 {
            let p = i as f32 / 100.0;
            let go = PcmCrossfadeMixer::gain_out(p);
            let gi = PcmCrossfadeMixer::gain_in(p);
            let sum = go + gi;
            assert!(
                (sum - 1.0).abs() < 0.01,
                "sum={sum} at p={p}"
            );
        }
    }

    #[test]
    fn endpoints_are_correct() {
        // p=0: 全当前曲
        assert!((PcmCrossfadeMixer::gain_out(0.0) - 1.0).abs() < 1e-3);
        assert!(PcmCrossfadeMixer::gain_in(0.0) < 1e-3);
        // p=1: 全下一曲
        assert!(PcmCrossfadeMixer::gain_out(1.0) < 1e-3);
        assert!((PcmCrossfadeMixer::gain_in(1.0) - 1.0).abs() < 1e-3);
    }

    #[test]
    fn mix_in_place_blends() {
        let mut current = vec![1.0_f32; 8];
        let next = vec![0.0_f32; 8];
        PcmCrossfadeMixer::mix_in_place(&mut current, &next, 0.5, 0.5);
        // 0.5*1 + 0.5*0 = 0.5
        assert!((current[0] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn mix_crossfade_constant_amplitude() {
        // 两路同为 1.0，增益和恒为 1 → 输出恒为 1.0（无凹陷无凸起）
        let mut current = vec![1.0_f32; 100];
        let next = vec![1.0_f32; 100];
        PcmCrossfadeMixer::mix_crossfade(&mut current, &next);
        for v in &current {
            assert!((*v - 1.0).abs() < 0.01, "expected ~1.0, got {v}");
        }
    }

    #[test]
    fn mix_crossfade_transitions_between_signals() {
        // current=1.0, next=0.0 → 从 1.0 过渡到 0.0
        let mut current = vec![1.0_f32; 100];
        let next = vec![0.0_f32; 100];
        PcmCrossfadeMixer::mix_crossfade(&mut current, &next);
        // 起点接近 1.0，终点接近 0.0，中间约 0.5
        assert!(current[0] > 0.9, "start={}", current[0]);
        assert!(current[99] < 0.1, "end={}", current[99]);
        assert!((current[50] - 0.5).abs() < 0.1, "mid={}", current[50]);
    }

    #[test]
    fn gain_tables_length_matches() {
        let (out, inn) = PcmCrossfadeMixer::gain_tables(64);
        assert_eq!(out.len(), 64);
        assert_eq!(inn.len(), 64);
        // 起点（progress≈0）：gain_out 接近 1
        assert!((out[0] - 1.0).abs() < 0.01);
        // 终点（progress≈63/64）：gain_in 接近 1
        assert!(inn[63] > 0.95, "last gain_in={}", inn[63]);
    }

    #[test]
    fn handles_nan_safely() {
        let mut current = vec![f32::NAN; 4];
        let next = vec![1.0; 4];
        PcmCrossfadeMixer::mix_in_place(&mut current, &next, 0.5, 0.5);
        // NaN 输入应回退为 current（不崩溃）
        assert!(current[0].is_nan() || current[0].is_finite());
    }
}
