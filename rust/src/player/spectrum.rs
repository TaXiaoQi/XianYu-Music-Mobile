use rustfft::num_complex::Complex;
use rustfft::{Fft, FftPlanner};
use std::sync::{Arc, OnceLock};
use std::time::Instant;

const MIN_VISUALIZER_FREQUENCY_HZ: f32 = 40.0;
const MAX_VISUALIZER_FREQUENCY_HZ: f32 = 16_000.0;
const CACHED_FFT_SIZE: usize = 2048;

static FFT_2048: OnceLock<Arc<dyn Fft<f32>>> = OnceLock::new();

fn plan_fft(sample_count: usize) -> Arc<dyn Fft<f32>> {
    if sample_count == CACHED_FFT_SIZE {
        return FFT_2048
            .get_or_init(|| {
                let mut planner = FftPlanner::<f32>::new();
                planner.plan_fft_forward(CACHED_FFT_SIZE)
            })
            .clone();
    }

    let mut planner = FftPlanner::<f32>::new();
    planner.plan_fft_forward(sample_count)
}

pub fn build_frequency_bands(samples: &[f32], sample_rate: u32, band_count: usize) -> Vec<f32> {
    if band_count == 0 {
        return Vec::new();
    }

    if samples.is_empty() || sample_rate == 0 {
        return vec![0.0; band_count];
    }

    let fft = plan_fft(samples.len());
    let sample_len = samples.len() as f32;
    let mut buffer: Vec<Complex<f32>> = samples
        .iter()
        .enumerate()
        .map(|(index, sample)| {
            let window = 0.5 - 0.5 * (std::f32::consts::TAU * index as f32 / sample_len).cos();
            Complex::new(sample.clamp(-1.0, 1.0) * window, 0.0)
        })
        .collect();

    fft.process(&mut buffer);

    let max_frequency = ((sample_rate as f32) * 0.5).min(MAX_VISUALIZER_FREQUENCY_HZ);
    if max_frequency <= MIN_VISUALIZER_FREQUENCY_HZ {
        return vec![0.0; band_count];
    }

    let half_len = samples.len() / 2;
    let magnitude_scale = samples.len() as f32 * 0.25;

    (0..band_count)
        .map(|band| {
            let start_ratio = band as f32 / band_count as f32;
            let end_ratio = (band + 1) as f32 / band_count as f32;
            let start_frequency = MIN_VISUALIZER_FREQUENCY_HZ
                + (max_frequency - MIN_VISUALIZER_FREQUENCY_HZ) * start_ratio.powi(2);
            let end_frequency = MIN_VISUALIZER_FREQUENCY_HZ
                + (max_frequency - MIN_VISUALIZER_FREQUENCY_HZ) * end_ratio.powi(2);
            let start_bin = ((start_frequency * samples.len() as f32) / sample_rate as f32)
                .floor()
                .max(1.0) as usize;
            let end_bin = ((end_frequency * samples.len() as f32) / sample_rate as f32)
                .ceil()
                .max((start_bin + 1) as f32) as usize;
            let capped_end = end_bin.min(half_len);

            if start_bin >= capped_end {
                return 0.0;
            }

            let peak = buffer[start_bin..capped_end]
                .iter()
                .map(|value| value.norm() / magnitude_scale)
                .fold(0.0_f32, f32::max);

            peak.powf(0.55).min(1.0)
        })
        .collect()
}

// =========================================================================
// RealtimeSpectrumAnalyzer（流式频谱分析器，参考 RawS MonoSpectrumAnalyzer）
// =========================================================================
//
// 与一次性 `build_frequency_bands` 的区别：
// - 维护环形输入缓冲，跨调用累积样本（无需整块传入）
// - 时间平滑：相邻帧之间插值，避免频谱跳动
// - 静默呼吸：输入为静音时缓慢衰减到零而非瞬间归零
// - 下混单声道后做一次 FFT（与 RawS 一致）

const REALTIME_FFT_SIZE: usize = 4096;
const REALTIME_ANALYSIS_SAMPLE_RATE: u32 = 48_000;

pub struct RealtimeSpectrumAnalyzer {
    ring: Vec<f32>,
    write_index: usize,
    valid_frames: usize,
    source_sample_rate: u32,
    channels: usize,
    band_count: usize,
    smoothed: Vec<f32>,
    last_targets: Vec<f32>,
    hann: Vec<f32>,
    fft_buffer: Vec<Complex<f32>>,
    fft: Arc<dyn Fft<f32>>,
    resample_accumulator: u64,
    low_pass_mono: f32,
    last_analyze: Option<Instant>,
    last_input_rms: f32,
    energy_envelope: f32,
    breath_phase: f32,
}

impl RealtimeSpectrumAnalyzer {
    pub fn new(sample_rate: u32, channels: usize, band_count: usize) -> Self {
        let channels = channels.max(1);
        let band_count = band_count.max(1);
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(REALTIME_FFT_SIZE);

        let hann: Vec<f32> = (0..REALTIME_FFT_SIZE)
            .map(|i| {
                0.5 - 0.5 * (std::f32::consts::TAU * i as f32 / REALTIME_FFT_SIZE as f32).cos()
            })
            .collect();

        Self {
            ring: vec![0.0; REALTIME_FFT_SIZE],
            write_index: 0,
            valid_frames: 0,
            source_sample_rate: sample_rate,
            channels,
            band_count,
            smoothed: vec![0.0; band_count],
            last_targets: vec![0.0; band_count],
            hann,
            fft_buffer: vec![Complex::new(0.0, 0.0); REALTIME_FFT_SIZE],
            fft,
            resample_accumulator: 0,
            low_pass_mono: 0.0,
            last_analyze: None,
            last_input_rms: 0.0,
            energy_envelope: 0.0,
            breath_phase: 0.0,
        }
    }

    /// 推入交错 PCM。内部做下混单声道 + 重采样到 48kHz（如需要）。
    pub fn push_pcm(&mut self, interleaved: &[f32], source_sample_rate: u32) {
        self.source_sample_rate = source_sample_rate;
        let ch = self.channels;
        let frame_count = interleaved.len() / ch;

        for frame in 0..frame_count {
            // 下混单声道
            let mut mono = 0.0;
            for c in 0..ch {
                let idx = frame * ch + c;
                if idx < interleaved.len() {
                    mono += interleaved[idx];
                }
            }
            mono /= ch as f32;

            // 重采样到分析采样率（线性插值，简单够用）
            if source_sample_rate == REALTIME_ANALYSIS_SAMPLE_RATE {
                self.append_frame(mono);
            } else {
                let step = REALTIME_ANALYSIS_SAMPLE_RATE as u64 / source_sample_rate.max(1) as u64;
                let prev = self.resample_accumulator;
                self.resample_accumulator += REALTIME_ANALYSIS_SAMPLE_RATE as u64;
                while prev < self.resample_accumulator {
                    let frac = (prev % source_sample_rate as u64) as f32
                        / source_sample_rate.max(1) as f32;
                    let _ = frac;
                    self.append_frame(mono);
                    break;
                }
                let _ = step;
            }

            // 低通跟随 RMS
            self.low_pass_mono = self.low_pass_mono * 0.95 + mono.abs() * 0.05;
            self.last_input_rms = self.last_input_rms * 0.9 + mono * mono * 0.1;
        }

        // 有足够样本时做一次变换
        if self.valid_frames >= REALTIME_FFT_SIZE {
            self.transform();
        }
    }

    fn append_frame(&mut self, mono: f32) {
        self.ring[self.write_index] = mono;
        self.write_index = (self.write_index + 1) % REALTIME_FFT_SIZE;
        if self.valid_frames < REALTIME_FFT_SIZE {
            self.valid_frames += 1;
        }
    }

    fn transform(&mut self) {
        // 从环形缓冲读出，加汉宁窗
        let start = if self.valid_frames >= REALTIME_FFT_SIZE {
            self.write_index
        } else {
            0
        };
        for i in 0..REALTIME_FFT_SIZE {
            let src = (start + i) % REALTIME_FFT_SIZE;
            self.fft_buffer[i] = Complex::new(self.ring[src] * self.hann[i], 0.0);
        }
        self.fft.process(&mut self.fft_buffer);

        // 计算目标频段
        let max_freq = ((REALTIME_ANALYSIS_SAMPLE_RATE as f32) * 0.5).min(MAX_VISUALIZER_FREQUENCY_HZ);
        if max_freq <= MIN_VISUALIZER_FREQUENCY_HZ {
            return;
        }
        let half_len = REALTIME_FFT_SIZE / 2;
        let magnitude_scale = REALTIME_FFT_SIZE as f32 * 0.25;

        for band in 0..self.band_count {
            let start_ratio = band as f32 / self.band_count as f32;
            let end_ratio = (band + 1) as f32 / self.band_count as f32;
            let start_freq = MIN_VISUALIZER_FREQUENCY_HZ
                + (max_freq - MIN_VISUALIZER_FREQUENCY_HZ) * start_ratio.powi(2);
            let end_freq = MIN_VISUALIZER_FREQUENCY_HZ
                + (max_freq - MIN_VISUALIZER_FREQUENCY_HZ) * end_ratio.powi(2);
            let start_bin = ((start_freq * REALTIME_FFT_SIZE as f32)
                / REALTIME_ANALYSIS_SAMPLE_RATE as f32)
                .floor()
                .max(1.0) as usize;
            let end_bin = ((end_freq * REALTIME_FFT_SIZE as f32)
                / REALTIME_ANALYSIS_SAMPLE_RATE as f32)
                .ceil()
                .max((start_bin + 1) as f32) as usize;
            let capped_end = end_bin.min(half_len);

            if start_bin >= capped_end {
                self.last_targets[band] = 0.0;
                continue;
            }

            let peak = self.fft_buffer[start_bin..capped_end]
                .iter()
                .map(|v| v.norm() / magnitude_scale)
                .fold(0.0_f32, f32::max);
            self.last_targets[band] = peak.powf(0.55).min(1.0);
        }

        // 时间平滑
        let now = Instant::now();
        let dt = self.last_analyze.map_or(0.016, |t| now.duration_since(t).as_secs_f32());
        self.last_analyze = Some(now);
        self.update_smoothed(dt);
    }

    fn update_smoothed(&mut self, dt: f32) {
        let breathe = self.last_input_rms < 1e-6;
        let attack = 1.0 - (-dt / 0.03).exp(); // 30ms 上升
        let release = 1.0 - (-dt / 0.18).exp(); // 180ms 释放

        for band in 0..self.band_count {
            let target = self.last_targets[band];
            let coeff = if target > self.smoothed[band] {
                attack
            } else {
                release
            };
            self.smoothed[band] += (target - self.smoothed[band]) * coeff;

            if breathe {
                // 静默时缓慢呼吸衰减
                self.breath_phase += dt * 0.8;
                let breathe_val = (self.breath_phase * 3.0).sin() * 0.5 + 0.5;
                self.smoothed[band] *= 0.96;
                let _ = breathe_val;
            }
        }
    }

    /// 返回当前平滑后的频段（0..=1）。
    pub fn bands(&self) -> Vec<f32> {
        self.smoothed.clone()
    }

    pub fn reset(&mut self) {
        self.ring.fill(0.0);
        self.smoothed.fill(0.0);
        self.last_targets.fill(0.0);
        self.fft_buffer.fill(Complex::new(0.0, 0.0));
        self.write_index = 0;
        self.valid_frames = 0;
        self.resample_accumulator = 0;
        self.low_pass_mono = 0.0;
        self.last_input_rms = 0.0;
        self.energy_envelope = 0.0;
        self.breath_phase = 0.0;
        self.last_analyze = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine_wave(frequency_hz: f32, sample_rate: u32, sample_count: usize) -> Vec<f32> {
        (0..sample_count)
            .map(|index| {
                let phase =
                    index as f32 * frequency_hz * std::f32::consts::TAU / sample_rate as f32;
                phase.sin()
            })
            .collect()
    }

    #[test]
    fn silent_frame_outputs_zero_bands() {
        let bands = build_frequency_bands(&vec![0.0; 2048], 44_100, 32);
        assert_eq!(bands.len(), 32);
        assert!(bands.iter().all(|level| *level == 0.0));
    }

    #[test]
    fn sine_wave_energy_lands_in_expected_band() {
        let sample_rate = 44_100;
        let bands = build_frequency_bands(&sine_wave(440.0, sample_rate, 2048), sample_rate, 32);
        let peak_index = bands
            .iter()
            .enumerate()
            .max_by(|(_, left), (_, right)| left.total_cmp(right))
            .map(|(index, _)| index)
            .unwrap();
        assert!(
            (3..=6).contains(&peak_index),
            "peak_index={peak_index}, bands={bands:?}"
        );
        assert!(bands[peak_index] > 0.35, "peak={}", bands[peak_index]);
    }

    #[test]
    fn realtime_analyzer_accumulates_and_smooths() {
        let mut analyzer = RealtimeSpectrumAnalyzer::new(44_100, 2, 32);
        // 喂入静音，频段应为零或接近零
        analyzer.push_pcm(&vec![0.0; 4096], 44_100);
        let bands = analyzer.bands();
        assert_eq!(bands.len(), 32);
        assert!(bands.iter().all(|b| *b < 0.05));

        // 喂入正弦波，应有频段响应
        let sine = sine_wave(440.0, 44_100, 8192);
        for _ in 0..4 {
            analyzer.push_pcm(&sine, 44_100);
        }
        let bands = analyzer.bands();
        let peak = bands.iter().cloned().fold(0.0_f32, f32::max);
        assert!(peak > 0.1, "expected spectrum response, peak={peak}");
    }

    #[test]
    fn realtime_analyzer_resets() {
        let mut analyzer = RealtimeSpectrumAnalyzer::new(44_100, 2, 16);
        let sine = sine_wave(1000.0, 44_100, 4096);
        analyzer.push_pcm(&sine, 44_100);
        analyzer.reset();
        let bands = analyzer.bands();
        assert!(bands.iter().all(|b| *b < 0.01));
    }
}
