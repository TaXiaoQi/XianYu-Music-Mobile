import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../src/core/settings.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/audio/audio_devices.dart';

/// 设置分类。对应桌面版导航分类中在移动端可用的分组。
enum SettingsCategory {
  general,
  sources,
  appearance,
  playback,
  download,
  library,
  toolbox,
  advanced;

  static SettingsCategory fromPath(String p) => switch (p) {
        'sources' => SettingsCategory.sources,
        'appearance' => SettingsCategory.appearance,
        'playback' => SettingsCategory.playback,
        'download' => SettingsCategory.download,
        'library' => SettingsCategory.library,
        'toolbox' => SettingsCategory.toolbox,
        'advanced' => SettingsCategory.advanced,
        _ => SettingsCategory.general,
      };

  String get title => switch (this) {
        SettingsCategory.general => '常规',
        SettingsCategory.sources => '音源',
        SettingsCategory.appearance => '外观',
        SettingsCategory.playback => '播放',
        SettingsCategory.download => '下载',
        SettingsCategory.library => '音乐库',
        SettingsCategory.toolbox => '工具箱',
        SettingsCategory.advanced => '高级设置',
      };
}

/// 设置页背景底色（浅白，与纯白卡片区分）。
///
/// 亮色：淡灰白 #F4F4F6，暗色：#222。
Color settingsSurfaceBg(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF222222) : const Color(0xFFF4F4F6);
}

/// 设置卡片纯白底色。
Color settingsCardColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF303030) : const Color(0xFFFFFFFF);
}

/// 设置详情页：浅白底 + 纯白卡片，展示单个分类下的全部设置项。
class SettingsCategoryPage extends ConsumerStatefulWidget {
  const SettingsCategoryPage({super.key, required this.category});

  final SettingsCategory category;

  @override
  ConsumerState<SettingsCategoryPage> createState() =>
      _SettingsCategoryPageState();
}

class _SettingsCategoryPageState extends ConsumerState<SettingsCategoryPage> {
  SettingsCategory get category => widget.category;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final exclusivePlaying = ref.watch(playerProvider).usbExclusive;

    return Scaffold(
      backgroundColor: settingsSurfaceBg(context),
      appBar: AppBar(title: Text(category.title)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          24 + MediaQuery.of(context).padding.bottom,
        ),
        children: _buildItems(
          context,
          ref,
          category,
          settings,
          notifier,
          exclusivePlaying,
        ),
      ),
    );
  }

  List<Widget> _buildItems(
    BuildContext context,
    WidgetRef ref,
    SettingsCategory category,
    AppSettings? settings,
    SettingsNotifier notifier,
    bool exclusivePlaying,
  ) {
    switch (category) {
      case SettingsCategory.general:
        return _general(context, ref, settings, notifier);
      case SettingsCategory.sources:
        return _sources(context, ref, settings, notifier);
      case SettingsCategory.appearance:
        return _appearance(context, ref, settings, notifier);
      case SettingsCategory.playback:
        return _playback(context, ref, settings, notifier, exclusivePlaying);
      case SettingsCategory.download:
        return _download(context, ref, settings, notifier);
      case SettingsCategory.library:
        return _library(context, ref, settings, notifier);
      case SettingsCategory.toolbox:
        return _toolbox(context);
      case SettingsCategory.advanced:
        return _advanced(context, settings, notifier);
    }
  }

  // ---- 常规 ----
  List<Widget> _general(BuildContext context, WidgetRef ref, AppSettings? s,
      SettingsNotifier n) {
    return [
      _sectionHeader(context, '语言与导航'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.language_outlined,
            title: '语言',
            trailing: Text(_languageLabel(s?.language ?? AppLanguage.system)),
            onTap: () => _pickLanguage(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.navigation_outlined,
            title: '导航栏位置',
            trailing: Text(switch (s?.navBarPosition ?? NavBarPosition.bottom) {
              NavBarPosition.bottom => '底部导航',
              NavBarPosition.side => '侧边悬浮',
            }),
            onTap: () => _pickNavBarPosition(context, ref, s),
          ),
          if ((s?.navBarPosition ?? NavBarPosition.bottom) ==
              NavBarPosition.bottom)
            _switchTile(
              context,
              icon: Icons.subtitles_outlined,
              title: '悬浮式底栏',
              value: s?.floatingNavBar ?? true,
              onChanged: (v) => n.setFloatingNavBar(v),
            ),
          if ((s?.navBarPosition ?? NavBarPosition.side) == NavBarPosition.side)
            _tile(
              context,
              icon: Icons.swap_vert_outlined,
              title: '侧边栏展开方向',
              trailing:
                  Text(switch (s?.sideBarExpandDirection ??
                      SideBarExpandDirection.down) {
                SideBarExpandDirection.down => '向下展开',
                SideBarExpandDirection.up => '向上展开',
              }),
              onTap: () => _pickSideBarExpandDirection(context, ref, s),
            ),
        ],
      ),
    ];
  }

  // ---- 音源 ----
  List<Widget> _sources(
      BuildContext context, WidgetRef ref, AppSettings? s, SettingsNotifier n) {
    return [
      _sectionHeader(context, '在线音质'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.high_quality_outlined,
            title: '在线默认音质',
            trailing: Text(s?.onlineDefaultQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, s, isOnline: true),
          ),
          _tile(
            context,
            icon: Icons.play_disabled_outlined,
            title: '起播失败行为',
            subtitle: '在线音源完全无法播放时的处理方式',
            trailing:
                Text(_failureBehaviorLabel(s?.onlineFailureBehavior ?? 'skip')),
            onTap: () => _pickFailureBehavior(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.vertical_align_bottom_outlined,
            title: '音质回退行为',
            subtitle: '默认音质播放失败时如何切换音质档位',
            trailing: Text(
                _qualityFallbackLabel(s?.onlineQualityFallbackBehavior ?? 'lower')),
            onTap: () => _pickQualityFallback(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.swap_horiz_outlined,
            title: '播放失败自动换源',
            subtitle: '在线播放失败时自动在其他落雪音源搜索并播放同一首歌',
            value: s?.autoSwitchSourceOnFailure ?? false,
            onChanged: (v) => n.setAutoSwitchSourceOnFailure(v),
          ),
        ],
      ),
      _sectionHeader(context, '输出'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.speaker_outlined,
            title: '输出设备',
            subtitle: 'USB 独占 / DSD 直出到所选设备，可查看设备支持格式',
            trailing:
                Text(_outputDeviceLabel(s?.usbExclusiveDeviceId ?? -1)),
            onTap: () => _pickOutputDevice(context, ref),
          ),
          _switchTile(
            context,
            icon: Icons.usb_outlined,
            title: 'USB 独占输出 (Bit-perfect)',
            subtitle:
                '绕过系统混音器直达 USB DAC，仅本地音乐生效；均衡器与音效走原生 DSP 管线，无 USB DAC 或启动失败时自动回退',
            value: s?.usbExclusiveOutput ?? false,
            onChanged: (v) => n.setUsbExclusiveOutput(v),
          ),
          _switchTile(
            context,
            icon: Icons.graphic_eq_outlined,
            title: 'DSD 原生直出',
            subtitle:
                'dsf/dff 本地文件按 DoP 打包直送 DSD-DAC，绕过解码与所有音效；需 USB DSD-DAC 支持，失败自动回退普通播放，直出时音量与均衡器自动锁定',
            value: s?.dsdNativePassthrough ?? false,
            onChanged: (v) => n.setDsdNativePassthrough(v),
          ),
        ],
      ),
    ];
  }

  // ---- 外观 ----
  List<Widget> _appearance(BuildContext context, WidgetRef ref, AppSettings? s,
      SettingsNotifier n) {
    return [
      _sectionHeader(context, '主题'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.palette_outlined,
            title: '主题模式',
            trailing: _themeLabel(s),
            onTap: () => _pickThemeMode(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.color_lens_outlined,
            title: '主题色',
            trailing: _ColorDot(color: Color(s?.accentColor ?? 0xFFEC4141)),
            onTap: () => _pickAccentColor(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.blur_on_outlined,
            title: '晶莹液态玻璃 (Liquid Glass)',
            value: s?.liquidGlass ?? true,
            onChanged: (v) => n.setLiquidGlass(v),
          ),
        ],
      ),
      _sectionHeader(context, '歌词显示'),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.translate_outlined,
            title: '显示翻译',
            value: s?.showLyricsTranslation ?? true,
            onChanged: (v) => n.setShowLyricsTranslation(v),
          ),
          _switchTile(
            context,
            icon: Icons.spellcheck_outlined,
            title: '逐字动效',
            value: s?.enableWordEffect ?? true,
            onChanged: (v) => n.setEnableWordEffect(v),
          ),
        ],
      ),
    ];
  }

  // ---- 播放 ----
  List<Widget> _playback(BuildContext context, WidgetRef ref, AppSettings? s,
      SettingsNotifier n, bool exclusivePlaying) {
    return [
      _sectionHeader(context, '播放'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.volume_up_outlined,
            title: exclusivePlaying ? '音量（直出已锁定）' : '音量',
            trailing: _volumeSlider(s, n, locked: exclusivePlaying),
            subtitle:
                exclusivePlaying ? 'Bit-perfect / DSD 直出中，音量由 DAC 控制' : null,
          ),
          _switchTile(
            context,
            icon: Icons.mouse_outlined,
            title: '双击播放歌曲',
            subtitle: '开启后双击歌曲播放，关闭后单击播放',
            value: (s?.songClickAction ?? 'single') == 'double',
            onChanged: (v) => n.setSongClickAction(v ? 'double' : 'single'),
          ),
        ],
      ),
      _sectionHeader(context, '音量平衡 (ReplayGain)'),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.balance_outlined,
            title: '音量平衡',
            subtitle: '按歌曲内置的 ReplayGain 标签调整增益，让不同歌曲响度一致；无标签的歌曲保持原音量',
            value: s?.volumeBalanceEnabled ?? false,
            onChanged: (v) => n.setVolumeBalanceEnabled(v),
          ),
          if (s?.volumeBalanceEnabled ?? false) ...[
            _tile(
              context,
              icon: Icons.tune_outlined,
              title: '整体增益偏移',
              trailing: _gainOffsetSlider(s, n),
            ),
            _switchTile(
              context,
              icon: Icons.shield_outlined,
              title: '防削波破音保护',
              subtitle: '增益可能超出 0 dB 极限时自动压低；无峰值标签的歌曲不提升音量',
              value: s?.volumeBalancePreventClipping ?? true,
              onChanged: (v) => n.setVolumeBalancePreventClipping(v),
            ),
          ],
        ],
      ),
    ];
  }

  // ---- 下载 ----
  List<Widget> _download(BuildContext context, WidgetRef ref, AppSettings? s,
      SettingsNotifier n) {
    return [
      _sectionHeader(context, '下载'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.folder_outlined,
            title: '下载路径',
            trailing: Text(
              s?.downloadPath == null || s!.downloadPath.isEmpty ? '默认' : '自定义',
            ),
            onTap: () => _pickDownloadPath(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.download_outlined,
            title: '下载音质',
            trailing: Text(s?.downloadQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, s, isOnline: false),
          ),
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: '同时下载歌词',
            value: s?.downloadLyrics ?? true,
            onChanged: (v) => n.setDownloadLyrics(v),
          ),
          _tile(
            context,
            icon: Icons.speed_outlined,
            title: '批量并发数',
            trailing: Text('${s?.downloadConcurrency ?? 3}'),
            onTap: () => _pickConcurrency(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.label_outline,
            title: '文件名样式',
            trailing: Text(
                _fileNameStyleLabel(s?.downloadFileNameStyle ?? 'artist-title')),
            onTap: () => _pickFileNameStyle(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.file_copy_outlined,
            title: '覆盖同名文件',
            subtitle: '关闭时同名文件自动追加序号，避免覆盖',
            value: s?.overwriteExisting ?? false,
            onChanged: (v) => n.setOverwriteExisting(v),
          ),
          _tile(
            context,
            icon: Icons.download_done_outlined,
            title: '下载管理',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/download'),
          ),
        ],
      ),
      _sectionHeader(context, '下载后嵌入'),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.info_outline,
            title: '嵌入元数据',
            value: s?.embedDownloadMetadata ?? true,
            onChanged: (v) => n.setEmbedDownloadMetadata(v),
          ),
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: '嵌入歌词',
            subtitle: '需同时开启「同时下载歌词」',
            value: s?.embedDownloadLyrics ?? false,
            onChanged: (v) => n.setEmbedDownloadLyrics(v),
          ),
          _switchTile(
            context,
            icon: Icons.image_outlined,
            title: '嵌入封面',
            value: s?.embedDownloadCover ?? true,
            onChanged: (v) => n.setEmbedDownloadCover(v),
          ),
        ],
      ),
    ];
  }

  // ---- 音乐库 ----
  List<Widget> _library(BuildContext context, WidgetRef ref, AppSettings? s,
      SettingsNotifier n) {
    return [
      _sectionHeader(context, '扫描'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.create_new_folder_outlined,
            title: '扫描文件夹',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/scan-folders'),
          ),
          _tile(
            context,
            icon: Icons.timer_outlined,
            title: '排除短音频（秒）',
            trailing: Text('${s?.libraryMinDurationSeconds ?? 0}'),
            onTap: () => _pickMinDuration(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.verified_outlined,
            title: '显示音质标识',
            value: s?.showQualityBadges ?? true,
            onChanged: (v) => n.setShowQualityBadges(v),
          ),
          _tile(
            context,
            icon: Icons.cloud_outlined,
            title: '远程音乐库 (WebDAV)',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/remote-library'),
          ),
        ],
      ),
    ];
  }

  // ---- 工具箱 ----
  List<Widget> _toolbox(BuildContext context) {
    return [
      _sectionHeader(context, '数据与扩展'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.cloud_sync_outlined,
            title: '同步与备份',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/sync'),
          ),
          _tile(
            context,
            icon: Icons.extension_outlined,
            title: '插件扩展',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/plugin'),
          ),
          _tile(
            context,
            icon: Icons.queue_music_outlined,
            title: '我的歌单',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/playlists'),
          ),
          _tile(
            context,
            icon: Icons.wallpaper_outlined,
            title: '壁纸中心',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/wallpaper'),
          ),
          _tile(
            context,
            icon: Icons.lock_open_outlined,
            title: 'QMC 文件解密',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/qmc-decrypt'),
          ),
          _tile(
            context,
            icon: Icons.drive_file_rename_outline,
            title: '批量重命名',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/batch-rename'),
          ),
          _tile(
            context,
            icon: Icons.leaderboard_outlined,
            title: '听歌排行榜',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/leaderboard'),
          ),
        ],
      ),
    ];
  }

  // ---- 高级设置 ----
  List<Widget> _advanced(
      BuildContext context, AppSettings? s, SettingsNotifier n) {
    return [
      _sectionHeader(context, '系统'),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.screen_lock_rotation_outlined,
            title: '保持屏幕常亮',
            value: s?.keepScreenOn ?? true,
            onChanged: (v) => n.setKeepScreenOn(v),
          ),
        ],
      ),
      _sectionHeader(context, '导航'),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.arrow_back_outlined,
            title: '预测返回手势',
            subtitle: '开启后二级页面支持安卓系统预测返回动画（需 Android 13+ 手势导航）',
            value: s?.enablePredictiveBack ?? false,
            onChanged: (v) => n.setEnablePredictiveBack(v),
          ),
        ],
      ),
    ];
  }

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

  Widget _tile(BuildContext context,
      {required IconData icon,
      required String title,
      required Widget trailing,
      VoidCallback? onTap,
      String? subtitle}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      trailing: onTap == null
          ? trailing
          : Row(mainAxisSize: MainAxisSize.min, children: [
              trailing,
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 18, color: Theme.of(context).colorScheme.outline),
            ]),
      onTap: onTap,
    );
  }

  Widget _switchTile(BuildContext context,
      {required IconData icon,
      required String title,
      required bool value,
      required ValueChanged<bool> onChanged,
      String? subtitle}) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _themeLabel(AppSettings? s) {
    return Text(switch (s?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.system => '跟随系统',
      ThemeModePreference.light => '浅色',
      ThemeModePreference.dark => '深色',
    });
  }

  String _languageLabel(AppLanguage v) => switch (v) {
        AppLanguage.system => '跟随系统',
        AppLanguage.zhCN => '简体中文',
        AppLanguage.zhTW => '繁體中文',
        AppLanguage.en => 'English',
      };

  Widget _volumeSlider(AppSettings? s, SettingsNotifier n,
      {required bool locked}) {
    return SizedBox(
      width: 120,
      child: Slider(
        value: s?.volume ?? 1.0,
        onChanged: locked ? null : (v) => n.setVolume(v),
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
          child: Slider(
            min: -12,
            max: 6,
            divisions: 18,
            value: db.clamp(-12.0, 6.0),
            onChanged: (v) => n.setVolumeBalanceGainOffsetDb(v),
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

  String _failureBehaviorLabel(String v) => switch (v) {
        'stop' => '停止播放',
        _ => '跳到下一首',
      };

  String _qualityFallbackLabel(String v) => switch (v) {
        'pause' => '暂停',
        'higher' => '播放更高音质',
        _ => '播放更低音质',
      };

  String _outputDeviceLabel(int id) => id == -1 ? '默认设备' : '设备 #$id';

  String? _deviceFormatSubtitle(AudioOutputDevice? d) {
    if (d == null) return null;
    final rates = d.sampleRates
        .map((r) => r >= 1000 ? '${(r / 1000).toStringAsFixed(1)}kHz' : '$r Hz')
        .join('/');
    final chans = d.channelCounts
        .map((c) => c == 1
            ? '单声道'
            : c == 2
                ? '立体声'
                : '${c}ch')
        .join('/');
    final parts = <String>[
      if (rates.isNotEmpty) '采样率 $rates',
      if (chans.isNotEmpty) chans,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _fileNameStyleLabel(String v) => switch (v) {
        'title-artist' => '标题 - 歌手',
        'title-artist-album' => '标题 - 歌手 - 专辑',
        _ => '歌手 - 标题',
      };

  // ============ 各类选择器 ============

  Future<void> _pickNavBarPosition(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.navBarPosition ?? NavBarPosition.bottom;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('底部导航', NavBarPosition.bottom),
        _Choice('侧边悬浮', NavBarPosition.side),
      ], cur, labelOf: (v) => switch (v) {
        NavBarPosition.bottom => '底部导航',
        NavBarPosition.side => '侧边悬浮',
        _ => '底部导航',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setNavBarPosition(choice.value as NavBarPosition);
    }
  }

  Future<void> _pickSideBarExpandDirection(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.sideBarExpandDirection ?? SideBarExpandDirection.down;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('向下展开', SideBarExpandDirection.down),
        _Choice('向上展开', SideBarExpandDirection.up),
      ], cur, labelOf: (v) => switch (v) {
        SideBarExpandDirection.down => '向下展开',
        SideBarExpandDirection.up => '向上展开',
        _ => '向下展开',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setSideBarExpandDirection(choice.value as SideBarExpandDirection);
    }
  }

  Future<void> _pickLanguage(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.language ?? AppLanguage.system;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('跟随系统', AppLanguage.system),
        _Choice('简体中文', AppLanguage.zhCN),
        _Choice('繁體中文', AppLanguage.zhTW),
        _Choice('English', AppLanguage.en),
      ], cur, labelOf: (v) => _languageLabel(v as AppLanguage)),
    );
    if (choice != null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (context.mounted) {
        await ref
            .read(settingsProvider.notifier)
            .setLanguage(choice.value as AppLanguage);
      }
    }
  }

  Future<void> _pickThemeMode(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.themeMode ?? ThemeModePreference.system;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('跟随系统', ThemeModePreference.system),
        _Choice('浅色', ThemeModePreference.light),
        _Choice('深色', ThemeModePreference.dark),
      ], cur, labelOf: (v) => switch (v) {
        ThemeModePreference.system => '跟随系统',
        ThemeModePreference.light => '浅色',
        ThemeModePreference.dark => '深色',
        _ => '跟随系统',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setThemeMode(choice.value as ThemeModePreference);
    }
  }

  Future<void> _pickAccentColor(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.accentColor ?? 0xFFEC4141;
    const colors = [
      0xFFEC4141, 0xFFE64A2E, 0xFFFF8A00, 0xFF4CAF50, 0xFF2196F3,
      0xFF7C4DFF, 0xFF9C27B0, 0xFF795548, 0xFF607D8B, 0xFF000000,
    ];
    final choice = await showSheetDialog<int>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('主题色', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in colors)
                  InkWell(
                    onTap: () => Navigator.pop(context, c),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == cur
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: c == cur
                          ? const Icon(Icons.check,
                              color: Colors.white, size: 20)
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setAccentColor(choice);
    }
  }

  Future<void> _pickQuality(BuildContext context, WidgetRef ref,
      AppSettings? s, {required bool isOnline}) async {
    final cur = isOnline
        ? s?.onlineDefaultQuality ?? '320k'
        : s?.downloadQuality ?? '320k';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('低清 (96k)', 'mgg'),
        _Choice('普通', '128k'),
        _Choice('中等', '192k'),
        _Choice('HQ', '320k'),
        _Choice('SQ (无损)', 'flac'),
        _Choice('Hi-Res', 'flac24bit'),
        _Choice('高解析度', 'hires'),
        _Choice('黑胶', 'vinyl'),
        _Choice('杜比全景声', 'dolby'),
        _Choice('臻品音质', 'atmos'),
        _Choice('臻品全景声', 'atmos_plus'),
        _Choice('臻品母带', 'master'),
      ], cur, labelOf: (v) => v as String),
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
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.onlineFailureBehavior ?? 'skip';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('跳到下一首', 'skip'),
        _Choice('停止播放', 'stop'),
      ], cur, labelOf: (v) => _failureBehaviorLabel(v as String)),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setOnlineFailureBehavior(choice.value as String);
    }
  }

  Future<void> _pickQualityFallback(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.onlineQualityFallbackBehavior ?? 'lower';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('暂停', 'pause'),
        _Choice('播放更低音质', 'lower'),
        _Choice('播放更高音质', 'higher'),
      ], cur, labelOf: (v) => _qualityFallbackLabel(v as String)),
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

    final choice = await showSheetDialog<int>(
      context,
      (dialogContext) {
        final list = <(String, int)>[
          ('系统默认设备', -1),
          for (final d in devices) (d.displayName, d.id),
        ];
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
                child: Text('输出设备',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              if (!supported || devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    !supported
                        ? '仅 Android 支持设备枚举'
                        : '未检测到可用的输出设备',
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (label, id) in list)
                        ListTile(
                          dense: true,
                          selected: current == id,
                          title: Text(label),
                          subtitle: id == -1
                              ? null
                              : Text(_deviceFormatSubtitle(byId[id]) ?? '',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant)),
                          trailing: current == id
                              ? Icon(Icons.check,
                                  color: scheme.primary, size: 20)
                              : null,
                          onTap: () => Navigator.pop(dialogContext, id),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setUsbExclusiveDeviceId(choice);
    }
  }

  Future<void> _pickConcurrency(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = (s?.downloadConcurrency ?? 3).clamp(1, 5);
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('1', 1),
        _Choice('2', 2),
        _Choice('3', 3),
        _Choice('4', 4),
        _Choice('5', 5),
      ], cur, labelOf: (v) => '${v as int}'),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setDownloadConcurrency(choice.value as int);
    }
  }

  Future<void> _pickFileNameStyle(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.downloadFileNameStyle ?? 'artist-title';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, const [
        _Choice('歌手 - 标题', 'artist-title'),
        _Choice('标题 - 歌手', 'title-artist'),
        _Choice('标题 - 歌手 - 专辑', 'title-artist-album'),
      ], cur, labelOf: (v) => _fileNameStyleLabel(v as String)),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setDownloadFileNameStyle(choice.value as String);
    }
  }

  Future<void> _pickMinDuration(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.libraryMinDurationSeconds ?? 0;
    final choices = const [
      _Choice('不排除', 0),
      _Choice('10 秒', 10),
      _Choice('30 秒', 30),
      _Choice('60 秒', 60),
    ];
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(context, choices, cur, labelOf: (v) => switch (v) {
        0 => '不排除',
        10 => '10 秒',
        30 => '30 秒',
        60 => '60 秒',
        _ => '$v 秒',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setLibraryMinDurationSeconds(choice.value as int);
    }
  }

  Future<void> _pickDownloadPath(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.downloadPath ?? '';
    final controller = TextEditingController(text: cur);
    final action = await showSheetDialog<Object?>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('下载路径',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '留空使用默认下载目录',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(ctx).colorScheme.outline),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '路径',
                hintText: '例如 /storage/emulated/0/Music',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'default'),
                  child: const Text('恢复默认'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    final path = action == 'default' ? '' : action as String;
    await ref.read(settingsProvider.notifier).setDownloadPath(path);
  }

  Widget _choiceSheet(BuildContext context, List<_Choice> choices, Object? cur,
      {required String Function(dynamic) labelOf}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in choices)
          ListTile(
            title: Text(labelOf(c.value)),
            trailing: c.value == cur
                ? Icon(Icons.check,
                    color: Theme.of(context).colorScheme.primary)
                : null,
            selected: c.value == cur,
            onTap: () => Navigator.pop(context, c),
          ),
      ],
    );
  }
}

/// 分组圆角卡片包裹容器（纯白卡片）。
class _CardGroup extends StatelessWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            height: 1,
            indent: 52,
            endIndent: 16,
            thickness: 0.5,
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        );
      }
    }

    return Material(
      color: settingsCardColor(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Choice {
  final String label;
  final dynamic value;
  const _Choice(this.label, this.value);
}