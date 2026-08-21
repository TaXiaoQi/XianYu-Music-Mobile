import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/effects/sound_effect_provider.dart';

/// 音效页：EQ / 变速变调 / 混响 / 空间音效 / 高级音效。
class EffectsPage extends ConsumerWidget {
  const EffectsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(soundEffectProvider).settings;
    final notifier = ref.read(soundEffectProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('音效'),
        actions: [
          TextButton.icon(
            onPressed: () => notifier.resetAll(),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('重置'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 150),
        children: [
          _sectionHeader(context, '均衡器'),
          _EqSection(settings: settings, notifier: notifier),
          _sectionHeader(context, '变速变调'),
          _PitchRateSection(settings: settings, notifier: notifier),
          _sectionHeader(context, '混响'),
          _ReverbSection(settings: settings, notifier: notifier),
          _sectionHeader(context, '空间音效'),
          _SpatialSection(settings: settings, notifier: notifier),
          _sectionHeader(context, '高级音效'),
          _AdvancedSection(settings: settings, notifier: notifier),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '音效由 Rust DSP 引擎实时处理；变速变调即时生效，其余效果在播放时同步到引擎。',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

/// 10 段均衡器：预设横滑 + 滑块。
class _EqSection extends ConsumerWidget {
  const _EqSection({required this.settings, required this.notifier});
  final SoundEffectSettings settings;
  final SoundEffectManager notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final p in eqPresets)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.name),
                    selected: _isPresetActive(settings, p),
                    onSelected: (_) => notifier.applyEqPreset(p.name),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (var i = 0; i < eqFreqLabels.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    children: [
                      Text(
                        '${settings.eqGains[i] >= 0 ? '+' : ''}${settings.eqGains[i].round()}',
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Slider(
                            value: settings.eqGains[i].clamp(-12.0, 12.0),
                            min: -12,
                            max: 12,
                            onChanged: (v) => notifier.setEqGain(i, v),
                          ),
                        ),
                      ),
                      Text(eqFreqLabels[i],
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  bool _isPresetActive(SoundEffectSettings s, EqPreset p) {
    if (s.eqGains.length != p.gains.length) return false;
    for (var i = 0; i < s.eqGains.length; i++) {
      if ((s.eqGains[i] - p.gains[i]).abs() > 0.01) return false;
    }
    return true;
  }
}

/// 变速变调：倍速 + 变调 + 音调补偿。
class _PitchRateSection extends ConsumerWidget {
  const _PitchRateSection({required this.settings, required this.notifier});
  final SoundEffectSettings settings;
  final SoundEffectManager notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          _SliderTile(
            label: '倍速',
            value: settings.playbackRate,
            min: 50,
            max: 200,
            display: '${settings.playbackRate.round()}%',
            onChanged: (v) => notifier.setPlaybackRate(v),
          ),
          _SliderTile(
            label: '变调',
            value: settings.pitchShift,
            min: 50,
            max: 200,
            display: '${settings.pitchShift.round()}%',
            onChanged: (v) => notifier.setPitchShift(v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.music_note),
            title: const Text('变速时保持音调'),
            value: settings.preservesPitch,
            onChanged: (v) => notifier.setPreservesPitch(v),
          ),
        ],
      ),
    );
  }
}

/// 混响：卷积/算法预设选择 + 干湿滑杆。
class _ReverbSection extends ConsumerWidget {
  const _ReverbSection({required this.settings, required this.notifier});
  final SoundEffectSettings settings;
  final SoundEffectManager notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = settings.reverbKind == 'none' ? null : settings.reverbPreset;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in [...reverbPresets, ...algoReverbPresets])
                ChoiceChip(
                  label: Text(p.label),
                  selected: active == p.label,
                  onSelected: (_) {
                    if (active == p.label) {
                      notifier.clearReverb();
                    } else {
                      final kind = reverbPresets.contains(p)
                          ? 'convolution'
                          : 'algorithmic';
                      notifier.setReverb(kind, p.label, p.dry.toDouble(),
                          p.wet.toDouble());
                    }
                  },
                ),
            ],
          ),
          if (settings.reverbKind != 'none') ...[
            const SizedBox(height: 8),
            _SliderTile(
              label: '干声',
              value: settings.reverbDry * 100,
              min: 0,
              max: 100,
              display: '${(settings.reverbDry * 100).round()}%',
              onChanged: (v) => notifier.setReverb(
                  settings.reverbKind, settings.reverbPreset, v / 100,
                  settings.reverbWet),
            ),
            _SliderTile(
              label: '湿声',
              value: settings.reverbWet * 100,
              min: 0,
              max: 100,
              display: '${(settings.reverbWet * 100).round()}%',
              onChanged: (v) => notifier.setReverb(
                  settings.reverbKind, settings.reverbPreset, settings.reverbDry,
                  v / 100),
            ),
          ],
        ],
      ),
    );
  }
}

/// 空间音效：3D / 8D / 36D / 虚拟环绕（互斥）。
class _SpatialSection extends ConsumerWidget {
  const _SpatialSection({required this.settings, required this.notifier});
  final SoundEffectSettings settings;
  final SoundEffectManager notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = settings.spatialMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in const [
                ('none', '关闭'),
                ('surround3d', '3D 环绕'),
                ('d8', '8D 环绕'),
                ('d36', '36D 环绕'),
                ('virtual', '虚拟环绕'),
              ])
                ChoiceChip(
                  label: Text(m.$2),
                  selected: mode == m.$1,
                  onSelected: (_) => notifier.setSpatial(
                      mode == m.$1 ? 'none' : m.$1),
                ),
            ],
          ),
          if (mode == 'surround3d') ...[
            _SliderTile(
              label: '旋转速度',
              value: settings.spatialSpeed,
              min: 2,
              max: 20,
              display: '${settings.spatialSpeed.toStringAsFixed(1)}s/圈',
              onChanged: (v) => notifier.setSpatial(mode, speed: v),
            ),
            _SliderTile(
              label: '声源距离',
              value: settings.spatialRadius * 10,
              min: 1,
              max: 20,
              display: '${(settings.spatialRadius * 10).round()}',
              onChanged: (v) => notifier.setSpatial(mode, radius: v / 10),
            ),
          ],
          if (mode == 'd8' || mode == 'd36') ...[
            _SliderTile(
              label: '旋转速度',
              value: settings.spatialSpeed,
              min: 2,
              max: 60,
              display: '${settings.spatialSpeed.round()}s/圈',
              onChanged: (v) => notifier.setSpatial(mode, speed: v),
            ),
            _SliderTile(
              label: '虚拟距离',
              value: settings.spatialRadius * 5,
              min: 1,
              max: 20,
              display: '${(settings.spatialRadius * 5).round()}',
              onChanged: (v) => notifier.setSpatial(mode, radius: v / 5),
            ),
          ],
          if (mode == 'virtual') ...[
            _SliderTile(
              label: '声场宽度',
              value: settings.virtualSurroundSpread,
              min: 1,
              max: 20,
              display: '${settings.virtualSurroundSpread.round()}',
              onChanged: (v) => notifier.setSpatial(mode),
            ),
          ],
        ],
      ),
    );
  }
}

/// 高级音效：可开关的各类效果。
class _AdvancedSection extends ConsumerWidget {
  const _AdvancedSection({required this.settings, required this.notifier});
  final SoundEffectSettings settings;
  final SoundEffectManager notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          _switchTile(
            context,
            icon: Icons.mic_off,
            title: '消人声',
            value: settings.vocalRemoval,
            onChanged: (v) => notifier.set(settings.copyWith(vocalRemoval: v)),
          ),
          _switchTile(
            context,
            icon: Icons.waves,
            title: '颤音',
            value: settings.vibratoEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(vibratoEnabled: v)),
          ),
          if (settings.vibratoEnabled) ...[
            _SliderTile(
              label: '颤音速率',
              value: settings.vibratoRate,
              min: 1,
              max: 20,
              display: '${settings.vibratoRate.round()} Hz',
              onChanged: (v) => notifier.set(settings.copyWith(vibratoRate: v)),
            ),
            _SliderTile(
              label: '颤音深度',
              value: settings.vibratoDepth,
              min: 0,
              max: 10,
              display: '${settings.vibratoDepth.round()} ms',
              onChanged: (v) => notifier.set(settings.copyWith(vibratoDepth: v)),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.album,
            title: '抖音效果器',
            value: settings.tremoloEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(tremoloEnabled: v)),
          ),
          if (settings.tremoloEnabled) ...[
            _SliderTile(
              label: '速率',
              value: settings.tremoloRate,
              min: 1,
              max: 20,
              display: '${settings.tremoloRate.round()} Hz',
              onChanged: (v) => notifier.set(settings.copyWith(tremoloRate: v)),
            ),
            _SliderTile(
              label: '深度',
              value: settings.tremoloDepth,
              min: 0,
              max: 100,
              display: '${settings.tremoloDepth.round()}%',
              onChanged: (v) => notifier.set(settings.copyWith(tremoloDepth: v)),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.speaker,
            title: 'Bass 重低音增强',
            value: settings.bassBoostEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(bassBoostEnabled: v)),
          ),
          if (settings.bassBoostEnabled) ...[
            _SliderTile(
              label: '增益',
              value: settings.bassBoostGain,
              min: 0,
              max: 15,
              display: '${settings.bassBoostGain.round()} dB',
              onChanged: (v) =>
                  notifier.set(settings.copyWith(bassBoostGain: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.bolt),
              title: const Text('动态低音回弹'),
              value: settings.bassBoostDynamic,
              onChanged: (v) =>
                  notifier.set(settings.copyWith(bassBoostDynamic: v)),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.auto_fix_high,
            title: '失真',
            value: settings.distortionEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(distortionEnabled: v)),
          ),
          if (settings.distortionEnabled) ...[
            _SliderTile(
              label: '失真强度',
              value: settings.distortionAmount,
              min: 1,
              max: 100,
              display: '${settings.distortionAmount.round()}',
              onChanged: (v) =>
                  notifier.set(settings.copyWith(distortionAmount: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.tune),
              title: const Text('软失真'),
              value: settings.distortionType == 'soft',
              onChanged: (v) => notifier.set(settings.copyWith(
                  distortionType: v ? 'soft' : 'hard')),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.repeat,
            title: '延迟回声',
            value: settings.delayEnabled,
            onChanged: (v) => notifier.set(settings.copyWith(delayEnabled: v)),
          ),
          if (settings.delayEnabled) ...[
            _SliderTile(
              label: '延迟时间',
              value: settings.delayTime,
              min: 50,
              max: 2000,
              display: '${settings.delayTime.round()} ms',
              onChanged: (v) => notifier.set(settings.copyWith(delayTime: v)),
            ),
            _SliderTile(
              label: '反馈',
              value: settings.delayFeedback,
              min: 0,
              max: 90,
              display: '${settings.delayFeedback.round()}%',
              onChanged: (v) =>
                  notifier.set(settings.copyWith(delayFeedback: v)),
            ),
            _SliderTile(
              label: '混合',
              value: settings.delayMix,
              min: 0,
              max: 100,
              display: '${settings.delayMix.round()}%',
              onChanged: (v) => notifier.set(settings.copyWith(delayMix: v)),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.layers,
            title: '镶边',
            value: settings.flangerEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(flangerEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.blur_on,
            title: '相位',
            value: settings.phaserEnabled,
            onChanged: (v) => notifier.set(settings.copyWith(phaserEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.compress,
            title: '压缩器',
            value: settings.compressorEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(compressorEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.volume_off,
            title: '噪声门',
            value: settings.noiseGateEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(noiseGateEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.vertical_align_top,
            title: '限制器',
            value: settings.limiterEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(limiterEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.highlight,
            title: '谐波激励器',
            value: settings.exciterEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(exciterEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.speaker_group,
            title: '次谐波低音增强',
            value: settings.subBassEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(subBassEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.graphic_eq,
            title: 'Lo-Fi 低保真',
            value: settings.loFiEnabled,
            onChanged: (v) => notifier.set(settings.copyWith(loFiEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.space_bar,
            title: '立体声拓宽',
            value: settings.stereoWidenEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(stereoWidenEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.merge,
            title: '单声道合并',
            value: settings.monoMerge,
            onChanged: (v) => notifier.set(settings.copyWith(monoMerge: v)),
          ),
          _switchTile(
            context,
            icon: Icons.swap_horiz,
            title: '左右声道交换',
            value: settings.channelSwap,
            onChanged: (v) => notifier.set(settings.copyWith(channelSwap: v)),
          ),
          _switchTile(
            context,
            icon: Icons.auto_awesome,
            title: 'V4A 组合音效',
            value: settings.v4aEnabled,
            onChanged: (v) => notifier.set(settings.copyWith(v4aEnabled: v)),
          ),
        ],
      ),
    );
  }

  Widget _switchTile(BuildContext context,
      {required IconData icon,
      required String title,
      required bool value,
      required ValueChanged<bool> onChanged}) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// 通用滑杆行：标签 + 滑杆 + 当前值。
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}
