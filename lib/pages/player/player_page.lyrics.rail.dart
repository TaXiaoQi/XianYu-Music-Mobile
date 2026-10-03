part of 'player_page.dart';

class _LyricSettingsRail extends ConsumerStatefulWidget {
  const _LyricSettingsRail({
    required this.fontSizeIdx,
    required this.showTranslation,
    required this.showRomaji,
    required this.offsetMs,
    required this.hasTranslation,
    required this.hasRomaji,
    required this.onFontSize,
    required this.onToggleTranslation,
    required this.onToggleRomaji,
    required this.onOffset,
  });

  final int fontSizeIdx;
  final bool showTranslation;
  final bool showRomaji;
  final int offsetMs;
  final bool hasTranslation;
  final bool hasRomaji;
  final VoidCallback onFontSize;
  final VoidCallback onToggleTranslation;
  final VoidCallback onToggleRomaji;
  final VoidCallback onOffset;

  @override
  ConsumerState<_LyricSettingsRail> createState() => _LyricSettingsRailState();
}

class _LyricSettingsRailState extends ConsumerState<_LyricSettingsRail> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelWidth = _expanded ? 46.0 : 40.0;
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.overlay));
    final sigma = surfaceBlurSigma(
      base: 14,
      budget: budget,
      type: BlurSurfaceType.overlay,
    );
    final panelBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.75);

    // 静态帧：转场/动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            width: panelWidth,
            decoration: BoxDecoration(
              color: surfaceFillWithBudget(panelBg, budget),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.5),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(20),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: AnimatedRotation(
                        turns: _expanded ? 0.25 : 0.0,
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.tune_rounded,
                          size: 20,
                          color: _expanded
                              ? const Color(0xFFEC4141)
                              : Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  ),
                ),

                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _expanded
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Divider(
                              height: 1,
                              indent: 8,
                              endIndent: 8,
                              thickness: 0.5,
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                            const SizedBox(height: 4),

                            _RailIconButton(
                              icon: Icons.format_size_rounded,
                              active: widget.fontSizeIdx != 1,
                              onTap: widget.onFontSize,
                            ),

                            _RailIconButton(
                              icon: Icons.translate_rounded,
                              active:
                                  widget.showTranslation &&
                                  widget.hasTranslation,
                              disabled: !widget.hasTranslation,
                              onTap: widget.onToggleTranslation,
                            ),

                            _RailIconButton(
                              icon: Icons.abc_rounded,
                              active: widget.showRomaji && widget.hasRomaji,
                              disabled: !widget.hasRomaji,
                              onTap: widget.onToggleRomaji,
                            ),

                            _RailIconButton(
                              icon: Icons.av_timer_rounded,
                              active: widget.offsetMs != 0,
                              onTap: widget.onOffset,
                            ),

                            const SizedBox(height: 6),
                          ],
                        )
                      : const SizedBox(width: 40, height: 0),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FontImportAction extends ConsumerWidget {
  const _FontImportAction({required this.sheetCtx});
  final BuildContext sheetCtx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontName = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.lyricFontName ?? ''),
    );
    final hasFont = fontName.isNotEmpty;

    if (!hasFont) {
      return TextButton.icon(
        onPressed: () async {
          try {
            final imported = await LyricFontManager.importCustomFont(
              onApplied: (name, path) async {
                final n = ref.read(settingsProvider.notifier);
                await n.setLyricFontPath(path);
                await n.setLyricFontName(name);
              },
            );
            if (imported == null) return;
            if (context.mounted) {
              showXianYuToast(context, tr('已应用自定义歌词字体'));
            }
          } catch (e) {
            if (context.mounted) {
              showXianYuToast(context, tr('字体导入失败：{e}', {'e': e}));
            }
          }
        },
        icon: const Icon(Icons.file_open_outlined, size: 18),
        label: Text(tr('选择字体')),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr('已应用'),
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        TextButton.icon(
          onPressed: () async {
            final n = ref.read(settingsProvider.notifier);
            await n.setLyricFontName('');
            await n.setLyricFontPath('');
          },
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(tr('恢复默认')),
        ),
      ],
    );
  }
}

class _RailIconButton extends StatelessWidget {
  const _RailIconButton({
    required this.icon,
    required this.active,
    this.disabled = false,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const activeColor = Color(0xFFEC4141);
    final inactiveColor = Colors.white.withValues(alpha: disabled ? 0.3 : 0.85);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active
                ? activeColor.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            size: 19,
            color: active ? activeColor : inactiveColor,
          ),
        ),
      ),
    );
  }
}
