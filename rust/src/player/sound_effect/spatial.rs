//! 空间音效机架（3D / 8D / 36D / 虚拟多声道）。
//!
//! 2026-08-02 完全重新实现，对齐 YinDongMusic 听感 + 解决"开效果声音变小"问题。
//!
//! ## 核心改进
//!
//! ### 音量保持（旧版最大问题）
//! 旧版叠加了 4 层衰减（距离 atten + 后方 back_gain + 等功率pan中心-3dB + 单声道折叠-3dB），
//! 导致开启空间音效后音量骤降。新版：
//! - **近耳增益 = 1.0**（中心方位不衰减，仅远耳有头影衰减）
//! - **距离衰减 = 1/max(1,dist)**（refDistance=1，距离≤1 时不衰减，匹配 WebAudio inverse 模型）
//! - **单声道折叠补偿**：`(L+R)*0.5` 后近耳获得全量信号，中心方位输出 = 输入（零损耗）
//! - **无 back_gain**：前后区分由 ITD/ILD/距离低通自然实现，不额外衰减
//!
//! ### 8D/36D 双耳合成（Binaural Synthesis）
//! 无需 HRIR 数据文件，用三重耳间线索近似 WebAudio HRTF PannerNode：
//! 1. **ITD（耳间时间差）**：远耳延迟 max 0.6ms，按 |sin(方位角)| 缩放
//! 2. **ILD（耳间电平差）**：远耳增益 1.0→0.7（-3dB），按方位角缩放
//! 3. **头影低通**：远耳高频衰减，截止 20000→5000Hz 按 |sin(方位角)| 缩放
//! 声源位置匹配 YinDongMusic startPanner8D/36D。
//!
//! ### 3D 环绕（非 HRTF，立体声旋转）
//! 匹配 YinDongMusic startPanner 的 non-HRTF PannerNode（equalpower panning）：
//! 位置 `(sin, cos, cos) * r` 对角面旋转，等功率 pan + 距离低通。
//!
//! ### 速度映射修正
//! - 3D：`spatial_speed` 是倍率（0.2-4.0），转换为秒/圈 = 3.6 * speed
//!   （YinDongMusic: interval=speed*10ms, 1°/tick → 3.6*speed 秒/圈）
//! - 8D/36D：`spatial_speed` 直接是秒/圈（2-60），无需转换
//! - 8D/36D 忽略 `spatial_intensity`（该字段是 3D 专用），始终全强度

use super::dsp::{Biquad, DelayLine, SmoothedValue};
use super::{SoundEffectSettings, SpatialMode, VirtualSurroundMode};
use std::f32::consts::PI;

/// √2，用于等功率 pan 归一化（中心方位补 +3dB，使中心输出 = 输入）
const SQRT_2: f32 = 1.41421356;

/// 最大 ITD（耳间时间差）≈ 0.6ms（球径 ~21cm，声速 343m/s）
const MAX_ITD_MS: f32 = 0.6;
/// 远耳 ILD 增益下限（90° 方位时远耳增益 = 1.0 - 1.0*0.3 = 0.7，约 -3dB）
const ILD_MAX_ATTEN: f32 = 0.3;
/// 头影低通截止范围：中心 20000Hz（透明），90°方位 5000Hz（明显高频衰减）
const SHADOW_CUTOFF_MIN: f32 = 5000.0;
const SHADOW_CUTOFF_MAX: f32 = 20000.0;
/// 空气吸收低通范围（36D）：近 20000Hz，远 2500Hz
const AIR_CUTOFF_MIN: f32 = 2500.0;
const AIR_CUTOFF_MAX: f32 = 20000.0;
/// 3D 环绕后方低通（非 HRTF，简化前后区分）
const REAR_CUTOFF: f32 = 6000.0;
const FRONT_CUTOFF: f32 = 20000.0;

pub struct SpatialRack {
    sample_rate: f32,
    enabled: SmoothedValue,
    /// 旋转角（弧度），3D/8D/36D 共用
    angle: f32,
    /// ITD 延迟线（2 条：左远耳路径、右远耳路径，双缓冲避免切换跳变）
    cross_dl: [DelayLine; 2],
    /// 头影低通（2 条：左远耳、右远耳，模拟头影高频衰减）
    head_shadow_lp: [Biquad; 2],
    /// 空气吸收低通（36D 距离效应，2 条 L/R）
    air_lp: [Biquad; 2],
    /// 3D 环绕距离/前后低通（2 条 L/R）
    dist_lp: [Biquad; 2],
    /// 缓存上次头影截止频率（仅在变化 > 100Hz 时重算 biquad 系数）
    last_shadow_cutoff: f32,
    /// 缓存上次空气低通截止频率
    last_air_cutoff: f32,
    /// 缓存上次 3D 距离低通截止频率
    last_dist_cutoff: f32,
    /// 虚拟多声道：各扬声器延迟
    virt_delay: [DelayLine; 2],
    virt_delay2: [DelayLine; 2],
    /// 当前模式（参数变更检测）
    cur_mode: SpatialMode,
}

impl SpatialRack {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            enabled: SmoothedValue::new(0.0),
            angle: 0.0,
            cross_dl: [DelayLine::new(128), DelayLine::new(128)],
            head_shadow_lp: [Biquad::new(2), Biquad::new(2)],
            air_lp: [Biquad::new(2), Biquad::new(2)],
            dist_lp: [Biquad::new(2), Biquad::new(2)],
            last_shadow_cutoff: f32::NAN,
            last_air_cutoff: f32::NAN,
            last_dist_cutoff: f32::NAN,
            virt_delay: [DelayLine::new(8192), DelayLine::new(8192)],
            virt_delay2: [DelayLine::new(8192), DelayLine::new(8192)],
            cur_mode: SpatialMode::None,
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, _channels: usize) {
        self.sample_rate = sample_rate;
        self.enabled.set_time_constant(0.08, sample_rate);
        // ITD 延迟线：最大 0.6ms → 0.6ms * sr 样本，留余量到 2x
        let cross_size = ((sample_rate * MAX_ITD_MS / 500.0) as usize)
            .next_power_of_two()
            .max(128);
        for d in &mut self.cross_dl {
            d.resize(cross_size);
        }
        for d in &mut self.virt_delay {
            d.resize(((sample_rate * 0.1) as usize).next_power_of_two().max(8192));
        }
        for d in &mut self.virt_delay2 {
            d.resize(((sample_rate * 0.1) as usize).next_power_of_two().max(8192));
        }
        for f in &mut self.head_shadow_lp {
            f.resize_channels(2);
        }
        for f in &mut self.air_lp {
            f.resize_channels(2);
        }
        for f in &mut self.dist_lp {
            f.resize_channels(2);
        }
        self.last_shadow_cutoff = f32::NAN;
        self.last_air_cutoff = f32::NAN;
        self.last_dist_cutoff = f32::NAN;
    }

    pub fn reset(&mut self) {
        for d in &mut self.cross_dl {
            d.clear();
        }
        for d in &mut self.virt_delay {
            d.clear();
        }
        for d in &mut self.virt_delay2 {
            d.clear();
        }
        for f in &mut self.head_shadow_lp {
            f.reset();
        }
        for f in &mut self.air_lp {
            f.reset();
        }
        for f in &mut self.dist_lp {
            f.reset();
        }
        self.angle = 0.0;
        self.last_shadow_cutoff = f32::NAN;
        self.last_air_cutoff = f32::NAN;
        self.last_dist_cutoff = f32::NAN;
    }

    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        let active = s.spatial_mode != SpatialMode::None;
        self.enabled.set_target(if active { 1.0 } else { 0.0 });

        if s.spatial_mode != self.cur_mode {
            self.cur_mode = s.spatial_mode.clone();
            // 模式切换时重置角度与低通缓存，避免相位跳变
            self.angle = 0.0;
            self.last_shadow_cutoff = f32::NAN;
            self.last_air_cutoff = f32::NAN;
            self.last_dist_cutoff = f32::NAN;
        }
    }

    /// 设置头影低通截止（带缓存，仅在变化 > 100Hz 时重算系数）
    #[inline]
    fn set_shadow_cutoff(&mut self, cutoff: f32) {
        let cutoff = cutoff.clamp(SHADOW_CUTOFF_MIN, SHADOW_CUTOFF_MAX);
        if !self.last_shadow_cutoff.is_finite() || (cutoff - self.last_shadow_cutoff).abs() > 100.0
        {
            self.last_shadow_cutoff = cutoff;
            self.head_shadow_lp[0].set_lowpass(cutoff, self.sample_rate, 0.707);
            self.head_shadow_lp[1].set_lowpass(cutoff, self.sample_rate, 0.707);
        }
    }

    /// 设置空气吸收低通截止（带缓存）
    #[inline]
    fn set_air_cutoff(&mut self, cutoff: f32) {
        let cutoff = cutoff.clamp(AIR_CUTOFF_MIN, AIR_CUTOFF_MAX);
        if !self.last_air_cutoff.is_finite() || (cutoff - self.last_air_cutoff).abs() > 100.0 {
            self.last_air_cutoff = cutoff;
            self.air_lp[0].set_lowpass(cutoff, self.sample_rate, 0.5);
            self.air_lp[1].set_lowpass(cutoff, self.sample_rate, 0.5);
        }
    }

    /// 设置 3D 距离/前后低通截止（带缓存）
    #[inline]
    fn set_dist_cutoff(&mut self, cutoff: f32) {
        let cutoff = cutoff.clamp(2000.0, FRONT_CUTOFF);
        if !self.last_dist_cutoff.is_finite() || (cutoff - self.last_dist_cutoff).abs() > 100.0 {
            self.last_dist_cutoff = cutoff;
            self.dist_lp[0].set_lowpass(cutoff, self.sample_rate, 0.707);
            self.dist_lp[1].set_lowpass(cutoff, self.sample_rate, 0.707);
        }
    }

    /// 处理一帧（frame[0]=L, frame[1]=R）
    pub fn process(&mut self, frame: &mut [f32], channels: u16, s: &SoundEffectSettings) {
        if channels != 2 || frame.len() < 2 {
            return;
        }
        let w = self.enabled.tick();
        if w < 0.001 {
            return;
        }
        let in_l = frame[0];
        let in_r = frame[1];

        let out = match s.spatial_mode {
            SpatialMode::Surround3d => self.process_3d(in_l, in_r, s),
            SpatialMode::D8 => self.process_8d(in_l, in_r, s),
            SpatialMode::D36 => self.process_36d(in_l, in_r, s),
            SpatialMode::Virtual => self.process_virtual(in_l, in_r, s),
            SpatialMode::None => (in_l, in_r),
        };

        // enabled 平滑过渡（bypass ↔ 全效果），w=1 时完全使用空间化输出
        frame[0] = in_l * (1.0 - w) + out.0 * w;
        frame[1] = in_r * (1.0 - w) + out.1 * w;
    }

    /// 更新旋转角。返回当前角度 rad。
    /// seconds_per_rev: 旋转一圈所需秒数
    #[inline]
    fn update_angle(&mut self, seconds_per_rev: f32) -> f32 {
        let spr = seconds_per_rev.max(0.1);
        self.angle += 2.0 * PI / (spr * self.sample_rate);
        if self.angle >= 2.0 * PI {
            self.angle -= 2.0 * PI;
        }
        self.angle
    }

    // =====================================================================
    // 3D 环绕（非 HRTF，立体声旋转）
    // =====================================================================

    /// 3D 环绕：匹配 YinDongMusic startPanner 的 non-HRTF PannerNode（equalpower）。
    ///
    /// 位置模式：`(sin(rad), cos(rad), cos(rad)) * radius` —— 对角面旋转（水平+垂直）。
    /// 速度：`spatial_speed` 是倍率（0.2-4.0），秒/圈 = 3.6 * speed
    /// （YinDongMusic: interval = speed * 10ms, 每tick 1°, → 360*speed*10ms = 3.6*speed 秒/圈）。
    /// 强度：`spatial_intensity` 控制效果深度（dry/wet 混合比例）。
    fn process_3d(&mut self, in_l: f32, in_r: f32, s: &SoundEffectSettings) -> (f32, f32) {
        // 3D 速度参数是倍率，转换为秒/圈
        let spr = 3.6 * s.spatial_speed.max(0.1);
        let rad = self.update_angle(spr);
        let radius = s.spatial_radius.max(0.1);

        // 位置 (sin, cos, cos) * radius（YinDongMusic startPanner 对角面）
        let x = rad.sin() * radius;
        let z = rad.cos() * radius;
        let dist = (x * x + z * z).sqrt();

        // 距离衰减（inverse, refDistance=1, ≤1 不衰减）
        let dist_gain = 1.0 / dist.max(1.0);

        // 方位角（听众在原点面朝 -Z，azimuth = atan2(x, -z)）
        let azimuth = x.atan2(-z);
        // pan: -1=左, 0=中, +1=右
        let pan = azimuth.sin().clamp(-1.0, 1.0);

        // 等功率 pan（归一化：中心 = 1.0，不衰减）
        // l = cos((pan+1)*π/4) * √2, r = sin((pan+1)*π/4) * √2
        // 中心(pan=0): l=r=0.707*1.414=1.0
        let pa = (pan + 1.0) * 0.25 * PI;
        let l_gain = pa.cos() * SQRT_2;
        let r_gain = pa.sin() * SQRT_2;

        // 前后区分：后方（z>0，即 cos(rad)<0）降低低通截止（模拟头影）
        // 3D 位置 z=cos(rad)*radius，z>0 → 后方
        let front_back = rad.cos(); // +1=前, -1=后
        let cutoff = if front_back < 0.0 {
            FRONT_CUTOFF + (REAR_CUTOFF - FRONT_CUTOFF) * (-front_back) // 后方 20000→6000
        } else {
            FRONT_CUTOFF
        };
        self.set_dist_cutoff(cutoff);

        // 单声道折叠（3D 非双耳，等功率 mono）
        let src = (in_l + in_r) * 0.5;

        // 等功率 pan + 距离衰减 + 前后低通
        let panned_l = src * l_gain * dist_gain;
        let panned_r = src * r_gain * dist_gain;
        let out_l = self.dist_lp[0].process(panned_l, 0);
        let out_r = self.dist_lp[1].process(panned_r, 1);

        // 强度混合（3D 专用：spatial_intensity 控制效果深度）
        let intensity = (s.spatial_intensity / 10.0).clamp(0.1, 1.0);
        (
            in_l * (1.0 - intensity) + out_l * intensity,
            in_r * (1.0 - intensity) + out_r * intensity,
        )
    }

    // =====================================================================
    // 8D 环绕（HRTF 近似，双耳合成）
    // =====================================================================

    /// 8D：匹配 YinDongMusic startPanner8D 的 HRTF PannerNode。
    ///
    /// 位置模式：`(cos(rad)*r, 0, sin(rad)*r)` —— 水平面 X-Z 圆周。
    /// 速度：`spatial_speed` 直接是秒/圈（2-60）。
    /// 全强度（8D 无强度调节，忽略 spatial_intensity）。
    ///
    /// 双耳合成：
    /// - 近耳（ipsilateral）：直接信号，增益 1.0（无衰减）
    /// - 远耳（contralateral）：ITD 延迟 + ILD 增益衰减 + 头影低通
    /// - 距离衰减：1/max(1,dist)（refDistance=1 时不衰减）
    fn process_8d(&mut self, in_l: f32, in_r: f32, s: &SoundEffectSettings) -> (f32, f32) {
        let spr = s.spatial_speed.max(0.5);
        let rad = self.update_angle(spr);
        let radius = s.spatial_radius.max(0.1);

        // 3D 位置（YinDongMusic startPanner8D: x=cos*r, y=0, z=sin*r）
        let x = rad.cos() * radius;
        let z = rad.sin() * radius;
        let dist = (x * x + z * z).sqrt(); // = radius

        self.binaural(in_l, in_r, x, 0.0, z, dist)
    }

    // =====================================================================
    // 36D 环绕（8D + 垂直摆动 + 距离波动 + 空气低通）
    // =====================================================================

    /// 36D：匹配 YinDongMusic startPanner36D。
    ///
    /// 在 8D 水平旋转基础上叠加三层动态（全部绑定旋转角 rad）：
    /// 1. 距离波动 ±60%：`r' = max(0.3, radius * (1 + 0.6*sin(rad*0.5)))`
    /// 2. 垂直摆动：`y = sin(rad*1.5) * radius`（1.5 倍频率，螺旋感）
    /// 3. 空气低通：`cutoff = 20000 - distRatio * 17500`（远闷近亮）
    ///
    /// 速度：`spatial_speed` 直接是秒/圈（2-60）。全强度（忽略 spatial_intensity）。
    fn process_36d(&mut self, in_l: f32, in_r: f32, s: &SoundEffectSettings) -> (f32, f32) {
        let spr = s.spatial_speed.max(0.5);
        let rad = self.update_angle(spr);
        let base_radius = s.spatial_radius.max(0.1);

        // 1. 距离波动 ±60%（半旋转频率呼吸）+ 半径下限保护
        let r = (base_radius * (1.0 + 0.6 * (rad * 0.5).sin())).max(0.3);

        // 2. 水平旋转（X-Z 平面）
        let x = rad.cos() * r;
        let z = rad.sin() * r;

        // 3. 垂直摆动（Y 轴）：sin(rad*1.5) 错开水平旋转，幅度 = baseR
        let y = (rad * 1.5).sin() * base_radius;

        // 4. 总距离 = sqrt(x²+y²+z²)（x²+z²=r²）
        let dist = (r * r + y * y).sqrt();

        // 5. 空气吸收低通：距离越远高频越衰减（20000→2500Hz）
        let dist_ratio = (dist / (base_radius * 1.8 + 0.01)).min(1.0);
        let air_cutoff = AIR_CUTOFF_MAX - dist_ratio * (AIR_CUTOFF_MAX - AIR_CUTOFF_MIN);
        self.set_air_cutoff(air_cutoff);

        // 双耳合成（含空气低通）
        self.binaural_with_air_lp(in_l, in_r, x, y, z, dist)
    }

    // =====================================================================
    // 双耳合成核心（8D/36D 共用）
    // =====================================================================

    /// 双耳合成：将立体声折叠为单声道源，按 3D 位置分配到左右耳。
    ///
    /// 近耳（声源同侧）：直接信号，增益 1.0（无衰减）。
    /// 远耳（声源对侧）：ITD 延迟 + ILD 增益衰减 + 头影低通。
    /// 距离衰减：1/max(1,dist)（refDistance=1 时不衰减，匹配 WebAudio inverse）。
    ///
    /// 音量保持：中心方位（azimuth=0）时两耳均获全量信号，输出 = 输入（零损耗）。
    #[inline]
    fn binaural(&mut self, in_l: f32, in_r: f32, x: f32, _y: f32, z: f32, dist: f32) -> (f32, f32) {
        // 单声道折叠（等功率 mono）
        let src = (in_l + in_r) * 0.5;
        // 距离衰减（inverse, refDistance=1）
        let dist_gain = 1.0 / dist.max(1.0);
        let src_d = src * dist_gain;

        // 方位角（听众面朝 -Z，azimuth = atan2(x, -z)）
        let azimuth = x.atan2(-z);
        // pan: -1=左, 0=中, +1=右（sin(azimuth)，azimuth=π/2→pan=1=右）
        let pan = azimuth.sin().clamp(-1.0, 1.0);
        let pan_abs = pan.abs();

        // ITD 延迟（max 0.6ms，按 |pan| 缩放）
        let max_itd_samples = self.sample_rate * MAX_ITD_MS / 1000.0;
        let itd = pan_abs * max_itd_samples;

        // ILD 增益衰减（远耳 max -3dB，按 |pan| 缩放）
        let ild_gain = 1.0 - pan_abs * ILD_MAX_ATTEN;

        // 头影低通截止（中心 20000Hz 透明，90° 5000Hz 明显衰减）
        let shadow_cutoff = SHADOW_CUTOFF_MAX - pan_abs * (SHADOW_CUTOFF_MAX - SHADOW_CUTOFF_MIN);
        self.set_shadow_cutoff(shadow_cutoff);

        // 写入两条延迟线（双缓冲，避免左右切换时读取到陈旧数据）
        self.cross_dl[0].write(src_d);
        self.cross_dl[1].write(src_d);

        // 近耳：直接信号（无延迟、无低通、无衰减）
        let near = src_d;

        // 远耳：ITD 延迟 + 头影低通 + ILD 衰减
        let (out_l, out_r) = if pan >= 0.0 {
            // 声源偏右 → 左耳是远耳（延迟+低通+衰减），右耳是近耳（直接）
            let far = self.cross_dl[0].read(itd);
            let far = self.head_shadow_lp[0].process(far, 0) * ild_gain;
            (far, near)
        } else {
            // 声源偏左 → 右耳是远耳，左耳是近耳
            let far = self.cross_dl[1].read(itd);
            let far = self.head_shadow_lp[1].process(far, 1) * ild_gain;
            (near, far)
        };

        (out_l, out_r)
    }

    /// 双耳合成 + 空气吸收低通（36D 专用）
    #[inline]
    fn binaural_with_air_lp(
        &mut self,
        in_l: f32,
        in_r: f32,
        x: f32,
        y: f32,
        z: f32,
        dist: f32,
    ) -> (f32, f32) {
        // 先做双耳合成
        let (l, r) = self.binaural(in_l, in_r, x, y, z, dist);
        // 再施加空气吸收低通（距离越远越闷，对双耳相同）
        let out_l = self.air_lp[0].process(l, 0);
        let out_r = self.air_lp[1].process(r, 1);
        (out_l, out_r)
    }

    // =====================================================================
    // 虚拟多声道（5.1/7.1）
    // =====================================================================

    /// 虚拟多声道（5.1/7.1）：立体声分配到多扬声器位置后 downmix。
    /// 保持旧实现（用户未反馈此功能问题），仅微调增益避免削波。
    fn process_virtual(&mut self, in_l: f32, in_r: f32, s: &SoundEffectSettings) -> (f32, f32) {
        let sr = self.sample_rate;
        let spread = (s.virtual_surround_spread / 10.0).clamp(0.3, 2.0);
        let is_71 = s.virtual_surround_mode == VirtualSurroundMode::SevenOne;

        // 中置 = (L+R)/2 * 0.6（避免中置过响）
        let center = (in_l + in_r) * 0.5 * 0.6;

        // 侧环绕（SL/SR）：延迟 ~15ms
        let sl_delay = (sr * 0.015) as f32;
        let sr_delay = (sr * 0.015) as f32;
        self.virt_delay[0].write(in_l * 0.5);
        self.virt_delay[1].write(in_r * 0.5);
        let sl = self.virt_delay[0].read(sl_delay);
        let sr = self.virt_delay[1].read(sr_delay);

        let mut out_l = in_l * 0.9 + center * 0.7 + sl * 0.5 * spread;
        let mut out_r = in_r * 0.9 + center * 0.7 + sr * 0.5 * spread;

        if is_71 {
            // 后环绕（RL/RR）：延迟 ~30ms
            let rl_delay = (sr * 0.030) as f32;
            let rr_delay = (sr * 0.030) as f32;
            self.virt_delay2[0].write(in_l * 0.4);
            self.virt_delay2[1].write(in_r * 0.4);
            let rl = self.virt_delay2[0].read(rl_delay);
            let rr = self.virt_delay2[1].read(rr_delay);
            out_l += rl * 0.4 * spread;
            out_r += rr * 0.4 * spread;
        }

        // 交叉馈送增强空间感（幅度受 spread 控制）
        let cross = 0.1 * spread;
        out_l = out_l * (1.0 - cross) + in_r * cross;
        out_r = out_r * (1.0 - cross) + in_l * cross;

        (out_l, out_r)
    }
}

// =========================================================================
// 单元测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn settings_for(mode: SpatialMode) -> SoundEffectSettings {
        let mut s = SoundEffectSettings::default();
        s.spatial_mode = mode;
        s.spatial_speed = 10.0; // 10 秒/圈（8D/36D）或倍率（3D）
        s.spatial_radius = 1.0; // refDistance=1，无距离衰减
        s.spatial_intensity = 10.0;
        s
    }

    #[test]
    fn test_no_nan_8d() {
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for(SpatialMode::D8);
        rack.update_params(&s);
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "L NaN/Inf");
            assert!(frame[1].is_finite(), "R NaN/Inf");
        }
    }

    #[test]
    fn test_no_nan_36d() {
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for(SpatialMode::D36);
        rack.update_params(&s);
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "L NaN/Inf");
            assert!(frame[1].is_finite(), "R NaN/Inf");
        }
    }

    #[test]
    fn test_no_nan_3d() {
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for(SpatialMode::Surround3d);
        rack.update_params(&s);
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "L NaN/Inf");
            assert!(frame[1].is_finite(), "R NaN/Inf");
        }
    }

    #[test]
    fn test_volume_preserved_8d() {
        // 8D 开启后，1 秒内 RMS 不应显著低于输入 RMS（旧版会降到 ~40%）
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for(SpatialMode::D8);
        rack.update_params(&s);

        let mut sum_sq = 0.0_f32;
        let n = 44100_usize;
        for _ in 0..n {
            let mut frame = [0.5_f32, 0.5]; // 立体声输入
            rack.process(&mut frame, 2, &s);
            sum_sq += frame[0] * frame[0] + frame[1] * frame[1];
        }
        let rms = (sum_sq / (2.0 * n as f32)).sqrt();
        // 输入 RMS = 0.5。8D 双耳合成在中心方位时输出 ≈ 输入，
        // 旋转过程中近耳保持全量，远耳衰减有限。RMS 应 > 0.35（旧版 < 0.2）
        assert!(rms > 0.35, "8D RMS={} 过低（音量损失过大）", rms);
    }

    #[test]
    fn test_volume_preserved_36d() {
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for(SpatialMode::D36);
        rack.update_params(&s);

        let mut sum_sq = 0.0_f32;
        let n = 44100_usize;
        for _ in 0..n {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
            sum_sq += frame[0] * frame[0] + frame[1] * frame[1];
        }
        let rms = (sum_sq / (2.0 * n as f32)).sqrt();
        // 36D 有距离波动（±60%）+ 空气低通，RMS 略低于 8D 但应 > 0.3
        assert!(rms > 0.3, "36D RMS={} 过低（音量损失过大）", rms);
    }

    #[test]
    fn test_volume_preserved_3d() {
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for(SpatialMode::Surround3d);
        rack.update_params(&s);

        let mut sum_sq = 0.0_f32;
        let n = 44100_usize;
        for _ in 0..n {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
            sum_sq += frame[0] * frame[0] + frame[1] * frame[1];
        }
        let rms = (sum_sq / (2.0 * n as f32)).sqrt();
        // 3D 归一化等功率 pan（中心 = 1.0），RMS 应接近输入 0.5
        assert!(rms > 0.35, "3D RMS={} 过低（音量损失过大）", rms);
    }

    #[test]
    fn test_bypass_passthrough() {
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let mut s = SoundEffectSettings::default();
        s.spatial_mode = SpatialMode::None;
        rack.update_params(&s);
        // enabled.target=0，灌足够样本让 enabled 平滑到 ~0
        for _ in 0..20000 {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
        }
        let mut frame = [0.42_f32, -0.17];
        rack.process(&mut frame, 2, &s);
        assert!(
            (frame[0] - 0.42).abs() < 1e-6,
            "bypass 后 L 不等于输入: {}",
            frame[0]
        );
        assert!(
            (frame[1] + 0.17).abs() < 1e-6,
            "bypass 后 R 不等于输入: {}",
            frame[1]
        );
    }

    #[test]
    fn test_rotation_produces_stereo_variation() {
        // 8D 旋转应产生 L/R 通道差异（声源绕头旋转，不可能始终 L=R）
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let mut s = settings_for(SpatialMode::D8);
        s.spatial_speed = 2.0; // 2 秒/圈（快速旋转，1 秒覆盖半圈）
        rack.update_params(&s);

        let mut max_diff = 0.0_f32;
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.5]; // 立体声输入（L=R）
            rack.process(&mut frame, 2, &s);
            max_diff = max_diff.max((frame[0] - frame[1]).abs());
        }
        // 旋转半圈应经过 90° 方位（L≠R 最大差异），max_diff 应 > 0.05
        assert!(
            max_diff > 0.05,
            "8D 旋转未产生 L/R 差异（max_diff={}）",
            max_diff
        );
    }

    #[test]
    fn test_3d_speed_conversion() {
        // 3D 速度参数是倍率，应转换为秒/圈 = 3.6 * speed
        // speed=1.0 → 3.6 秒/圈 → 1 秒后角度 ≈ 2π/3.6 ≈ 1.745 rad
        let mut rack = SpatialRack::new();
        rack.prepare(44100.0, 2);
        let mut s = settings_for(SpatialMode::Surround3d);
        s.spatial_speed = 1.0; // 倍率 1.0 → 3.6 秒/圈
        rack.update_params(&s);
        // 灌 1 秒样本
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
        }
        // 角度应 ≈ 2π/3.6 ≈ 1.745 rad（允许 ±0.1 容差）
        let expected = 2.0 * PI / 3.6;
        assert!(
            (rack.angle - expected).abs() < 0.15,
            "3D 速度转换错误: angle={} expected≈{}",
            rack.angle,
            expected
        );
    }
}