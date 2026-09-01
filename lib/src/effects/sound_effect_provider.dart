import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../i18n/i18n.dart';

/// 10 段 EQ 频率标签（与 Rust equalizer.rs 的 EQ_FREQUENCIES 一致）。
const eqFreqLabels = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];

/// 内置 EQ 预设（与桌面端 freqsPreset 对齐）。
class EqPreset {
  final String name;
  final List<double> gains;
  const EqPreset(this.name, this.gains);
}

List<EqPreset> get eqPresets => <EqPreset>[
  EqPreset(tr('默认'), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqPreset(tr('流行'), [-1, 0, 1, 2, 2, 1, 0, -1, -1, -1]),
  EqPreset(tr('摇滚'), [3, 2, 1, 0, -1, -1, 0, 1, 2, 3]),
  EqPreset(tr('爵士'), [2, 1, 0, 1, 1, 0, -1, 0, 1, 2]),
  EqPreset(tr('古典'), [2, 1, 0, -1, -1, -1, 0, 1, 2, 3]),
  EqPreset(tr('电子'), [3, 2, 1, 0, -1, 0, 1, 2, 3, 4]),
  EqPreset(tr('低音增强'), [4, 3, 2, 1, 0, 0, 0, 0, 0, 0]),
  EqPreset(tr('人声'), [-1, -1, -1, 1, 2, 3, 2, 1, 0, -1]),
  EqPreset(tr('高音增强'), [0, 0, 0, 0, 0, 1, 2, 3, 4, 4]),
];

/// 混响预设（卷积 IR 列表，与桌面端 convolutions 对齐）。
class ReverbPreset {
  final String label;
  final int dry;
  final int wet;
  const ReverbPreset(this.label, this.dry, this.wet);
}

List<ReverbPreset> get reverbPresets => <ReverbPreset>[
  ReverbPreset(tr('大厅'), 80, 40),
  ReverbPreset(tr('房间'), 85, 30),
  ReverbPreset(tr('浴室'), 75, 50),
  ReverbPreset(tr('隧道'), 70, 60),
  ReverbPreset(tr('峡谷'), 65, 55),
  ReverbPreset(tr('教堂'), 60, 45),
];

/// 算法混响预设。
List<ReverbPreset> get algoReverbPresets => <ReverbPreset>[
  ReverbPreset(tr('算法大厅'), 85, 40),
  ReverbPreset(tr('算法房间'), 90, 30),
  ReverbPreset(tr('算法板式'), 80, 50),
  ReverbPreset(tr('算法弹簧'), 88, 35),
];

/// 音效设置（camelCase，与 Rust SoundEffectSettings JSON 对齐，可部分省略）。
class SoundEffectSettings {
  final double pitchShift; // 50~200
  final double playbackRate; // 50~200
  final bool preservesPitch;
  final String reverbKind; // none | convolution | algorithmic
  final String reverbPreset;
  final double reverbDry;
  final double reverbWet;
  final String spatialMode; // none | surround3d | d8 | d36 | virtual
  final double spatialSpeed;
  final double spatialRadius;
  final double spatialIntensity;
  final String virtualSurroundMode; // 5.1 | 7.1
  final double virtualSurroundSpread;
  final bool vocalRemoval;
  final bool vibratoEnabled;
  final double vibratoRate;
  final double vibratoDepth;
  final bool tremoloEnabled;
  final double tremoloRate;
  final double tremoloDepth;
  final bool bassBoostEnabled;
  final double bassBoostGain;
  final bool bassBoostDynamic;
  final bool trebleEnabled;
  final double trebleGain;
  final bool distortionEnabled;
  final double distortionAmount;
  final String distortionType; // soft | hard
  final bool delayEnabled;
  final double delayTime;
  final double delayFeedback;
  final double delayMix;
  final String delayType; // single | pingpong
  final bool flangerEnabled;
  final double flangerRate;
  final double flangerDepth;
  final double flangerFeedback;
  final double flangerMix;
  final bool phaserEnabled;
  final double phaserRate;
  final double phaserDepth;
  final double phaserFeedback;
  final double phaserMix;
  final bool compressorEnabled;
  final double compressorThreshold;
  final double compressorRatio;
  final double compressorAttack;
  final double compressorRelease;
  final bool noiseGateEnabled;
  final double noiseGateThreshold;
  final bool limiterEnabled;
  final double limiterThreshold;
  final bool exciterEnabled;
  final double exciterAmount;
  final double exciterFrequency;
  final bool subBassEnabled;
  final double subBassAmount;
  final double subBassFrequency;
  final bool loFiEnabled;
  final double loFiSampleRate;
  final double loFiBitDepth;
  final bool stereoWidenEnabled;
  final double stereoWidenAmount;
  final bool monoMerge;
  final bool channelSwap;
  final bool v4aEnabled;
  final bool bypass;
  final double audioBoost;
  final List<double> eqGains;

  const SoundEffectSettings({
    this.pitchShift = 100,
    this.playbackRate = 100,
    this.preservesPitch = true,
    this.reverbKind = 'none',
    this.reverbPreset = '',
    this.reverbDry = 0,
    this.reverbWet = 0,
    this.spatialMode = 'none',
    this.spatialSpeed = 10,
    this.spatialRadius = 5,
    this.spatialIntensity = 9,
    this.virtualSurroundMode = '7.1',
    this.virtualSurroundSpread = 10,
    this.vocalRemoval = false,
    this.vibratoEnabled = false,
    this.vibratoRate = 5,
    this.vibratoDepth = 3,
    this.tremoloEnabled = false,
    this.tremoloRate = 6,
    this.tremoloDepth = 30,
    this.bassBoostEnabled = false,
    this.bassBoostGain = 6,
    this.bassBoostDynamic = true,
    this.trebleEnabled = false,
    this.trebleGain = 6,
    this.distortionEnabled = false,
    this.distortionAmount = 10,
    this.distortionType = 'soft',
    this.delayEnabled = false,
    this.delayTime = 300,
    this.delayFeedback = 40,
    this.delayMix = 30,
    this.delayType = 'single',
    this.flangerEnabled = false,
    this.flangerRate = 0.5,
    this.flangerDepth = 2,
    this.flangerFeedback = 30,
    this.flangerMix = 35,
    this.phaserEnabled = false,
    this.phaserRate = 0.5,
    this.phaserDepth = 1,
    this.phaserFeedback = 30,
    this.phaserMix = 50,
    this.compressorEnabled = false,
    this.compressorThreshold = -18,
    this.compressorRatio = 4,
    this.compressorAttack = 8,
    this.compressorRelease = 400,
    this.noiseGateEnabled = false,
    this.noiseGateThreshold = -60,
    this.limiterEnabled = false,
    this.limiterThreshold = -1,
    this.exciterEnabled = false,
    this.exciterAmount = 20,
    this.exciterFrequency = 3000,
    this.subBassEnabled = false,
    this.subBassAmount = 30,
    this.subBassFrequency = 120,
    this.loFiEnabled = false,
    this.loFiSampleRate = 8000,
    this.loFiBitDepth = 8,
    this.stereoWidenEnabled = false,
    this.stereoWidenAmount = 1.5,
    this.monoMerge = false,
    this.channelSwap = false,
    this.v4aEnabled = false,
    this.bypass = false,
    this.audioBoost = 0,
    this.eqGains = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  });

  SoundEffectSettings copyWith({
    double? pitchShift,
    double? playbackRate,
    bool? preservesPitch,
    String? reverbKind,
    String? reverbPreset,
    double? reverbDry,
    double? reverbWet,
    String? spatialMode,
    double? spatialSpeed,
    double? spatialRadius,
    double? spatialIntensity,
    String? virtualSurroundMode,
    double? virtualSurroundSpread,
    bool? vocalRemoval,
    bool? vibratoEnabled,
    double? vibratoRate,
    double? vibratoDepth,
    bool? tremoloEnabled,
    double? tremoloRate,
    double? tremoloDepth,
    bool? bassBoostEnabled,
    double? bassBoostGain,
    bool? bassBoostDynamic,
    bool? trebleEnabled,
    double? trebleGain,
    bool? distortionEnabled,
    double? distortionAmount,
    String? distortionType,
    bool? delayEnabled,
    double? delayTime,
    double? delayFeedback,
    double? delayMix,
    String? delayType,
    bool? flangerEnabled,
    double? flangerRate,
    double? flangerDepth,
    double? flangerFeedback,
    double? flangerMix,
    bool? phaserEnabled,
    double? phaserRate,
    double? phaserDepth,
    double? phaserFeedback,
    double? phaserMix,
    bool? compressorEnabled,
    double? compressorThreshold,
    double? compressorRatio,
    double? compressorAttack,
    double? compressorRelease,
    bool? noiseGateEnabled,
    double? noiseGateThreshold,
    bool? limiterEnabled,
    double? limiterThreshold,
    bool? exciterEnabled,
    double? exciterAmount,
    double? exciterFrequency,
    bool? subBassEnabled,
    double? subBassAmount,
    double? subBassFrequency,
    bool? loFiEnabled,
    double? loFiSampleRate,
    double? loFiBitDepth,
    bool? stereoWidenEnabled,
    double? stereoWidenAmount,
    bool? monoMerge,
    bool? channelSwap,
    bool? v4aEnabled,
    bool? bypass,
    double? audioBoost,
    List<double>? eqGains,
  }) {
    return SoundEffectSettings(
      pitchShift: pitchShift ?? this.pitchShift,
      playbackRate: playbackRate ?? this.playbackRate,
      preservesPitch: preservesPitch ?? this.preservesPitch,
      reverbKind: reverbKind ?? this.reverbKind,
      reverbPreset: reverbPreset ?? this.reverbPreset,
      reverbDry: reverbDry ?? this.reverbDry,
      reverbWet: reverbWet ?? this.reverbWet,
      spatialMode: spatialMode ?? this.spatialMode,
      spatialSpeed: spatialSpeed ?? this.spatialSpeed,
      spatialRadius: spatialRadius ?? this.spatialRadius,
      spatialIntensity: spatialIntensity ?? this.spatialIntensity,
      virtualSurroundMode: virtualSurroundMode ?? this.virtualSurroundMode,
      virtualSurroundSpread: virtualSurroundSpread ?? this.virtualSurroundSpread,
      vocalRemoval: vocalRemoval ?? this.vocalRemoval,
      vibratoEnabled: vibratoEnabled ?? this.vibratoEnabled,
      vibratoRate: vibratoRate ?? this.vibratoRate,
      vibratoDepth: vibratoDepth ?? this.vibratoDepth,
      tremoloEnabled: tremoloEnabled ?? this.tremoloEnabled,
      tremoloRate: tremoloRate ?? this.tremoloRate,
      tremoloDepth: tremoloDepth ?? this.tremoloDepth,
      bassBoostEnabled: bassBoostEnabled ?? this.bassBoostEnabled,
      bassBoostGain: bassBoostGain ?? this.bassBoostGain,
      bassBoostDynamic: bassBoostDynamic ?? this.bassBoostDynamic,
      trebleEnabled: trebleEnabled ?? this.trebleEnabled,
      trebleGain: trebleGain ?? this.trebleGain,
      distortionEnabled: distortionEnabled ?? this.distortionEnabled,
      distortionAmount: distortionAmount ?? this.distortionAmount,
      distortionType: distortionType ?? this.distortionType,
      delayEnabled: delayEnabled ?? this.delayEnabled,
      delayTime: delayTime ?? this.delayTime,
      delayFeedback: delayFeedback ?? this.delayFeedback,
      delayMix: delayMix ?? this.delayMix,
      delayType: delayType ?? this.delayType,
      flangerEnabled: flangerEnabled ?? this.flangerEnabled,
      flangerRate: flangerRate ?? this.flangerRate,
      flangerDepth: flangerDepth ?? this.flangerDepth,
      flangerFeedback: flangerFeedback ?? this.flangerFeedback,
      flangerMix: flangerMix ?? this.flangerMix,
      phaserEnabled: phaserEnabled ?? this.phaserEnabled,
      phaserRate: phaserRate ?? this.phaserRate,
      phaserDepth: phaserDepth ?? this.phaserDepth,
      phaserFeedback: phaserFeedback ?? this.phaserFeedback,
      phaserMix: phaserMix ?? this.phaserMix,
      compressorEnabled: compressorEnabled ?? this.compressorEnabled,
      compressorThreshold: compressorThreshold ?? this.compressorThreshold,
      compressorRatio: compressorRatio ?? this.compressorRatio,
      compressorAttack: compressorAttack ?? this.compressorAttack,
      compressorRelease: compressorRelease ?? this.compressorRelease,
      noiseGateEnabled: noiseGateEnabled ?? this.noiseGateEnabled,
      noiseGateThreshold: noiseGateThreshold ?? this.noiseGateThreshold,
      limiterEnabled: limiterEnabled ?? this.limiterEnabled,
      limiterThreshold: limiterThreshold ?? this.limiterThreshold,
      exciterEnabled: exciterEnabled ?? this.exciterEnabled,
      exciterAmount: exciterAmount ?? this.exciterAmount,
      exciterFrequency: exciterFrequency ?? this.exciterFrequency,
      subBassEnabled: subBassEnabled ?? this.subBassEnabled,
      subBassAmount: subBassAmount ?? this.subBassAmount,
      subBassFrequency: subBassFrequency ?? this.subBassFrequency,
      loFiEnabled: loFiEnabled ?? this.loFiEnabled,
      loFiSampleRate: loFiSampleRate ?? this.loFiSampleRate,
      loFiBitDepth: loFiBitDepth ?? this.loFiBitDepth,
      stereoWidenEnabled: stereoWidenEnabled ?? this.stereoWidenEnabled,
      stereoWidenAmount: stereoWidenAmount ?? this.stereoWidenAmount,
      monoMerge: monoMerge ?? this.monoMerge,
      channelSwap: channelSwap ?? this.channelSwap,
      v4aEnabled: v4aEnabled ?? this.v4aEnabled,
      bypass: bypass ?? this.bypass,
      audioBoost: audioBoost ?? this.audioBoost,
      eqGains: eqGains ?? this.eqGains,
    );
  }

  /// 构建传给 Rust SoundEffectSettings 的完整 JSON（camelCase）。
  Map<String, dynamic> toRustJson() => {
        'pitchShift': pitchShift,
        'playbackRate': playbackRate,
        'preservesPitch': preservesPitch,
        'reverbKind': reverbKind,
        'reverbPreset': reverbPreset,
        'reverbDry': _clamp01(reverbDry),
        'reverbWet': _clamp01(reverbWet),
        'spatialMode': spatialMode,
        'spatialSpeed': spatialSpeed,
        'spatialRadius': spatialRadius,
        'spatialIntensity': spatialIntensity,
        'virtualSurroundMode': virtualSurroundMode,
        'virtualSurroundSpread': virtualSurroundSpread,
        'vocalRemoval': vocalRemoval,
        'vibrato': {
          'enabled': vibratoEnabled,
          'rate': vibratoRate,
          'depth': vibratoDepth,
        },
        'tremolo': {
          'enabled': tremoloEnabled,
          'rate': tremoloRate,
          'depth': tremoloDepth,
        },
        'bassBoost': {
          'enabled': bassBoostEnabled,
          'gain': bassBoostGain,
          'dynamic': bassBoostDynamic,
        },
        'treble': {
          'enabled': trebleEnabled,
          'gain': trebleGain,
        },
        'distortion': {
          'enabled': distortionEnabled,
          'amount': distortionAmount,
          'distortionType': distortionType,
        },
        'delay': {
          'enabled': delayEnabled,
          'timeMs': delayTime,
          'feedback': delayFeedback,
          'mix': delayMix,
          'delayType': delayType,
        },
        'flanger': {
          'enabled': flangerEnabled,
          'rate': flangerRate,
          'depth': flangerDepth,
          'feedback': flangerFeedback,
          'mix': flangerMix,
        },
        'phaser': {
          'enabled': phaserEnabled,
          'rate': phaserRate,
          'depth': phaserDepth,
          'feedback': phaserFeedback,
          'mix': phaserMix,
        },
        'compressor': {
          'enabled': compressorEnabled,
          'threshold': compressorThreshold,
          'ratio': compressorRatio,
          'attack': compressorAttack,
          'release': compressorRelease,
        },
        'noiseGate': {
          'enabled': noiseGateEnabled,
          'threshold': noiseGateThreshold,
        },
        'limiter': {
          'enabled': limiterEnabled,
          'threshold': limiterThreshold,
        },
        'exciter': {
          'enabled': exciterEnabled,
          'amount': exciterAmount,
          'frequency': exciterFrequency,
        },
        'subBass': {
          'enabled': subBassEnabled,
          'amount': subBassAmount,
          'frequency': subBassFrequency,
        },
        'loFi': {
          'enabled': loFiEnabled,
          'sampleRate': loFiSampleRate,
          'bitDepth': loFiBitDepth,
        },
        'stereoWiden': {
          'enabled': stereoWidenEnabled,
          'amount': stereoWidenAmount,
        },
        'monoMerge': monoMerge,
        'channelSwap': channelSwap,
        'v4aEnabled': v4aEnabled,
        'bypass': bypass,
        'audioBoost': audioBoost,
      };

  static double _clamp01(double v) => v.clamp(0.0, 1.0).toDouble();

  /// 是否有真正会改变音频内容的音效（用于判断是否直通）。
  bool get hasAudibleProcessing =>
      (pitchShift - 100).abs() > 0.1 ||
      (playbackRate - 100).abs() > 0.1 ||
      reverbKind != 'none' ||
      spatialMode != 'none' ||
      vocalRemoval ||
      vibratoEnabled ||
      tremoloEnabled ||
      bassBoostEnabled ||
      trebleEnabled ||
      distortionEnabled ||
      delayEnabled ||
      flangerEnabled ||
      phaserEnabled ||
      compressorEnabled ||
      noiseGateEnabled ||
      limiterEnabled ||
      exciterEnabled ||
      subBassEnabled ||
      loFiEnabled ||
      stereoWidenEnabled ||
      monoMerge ||
      channelSwap ||
      v4aEnabled;

  Map<String, dynamic> toJson() => {
        'pitchShift': pitchShift,
        'playbackRate': playbackRate,
        'preservesPitch': preservesPitch,
        'reverbKind': reverbKind,
        'reverbPreset': reverbPreset,
        'reverbDry': reverbDry,
        'reverbWet': reverbWet,
        'spatialMode': spatialMode,
        'spatialSpeed': spatialSpeed,
        'spatialRadius': spatialRadius,
        'spatialIntensity': spatialIntensity,
        'virtualSurroundMode': virtualSurroundMode,
        'virtualSurroundSpread': virtualSurroundSpread,
        'vocalRemoval': vocalRemoval,
        'vibratoEnabled': vibratoEnabled,
        'vibratoRate': vibratoRate,
        'vibratoDepth': vibratoDepth,
        'tremoloEnabled': tremoloEnabled,
        'tremoloRate': tremoloRate,
        'tremoloDepth': tremoloDepth,
        'bassBoostEnabled': bassBoostEnabled,
        'bassBoostGain': bassBoostGain,
        'bassBoostDynamic': bassBoostDynamic,
        'trebleEnabled': trebleEnabled,
        'trebleGain': trebleGain,
        'distortionEnabled': distortionEnabled,
        'distortionAmount': distortionAmount,
        'distortionType': distortionType,
        'delayEnabled': delayEnabled,
        'delayTime': delayTime,
        'delayFeedback': delayFeedback,
        'delayMix': delayMix,
        'delayType': delayType,
        'flangerEnabled': flangerEnabled,
        'flangerRate': flangerRate,
        'flangerDepth': flangerDepth,
        'flangerFeedback': flangerFeedback,
        'flangerMix': flangerMix,
        'phaserEnabled': phaserEnabled,
        'phaserRate': phaserRate,
        'phaserDepth': phaserDepth,
        'phaserFeedback': phaserFeedback,
        'phaserMix': phaserMix,
        'compressorEnabled': compressorEnabled,
        'compressorThreshold': compressorThreshold,
        'compressorRatio': compressorRatio,
        'compressorAttack': compressorAttack,
        'compressorRelease': compressorRelease,
        'noiseGateEnabled': noiseGateEnabled,
        'noiseGateThreshold': noiseGateThreshold,
        'limiterEnabled': limiterEnabled,
        'limiterThreshold': limiterThreshold,
        'exciterEnabled': exciterEnabled,
        'exciterAmount': exciterAmount,
        'exciterFrequency': exciterFrequency,
        'subBassEnabled': subBassEnabled,
        'subBassAmount': subBassAmount,
        'subBassFrequency': subBassFrequency,
        'loFiEnabled': loFiEnabled,
        'loFiSampleRate': loFiSampleRate,
        'loFiBitDepth': loFiBitDepth,
        'stereoWidenEnabled': stereoWidenEnabled,
        'stereoWidenAmount': stereoWidenAmount,
        'monoMerge': monoMerge,
        'channelSwap': channelSwap,
        'v4aEnabled': v4aEnabled,
        'bypass': bypass,
        'audioBoost': audioBoost,
        'eqGains': eqGains,
      };

  /// 转换为 Rust EqualizerSettings 兼容 JSON（10 段 EQ，任一频带非 0 即启用）。
  Map<String, dynamic> toEqualizerRustJson() => {
        'enabled': eqGains.any((g) => g != 0),
        'preamp': 0.0,
        'gains': eqGains,
      };

  factory SoundEffectSettings.fromJson(Map<String, dynamic> j) {
    final s = SoundEffectSettings(
      pitchShift: (j['pitchShift'] as num?)?.toDouble() ?? 100,
      playbackRate: (j['playbackRate'] as num?)?.toDouble() ?? 100,
      preservesPitch: j['preservesPitch'] as bool? ?? true,
      reverbKind: j['reverbKind'] as String? ?? 'none',
      reverbPreset: j['reverbPreset'] as String? ?? '',
      reverbDry: (j['reverbDry'] as num?)?.toDouble() ?? 0,
      reverbWet: (j['reverbWet'] as num?)?.toDouble() ?? 0,
      spatialMode: j['spatialMode'] as String? ?? 'none',
      spatialSpeed: (j['spatialSpeed'] as num?)?.toDouble() ?? 10,
      spatialRadius: (j['spatialRadius'] as num?)?.toDouble() ?? 5,
      spatialIntensity: (j['spatialIntensity'] as num?)?.toDouble() ?? 9,
      virtualSurroundMode: j['virtualSurroundMode'] as String? ?? '7.1',
      virtualSurroundSpread: (j['virtualSurroundSpread'] as num?)?.toDouble() ?? 10,
      vocalRemoval: j['vocalRemoval'] as bool? ?? false,
      vibratoEnabled: j['vibratoEnabled'] as bool? ?? false,
      vibratoRate: (j['vibratoRate'] as num?)?.toDouble() ?? 5,
      vibratoDepth: (j['vibratoDepth'] as num?)?.toDouble() ?? 3,
      tremoloEnabled: j['tremoloEnabled'] as bool? ?? false,
      tremoloRate: (j['tremoloRate'] as num?)?.toDouble() ?? 6,
      tremoloDepth: (j['tremoloDepth'] as num?)?.toDouble() ?? 30,
      bassBoostEnabled: j['bassBoostEnabled'] as bool? ?? false,
      bassBoostGain: (j['bassBoostGain'] as num?)?.toDouble() ?? 6,
      bassBoostDynamic: j['bassBoostDynamic'] as bool? ?? true,
      trebleEnabled: j['trebleEnabled'] as bool? ?? false,
      trebleGain: (j['trebleGain'] as num?)?.toDouble() ?? 6,
      distortionEnabled: j['distortionEnabled'] as bool? ?? false,
      distortionAmount: (j['distortionAmount'] as num?)?.toDouble() ?? 10,
      distortionType: j['distortionType'] as String? ?? 'soft',
      delayEnabled: j['delayEnabled'] as bool? ?? false,
      delayTime: (j['delayTime'] as num?)?.toDouble() ?? 300,
      delayFeedback: (j['delayFeedback'] as num?)?.toDouble() ?? 40,
      delayMix: (j['delayMix'] as num?)?.toDouble() ?? 30,
      delayType: j['delayType'] as String? ?? 'single',
      flangerEnabled: j['flangerEnabled'] as bool? ?? false,
      flangerRate: (j['flangerRate'] as num?)?.toDouble() ?? 0.5,
      flangerDepth: (j['flangerDepth'] as num?)?.toDouble() ?? 2,
      flangerFeedback: (j['flangerFeedback'] as num?)?.toDouble() ?? 30,
      flangerMix: (j['flangerMix'] as num?)?.toDouble() ?? 35,
      phaserEnabled: j['phaserEnabled'] as bool? ?? false,
      phaserRate: (j['phaserRate'] as num?)?.toDouble() ?? 0.5,
      phaserDepth: (j['phaserDepth'] as num?)?.toDouble() ?? 1,
      phaserFeedback: (j['phaserFeedback'] as num?)?.toDouble() ?? 30,
      phaserMix: (j['phaserMix'] as num?)?.toDouble() ?? 50,
      compressorEnabled: j['compressorEnabled'] as bool? ?? false,
      compressorThreshold: (j['compressorThreshold'] as num?)?.toDouble() ?? -18,
      compressorRatio: (j['compressorRatio'] as num?)?.toDouble() ?? 4,
      compressorAttack: (j['compressorAttack'] as num?)?.toDouble() ?? 8,
      compressorRelease: (j['compressorRelease'] as num?)?.toDouble() ?? 400,
      noiseGateEnabled: j['noiseGateEnabled'] as bool? ?? false,
      noiseGateThreshold: (j['noiseGateThreshold'] as num?)?.toDouble() ?? -60,
      limiterEnabled: j['limiterEnabled'] as bool? ?? false,
      limiterThreshold: (j['limiterThreshold'] as num?)?.toDouble() ?? -1,
      exciterEnabled: j['exciterEnabled'] as bool? ?? false,
      exciterAmount: (j['exciterAmount'] as num?)?.toDouble() ?? 20,
      exciterFrequency: (j['exciterFrequency'] as num?)?.toDouble() ?? 3000,
      subBassEnabled: j['subBassEnabled'] as bool? ?? false,
      subBassAmount: (j['subBassAmount'] as num?)?.toDouble() ?? 30,
      subBassFrequency: (j['subBassFrequency'] as num?)?.toDouble() ?? 120,
      loFiEnabled: j['loFiEnabled'] as bool? ?? false,
      loFiSampleRate: (j['loFiSampleRate'] as num?)?.toDouble() ?? 8000,
      loFiBitDepth: (j['loFiBitDepth'] as num?)?.toDouble() ?? 8,
      stereoWidenEnabled: j['stereoWidenEnabled'] as bool? ?? false,
      stereoWidenAmount: (j['stereoWidenAmount'] as num?)?.toDouble() ?? 1.5,
      monoMerge: j['monoMerge'] as bool? ?? false,
      channelSwap: j['channelSwap'] as bool? ?? false,
      v4aEnabled: j['v4aEnabled'] as bool? ?? false,
      bypass: j['bypass'] as bool? ?? false,
      audioBoost: (j['audioBoost'] as num?)?.toDouble() ?? 0,
      eqGains: (j['eqGains'] as List? ?? const [])
          .map((e) => (e as num).toDouble())
          .toList(),
    );
    if (s.eqGains.length != 10) {
      return s.copyWith(eqGains: const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    }
    return s;
  }
}

/// 用户自定义 EQ 预设。
class CustomEqPreset {
  final String name;
  final List<double> gains;
  const CustomEqPreset(this.name, this.gains);

  Map<String, dynamic> toJson() => {'name': name, 'gains': gains};

  factory CustomEqPreset.fromJson(Map<String, dynamic> j) => CustomEqPreset(
        j['name'] as String? ?? tr('未命名'),
        (j['gains'] as List? ?? const [])
            .map((e) => (e as num).toDouble())
            .toList(),
      );
}

class SoundEffectState {
  final SoundEffectSettings settings;
  final List<CustomEqPreset> customEqPresets;
  const SoundEffectState({
    required this.settings,
    this.customEqPresets = const [],
  });
}

class SoundEffectManager extends StateNotifier<SoundEffectState> {
  SoundEffectManager() : super(SoundEffectState(settings: const SoundEffectSettings())) {
    _load();
  }

  static const _key = 'xianyu_sound_effect_v1';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        // 新版为 { settings, customEqPresets } 包装；兼容旧版扁平 settings。
        final settingsRaw = decoded.containsKey('settings')
            ? decoded['settings'] as Map<String, dynamic>
            : decoded;
        final s = SoundEffectSettings.fromJson(settingsRaw);
        final customs = (decoded['customEqPresets'] as List? ?? const [])
            .map((e) => CustomEqPreset.fromJson(e as Map<String, dynamic>))
            .toList();
        state = SoundEffectState(settings: s, customEqPresets: customs);
      }
    } catch (_) {}
  }

  Future<void> _update(
    SoundEffectSettings next, {
    List<CustomEqPreset>? customEqPresets,
  }) async {
    state = SoundEffectState(
      settings: next,
      customEqPresets: customEqPresets ?? state.customEqPresets,
    );
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({
          'settings': state.settings.toJson(),
          'customEqPresets':
              state.customEqPresets.map((p) => p.toJson()).toList(),
        }),
      );
    } catch (_) {}
  }

  Future<void> _mutateCustom(List<CustomEqPreset> list) async {
    state = SoundEffectState(settings: state.settings, customEqPresets: list);
    await _persist();
  }

  Future<void> set(SoundEffectSettings s) => _update(s);

  Future<void> setEqGain(int index, double value) async {
    final gains = [...state.settings.eqGains];
    gains[index] = value;
    await _update(state.settings.copyWith(eqGains: gains));
  }

  Future<void> applyEqPreset(String name) async {
    final preset = eqPresets.where((p) => p.name == name).toList();
    if (preset.isEmpty) return;
    await _update(state.settings.copyWith(eqGains: [...preset.first.gains]));
  }

  /// 保存当前 EQ 增益为自定义预设；同名则覆盖。
  Future<void> saveCustomEqPreset(String name) async {
    final g = name.trim();
    if (g.isEmpty) return;
    final preset = CustomEqPreset(g, [...state.settings.eqGains]);
    final list = [...state.customEqPresets];
    final idx = list.indexWhere((p) => p.name == g);
    if (idx >= 0) {
      list[idx] = preset;
    } else {
      list.add(preset);
    }
    await _mutateCustom(list);
  }

  /// 重命名（编辑）自定义预设。
  Future<void> renameCustomEqPreset(String oldName, String newName) async {
    final g = newName.trim();
    if (g.isEmpty || g == oldName) return;
    final list = [...state.customEqPresets];
    final idx = list.indexWhere((p) => p.name == oldName);
    if (idx < 0) return;
    list[idx] = CustomEqPreset(g, list[idx].gains);
    await _mutateCustom(list);
  }

  /// 删除自定义预设。
  Future<void> deleteCustomEqPreset(String name) async {
    await _mutateCustom(
        state.customEqPresets.where((p) => p.name != name).toList());
  }

  /// 应用自定义预设到 EQ 增益。
  Future<void> applyCustomEqPreset(String name) async {
    final preset =
        state.customEqPresets.where((p) => p.name == name).toList();
    if (preset.isEmpty) return;
    await _update(state.settings.copyWith(eqGains: [...preset.first.gains]));
  }

  Future<void> resetEq() async {
    await _update(state.settings.copyWith(
        eqGains: const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  }

  Future<void> setPitchShift(double v) async {
    await _update(state.settings.copyWith(pitchShift: v));
  }

  Future<void> setPlaybackRate(double v) async {
    await _update(state.settings.copyWith(playbackRate: v));
  }

  Future<void> setPreservesPitch(bool v) async {
    await _update(state.settings.copyWith(preservesPitch: v));
  }

  Future<void> setReverb(String kind, String preset, double dry, double wet) async {
    await _update(state.settings.copyWith(
      reverbKind: kind,
      reverbPreset: preset,
      reverbDry: dry,
      reverbWet: wet,
    ));
  }

  Future<void> clearReverb() async {
    await _update(state.settings.copyWith(
      reverbKind: 'none',
      reverbPreset: '',
      reverbDry: 0,
      reverbWet: 0,
    ));
  }

  Future<void> setSpatial(String mode, {double? speed, double? radius}) async {
    await _update(state.settings.copyWith(
      spatialMode: mode,
      spatialSpeed: speed ?? state.settings.spatialSpeed,
      spatialRadius: radius ?? state.settings.spatialRadius,
    ));
  }

  Future<void> setBypass(bool v) async {
    await _update(state.settings.copyWith(bypass: v));
  }

  /// 重置所有音效（含 EQ）。
  Future<void> resetAll() async {
    await _update(const SoundEffectSettings());
  }
}

final soundEffectProvider =
    StateNotifierProvider<SoundEffectManager, SoundEffectState>((ref) {
  return SoundEffectManager();
});
