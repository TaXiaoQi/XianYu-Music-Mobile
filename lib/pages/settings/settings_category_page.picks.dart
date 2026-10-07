part of 'settings_category_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _SettingsCategoryPagePicks on _SettingsCategoryPageState {
  // ============ 各类选择器 ============

  Future<void> _pickNavBarPosition(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.navBarPosition ?? NavBarPosition.bottom;
    final choice = await showModernChoiceSheet<NavBarPosition>(
      context: context,
      title: tr('导航栏位置'),
      options:   [
        ModernChoiceOption(label: tr('底部导航'), value: NavBarPosition.bottom, icon: Icons.subtitles_outlined),
        ModernChoiceOption(label: tr('侧边悬浮'), value: NavBarPosition.side, icon: Icons.navigation_outlined),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setNavBarPosition(choice);
    }
  }

  Future<void> _pickPageTransitionStyle(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.pageTransitionStyle ?? PageTransitionStyle.cover;
    final choice = await showModernChoiceSheet<PageTransitionStyle>(
      context: context,
      title: tr('竖屏切换动画'),
      options:   [
        ModernChoiceOption(label: tr('覆盖'), value: PageTransitionStyle.cover, icon: Icons.layers_outlined),
        ModernChoiceOption(label: tr('平滑'), value: PageTransitionStyle.smooth, icon: Icons.sort_outlined),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setPageTransitionStyle(choice);
    }
  }

  Future<void> _pickSideBarExpandDirection(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.sideBarExpandDirection ?? SideBarExpandDirection.down;
    final choice = await showModernChoiceSheet<SideBarExpandDirection>(
      context: context,
      title: tr('侧边栏展开方向'),
      options:   [
        ModernChoiceOption(label: tr('向下展开'), value: SideBarExpandDirection.down, icon: Icons.arrow_downward),
        ModernChoiceOption(label: tr('向上展开'), value: SideBarExpandDirection.up, icon: Icons.arrow_upward),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setSideBarExpandDirection(choice);
    }
  }

  Future<void> _pickLanguage(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.language ?? AppLanguage.system;
    final choice = await showModernChoiceSheet<AppLanguage>(
      context: context,
      title: tr('语言设置'),
      options:   [
        ModernChoiceOption(label: tr('跟随系统'), value: AppLanguage.system),
        ModernChoiceOption(label: tr('简体中文'), value: AppLanguage.zhCN),
        ModernChoiceOption(label: tr('繁體中文'), value: AppLanguage.zhTW),
        ModernChoiceOption(label: 'English', value: AppLanguage.en),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (context.mounted) {
        await ref
            .read(settingsProvider.notifier)
            .setLanguage(choice);
      }
    }
  }

  Future<void> _pickHaptic(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.hapticStrength ?? 1;
    final choice = await showModernChoiceSheet<int>(
      context: context,
      title: tr('触觉反馈强度'),
      options:   [
        ModernChoiceOption(label: tr('轻'), value: 0),
        ModernChoiceOption(label: tr('正常'), value: 1),
        ModernChoiceOption(label: tr('重'), value: 2),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setHapticStrength(choice);
    }
  }

  Future<void> _pickUpdateCheckMode(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.updateCheckMode ?? 'startup';
    final choice = await showModernChoiceSheet<String>(
      context: context,
      title: tr('检测更新模式'),
      options: [
        ModernChoiceOption(label: tr('启动检测'), value: 'startup'),
        ModernChoiceOption(label: tr('从不检测'), value: 'never'),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setUpdateCheckMode(choice);
    }
  }

  Future<void> _pickListSize(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.listSize ?? ListSize.medium;
    final choice = await showModernChoiceSheet<ListSize>(
      context: context,
      title: tr('列表项尺寸'),
      options:   [
        ModernChoiceOption(label: tr('最小'), value: ListSize.compact, subtitle: tr('紧凑布局，一行多看')),
        ModernChoiceOption(label: tr('中等'), value: ListSize.medium, subtitle: tr('默认标准高度')),
        ModernChoiceOption(label: tr('最大'), value: ListSize.large, subtitle: tr('大图标大字号')),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setListSize(choice);
    }
  }

  Future<void> _pickFontSize(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.fontSize ?? AppFontSize.system;
    final choice = await showModernChoiceSheet<AppFontSize>(
      context: context,
      title: tr('字体大小'),
      options: [
        ModernChoiceOption(
          label: tr('跟随系统'),
          subtitle: tr('字号随系统字体缩放实时变化'),
          value: AppFontSize.system,
        ),
        ModernChoiceOption(
          label: tr('小'),
          subtitle: tr('紧凑排版，同屏更多文字'),
          value: AppFontSize.small,
        ),
        ModernChoiceOption(
          label: tr('标准'),
          subtitle: tr('应用设定的默认字号'),
          value: AppFontSize.standard,
        ),
        ModernChoiceOption(
          label: tr('大'),
          subtitle: tr('放大 10%，更易阅读'),
          value: AppFontSize.large,
        ),
        ModernChoiceOption(
          label: tr('更大'),
          subtitle: tr('放大 25%，清晰醒目'),
          value: AppFontSize.larger,
        ),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setFontSize(choice);
    }
  }

  Future<void> _pickUiScale(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.uiScaleIndex ?? 1;
    final choice = await showModernChoiceSheet<int>(
      context: context,
      title: tr('样式大小'),
      options: [
        ModernChoiceOption(
          label: tr('小'),
          subtitle: tr('整体缩小 15%，同屏内容更多'),
          value: 0,
        ),
        ModernChoiceOption(
          label: tr('标准'),
          subtitle: tr('应用设定的默认大小'),
          value: 1,
        ),
        ModernChoiceOption(
          label: tr('大'),
          subtitle: tr('整体放大 15%，更易点按'),
          value: 2,
        ),
        ModernChoiceOption(
          label: tr('特大'),
          subtitle: tr('整体放大 30%，清晰醒目'),
          value: 3,
        ),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setUiScaleIndex(choice);
    }
  }

  Future<void> _pickPlayerStyle(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.playerStyle ?? PlayerStyle.traditional;
    final choice = await showModernChoiceSheet<PlayerStyle>(
      context: context,
      title: tr('正在播放页样式'),
      options:   [
        ModernChoiceOption(label: tr('高级模式'), value: PlayerStyle.advanced, subtitle: tr('含唱片光芒、沉浸流光背景与动感频谱')),
        ModernChoiceOption(label: tr('传统模式'), value: PlayerStyle.traditional, subtitle: tr('经典平铺高斯模糊样式')),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setPlayerStyle(choice);
    }
  }

  Future<void> _pickFrostedGlassLevel(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.frostedGlassLevel ?? FrostedGlassLevel.medium;
    final choice = await showModernChoiceSheet<FrostedGlassLevel>(
      context: context,
      title: tr('毛玻璃效果'),
      options:   [
        ModernChoiceOption(
            label: tr('最强'),
            subtitle: tr('磨砂感最深，背景最模糊'),
            value: FrostedGlassLevel.strongest,
            icon: Icons.blur_on_outlined),
        ModernChoiceOption(
            label: tr('中等'),
            subtitle: tr('收敛模糊，兼顾辨识度'),
            value: FrostedGlassLevel.medium,
            icon: Icons.blur_circular_outlined),
        ModernChoiceOption(
            label: tr('轻度'),
            subtitle: tr('轻微磨砂，最通透'),
            value: FrostedGlassLevel.light,
            icon: Icons.blur_off_outlined),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setFrostedGlassLevel(choice);
    }
  }

  Future<void> _pickLiquidGlassQuality(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.liquidGlassQuality ?? LiquidGlassQuality.medium;
    final choice = await showModernChoiceSheet<LiquidGlassQuality>(
      context: context,
      title: tr('液态玻璃效果'),
      options:   [
        ModernChoiceOption(
            label: tr('低 · 透亮'),
            subtitle: tr('轻透微磨，折射最明显'),
            value: LiquidGlassQuality.low,
            icon: Icons.battery_saver_outlined),
        ModernChoiceOption(
            label: tr('中 · 均衡'),
            subtitle: tr('轻模糊，默认观感'),
            value: LiquidGlassQuality.medium,
            icon: Icons.tune_outlined),
        ModernChoiceOption(
            label: tr('高 · 磨砂'),
            subtitle: tr('磨砂最重档，糊度上限'),
            value: LiquidGlassQuality.high,
            icon: Icons.blur_on),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setLiquidGlassQuality(choice);
    }
  }

  Future<void> _pickThemeMode(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.themeMode ?? ThemeModePreference.system;
    final choice = await showModernChoiceSheet<ThemeModePreference>(
      context: context,
      title: tr('外观模式'),
      options:   [
        ModernChoiceOption(label: tr('跟随系统'), value: ThemeModePreference.system, icon: Icons.brightness_auto),
        ModernChoiceOption(label: tr('浅色模式'), value: ThemeModePreference.light, icon: Icons.light_mode),
        ModernChoiceOption(label: tr('深色模式'), value: ThemeModePreference.dark, icon: Icons.dark_mode),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setThemeMode(choice);
    }
  }

  Future<void> _pickAccentColor(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.accentColor ?? 0xFFEC4141;
    final choice = await showSheetDialog<int>(
      context,
      (ctx) => _AccentColorSheet(current: cur),
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setAccentColor(choice);
    }
  }

  Future<void> _pickMvQuality(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    const options = ['480p', '720p', '1080p', 'uhd'];
    final cur = s?.onlineDefaultMvQuality ?? '720p';
    final pick = await showModernChoiceSheet<String>(
      context: context,
      title: tr('MV 默认画质'),
      options: [
        for (final q in options)
          ModernChoiceOption(
            label: _mvQualityKeyLabel(q),
            subtitle: _mvQualityDescLabel(q),
            value: q,
          ),
      ],
      currentValue: cur,
    );
    if (pick != null) {
      await ref
          .read(settingsProvider.notifier)
          .setOnlineDefaultMvQuality(pick);
    }
  }

  Future<void> _pickDownloadMvQuality(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    const options = ['480p', '720p', '1080p', 'uhd'];
    final cur = s?.downloadMvQuality ?? '720p';
    final pick = await showModernChoiceSheet<String>(
      context: context,
      title: tr('MV 下载画质'),
      options: [
        for (final q in options)
          ModernChoiceOption(
            label: _mvQualityKeyLabel(q),
            subtitle: _mvQualityDescLabel(q),
            value: q,
          ),
      ],
      currentValue: cur,
    );
    if (pick != null) {
      await ref
          .read(settingsProvider.notifier)
          .setDownloadMvQuality(pick);
    }
  }

  Future<void> _pickQuality(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s, {
    required bool isOnline,
  }) async {
    final cur = isOnline
        ? s?.onlineDefaultQuality ?? '320k'
        : s?.downloadQuality ?? '320k';
    final choice = await showSheetDialog<_Choice>(
      context,
      (dialogContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(dialogContext).size.height * 0.6,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in   [
                _Choice(tr('低清'), 'mgg', subtitle: tr('96k · 极速云端试听')),
                _Choice(tr('普通'), '128k', subtitle: '128k'),
                _Choice(tr('中等'), '192k', subtitle: '192k'),
                _Choice('HQ', '320k', subtitle: tr('高品质 · 320k')),
                _Choice('SQ', 'flac', subtitle: tr('无损 · FLAC')),
                _Choice('Hi-Res', 'flac24bit', subtitle: tr('高解析 · FLAC 24bit')),
                _Choice(tr('高解析度'), 'hires', subtitle: tr('Hi-Res 高解析无损')),
                _Choice(tr('黑胶'), 'vinyl', subtitle: tr('黑胶音色 · 无损')),
                _Choice(tr('杜比全景声'), 'dolby', subtitle: tr('Dolby Atmos 沉浸环绕')),
                _Choice(tr('臻品音质'), 'atmos', subtitle: tr('臻品立体空间声场')),
                _Choice(tr('臻品全景声'), 'atmos_plus', subtitle: tr('臻品全空间沉浸声')),
                _Choice(tr('臻品母带'), 'master', subtitle: tr('母带级无损臻品')),
              ])
                ListTile(
                  title: Text(c.label),
                  subtitle: c.subtitle == null ? null : Text(c.subtitle!),
                  trailing: c.value == cur
                      ? Icon(Icons.check,
                          color: Theme.of(dialogContext).colorScheme.primary)
                      : null,
                  selected: c.value == cur,
                  onTap: () => Navigator.pop(dialogContext, c),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice != null) {
      final n = ref.read(settingsProvider.notifier);
      if (isOnline) {
        await n.setOnlineDefaultQuality(choice.value as String);
      } else {
        await n.setDownloadQuality(choice.value as String);
      }
    }
  }

  Future<void> _pickFailureBehavior(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.onlineFailureBehavior ?? 'stop';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
          [
          _Choice(tr('自动换源'), 'autoswitch'),
          _Choice(tr('停止播放'), 'stop'),
          _Choice(tr('跳到下一首'), 'skip'),
        ],
        cur,
        labelOf: (v) => _failureBehaviorLabel(v as String),
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setOnlineFailureBehavior(choice.value as String);
    }
  }

  Future<void> _pickShareFailureBehavior(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.sharePlaybackFailureBehavior ?? 'pause';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
          [
          _Choice(tr('暂停播放'), 'pause', subtitle: tr('分享歌曲起播失败时停止并显示错误')),
          _Choice(tr('替换播放'), 'replace', subtitle: tr('按来源信息走插件换源重播同一首歌')),
        ],
        cur,
        labelOf: (v) => _sharePlaybackFailureBehaviorLabel(v as String),
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setSharePlaybackFailureBehavior(choice.value as String);
    }
  }

  /// 曲间交叉淡入淡出的时长（秒）。
  Future<void> _pickCrossfadeSeconds(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) async {
    final cur = s?.crossfadeSeconds ?? 5;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        [
          for (final sec in const [2, 3, 5, 8, 12])
            _Choice('$sec s', sec,
                subtitle: sec == 5 ? tr('默认') : null),
        ],
        cur,
        labelOf: (v) => '${v as int} s',
      ),
    );
    if (choice != null) {
      await n.setCrossfadeSeconds(choice.value as int);
    }
  }

  /// 跳过静音：静音判定阈值档位。
  Future<void> _pickSkipSilenceThreshold(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) async {
    final cur = (s?.skipSilenceThresholdDb ?? -45.0).round();
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        [
          _Choice('-35 dB', -35, subtitle: tr('更灵敏：较安静的段落也会被剪')),
          _Choice('-40 dB', -40),
          _Choice('-45 dB', -45, subtitle: tr('默认：适合大多数歌曲')),
          _Choice('-50 dB', -50),
          _Choice('-55 dB', -55, subtitle: tr('更保守：只剪接近数字静音的段落')),
        ],
        cur,
        labelOf: (v) => '${v as int} dB',
      ),
    );
    if (choice != null) {
      await n.setSkipSilenceThresholdDb((choice.value as int).toDouble());
    }
  }

  /// 跳过静音：静音段保留时长。
  Future<void> _pickSkipSilenceKeep(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) async {
    final cur = s?.skipSilenceKeepMs ?? 500;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        [
          _Choice('200 ms', 200, subtitle: tr('激进：长静音几乎只剩一小截')),
          _Choice('500 ms', 500, subtitle: tr('默认')),
          _Choice('1000 ms', 1000),
          _Choice('2000 ms', 2000, subtitle: tr('保守：只剪很长的静音段')),
        ],
        cur,
        labelOf: (v) => '${v as int} ms',
      ),
    );
    if (choice != null) {
      await n.setSkipSilenceKeepMs(choice.value as int);
    }
  }

  Future<void> _pickQualityFallback(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.onlineQualityFallbackBehavior ?? 'lower';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
          [
          _Choice(tr('暂停'), 'pause'),
          _Choice(tr('播放更低音质'), 'lower'),
          _Choice(tr('播放更高音质'), 'higher'),
        ],
        cur,
        labelOf: (v) => _qualityFallbackLabel(v as String),
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setOnlineQualityFallbackBehavior(choice.value as String);
    }
  }

  Future<void> _pickOutputDevice(BuildContext context, WidgetRef ref) async {
    final scheme = Theme.of(context).colorScheme;
    final supported = defaultTargetPlatform == TargetPlatform.android;
    final devices = await listOutputDevices();
    if (!context.mounted) return;
    final current =
        ref.read(settingsProvider).valueOrNull?.usbExclusiveDeviceId ?? -1;
    final byId = {for (final d in devices) d.id: d};

    final choice = await showSheetDialog<int>(context, (dialogContext) {
      final list = <(String, int)>[
        (tr('系统默认设备'), -1),
        for (final d in devices) (d.displayName, d.id),
      ];
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 2),
              child: Text(
                tr('输出设备'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (!supported || devices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  !supported ? tr('仅 Android 支持设备枚举') : tr('未检测到可用的输出设备'),
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (label, id) in list)
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                          selected: current == id,
                          title: Text(label),
                          subtitle: id == -1
                              ? null
                              : Text(
                                  _deviceFormatSubtitle(byId[id]) ?? '',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                          trailing: current == id
                              ? Icon(Icons.check, color: scheme.primary, size: 20)
                              : null,
                          onTap: () => Navigator.pop(dialogContext, id),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    });
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setUsbExclusiveDeviceId(choice);
    }
  }

  Future<void> _pickConcurrency(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = (s?.downloadConcurrency ?? 3).clamp(1, 5);
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [
          _Choice('1', 1),
          _Choice('2', 2),
          _Choice('3', 3),
          _Choice('4', 4),
          _Choice('5', 5),
        ],
        cur,
        labelOf: (v) => '${v as int}',
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setDownloadConcurrency(choice.value as int);
    }
  }

  Future<void> _pickFileNameStyle(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.downloadFileNameStyle ?? 'artist-title';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
          [
          _Choice(tr('歌手 - 标题'), 'artist-title'),
          _Choice(tr('标题 - 歌手'), 'title-artist'),
          _Choice(tr('标题 - 歌手 - 专辑'), 'title-artist-album'),
        ],
        cur,
        labelOf: (v) => _fileNameStyleLabel(v as String),
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setDownloadFileNameStyle(choice.value as String);
    }
  }

  Future<void> _pickLyricsFormat(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.downloadLyricsFormat ?? 'lrc';
    final choice = await showModernChoiceSheet<String>(
      context: context,
      title: tr('歌词格式'),
      options: [
        ModernChoiceOption(
          label: 'LRC',
          value: 'lrc',
          subtitle: tr('带时间标签的歌词文件，支持同步显示'),
        ),
        ModernChoiceOption(
          label: 'TXT',
          value: 'txt',
          subtitle: tr('纯文本歌词，不带时间标签'),
        ),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setDownloadLyricsFormat(choice);
    }
  }

  Future<void> _pickLyricsStyle(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.downloadLyricsStyle ?? 'word-by-word';
    final choice = await showModernChoiceSheet<String>(
      context: context,
      title: tr('歌词风格'),
      options: [
        ModernChoiceOption(
          label: tr('内置逐字'),
          value: 'word-by-word',
          subtitle: tr('优先下载逐字歌词（无逐字时回退到逐行）'),
        ),
        ModernChoiceOption(
          label: tr('逐行'),
          value: 'line-by-line',
          subtitle: tr('仅下载标准逐行歌词'),
        ),
      ],
      currentValue: cur,
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setDownloadLyricsStyle(choice);
    }
  }

  Future<void> _pickDownloadPath(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final curPath = s?.downloadPath ?? '';
    final isDefault = curPath.isEmpty;

    final action = await showSheetDialog<String?>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('下载路径'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isDefault
                  ? tr('当前使用默认下载目录')
                  : tr('当前路径：{path}', {'path': curPath}),
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.folder_open_outlined, size: 20),
              label: Text(tr('选择系统文件夹')),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () => Navigator.pop(ctx, 'pick'),
            ),
            if (!isDefault) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.restore_outlined, size: 20),
                label: Text(tr('恢复默认下载目录')),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => Navigator.pop(ctx, 'default'),
              ),
            ],
          ],
        ),
      ),
    );

    if (action == null) return;

    if (action == 'default') {
      await ref.read(settingsProvider.notifier).setDownloadPath('');
      if (context.mounted) {
        showXianYuToast(context, tr('已恢复默认下载目录'));
      }
      return;
    }

    if (action == 'pick') {
      try {
        final selectedDir = await FilePicker.getDirectoryPath();
        if (selectedDir != null && selectedDir.trim().isNotEmpty) {
          final path = selectedDir.trim();
          if (path.startsWith('content://')) {
            if (context.mounted) {
              showXianYuToast(
                context,
                tr('该位置无法直接访问，请选择本地存储文件夹'),
              );
            }
            return;
          }
          await ref.read(settingsProvider.notifier).setDownloadPath(path);
          if (Platform.isAndroid) {
            var manage = await Permission.manageExternalStorage.request();
            if (manage.isPermanentlyDenied) await openAppSettings();
            await Permission.notification.request();
            if (!manage.isGranted && context.mounted) {
              showXianYuToast(
                  context, tr('未授予所有文件访问权限，将尝试兼容模式写入'));
            }
          }
          if (context.mounted) {
            showXianYuToast(context, tr('下载路径已更新'));
          }
        }
      } catch (e) {
        if (context.mounted) {
          showXianYuToast(context, tr('选择目录失败：{e}', {'e': e}));
        }
      }
    }
  }
}
