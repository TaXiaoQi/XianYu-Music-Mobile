part of 'settings_category_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _SettingsCategoryPageControls on _SettingsCategoryPageState {
  // ============ 通用 UI 部件 ============

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

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget trailing,
    VoidCallback? onTap,
    String? subtitle,
    bool enabled = true,
    bool showChevron = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final iconColor = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.45);
    final titleColor = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.55);
    final subtitleColor = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.45);

    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: LayoutBuilder(builder: (context, cons) {
            return Row(
              children: [
                Icon(icon, color: iconColor),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: (textTheme.bodyLarge ?? const TextStyle()).copyWith(
                          color: titleColor,
                          fontSize: 15,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: (textTheme.bodySmall ?? const TextStyle())
                              .copyWith(color: subtitleColor),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: cons.maxWidth * 0.5),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: DefaultTextStyle(
                      style: (textTheme.bodySmall ?? const TextStyle())
                          .copyWith(color: subtitleColor),
                      child: trailing,
                    ),
                  ),
                ),
                if (showChevron && onTap != null) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: enabled
                        ? scheme.outline
                        : scheme.outline.withValues(alpha: 0.4),
                  ),
                ],
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _switchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool value,
    ValueChanged<bool>? onChanged,
    String? subtitle,
    bool enabled = true,
  }) {
    return _tile(
      context,
      icon: icon,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      showChevron: false,
      trailing: Switch.adaptive(
        value: value,
        onChanged: enabled && onChanged != null ? onChanged : null,
      ),
      onTap: enabled && onChanged != null ? () => onChanged(!value) : null,
    );
  }

  Widget _themeLabel(AppSettings? s) {
    return Text(switch (s?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.system => tr('跟随系统'),
      ThemeModePreference.light => tr('浅色'),
      ThemeModePreference.dark => tr('深色'),
    });
  }

  String _fontSizeLabel(AppFontSize v) => switch (v) {
    AppFontSize.system => tr('跟随系统'),
    AppFontSize.small => tr('小'),
    AppFontSize.standard => tr('标准'),
    AppFontSize.large => tr('大'),
    AppFontSize.larger => tr('更大'),
  };

  String _languageLabel(AppLanguage v) => switch (v) {
    AppLanguage.system => tr('跟随系统'),
    AppLanguage.zhCN => tr('简体中文'),
    AppLanguage.zhTW => tr('繁體中文'),
    AppLanguage.en => 'English',
  };

  String _hapticLabel(int v) => switch (v) {
    0 => tr('轻'),
    2 => tr('重'),
    _ => tr('正常'),
  };

  String _updateModeLabel(String mode) => switch (mode) {
    'never' => tr('从不检测'),
    _ => tr('启动检测'),
  };

  Widget _volumeSlider(
    AppSettings? s,
    SettingsNotifier n, {
    required bool locked,
  }) {
    return SizedBox(
      width: 120,
      child: CommittedSlider(
        value: s?.volume ?? 1.0,
        min: 0,
        max: 1,
        onCommit: locked ? null : (v) => n.setVolume(v),
      ),
    );
  }

  Widget _gainOffsetSlider(AppSettings? s, SettingsNotifier n) {
    final db = s?.volumeBalanceGainOffsetDb ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 130,
          child: CommittedSlider(
            min: -12,
            max: 6,
            divisions: 18,
            value: db.clamp(-12.0, 6.0),
            onCommit: (v) => n.setVolumeBalanceGainOffsetDb(v),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${db > 0 ? '+' : ''}${db.toStringAsFixed(0)} dB',
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );
  }

  // ---- 桌面歌词 ----

  Future<void> _toggleFloatingLyrics(
    BuildContext context,
    WidgetRef ref,
    SettingsNotifier n,
    bool enable,
  ) async {
    if (enable) {
      final granted = await FloatingLyricsController.isPermissionGranted();
      if (!granted) {
        if (!context.mounted) return;
        final go = await showPredictiveDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title:   Text(tr('桌面歌词需要悬浮窗权限')),
            content:   Text(tr('开启后歌词窗可显示在其他应用上层。需要前往系统设置授予「显示在其他应用上层」权限。')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child:   Text(tr('取消')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:   Text(tr('去授权')),
              ),
            ],
          ),
        );
        if (go == true) {
          // 不立即切换开关：跳系统设置，回前台后由控制器复检权限，
          // 授权成功才开启；被拦截则保持关闭
          await ref
              .read(floatingLyricsControllerProvider)
              .requestEnableViaSettings();
        }
        return;
      }
      await n.setFloatingLyricsEnabled(true);
    } else {
      await n.setFloatingLyricsEnabled(false);
    }
  }

  Future<void> _pickFloatingLyricsColor(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.floatingLyricsTextColor ?? 0xFFFFFFFF;
    final choice = await showSheetDialog<int>(
      context,
      (ctx) => _AccentColorSheet(
        current: cur,
        title: tr('歌词文字颜色'),
        presets: _AccentColorSheet.lyricPresets,
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setFloatingLyricsTextColor(choice);
    }
  }

  Future<void> _pickFloatingLyricsUnplayedColor(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final mainColor = s?.floatingLyricsTextColor ?? 0xFFFFFFFF;
    // current 保留 0 以点亮「跟随主色」自动档；取色器以主色为起点
    final cur = s?.floatingLyricsUnplayedColor ?? 0;
    final choice = await showSheetDialog<int>(
      context,
      (ctx) => _AccentColorSheet(
        current: cur,
        title: tr('未播放文字颜色'),
        presets: _AccentColorSheet.lyricPresets,
        autoLabel: tr('跟随主色'),
        autoColor: Color(mainColor).withValues(alpha: 0.38),
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setFloatingLyricsUnplayedColor(choice);
    }
  }

  Widget _floatingLyricsOpacitySlider(AppSettings? s, SettingsNotifier n) {
    final enabled = s?.floatingLyricsEnabled ?? false;
    final v = (s?.floatingLyricsOpacity ?? 100).toDouble();
    return _StepperSliderRow(
      enabled: enabled,
      readValue: () => (s?.floatingLyricsOpacity ?? 100).toDouble(),
      step: 5,
      min: 35,
      max: 100,
      format: (x) => '${x.round()}%',
      slider: CommittedSlider(
        min: 35,
        max: 100,
        divisions: 13,
        value: v,
        enabled: enabled,
        onCommit: (x) => n.setFloatingLyricsOpacity(x.round()),
      ),
      onAdjust: (x) => n.setFloatingLyricsOpacity(x.round()),
    );
  }

  Widget _floatingLyricsFontSlider(AppSettings? s, SettingsNotifier n) {
    final enabled = s?.floatingLyricsEnabled ?? false;
    final v = (s?.floatingLyricsFontScale ?? 100).toDouble();
    return _StepperSliderRow(
      enabled: enabled,
      readValue: () => (s?.floatingLyricsFontScale ?? 100).toDouble(),
      step: 5,
      min: 80,
      max: 220,
      format: (x) => '${x.round()}%',
      slider: CommittedSlider(
        min: 80,
        max: 220,
        divisions: 28,
        value: v,
        enabled: enabled,
        onCommit: (x) => n.setFloatingLyricsFontScale(x.round()),
      ),
      onAdjust: (x) => n.setFloatingLyricsFontScale(x.round()),
    );
  }

  Widget _lyricsSyncOffsetSlider(AppSettings? s, SettingsNotifier n) {
    final v = (s?.lyricOffsetMs ?? 0).toDouble();
    return _StepperSliderRow(
      enabled: true,
      readValue: () => (s?.lyricOffsetMs ?? 0).toDouble(),
      step: 5,
      min: -100,
      max: 100,
      format: (x) {
        final v = x.round();
        return v > 0 ? '+$v' : '$v';
      },
      valueWidth: 32,
      slider: CommittedSlider(
        min: -100,
        max: 100,
        divisions: 40,
        value: v,
        enabled: true,
        onCommit: (x) => n.setLyricOffsetMs(x.round()),
      ),
      onAdjust: (x) => n.setLyricOffsetMs(x.round()),
    );
  }

  Widget _floatingLyricsSecondarySlider(AppSettings? s, SettingsNotifier n) {
    final enabled = s?.floatingLyricsEnabled ?? false;
    final v = (s?.floatingLyricsSecondaryScale ?? 88).toDouble();
    return _StepperSliderRow(
      enabled: enabled,
      readValue: () => (s?.floatingLyricsSecondaryScale ?? 88).toDouble(),
      step: 5,
      min: 70,
      max: 180,
      format: (x) => '${x.round()}%',
      slider: CommittedSlider(
        min: 70,
        max: 180,
        divisions: 22,
        value: v,
        enabled: enabled,
        onCommit: (x) => n.setFloatingLyricsSecondaryScale(x.round()),
      ),
      onAdjust: (x) => n.setFloatingLyricsSecondaryScale(x.round()),
    );
  }

  Widget _floatingLyricsWidthSlider(AppSettings? s, SettingsNotifier n) {
    final enabled = s?.floatingLyricsEnabled ?? false;
    final v = (s?.floatingLyricsWidthPercent ?? 92).toDouble();
    return _StepperSliderRow(
      enabled: enabled,
      readValue: () => (s?.floatingLyricsWidthPercent ?? 92).toDouble(),
      step: 5,
      min: 40,
      max: 100,
      format: (x) => '${x.round()}%',
      slider: CommittedSlider(
        min: 40,
        max: 100,
        divisions: 12,
        value: v,
        enabled: enabled,
        onCommit: (x) => n.setFloatingLyricsWidthPercent(x.round()),
      ),
      onAdjust: (x) => n.setFloatingLyricsWidthPercent(x.round()),
    );
  }

  Widget _floatingLyricsXSlider(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final enabled = s?.floatingLyricsEnabled ?? false;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenW = MediaQuery.of(context).size.width * dpr;
    final widthPercent = (s?.floatingLyricsWidthPercent ?? 92) / 100;
    final overlayW =
        (screenW * widthPercent).clamp(180.0 * dpr, screenW - 12 * dpr);
    final maxX = (screenW / 2 - overlayW / 2).clamp(0.0, double.infinity);
    double norm(double x) =>
        maxX <= 0 ? 0.0 : (x / maxX * 100).clamp(-100.0, 100.0);
    final v = norm((s?.floatingLyricsX ?? 0).toDouble());
    return _StepperSliderRow(
      enabled: enabled,
      readValue: () => norm((s?.floatingLyricsX ?? 0).toDouble()),
      step: 5,
      min: -100,
      max: 100,
      valueWidth: 44,
      format: (x) => x == 0 ? '0' : ('${x > 0 ? '+' : ''}${x.round()}'),
      slider: CommittedSlider(
        min: -100,
        max: 100,
        divisions: 40,
        value: v,
        enabled: enabled,
        onCommit: (val) {
          final px = (val / 100 * maxX).round();
          n.setFloatingLyricsPosition(px, s?.floatingLyricsY ?? 96);
        },
      ),
      onAdjust: (val) {
        final px = (val / 100 * maxX).round();
        n.setFloatingLyricsPosition(px, s?.floatingLyricsY ?? 96);
      },
    );
  }

  Widget _floatingLyricsYSlider(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final enabled = s?.floatingLyricsEnabled ?? false;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenH = MediaQuery.of(context).size.height * dpr;
    final statusBar = MediaQuery.of(context).padding.top * dpr;
    final overlayH = 150.0 * dpr;
    final minY = -statusBar;
    final maxY = (screenH - overlayH).clamp(0.0, double.infinity);
    double norm(double y) =>
        maxY <= minY ? 0.0 : ((y - minY) / (maxY - minY) * 100).clamp(0.0, 100.0);
    final v = norm((s?.floatingLyricsY ?? 96).toDouble());
    return _StepperSliderRow(
      enabled: enabled,
      readValue: () => norm((s?.floatingLyricsY ?? 96).toDouble()),
      step: 5,
      min: 0,
      max: 100,
      format: (x) => '${x.round()}',
      slider: CommittedSlider(
        min: 0,
        max: 100,
        divisions: 40,
        value: v,
        enabled: enabled,
        onCommit: (val) {
          final px = (minY + val / 100 * (maxY - minY)).round();
          n.setFloatingLyricsPosition(s?.floatingLyricsX ?? 0, px);
        },
      ),
      onAdjust: (val) {
        final px = (minY + val / 100 * (maxY - minY)).round();
        n.setFloatingLyricsPosition(s?.floatingLyricsX ?? 0, px);
      },
    );
  }

  Future<void> _resetFloatingLyricsPosition() async {
    await FloatingLyricsController.resetPosition();
    await ref
        .read(settingsProvider.notifier)
        .setFloatingLyricsPosition(0, 96);
  }

  Widget _shareValidityTile(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final minutes = (s?.shareLinkValidityMinutes ?? 120).clamp(5, 1440).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tile(
          context,
          icon: Icons.timer_outlined,
          title: tr('分享链接有效时长'),
          subtitle: tr('分享链接过期后即被服务端丢弃，他人将无法打开（5 分钟 ~ 24 小时）'),
          trailing: Text(
            _shareValidityLabel(minutes),
            style: TextStyle(
              fontSize: 12.5,
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: CommittedSlider(
            min: 5,
            max: 1440,
            divisions: 287,
            value: minutes.toDouble(),
            onCommit: (v) => n.setShareLinkValidityMinutes(v.round()),
          ),
        ),
      ],
    );
  }

  String _shareValidityLabel(int v) =>
      v % 60 == 0 ? tr('{h} 小时', {'h': v ~/ 60}) : tr('{m} 分钟', {'m': v});

  String _failureBehaviorLabel(String v) => switch (v) {
    'autoswitch' => tr('自动换源'),
    'pause' => tr('暂停播放'),
    _ => tr('跳到下一首'),
  };

  String _sharePlaybackFailureBehaviorLabel(String v) =>
      v == 'pause' ? tr('暂停播放') : tr('替换播放');

  String _qualityFallbackLabel(String v) => switch (v) {
    'pause' => tr('暂停'),
    'higher' => tr('播放更高音质'),
    _ => tr('播放更低音质'),
  };

  String _outputDeviceLabel(int id) => id == -1 ? tr('默认设备') : '设备 #$id';

  String? _deviceFormatSubtitle(AudioOutputDevice? d) {
    if (d == null) return null;
    final rates = d.sampleRates
        .map((r) => r >= 1000 ? '${(r / 1000).toStringAsFixed(1)}kHz' : '$r Hz')
        .join('/');
    final chans = d.channelCounts
        .map(
          (c) => c == 1
              ? tr('单声道')
              : c == 2
              ? tr('立体声')
              : '${c}ch',
        )
        .join('/');
    final parts = <String>[
      if (rates.isNotEmpty) tr('采样率 {rates}', {'rates': rates}),
      if (chans.isNotEmpty) chans,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _fileNameStyleLabel(String v) => switch (v) {
    'title-artist' => tr('标题 - 歌手'),
    'title-artist-album' => tr('标题 - 歌手 - 专辑'),
    _ => tr('歌手 - 标题'),
  };

  String _uiScaleLabel(int index) => switch (index) {
        0 => tr('小'),
        2 => tr('大'),
        3 => tr('特大'),
        _ => tr('标准'),
      };
}
