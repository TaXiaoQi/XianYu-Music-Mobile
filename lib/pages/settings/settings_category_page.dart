import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../src/backup/app_backup.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/audio/audio_devices.dart';
import '../../src/rust/api.dart' as frb;

/// 设置分类。对应桌面版导航分类中在移动端可用的分组。
enum SettingsCategory {
  general,
  appearance,
  playback,
  download,
  advanced;

  static SettingsCategory fromPath(String p) => switch (p) {
    'appearance' => SettingsCategory.appearance,
    'playback' => SettingsCategory.playback,
    'download' => SettingsCategory.download,
    'advanced' => SettingsCategory.advanced,
    _ => SettingsCategory.general,
  };

  String get title => switch (this) {
    SettingsCategory.general => '常规',
    SettingsCategory.appearance => '外观',
    SettingsCategory.playback => '播放',
    SettingsCategory.download => '下载',
    SettingsCategory.advanced => '高级设置',
  };
}

/// 设置页背景底色（浅白，与纯白卡片区分）。
///
/// 亮色：淡灰白 #F4F4F6，暗色：#222。
Color settingsSurfaceBg(BuildContext context) => appSurfaceBg(context);

/// 设置卡片纯白底色。
Color settingsCardColor(BuildContext context) => appCardColor(context);

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
      case SettingsCategory.appearance:
        return _appearance(context, ref, settings, notifier);
      case SettingsCategory.playback:
        return _playback(context, ref, settings, notifier, exclusivePlaying);
      case SettingsCategory.download:
        return _download(context, ref, settings, notifier);
      case SettingsCategory.advanced:
        return _advanced(context, settings, notifier);
    }
  }

  // ---- 常规 ----
  List<Widget> _general(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, '语言'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.language_outlined,
            title: '语言',
            trailing: Text(_languageLabel(s?.language ?? AppLanguage.system)),
            onTap: () => _pickLanguage(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, '反馈'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.vibration_outlined,
            title: '触觉反馈力度',
            subtitle: '点击底部导航等操作的手感震动强度',
            trailing: Text(_hapticLabel(s?.hapticStrength ?? 1)),
            onTap: () => _pickHaptic(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, '存储空间'),
      const _StorageSettingsGroup(),
    ];
  }

  // ---- 外观 ----
  List<Widget> _appearance(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
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
          _tile(
            context,
            icon: Icons.wallpaper_outlined,
            title: '壁纸中心',
            subtitle: '自定义背景与动态壁纸',
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/wallpaper'),
          ),
          _switchTile(
            context,
            icon: Icons.blur_on_outlined,
            title: '毛玻璃材质',
            subtitle: '顶栏与底栏使用安卓原生高斯模糊磨砂',
            value: s?.frostedGlass ?? true,
            onChanged: (v) => n.setFrostedGlass(v),
          ),
          _switchTile(
            context,
            icon: Icons.gradient_outlined,
            title: '液态玻璃',
            subtitle: '悬浮导航 shader 折射光影，与毛玻璃二选一',
            value: s?.liquidGlass ?? false,
            onChanged: (v) => n.setLiquidGlass(v),
          ),
        ],
      ),
      // 导航栏与底栏样式：由「常规」页迁入外观。
      _sectionHeader(context, '导航栏与底栏'),
      _CardGroup(
        children: [
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
              trailing: Text(switch (s?.sideBarExpandDirection ??
                  SideBarExpandDirection.down) {
                SideBarExpandDirection.down => '向下展开',
                SideBarExpandDirection.up => '向上展开',
              }),
              onTap: () => _pickSideBarExpandDirection(context, ref, s),
            ),
        ],
      ),
      _sectionHeader(context, '列表'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.view_list_outlined,
            title: '列表大小',
            subtitle: '歌曲 / 歌手 / 专辑 / 歌单列表项尺寸',
            trailing: Text(listSizeLabel(
                s?.listSize ?? ListSize.medium)),
            onTap: () => _pickListSize(context, ref, s),
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
  List<Widget> _playback(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
    bool exclusivePlaying,
  ) {
    return [
      _sectionHeader(context, '播放'),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.volume_up_outlined,
            title: exclusivePlaying ? '音量（直出已锁定）' : '音量',
            trailing: _volumeSlider(s, n, locked: exclusivePlaying),
            subtitle: exclusivePlaying
                ? 'Bit-perfect / DSD 直出中，音量由 DAC 控制'
                : null,
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
      // 以下两组原属「音源」页，随重构并入播放页，与桌面端播放设置对齐。
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
            trailing: Text(
              _failureBehaviorLabel(s?.onlineFailureBehavior ?? 'skip'),
            ),
            onTap: () => _pickFailureBehavior(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.vertical_align_bottom_outlined,
            title: '音质回退行为',
            subtitle: '默认音质播放失败时如何切换音质档位',
            trailing: Text(
              _qualityFallbackLabel(
                s?.onlineQualityFallbackBehavior ?? 'lower',
              ),
            ),
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
      // 分享链接设置，与桌面端「播放 → 在线播放」下的分享设置对齐。
      _sectionHeader(context, '分享'),
      _CardGroup(
        children: [
          _shareValidityTile(context, s, n),
          _tile(
            context,
            icon: Icons.link_outlined,
            title: '分享链接播放失败行为',
            subtitle:
                '通过分享链接播放的歌曲起播失败时：暂停播放，或按来源信息走插件换源重播同一首歌',
            trailing: Text(
              _sharePlaybackFailureBehaviorLabel(
                s?.sharePlaybackFailureBehavior ?? 'pause',
              ),
            ),
            onTap: () => _pickShareFailureBehavior(context, ref, s),
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
            trailing: Text(_outputDeviceLabel(s?.usbExclusiveDeviceId ?? -1)),
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

  // ---- 下载 ----
  List<Widget> _download(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
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
              _fileNameStyleLabel(s?.downloadFileNameStyle ?? 'artist-title'),
            ),
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

  // ---- 高级设置 ----
  // 应用备份（歌单/收藏/插件/设置导出与导入）按需求从原「同步与备份」页上移至此。
  List<Widget> _advanced(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, '应用备份'),
      const _AppBackupGroup(),
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
            subtitle: '开启后所有页面支持安卓系统预测返回动画（需 Android 13+ 手势导航）',
            value: s?.enablePredictiveBack ?? true,
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

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget trailing,
    VoidCallback? onTap,
    String? subtitle,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      trailing: onTap == null
          ? trailing
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                trailing,
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
      onTap: onTap,
    );
  }

  Widget _switchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
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

  String _hapticLabel(int v) => switch (v) {
    0 => '轻',
    2 => '重',
    _ => '正常',
  };

  Widget _volumeSlider(
    AppSettings? s,
    SettingsNotifier n, {
    required bool locked,
  }) {
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
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('分享链接有效时长'),
          subtitle: Text(
            '分享链接过期后即被服务端丢弃，他人将无法打开（5 分钟 ~ 24 小时）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
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
          child: Slider(
            min: 5,
            max: 1440,
            divisions: 287,
            value: minutes.toDouble(),
            onChanged: (v) => n.setShareLinkValidityMinutes(v.round()),
          ),
        ),
      ],
    );
  }

  String _shareValidityLabel(int v) =>
      v % 60 == 0 ? '${v ~/ 60} 小时' : '$v 分钟';

  String _failureBehaviorLabel(String v) => switch (v) {
    'stop' => '停止播放',
    _ => '跳到下一首',
  };

  String _sharePlaybackFailureBehaviorLabel(String v) =>
      v == 'pause' ? '暂停播放' : '替换播放';

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
        .map(
          (c) => c == 1
              ? '单声道'
              : c == 2
              ? '立体声'
              : '${c}ch',
        )
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
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.navBarPosition ?? NavBarPosition.bottom;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [
          _Choice('底部导航', NavBarPosition.bottom),
          _Choice('侧边悬浮', NavBarPosition.side),
        ],
        cur,
        labelOf: (v) => switch (v) {
          NavBarPosition.bottom => '底部导航',
          NavBarPosition.side => '侧边悬浮',
          _ => '底部导航',
        },
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setNavBarPosition(choice.value as NavBarPosition);
    }
  }

  Future<void> _pickSideBarExpandDirection(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.sideBarExpandDirection ?? SideBarExpandDirection.down;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [
          _Choice('向下展开', SideBarExpandDirection.down),
          _Choice('向上展开', SideBarExpandDirection.up),
        ],
        cur,
        labelOf: (v) => switch (v) {
          SideBarExpandDirection.down => '向下展开',
          SideBarExpandDirection.up => '向上展开',
          _ => '向下展开',
        },
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setSideBarExpandDirection(choice.value as SideBarExpandDirection);
    }
  }

  Future<void> _pickLanguage(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.language ?? AppLanguage.system;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [
          _Choice('跟随系统', AppLanguage.system),
          _Choice('简体中文', AppLanguage.zhCN),
          _Choice('繁體中文', AppLanguage.zhTW),
          _Choice('English', AppLanguage.en),
        ],
        cur,
        labelOf: (v) => _languageLabel(v as AppLanguage),
      ),
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

  Future<void> _pickHaptic(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.hapticStrength ?? 1;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [
          _Choice('轻', 0),
          _Choice('正常', 1),
          _Choice('重', 2),
        ],
        cur,
        labelOf: (v) => _hapticLabel(v as int),
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setHapticStrength(choice.value as int);
    }
  }

  Future<void> _pickListSize(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.listSize ?? ListSize.medium;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [
          _Choice('最小', ListSize.compact),
          _Choice('中等', ListSize.medium),
          _Choice('最大', ListSize.large),
        ],
        cur,
        labelOf: (v) => listSizeLabel(v as ListSize),
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setListSize(choice.value as ListSize);
    }
  }

  Future<void> _pickThemeMode(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.themeMode ?? ThemeModePreference.system;
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [
          _Choice('跟随系统', ThemeModePreference.system),
          _Choice('浅色', ThemeModePreference.light),
          _Choice('深色', ThemeModePreference.dark),
        ],
        cur,
        labelOf: (v) => switch (v) {
          ThemeModePreference.system => '跟随系统',
          ThemeModePreference.light => '浅色',
          ThemeModePreference.dark => '深色',
          _ => '跟随系统',
        },
      ),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setThemeMode(choice.value as ThemeModePreference);
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
      (_) => _choiceSheet(
        context,
        const [
          _Choice('低清', 'mgg', subtitle: '96k · 极速云端试听'),
          _Choice('普通', '128k', subtitle: '128k'),
          _Choice('中等', '192k', subtitle: '192k'),
          _Choice('HQ', '320k', subtitle: '高品质 · 320k'),
          _Choice('SQ', 'flac', subtitle: '无损 · FLAC'),
          _Choice('Hi-Res', 'flac24bit', subtitle: '高解析 · FLAC 24bit'),
          _Choice('高解析度', 'hires', subtitle: 'Hi-Res 高解析无损'),
          _Choice('黑胶', 'vinyl', subtitle: '黑胶音色 · 无损'),
          _Choice('杜比全景声', 'dolby', subtitle: 'Dolby Atmos 沉浸环绕'),
          _Choice('臻品音质', 'atmos', subtitle: '臻品立体空间声场'),
          _Choice('臻品全景声', 'atmos_plus', subtitle: '臻品全空间沉浸声'),
          _Choice('臻品母带', 'master', subtitle: '母带级无损臻品'),
        ],
        cur,
        labelOf: (v) => v as String,
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
    final cur = s?.onlineFailureBehavior ?? 'skip';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
        const [_Choice('跳到下一首', 'skip'), _Choice('停止播放', 'stop')],
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
        const [
          _Choice('暂停播放', 'pause', subtitle: '分享歌曲起播失败时停止并显示错误'),
          _Choice('替换播放', 'replace', subtitle: '按来源信息走插件换源重播同一首歌'),
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
        const [
          _Choice('暂停', 'pause'),
          _Choice('播放更低音质', 'lower'),
          _Choice('播放更高音质', 'higher'),
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
              child: Text(
                '输出设备',
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
                  !supported ? '仅 Android 支持设备枚举' : '未检测到可用的输出设备',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
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
        const [
          _Choice('歌手 - 标题', 'artist-title'),
          _Choice('标题 - 歌手', 'title-artist'),
          _Choice('标题 - 歌手 - 专辑', 'title-artist-album'),
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

  Future<void> _pickDownloadPath(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
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
            const Text('下载路径', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '留空使用默认下载目录',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).colorScheme.outline,
              ),
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

  Widget _choiceSheet(
    BuildContext context,
    List<_Choice> choices,
    Object? cur, {
    required String Function(dynamic) labelOf,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in choices)
          ListTile(
            title: Text(labelOf(c.value)),
            subtitle: c.subtitle == null
                ? null
                : Text(
                    c.subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
            trailing: c.value == cur
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
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

/// 主题色选择弹层：桌面端同款 8 色预设网格 + 自定义 HSV 调色盘。
/// 预设点击即选中关闭；自定义区支持 SV 二维取色板、色相条与 Hex 输入。
class _AccentColorSheet extends StatefulWidget {
  const _AccentColorSheet({required this.current});
  final int current;

  @override
  State<_AccentColorSheet> createState() => _AccentColorSheetState();
}

class _AccentColorSheetState extends State<_AccentColorSheet> {
  late HSVColor _hsv;
  final _hexCtrl = TextEditingController();
  bool _hexError = false;

  static const _presets = <int, String>{
    0xFFEC4141: '经典红',
    0xFFF9735B: '珊瑚',
    0xFFF59E0B: '琥珀',
    0xFF22C55E: '翡翠',
    0xFF06B6D4: '青绿',
    0xFF3B82F6: '湖蓝',
    0xFF8B5CF6: '鸢尾紫',
    0xFFEC4899: '蔷薇',
  };

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(Color(widget.current));
    _syncHex();
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  void _syncHex() {
    _hexCtrl.text = _colorToHex(_color);
  }

  static String _colorToHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _update(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hexError = false;
      _syncHex();
    });
  }

  void _commitHex() {
    final text = _hexCtrl.text.trim().replaceFirst('#', '');
    if (text.length != 6 || int.tryParse(text, radix: 16) == null) {
      setState(() => _hexError = true);
      return;
    }
    final value = int.parse('FF$text', radix: 16);
    setState(() {
      _hsv = HSVColor.fromColor(Color(value));
      _hexError = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('主题色', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            // 预设网格（学桌面端：色块 + 名称，四列两行）
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.5,
              children: [
                for (final entry in _presets.entries)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context, entry.key),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: widget.current == entry.key
                              ? scheme.primary
                              : scheme.outlineVariant.withValues(alpha: 0.6),
                          width: widget.current == entry.key ? 2 : 1,
                        ),
                        color: widget.current == entry.key
                            ? scheme.primary.withValues(alpha: 0.08)
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: Color(entry.key),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.15),
                                  blurRadius: 4,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: widget.current == entry.key
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 16,
                                  )
                                : null,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.value,
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Divider(color: scheme.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '自定义颜色',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
                Expanded(child: Divider(color: scheme.outlineVariant)),
              ],
            ),
            const SizedBox(height: 14),
            _HsvPicker(hsv: _hsv, onChanged: _update),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _hexCtrl,
                    enabled: true,
                    maxLength: 7,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      letterSpacing: 1,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      labelText: 'Hex',
                      hintText: '#EC4141',
                      errorText: _hexError ? '格式应为 #RRGGBB' : null,
                      border: const OutlineInputBorder(),
                    ),
                    onEditingComplete: _commitHex,
                    onSubmitted: (_) => _commitHex(),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _color.toARGB32()),
                  child: const Text('应用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// HSV 调色盘：饱和度/明度二维取色板 + 色相条，均支持拖拽与点击取色。
class _HsvPicker extends StatelessWidget {
  const _HsvPicker({required this.hsv, required this.onChanged});
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  HSVColor _fromSvBox(Offset local, Size size) {
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    return HSVColor.fromAHSV(1, hsv.hue, s, v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumbColor = Colors.white;
    return Column(
      children: [
        // SV 二维取色板：横向白色→纯色，纵向透明→黑色
        LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, 150);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => onChanged(_fromSvBox(d.localPosition, size)),
              onPanUpdate: (d) => onChanged(_fromSvBox(d.localPosition, size)),
              child: Container(
                width: size.width,
                height: size.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: CustomPaint(
                  painter: _SvBoxPainter(
                    baseColor: hsv.withSaturation(1).withValue(1).toColor(),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: (hsv.saturation * size.width).clamp(
                          0.0,
                          size.width - 22,
                        ),
                        top: ((1 - hsv.value) * size.height).clamp(
                          0.0,
                          size.height - 22,
                        ),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hsv.toColor(),
                            border: Border.all(color: thumbColor, width: 2.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        // 色相条
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => _setHue(d.localPosition.dx / width),
              onPanUpdate: (d) => _setHue(d.localPosition.dx / width),
              child: Container(
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    const _HueRainbow(),
                    Positioned(
                      left: (hsv.hue / 360 * width).clamp(0.0, width - 18),
                      top: -3,
                      child: Container(
                        width: 18,
                        height: 18,
                        margin: const EdgeInsets.all(4.5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hsv.withSaturation(1).withValue(1).toColor(),
                          border: Border.all(color: thumbColor, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _setHue(double ratio) {
    final h = (ratio.clamp(0.0, 1.0)) * 360;
    onChanged(HSVColor.fromAHSV(1, h, hsv.saturation, hsv.value));
  }
}

/// SV 取色板底色：左白右纯色线性渐变叠加上黑下透明线性渐变。
class _SvBoxPainter extends CustomPainter {
  _SvBoxPainter({required this.baseColor});
  final Color baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final horizontal = LinearGradient(
      colors: [Colors.white, baseColor],
    ).createShader(rect);
    final vertical = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.transparent, Colors.black],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = horizontal);
    canvas.drawRect(rect, Paint()..shader = vertical);
  }

  @override
  bool shouldRepaint(_SvBoxPainter old) => old.baseColor != baseColor;
}

/// 色相彩虹条。
class _HueRainbow extends StatelessWidget {
  const _HueRainbow();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

class _Choice {
  final String label;
  final String? subtitle;
  final dynamic value;
  const _Choice(this.label, this.value, {this.subtitle});
}

/// 常规 → 存储空间：与桌面端 SettingsGeneral 对齐的在线播放流式缓存管理。
class _StorageSettingsGroup extends ConsumerStatefulWidget {
  const _StorageSettingsGroup();

  @override
  ConsumerState<_StorageSettingsGroup> createState() =>
      _StorageSettingsGroupState();
}

class _StorageSettingsGroupState extends ConsumerState<_StorageSettingsGroup> {
  static const _kMinMB = 1;
  static const _kMaxMB = 10240;

  int? _currentBytes;
  int? _maxBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final c = await frb.streamCacheCurrentBytes();
      final m = await frb.streamCacheMaxBytes();
      if (!mounted) return;
      setState(() {
        _currentBytes = c.toInt();
        _maxBytes = m.toInt();
      });
    } catch (_) {
      // 后端未就绪时静默。
    }
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _pickLimit() async {
    final s = ref.read(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final controller = TextEditingController(
      text: (s?.streamCacheSizeMB ?? 500).toString(),
    );
    var chosen = 0;
    await showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('播放缓存上限'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入 1 - 10240 MB',
            suffixText: ' MB',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              chosen = (v ?? 500).clamp(_kMinMB, _kMaxMB);
              Navigator.of(ctx).pop();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (chosen <= 0) return;
    await notifier.setStreamCacheSizeMB(chosen);
    await frb.setStreamCacheMaxSizeBytes(
      bytes: BigInt.from(chosen * 1024 * 1024),
    );
    await _refresh();
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await frb.clearStreamCache();
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider).valueOrNull;
    final limitMB = s?.streamCacheSizeMB ?? 500;
    final cur = _currentBytes;
    final max = _maxBytes ?? limitMB * 1024 * 1024;
    final scheme = Theme.of(context).colorScheme;
    return _CardGroup(
      children: [
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('播放缓存上限'),
          subtitle: const Text('在线播放的临时音源文件最大缓存量'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$limitMB MB',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: scheme.outline),
            ],
          ),
          onTap: _pickLimit,
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('清理在线播放缓存'),
          subtitle: Text(
            cur == null
                ? '读取中…'
                : '当前 ${_fmtBytes(cur)} / 上限 ${_fmtBytes(max)}',
          ),
          trailing: TextButton(
            onPressed: (cur ?? 0) == 0 ? null : _clear,
            child: Text(_busy ? '清理中…' : '清理'),
          ),
        ),
      ],
    );
  }
}

/// 高级设置 → 应用备份：歌单/收藏/插件/设置导出与导入为 JSON。
class _AppBackupGroup extends ConsumerStatefulWidget {
  const _AppBackupGroup();

  @override
  ConsumerState<_AppBackupGroup> createState() => _AppBackupGroupState();
}

class _AppBackupGroupState extends ConsumerState<_AppBackupGroup> {
  bool _busy = false;

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// 导出完整应用备份并调起系统分享。
  Future<void> _exportBackup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final service = ref.read(appBackupProvider);
      final json = await service.exportJson();
      final docs = await getApplicationDocumentsDirectory();
      final path = await writeBackupFile(docs.path, json);
      if (!mounted) return;
      _toast('备份已导出');
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: '弦予音乐应用备份'),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 选择备份文件 → 预览摘要 → 选择导入内容 → 执行。
  Future<void> _importBackup() async {
    if (_busy) return;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty) return;
      final file = files.first;

      String content = '';
      final path = file.path ?? '';
      if (path.isNotEmpty && File(path).existsSync()) {
        content = await File(path).readAsString();
      } else {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          _toast('无法读取所选文件');
          return;
        }
        content = utf8.decode(bytes);
      }

      final service = ref.read(appBackupProvider);
      final backup = service.parse(content);
      final options = await _confirmBackupImport(service.summarize(backup));
      if (options == null) return;

      setState(() => _busy = true);
      final result = await service.import(backup, includePlaylists: options.$1,
          includeFavorites: options.$2, includePlugins: options.$3, includeSettings: options.$4);
      if (!mounted) return;
      final parts = <String>[
        if (options.$1) '歌单 ${result.importedPlaylists}',
        if (options.$2) '收藏 ${result.importedFavorites}',
        if (options.$3)
          '插件 ${result.importedPlugins}'
          '${result.skippedPlugins > 0 ? '（跳过 ${result.skippedPlugins}）' : ''}',
        if (options.$4 && result.settingsApplied) '设置',
      ];
      _toast(parts.isEmpty ? '未导入任何内容' : '导入完成：${parts.join('，')}');
      if (result.errors.isNotEmpty && mounted) {
        await showPredictiveDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('部分内容导入失败'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in result.errors)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child:
                          Text(e, style: const TextStyle(fontSize: 12.5)),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } on FormatException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入确认对话框：摘要 + 导入内容勾选，返回 null 表示取消。
  Future<(bool, bool, bool, bool)?> _confirmBackupImport(
      AppBackupSummary summary) {
    var playlists = true;
    var favorites = true;
    var plugins = true;
    var settings = false;
    return showPredictiveDialog<(bool, bool, bool, bool)>(
            context: context,
            builder: (ctx) => StatefulBuilder(
              builder: (ctx, setDialog) => AlertDialog(
                title: const Text('导入应用备份'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (summary.createdAt.isNotEmpty)
                      Text(
                          '备份时间：${summary.createdAt.length >= 19 ? summary.createdAt.substring(0, 19).replaceAll('T', ' ') : summary.createdAt}',
                          style: const TextStyle(fontSize: 12.5)),
                    const SizedBox(height: 6),
                    Text(
                      '歌单 ${summary.playlistCount} 个（${summary.totalSongs} 首）\n'
                      '收藏 ${summary.favoriteCount} 首、收藏集 ${summary.favoriteCollectionCount} 个\n'
                      '插件 ${summary.pluginCount} 个${summary.hasSettings ? '\n含设置' : ''}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    const Text('选择导入内容：', style: TextStyle(fontSize: 12.5)),
                    _backupCheck('歌单', playlists, summary.playlistCount > 0,
                        (v) => setDialog(() => playlists = v ?? false)),
                    _backupCheck('收藏', favorites,
                        summary.favoriteCount + summary.favoriteCollectionCount > 0,
                        (v) => setDialog(() => favorites = v ?? false)),
                    _backupCheck('插件', plugins, summary.pluginCount > 0,
                        (v) => setDialog(() => plugins = v ?? false)),
                    _backupCheck(
                        '设置（覆盖当前设置）',
                        settings,
                        summary.hasSettings,
                        (v) => setDialog(() => settings = v ?? false)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(ctx, (playlists, favorites, plugins, settings)),
                    child: const Text('导入'),
                  ),
                ],
              ),
            ),
          );
  }

  Widget _backupCheck(
      String label, bool value, bool enabled, ValueChanged<bool?> onChanged) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trailing = _busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(Icons.chevron_right,
            size: 18, color: scheme.onSurfaceVariant);
    return _CardGroup(
      children: [
        ListTile(
          leading: const Icon(Icons.archive_outlined),
          title: const Text('导出应用备份'),
          subtitle: const Text('歌单、收藏、插件、设置备份为 JSON 并分享'),
          trailing: trailing,
          onTap: _busy ? null : _exportBackup,
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore_outlined),
          title: const Text('导入应用备份'),
          subtitle: const Text('从备份文件恢复（支持选择导入内容）'),
          trailing: trailing,
          onTap: _busy ? null : _importBackup,
        ),
      ],
    );
  }
}
