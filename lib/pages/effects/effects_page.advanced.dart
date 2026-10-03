part of 'effects_page.dart';

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
            title: tr('消人声'),
            value: settings.vocalRemoval,
            onChanged: (v) => notifier.set(settings.copyWith(vocalRemoval: v)),
          ),
          _switchTile(
            context,
            icon: Icons.waves,
            title: tr('颤音'),
            value: settings.vibratoEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(vibratoEnabled: v)),
          ),
          if (settings.vibratoEnabled) ...[
            _SliderTile(
              label: tr('颤音速率'),
              value: settings.vibratoRate,
              min: 1,
              max: 20,
              display: '${settings.vibratoRate.round()} Hz',
              onChanged: (v) => notifier.set(settings.copyWith(vibratoRate: v)),
            ),
            _SliderTile(
              label: tr('颤音深度'),
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
            title: tr('抖音效果器'),
            value: settings.tremoloEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(tremoloEnabled: v)),
          ),
          if (settings.tremoloEnabled) ...[
            _SliderTile(
              label: tr('速率'),
              value: settings.tremoloRate,
              min: 1,
              max: 20,
              display: '${settings.tremoloRate.round()} Hz',
              onChanged: (v) => notifier.set(settings.copyWith(tremoloRate: v)),
            ),
            _SliderTile(
              label: tr('深度'),
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
            title: tr('Bass 重低音增强'),
            value: settings.bassBoostEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(bassBoostEnabled: v)),
          ),
          if (settings.bassBoostEnabled) ...[
            _SliderTile(
              label: tr('增益'),
              value: settings.bassBoostGain,
              min: 0,
              max: 15,
              display: '${settings.bassBoostGain.round()} dB',
              onChanged: (v) =>
                  notifier.set(settings.copyWith(bassBoostGain: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.bolt),
              title:   Text(tr('动态低音回弹')),
              value: settings.bassBoostDynamic,
              onChanged: (v) =>
                  notifier.set(settings.copyWith(bassBoostDynamic: v)),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.graphic_eq,
            title: tr('高音增强'),
            value: settings.trebleEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(trebleEnabled: v)),
          ),
          if (settings.trebleEnabled) ...[
            _SliderTile(
              label: tr('增益'),
              value: settings.trebleGain,
              min: 0,
              max: 15,
              display: '${settings.trebleGain.round()} dB',
              onChanged: (v) =>
                  notifier.set(settings.copyWith(trebleGain: v)),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.auto_fix_high,
            title: tr('失真'),
            value: settings.distortionEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(distortionEnabled: v)),
          ),
          if (settings.distortionEnabled) ...[
            _SliderTile(
              label: tr('失真强度'),
              value: settings.distortionAmount,
              min: 1,
              max: 100,
              display: '${settings.distortionAmount.round()}',
              onChanged: (v) =>
                  notifier.set(settings.copyWith(distortionAmount: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.tune),
              title:   Text(tr('软失真')),
              value: settings.distortionType == 'soft',
              onChanged: (v) => notifier.set(settings.copyWith(
                  distortionType: v ? 'soft' : 'hard')),
            ),
          ],
          _switchTile(
            context,
            icon: Icons.repeat,
            title: tr('延迟回声'),
            value: settings.delayEnabled,
            onChanged: (v) => notifier.set(settings.copyWith(delayEnabled: v)),
          ),
          if (settings.delayEnabled) ...[
            _SliderTile(
              label: tr('延迟时间'),
              value: settings.delayTime,
              min: 50,
              max: 2000,
              display: '${settings.delayTime.round()} ms',
              onChanged: (v) => notifier.set(settings.copyWith(delayTime: v)),
            ),
            _SliderTile(
              label: tr('反馈'),
              value: settings.delayFeedback,
              min: 0,
              max: 90,
              display: '${settings.delayFeedback.round()}%',
              onChanged: (v) =>
                  notifier.set(settings.copyWith(delayFeedback: v)),
            ),
            _SliderTile(
              label: tr('混合'),
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
            title: tr('镶边'),
            value: settings.flangerEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(flangerEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.blur_on,
            title: tr('相位'),
            value: settings.phaserEnabled,
            onChanged: (v) => notifier.set(settings.copyWith(phaserEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.compress,
            title: tr('压缩器'),
            value: settings.compressorEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(compressorEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.volume_off,
            title: tr('噪声门'),
            value: settings.noiseGateEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(noiseGateEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.vertical_align_top,
            title: tr('限制器'),
            value: settings.limiterEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(limiterEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.highlight,
            title: tr('谐波激励器'),
            value: settings.exciterEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(exciterEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.speaker_group,
            title: tr('次谐波低音增强'),
            value: settings.subBassEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(subBassEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.graphic_eq,
            title: tr('Lo-Fi 低保真'),
            value: settings.loFiEnabled,
            onChanged: (v) => notifier.set(settings.copyWith(loFiEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.space_bar,
            title: tr('立体声拓宽'),
            value: settings.stereoWidenEnabled,
            onChanged: (v) =>
                notifier.set(settings.copyWith(stereoWidenEnabled: v)),
          ),
          _switchTile(
            context,
            icon: Icons.merge,
            title: tr('单声道合并'),
            value: settings.monoMerge,
            onChanged: (v) => notifier.set(settings.copyWith(monoMerge: v)),
          ),
          _switchTile(
            context,
            icon: Icons.swap_horiz,
            title: tr('左右声道交换'),
            value: settings.channelSwap,
            onChanged: (v) => notifier.set(settings.copyWith(channelSwap: v)),
          ),
          _switchTile(
            context,
            icon: Icons.auto_awesome,
            title: tr('V4A 组合音效'),
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
