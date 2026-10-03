part of 'player_page.dart';

class _LyricsAdjustDialog extends ConsumerStatefulWidget {
  const _LyricsAdjustDialog({required this.hasRomaji, required this.showAlign});

  final bool hasRomaji;
  final bool showAlign;

  @override
  ConsumerState<_LyricsAdjustDialog> createState() =>
      _LyricsAdjustDialogState();
}

enum _LyricAdjustPanel { main, font, offset }

class _LyricsAdjustDialogState extends ConsumerState<_LyricsAdjustDialog> {
  _LyricAdjustPanel _panel = _LyricAdjustPanel.main;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(settingsProvider.notifier);
    final align =
        ref.watch(settingsProvider).valueOrNull?.lyricAlignment ?? 'center';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          switch (_panel) {
            _LyricAdjustPanel.main => _buildMain(
              context,
              scheme,
              align,
              notifier,
            ),
            _LyricAdjustPanel.font => _buildFont(context),
            _LyricAdjustPanel.offset => _buildOffset(context),
          },
        ],
      ),
    );
  }

  Widget _backButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      icon: Icon(
        Icons.arrow_back_ios_new_rounded,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      onPressed: () => setState(() => _panel = _LyricAdjustPanel.main),
    );
  }

  Widget _buildMain(
    BuildContext context,
    ColorScheme scheme,
    String align,
    SettingsNotifier notifier,
  ) {
    final s = ref.watch(settingsProvider).valueOrNull;
    final showTranslation = s?.showLyricsTranslation ?? true;
    final showRomaji = s?.showLyricsRomaji ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('歌词调节'),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        if (widget.showAlign) ...[
          _TraditionalPlayerLayoutState._buildAlignSegmented(
            context,
            align,
            notifier,
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 4),
        ],
        _TraditionalPlayerLayoutState._buildLyricMenuAction(
          context,
          icon: Icons.format_size_rounded,
          label: tr('歌词字号'),
          onTap: () => setState(() => _panel = _LyricAdjustPanel.font),
        ),
        _TraditionalPlayerLayoutState._buildLyricMenuSwitch(
          context,
          icon: Icons.translate_rounded,
          label: tr('翻译'),
          value: showTranslation,
          onChanged: (v) => notifier.setShowLyricsTranslation(v),
        ),
        _TraditionalPlayerLayoutState._buildLyricMenuSwitch(
          context,
          icon: Icons.abc_rounded,
          label: tr('罗马音'),
          value: showRomaji,
          enabled: widget.hasRomaji,
          onChanged: (v) => notifier.setShowLyricsRomaji(v),
        ),
        _TraditionalPlayerLayoutState._buildLyricMenuAction(
          context,
          icon: Icons.av_timer_rounded,
          label: tr('时间偏移'),
          onTap: () => setState(() => _panel = _LyricAdjustPanel.offset),
        ),
      ],
    );
  }

  Widget _buildFont(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(settingsProvider.notifier);
    final current = ref.watch(settingsProvider).valueOrNull?.lyricFontSize ?? 1;
    final labels = [tr('小'), tr('标准'), tr('大'), tr('特大')];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _backButton(context),
            const SizedBox(width: 4),
            Text(
              tr('歌词字号'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => notifier.setLyricFontSize(i),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: current == i
                          ? const Color(0xFFEC4141).withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: current == i
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: current == i
                            ? const Color(0xFFEC4141)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(Icons.font_download_outlined, size: 18, color: scheme.outline),
            const SizedBox(width: 8),
            Text(
              tr('自定义歌词字体'),
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            _FontImportAction(sheetCtx: context),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          tr('支持 .ttf / .otf 字体文件，导入后立即应用到歌词'),
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
      ],
    );
  }

  Widget _buildOffset(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(settingsProvider.notifier);
    final value = ref.watch(settingsProvider).valueOrNull?.lyricOffsetMs ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _backButton(context),
            Text(
              tr('歌词偏移'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            TextButton(
              onPressed: () => notifier.setLyricOffsetMs(0),
              child: Text(tr('重置')),
            ),
          ],
        ),
        Text(
          value > 0
              ? tr('提前 {v}ms', {'v': value})
              : value < 0
              ? tr('延后 {v}ms', {'v': -value})
              : tr('无偏移'),
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        Text(
          tr('蓝牙耳机存在固有延迟，歌词提前时请向"延后"方向调节'),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        Slider(
          value: value.toDouble(),
          min: -2000,
          max: 2000,
          divisions: 400,
          label: '${value}ms',
          onChanged: (v) => notifier.setLyricOffsetMs(v.round()),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: ['-200', '-100', '-10', '-1', '+1', '+10', '+100', '+200']
              .map((label) {
                final step = int.parse(label);
                return _LyricsViewState._offsetStepChip(
                  context,
                  label,
                  scheme,
                  () => notifier.setLyricOffsetMs(
                    (value + step).clamp(-2000, 2000),
                  ),
                );
              })
              .toList(),
        ),
      ],
    );
  }
}
