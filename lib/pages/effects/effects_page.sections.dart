part of 'effects_page.dart';

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
            label: tr('倍速'),
            value: settings.playbackRate,
            min: 50,
            max: 200,
            displayBuilder: (v) => '${v.round()}%',
            onChanged: (v) => notifier.setPlaybackRate(v),
          ),
          _SliderTile(
            label: tr('变调'),
            value: settings.pitchShift,
            min: 50,
            max: 200,
            displayBuilder: (v) => '${v.round()}%',
            onChanged: (v) => notifier.setPitchShift(v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.music_note),
            title:   Text(tr('变速时保持音调')),
            value: settings.preservesPitch,
            onChanged: (v) => notifier.setPreservesPitch(v),
          ),
        ],
      ),
    );
  }
}

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
              label: tr('干声'),
              value: settings.reverbDry * 100,
              min: 0,
              max: 100,
              displayBuilder: (v) => '${v.round()}%',
              onChanged: (v) => notifier.setReverb(
                  settings.reverbKind, settings.reverbPreset, v / 100,
                  settings.reverbWet),
            ),
            _SliderTile(
              label: tr('湿声'),
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
              for (final m in   [
                ('none', tr('关闭')),
                ('surround3d', tr('3D 环绕')),
                ('d8', tr('8D 环绕')),
                ('d36', tr('36D 环绕')),
                ('virtual', tr('虚拟环绕')),
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
              label: tr('旋转速度'),
              value: settings.spatialSpeed,
              min: 2,
              max: 20,
              display: tr('{v}s/圈', {'v': settings.spatialSpeed.toStringAsFixed(1)}),
              onChanged: (v) => notifier.setSpatial(mode, speed: v),
            ),
            _SliderTile(
              label: tr('声源距离'),
              value: settings.spatialRadius * 10,
              min: 1,
              max: 20,
              display: '${(settings.spatialRadius * 10).round()}',
              onChanged: (v) => notifier.setSpatial(mode, radius: v / 10),
            ),
          ],
          if (mode == 'd8' || mode == 'd36') ...[
            _SliderTile(
              label: tr('旋转速度'),
              value: settings.spatialSpeed,
              min: 2,
              max: 60,
              display: tr('{v}s/圈', {'v': settings.spatialSpeed.round()}),
              onChanged: (v) => notifier.setSpatial(mode, speed: v),
            ),
            _SliderTile(
              label: tr('虚拟距离'),
              value: settings.spatialRadius * 5,
              min: 1,
              max: 20,
              display: '${(settings.spatialRadius * 5).round()}',
              onChanged: (v) => notifier.setSpatial(mode, radius: v / 5),
            ),
          ],
          if (mode == 'virtual') ...[
            _SliderTile(
              label: tr('声场宽度'),
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
