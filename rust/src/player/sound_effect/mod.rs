//! 音效处理模块（sound_effect）。
//!
//! 从桌面端 `XianYu-Music-Desktop` 抽取的可复用音效 DSP 核心。
//! 不含 rodio / Tauri 依赖，可被 Flutter（flutter_rust_bridge）宿主跨平台复用。
//!
//! 处理链顺序（每帧 L/R 同时处理）：
//! 变调变速 → 声道处理 → 波形整形 → 动态 → 调制 → 混响 → 空间 → audioBoost
//!
//! 各子模块：
//! - `dsp`：共享 DSP 原语（Biquad/DelayLine/LFO/平滑值/包络跟随器）
//! - `channel`：声道处理（消人声/单声道/交换/拓宽/分离度/Crossfeed/BassBoost/DynamicEQ）
//! - `shaper`：波形整形（失真/激励器/次低音/比特粉碎/LoFi）
//! - `dynamics`：动态类（噪声门/扩展器/压缩/多段/去齿音/限制器/AGC）
//! - `modulation`：调制类（抖音/颤音/音调漂移/镶边/相位/延迟）
//! - `reverb`：混响（Freeverb 算法，8 梳状 + 4 全通，每样本 O(1)，无 FFT/IR）
//! - `spatial`：空间音效（3D/8D/36D 环绕 + 虚拟多声道）
//! - `pitch`：变调变速（线性重采样 / 改 sample_rate）
//!
//! 对外入口为 [`SoundEffectBlockProcessor`]：对一块交错 PCM 批量处理，
//! 状态（混响/延迟/包络）在单次 `process_block` 调用内保持。

pub mod channel;
pub mod convolver;
pub mod dsp;
pub mod dynamics;
pub mod modulation;
pub mod pitch;
pub mod reverb;
pub mod shaper;
pub mod spatial;

use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

// =========================================================================
// 枚举
// =========================================================================

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ReverbKind {
    #[default]
    None,
    Algorithmic,
    Convolution,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SpatialMode {
    #[default]
    None,
    Surround3d,
    D8,
    D36,
    Virtual,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum DistortionType {
    #[default]
    Soft,
    Hard,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum DelayType {
    #[default]
    Single,
    Pingpong,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum VirtualSurroundMode {
    #[serde(rename = "5.1")]
    FiveOne,
    #[serde(rename = "7.1")]
    #[default]
    SevenOne,
}

// =========================================================================
// 参数结构体
// =========================================================================

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ModulationParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub rate: f32,
    #[serde(default)]
    pub depth: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FlangerParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub rate: f32,
    #[serde(default)]
    pub depth: f32,
    #[serde(default)]
    pub feedback: f32,
    #[serde(default)]
    pub mix: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PhaserParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub rate: f32,
    #[serde(default)]
    pub depth: f32,
    #[serde(default)]
    pub feedback: f32,
    #[serde(default)]
    pub mix: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DelayParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub time_ms: f32,
    #[serde(default)]
    pub feedback: f32,
    #[serde(default)]
    pub mix: f32,
    #[serde(default)]
    pub delay_type: DelayType,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CompressorParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub threshold: f32,
    #[serde(default)]
    pub ratio: f32,
    #[serde(default)]
    pub attack: f32,
    #[serde(default)]
    pub release: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MultibandParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub low_freq: f32,
    #[serde(default)]
    pub mid_freq: f32,
    #[serde(default)]
    pub threshold: f32,
    #[serde(default)]
    pub ratio: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LimiterParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub threshold: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NoiseGateParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub threshold: f32,
    #[serde(default)]
    pub attack: f32,
    #[serde(default)]
    pub release: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ExpanderParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub threshold: f32,
    #[serde(default)]
    pub ratio: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgcParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub target_level: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DeEsserParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub threshold: f32,
    #[serde(default)]
    pub frequency: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DistortionParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub amount: f32,
    #[serde(default)]
    pub distortion_type: DistortionType,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ExciterParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub amount: f32,
    #[serde(default)]
    pub frequency: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SubBassParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub amount: f32,
    #[serde(default)]
    pub frequency: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LoFiParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub sample_rate: f32,
    #[serde(default)]
    pub bit_depth: f32,
    #[serde(default)]
    pub noise: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BitcrushParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub bits: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StereoWidenParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub amount: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StereoSepParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub width: f32,
    #[serde(default)]
    pub center_level: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CrossfeedParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub strength: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BassBoostParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub gain: f32,
    #[serde(default)]
    pub dynamic: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DynamicEqParams {
    #[serde(default)]
    pub enabled: bool,
}

/// 音调漂移参数（前端 contracts 中为 ModulationParams{rate,depth}，此处 speed 接收 rate 别名）
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PitchDriftParams {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default, alias = "rate")]
    pub speed: f32,
    #[serde(default)]
    pub depth: f32,
}

// =========================================================================
// SoundEffectSettings（与前端 contracts 一一对应，camelCase）
// =========================================================================
//
// 注意：pitch_shift / playback_rate 以 100 为基准（100 = 原调原速），
// 不能用 f32 的默认值 0.0（会被 pitch 处理器解读为 0% → 极端变调变速 → 破音/静音）。
// 因此 SoundEffectSettings 不使用 #[derive(Default)]，而是手动实现 Default，
// 并为这两个字段提供 serde 级别的默认函数，确保前端漏传字段时也安全。

fn default_pitch_rate() -> f32 {
    100.0
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SoundEffectSettings {
    // 变调/变速（100 = 原调原速）
    #[serde(default = "default_pitch_rate")]
    pub pitch_shift: f32,
    #[serde(default = "default_pitch_rate")]
    pub playback_rate: f32,
    #[serde(default)]
    pub preserves_pitch: bool,
    // 混响
    pub reverb_kind: ReverbKind,
    pub reverb_preset: String,
    pub reverb_dry: f32,
    pub reverb_wet: f32,
    // 空间
    pub spatial_mode: SpatialMode,
    pub spatial_speed: f32,
    pub spatial_radius: f32,
    pub spatial_intensity: f32,
    pub virtual_surround_mode: VirtualSurroundMode,
    pub virtual_surround_spread: f32,
    // 调制
    pub vibrato: ModulationParams,
    pub pitch_drift: PitchDriftParams,
    pub tremolo: ModulationParams,
    pub flanger: FlangerParams,
    pub phaser: PhaserParams,
    pub delay: DelayParams,
    // 动态
    pub compressor: CompressorParams,
    pub multiband: MultibandParams,
    pub limiter: LimiterParams,
    pub noise_gate: NoiseGateParams,
    pub expander: ExpanderParams,
    pub agc: AgcParams,
    pub de_esser: DeEsserParams,
    // 波形整形
    pub distortion: DistortionParams,
    pub exciter: ExciterParams,
    pub sub_bass: SubBassParams,
    pub lo_fi: LoFiParams,
    pub bitcrush: BitcrushParams,
    // 声道处理
    pub vocal_removal: bool,
    pub stereo_widen: StereoWidenParams,
    pub mono_merge: bool,
    pub channel_swap: bool,
    pub stereo_separation: StereoSepParams,
    pub crossfeed: CrossfeedParams,
    pub bass_boost: BassBoostParams,
    pub dynamic_eq: DynamicEqParams,
    // 组合
    pub v4a_enabled: bool,
    pub bypass: bool,
    pub audio_boost: f32,
}

/// 手动实现 Default：pitch_shift / playback_rate 必须为 100.0（原调原速），
/// 其余字段沿用类型默认（全部 disabled / 0 / None，等价于纯直通）。
impl Default for SoundEffectSettings {
    fn default() -> Self {
        Self {
            pitch_shift: 100.0,
            playback_rate: 100.0,
            preserves_pitch: false,
            reverb_kind: ReverbKind::None,
            reverb_preset: String::new(),
            reverb_dry: 0.0,
            reverb_wet: 0.0,
            spatial_mode: SpatialMode::None,
            spatial_speed: 0.0,
            spatial_radius: 0.0,
            spatial_intensity: 0.0,
            virtual_surround_mode: VirtualSurroundMode::SevenOne,
            virtual_surround_spread: 0.0,
            vibrato: ModulationParams::default(),
            pitch_drift: PitchDriftParams::default(),
            tremolo: ModulationParams::default(),
            flanger: FlangerParams::default(),
            phaser: PhaserParams::default(),
            delay: DelayParams::default(),
            compressor: CompressorParams::default(),
            multiband: MultibandParams::default(),
            limiter: LimiterParams::default(),
            noise_gate: NoiseGateParams::default(),
            expander: ExpanderParams::default(),
            agc: AgcParams::default(),
            de_esser: DeEsserParams::default(),
            distortion: DistortionParams::default(),
            exciter: ExciterParams::default(),
            sub_bass: SubBassParams::default(),
            lo_fi: LoFiParams::default(),
            bitcrush: BitcrushParams::default(),
            vocal_removal: false,
            stereo_widen: StereoWidenParams::default(),
            mono_merge: false,
            channel_swap: false,
            stereo_separation: StereoSepParams::default(),
            crossfeed: CrossfeedParams::default(),
            bass_boost: BassBoostParams::default(),
            dynamic_eq: DynamicEqParams::default(),
            v4a_enabled: false,
            bypass: false,
            audio_boost: 0.0,
        }
    }
}

impl SoundEffectSettings {
    #[inline]
    fn pitch_rate_is_neutral(&self) -> bool {
        let pitch = if self.pitch_shift.is_finite() {
            self.pitch_shift
        } else {
            100.0
        };
        let rate = if self.playback_rate.is_finite() {
            self.playback_rate
        } else {
            100.0
        };
        (pitch - 100.0).abs() < 0.1 && (rate - 100.0).abs() < 0.1
    }

    /// 是否存在真正会改变音频内容的音效。
    /// audio_boost 不参与判断，避免没开音效时被额外放大并削波。
    #[inline]
    fn has_audible_processing(&self) -> bool {
        !self.pitch_rate_is_neutral()
            || self.reverb_kind != ReverbKind::None
            || self.spatial_mode != SpatialMode::None
            || self.vibrato.enabled
            || self.pitch_drift.enabled
            || self.tremolo.enabled
            || self.flanger.enabled
            || self.phaser.enabled
            || self.delay.enabled
            || self.compressor.enabled
            || self.multiband.enabled
            || self.limiter.enabled
            || self.noise_gate.enabled
            || self.expander.enabled
            || self.agc.enabled
            || self.de_esser.enabled
            || self.distortion.enabled
            || self.exciter.enabled
            || self.sub_bass.enabled
            || self.lo_fi.enabled
            || self.bitcrush.enabled
            || self.vocal_removal
            || self.stereo_widen.enabled
            || self.mono_merge
            || self.channel_swap
            || self.stereo_separation.enabled
            || self.crossfeed.enabled
            || self.bass_boost.enabled
            || self.dynamic_eq.enabled
            || self.v4a_enabled
    }

    #[inline]
    fn should_hard_bypass(&self) -> bool {
        self.bypass || !self.has_audible_processing()
    }
}

// =========================================================================
// SoundEffectBlockProcessor（无 rodio / Tauri 依赖的批量处理核心）
// =========================================================================

#[frb(opaque)]
pub struct SoundEffectBlockProcessor {
    sample_rate: u32,
    channels: u16,
    settings: SoundEffectSettings,
    // 变调变速处理器
    pitch: pitch::PitchRateProcessor,
    // 各效果机架
    channel_rack: channel::ChannelRack,
    shaper_rack: shaper::ShaperRack,
    dynamics_rack: dynamics::DynamicsRack,
    modulation_rack: modulation::ModulationRack,
    reverb_rack: reverb::ReverbRack,
    spatial_rack: spatial::SpatialRack,
    // 帧缓冲
    frame: Vec<f32>,
}

impl SoundEffectBlockProcessor {
    pub fn new(sample_rate: u32, channels: u16) -> Self {
        let ch = (channels as usize).max(1);
        let mut p = Self {
            sample_rate,
            channels: channels.max(1),
            settings: SoundEffectSettings::default(),
            pitch: pitch::PitchRateProcessor::new(channels, sample_rate),
            channel_rack: channel::ChannelRack::new(),
            shaper_rack: shaper::ShaperRack::new(),
            dynamics_rack: dynamics::DynamicsRack::new(),
            modulation_rack: modulation::ModulationRack::new(),
            reverb_rack: reverb::ReverbRack::new(),
            spatial_rack: spatial::SpatialRack::new(),
            frame: vec![0.0; ch],
        };
        p.prepare_all();
        p
    }

    fn prepare_all(&mut self) {
        let sr = self.sample_rate as f32;
        let ch = self.channels as usize;
        self.pitch.prepare(sr, ch);
        self.channel_rack.prepare(sr, ch);
        self.shaper_rack.prepare(sr, ch);
        self.dynamics_rack.prepare(sr, ch);
        self.modulation_rack.prepare(sr, ch);
        self.reverb_rack.prepare(sr, ch);
        self.spatial_rack.prepare(sr, ch);
    }

    /// 应用新设置。V4A 开启时合并其子效果参数到各机架（语义对齐桌面端）。
    pub fn set_settings(&mut self, s: SoundEffectSettings) {
        let effective = if s.v4a_enabled {
            let mut e = s.clone();
            e.vocal_removal = false;
            e.bass_boost.enabled = true;
            e.bass_boost.gain = e.bass_boost.gain.max(6.0);
            e.bass_boost.dynamic = true;
            e.dynamic_eq.enabled = true;
            e.stereo_widen.enabled = true;
            e.stereo_widen.amount = e.stereo_widen.amount.max(1.4);
            e.compressor.enabled = true;
            e.compressor.threshold = e.compressor.threshold.min(-20.0);
            e.compressor.ratio = e.compressor.ratio.max(4.0);
            e.compressor.attack = e.compressor.attack.min(3.0);
            e.compressor.release = e.compressor.release.max(100.0);
            e
        } else {
            s
        };
        self.settings = effective.clone();
        self.pitch.update_params(&effective);
        self.channel_rack.update_params(&effective);
        self.shaper_rack.update_params(&effective);
        self.dynamics_rack.update_params(&effective);
        self.modulation_rack.update_params(&effective);
        self.reverb_rack.update_params(&effective);
        self.spatial_rack.update_params(&effective);
    }

    pub fn reset(&mut self) {
        self.pitch.reset();
        self.channel_rack.reset();
        self.shaper_rack.reset();
        self.dynamics_rack.reset();
        self.modulation_rack.reset();
        self.reverb_rack.reset();
        self.spatial_rack.reset();
    }

    /// 变调变速后的有效采样率；无音效（硬旁路）时返回原始采样率。
    pub fn effective_sample_rate(&self) -> u32 {
        if self.settings.should_hard_bypass() {
            self.sample_rate
        } else {
            self.pitch.effective_sample_rate(self.sample_rate)
        }
    }

    /// 处理一块交错 PCM（样本数应为 channels 的整数倍），返回处理后的交错 PCM。
    /// 变调变速时输出样本数可能 ≠ 输入。默认（无音效）为无损直通。
    pub fn process_block(&mut self, input: Vec<f32>) -> Vec<f32> {
        let ch = self.channels;
        let s = &self.settings;
        if s.should_hard_bypass() {
            return input;
        }
        let mut iter = input.into_iter();
        let mut out = Vec::with_capacity(self.frame.len() * 2);
        loop {
            if !self.pitch.fill(&mut iter, &mut self.frame) {
                break;
            }
            self.channel_rack.process(&mut self.frame, ch, s);
            self.shaper_rack.process(&mut self.frame, ch, s);
            self.dynamics_rack.process(&mut self.frame, ch, s);
            self.modulation_rack.process(&mut self.frame, ch, s);
            self.reverb_rack.process(&mut self.frame, ch, s);
            self.spatial_rack.process(&mut self.frame, ch, s);
            // audioBoost：0-100 → 0~6dB 增益
            let boost_db = (s.audio_boost / 100.0).clamp(0.0, 1.0) * 6.0;
            if boost_db > 0.01 {
                let g = dsp::db_to_gain(boost_db);
                for v in &mut self.frame {
                    *v = dsp::soft_clip(*v * g);
                }
            }
            out.extend_from_slice(&self.frame);
        }
        out
    }
}