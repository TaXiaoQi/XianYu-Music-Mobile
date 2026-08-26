import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/effects/sound_effect_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/sheet_dialog.dart';

/// 音效页：EQ / 变速变调 / 混响 / 空间音效 / 高级音效。
class EffectsPage extends ConsumerWidget {
  const EffectsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(soundEffectProvider).settings;
    final notifier = ref.read(soundEffectProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final locked = ref.watch(playerProvider.select((s) => s.usbExclusive));

    return Scaffold(
      body: Stack(
        children: [
          IgnorePointer(
            ignoring: locked,
            child: Opacity(
              opacity: locked ? 0.5 : 1.0,
              child: ListView(
                // 顶部预留顶栏高度：静止时内容位于毛玻璃下方，上拉时内容滑入顶栏被高斯模糊。
                padding: EdgeInsets.only(
                    top: GlassTopBar.height(context), bottom: 150),
                children: [
                  if (locked)
                    Container(
                      width: double.infinity,
                      margin:
                          const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_outline,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Bit-perfect / DSD 直出中，音效已锁定',
                              style: TextStyle(
                                  fontSize: 13, color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
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
            ),
          ),
          // 顶栏高斯模糊毛玻璃。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: const Text('音效'),
              actions: [
                TextButton.icon(
                  onPressed: locked ? null : () => notifier.resetAll(),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('重置'),
                ),
              ],
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
    final customPresets =
        ref.watch(soundEffectProvider).customEqPresets;
    final manager = ref.read(soundEffectProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  avatar: Icon(Icons.add, size: 18, color: scheme.primary),
                  label: const Text('保存'),
                  onPressed: () => _savePreset(context, manager),
                ),
              ),
              for (final p in eqPresets)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.name),
                    selected: _isPresetActive(settings, p.gains),
                    onSelected: (_) => notifier.applyEqPreset(p.name),
                  ),
                ),
              if (customPresets.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _dividerDot(context),
                ),
                for (final p in customPresets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: () => _editPreset(context, manager, p.name),
                      child: ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.person_pin, size: 14),
                            const SizedBox(width: 4),
                            Text(p.name),
                          ],
                        ),
                        selected: _isPresetActive(settings, p.gains),
                        onSelected: (_) =>
                            manager.applyCustomEqPreset(p.name),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 16, 6),
          child: Text(
            customPresets.isEmpty ? '长按自定义预设可重命名或删除' : '预设 · 点按应用 · 长按编辑',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (var i = 0; i < eqFreqLabels.length; i++)
                _EqBand(
                  value: settings.eqGains[i],
                  freqLabel: eqFreqLabels[i],
                  onCommit: (v) => notifier.setEqGain(i, v),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dividerDot(BuildContext context) => Center(
        child: Container(
          width: 1,
          height: 20,
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.3),
        ),
      );

  bool _isPresetActive(SoundEffectSettings s, List<double> gains) {
    if (s.eqGains.length != gains.length) return false;
    for (var i = 0; i < s.eqGains.length; i++) {
      if ((s.eqGains[i] - gains[i]).abs() > 0.01) return false;
    }
    return true;
  }

  Future<void> _savePreset(BuildContext context, SoundEffectManager manager) async {
    final scheme = Theme.of(context).colorScheme;
    final controller = TextEditingController();
    final name = await showSheetDialog<String>(
      context,
      (dialogContext) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('保存均衡器预设', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('将当前 EQ 增益保存为自定义预设，同名将覆盖',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '预设名称',
                hintText: '例如：我的流行',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(dialogContext, controller.text.trim());
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await manager.saveCustomEqPreset(name);
      if (context.mounted) {
        showXianYuToast(context, '已保存预设「$name」',
            duration: const Duration(seconds: 1));
      }
    }
  }

  Future<void> _editPreset(
      BuildContext context, SoundEffectManager manager, String name) async {
    final scheme = Theme.of(context).colorScheme;
    final action = await showSheetDialog<String>(
      context,
      (dialogContext) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('预设「$name」',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(dialogContext, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.pop(dialogContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') {
      if (!context.mounted) return;
      final controller = TextEditingController(text: name);
      final newName = await showSheetDialog<String>(
        context,
        (dialogContext) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('重命名预设',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '预设名称',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) =>
                    Navigator.pop(dialogContext, v.trim()),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, controller.text.trim()),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      controller.dispose();
      if (newName != null && newName.isNotEmpty) {
        await manager.renameCustomEqPreset(name, newName);
      }
    } else if (action == 'delete') {
      await manager.deleteCustomEqPreset(name);
      if (context.mounted) {
        showXianYuToast(context, '已删除预设「$name」',
            duration: const Duration(seconds: 1));
      }
    }
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
            displayBuilder: (v) => '${v.round()}%',
            onChanged: (v) => notifier.setPlaybackRate(v),
          ),
          _SliderTile(
            label: '变调',
            value: settings.pitchShift,
            min: 50,
            max: 200,
            displayBuilder: (v) => '${v.round()}%',
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
              displayBuilder: (v) => '${v.round()}%',
              onChanged: (v) => notifier.setReverb(
                  settings.reverbKind, settings.reverbPreset, v / 100,
                  settings.reverbWet),
            ),
            _SliderTile(
              label: '湿声',
              value: settings.reverbWet * 100,
              min: 0,
              max: 100,
              displayBuilder: (v) => '${v.round()}%',
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
///
/// 拖动期间仅本地跟手——拇指移动只在 [State] 内 `setState` 重建本行
/// （值暂存 [draft]，hit 到 provider），松手（onChangeEnd）才提交一次。
/// 避免每个 tick 都写 provider 触发整页 rebuild，导致音效页滑动卡顿。
class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.display,
    this.displayBuilder,
  });

  final String label;
  final double value;
  final double min;
  final double max;

  /// 未传 [displayBuilder] 时的静态兜底文本。
  final String? display;

  /// 数值实时文本（由当前拖拽值驱动）；缺省则用 [display] 或取整数值。
  final String Function(double)? displayBuilder;
  final ValueChanged<double> onChanged;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final v = (_draft ?? widget.value).clamp(widget.min, widget.max);
    final text = widget.displayBuilder?.call(v) ??
        widget.display ??
        v.round().toString();
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(widget.label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: widget.min,
            max: widget.max,
            onChanged: (x) => setState(() => _draft = x),
            onChangeEnd: (x) {
              widget.onChanged(x);
              setState(() => _draft = null);
            },
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// 均衡器单段：上方增益数值 + 竖向滑杆 + 下方频率标签。
///
/// 与 [_SliderTile] 同一提交式优化：拖动只重建本段，松手才写 provider。
class _EqBand extends StatefulWidget {
  const _EqBand({
    required this.value,
    required this.freqLabel,
    required this.onCommit,
  });

  final double value;
  final String freqLabel;
  final ValueChanged<double> onCommit;

  @override
  State<_EqBand> createState() => _EqBandState();
}

class _EqBandState extends State<_EqBand> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = (_draft ?? widget.value).clamp(-12.0, 12.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        children: [
          Text(
            '${v >= 0 ? '+' : ''}${v.round()}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: v,
                min: -12,
                max: 12,
                onChanged: (x) => setState(() => _draft = x),
                onChangeEnd: (x) {
                  widget.onCommit(x);
                  setState(() => _draft = null);
                },
              ),
            ),
          ),
          Text(widget.freqLabel,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
