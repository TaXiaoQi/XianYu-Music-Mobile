import '../../src/widgets/modern_dialog.dart';
import '../../src/widgets/predictive_dialog_route.dart';
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
import '../../src/core/application_logger.dart';
import '../../src/core/settings.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/committed_slider.dart';
import '../../src/audio/audio_devices.dart';
import '../../src/lyrics/floating_lyrics.dart';
import '../../src/rust/api.dart' as frb;
import '../../src/i18n/i18n.dart';

/// 设置分类。对应桌面版导航分类中在移动端可用的分组。
enum SettingsCategory {
  general,
  appearance,
  lyrics,
  playback,
  download,
  advanced;

  static SettingsCategory fromPath(String p) => switch (p) {
    'appearance' => SettingsCategory.appearance,
    'lyrics' => SettingsCategory.lyrics,
    'playback' => SettingsCategory.playback,
    'download' => SettingsCategory.download,
    'advanced' => SettingsCategory.advanced,
    _ => SettingsCategory.general,
  };

  String get title => switch (this) {
    SettingsCategory.general => tr('常规'),
    SettingsCategory.appearance => tr('外观'),
    SettingsCategory.lyrics => tr('歌词'),
    SettingsCategory.playback => tr('播放'),
    SettingsCategory.download => tr('下载'),
    SettingsCategory.advanced => tr('高级设置'),
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
  const SettingsCategoryPage({
    super.key,
    required this.category,
    this.embedded = false,
  });

  final SettingsCategory category;

  /// 嵌入态：用于横屏 master-detail 右侧，去掉顶栏仅渲染设置体。
  final bool embedded;

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
    final exclusivePlaying = ref.watch(playerProvider.select((s) => s.usbExclusive));

    if (widget.embedded) {
      // 嵌入态：仅渲染设置体，顶栏/背景交由上层（横屏 master-detail 右侧）负责。
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: _buildItems(
          context,
          ref,
          category,
          settings,
          notifier,
          exclusivePlaying,
        ),
      );
    }

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: RepaintBoundary(child: ListView(
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
            )),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              // 设置页内容从顶栏高度之下才开始，下方是纯色底色：
              // 扁平背板，跳过全屏 BackdropFilter，消除切页卡顿（视觉不变）。
              flatBackdrop: true,
              leading: const BackButton(),
              title: Text(category.title),
            ),
          ),
        ],
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
      case SettingsCategory.lyrics:
        return _lyrics(context, ref, settings, notifier);
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
      _sectionHeader(context, tr('语言')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.language_outlined,
            title: tr('语言'),
            trailing: Text(_languageLabel(s?.language ?? AppLanguage.system)),
            onTap: () => _pickLanguage(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, tr('反馈')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.vibration_outlined,
            title: tr('触觉反馈力度'),
            subtitle: tr('点击底部导航等操作的手感震动强度'),
            trailing: Text(_hapticLabel(s?.hapticStrength ?? 1)),
            onTap: () => _pickHaptic(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, tr('检测更新')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.system_update_alt_outlined,
            title: tr('检测更新模式'),
            subtitle: tr('启动时自动检查 App 更新'),
            trailing: Text(_updateModeLabel(s?.updateCheckMode ?? 'startup')),
            onTap: () => _pickUpdateCheckMode(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, tr('存储空间')),
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
      _sectionHeader(context, tr('主题')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.palette_outlined,
            title: tr('主题模式'),
            trailing: _themeLabel(s),
            onTap: () => _pickThemeMode(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.color_lens_outlined,
            title: tr('主题色'),
            trailing: _ColorDot(color: Color(s?.accentColor ?? 0xFFEC4141)),
            onTap: () => _pickAccentColor(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.wallpaper_outlined,
            title: tr('壁纸中心'),
            subtitle: tr('自定义背景与动态壁纸'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/wallpaper'),
          ),
        ],
      ),
      // 材质：毛玻璃（伪毛玻璃）与液态玻璃是两种独立材质，默认交给玻璃表面渲染。
      _sectionHeader(context, tr('材质')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.blur_on_outlined,
            title: tr('毛玻璃材质'),
            subtitle: tr('顶栏、底栏与播放条透明磨砂质感，关闭时回退纯色'),
            // 毛玻璃默认开启；关闭后回退为高不透明度纯色。壁纸模式行为一致
            // （壁纸只是替换底色，不改变玻璃开关）。
            value: s?.frostedGlass ?? true,
            onChanged: (v) => n.setFrostedGlass(v),
          ),
          // 毛玻璃强度调节：毛玻璃开启时才显示。
          // 与液态玻璃共存：液态只覆盖固定几个控件，其余表面由毛玻璃负责，
          // 因此液态玻璃开启时此入口仍然可见、可调。
          if (s?.frostedGlass ?? true)
            _tile(
              context,
              icon: Icons.tune_outlined,
              title: tr('毛玻璃效果'),
              subtitle: tr('调整毛玻璃模糊强度'),
              trailing: Text(switch (s?.frostedGlassLevel ??
                  FrostedGlassLevel.strongest) {
                FrostedGlassLevel.strongest => tr('最强'),
                FrostedGlassLevel.medium => tr('中等'),
                FrostedGlassLevel.light => tr('轻度'),
              }),
              onTap: () => _pickFrostedGlassLevel(context, ref, s),
            ),
          _switchTile(
            context,
            icon: Icons.gradient_outlined,
            title: tr('液态玻璃'),
            subtitle: tr(
                '开启时自动切换到悬浮式底栏；底栏、迷你条、搜索框与播放页控制卡优先液态，其余表面由毛玻璃补齐'),
            // 液态玻璃开关始终可点，不再因悬浮底栏关闭而强制置灰/归假：
            // 打开时由 setLiquidGlass 联动打开悬浮底栏。
            // 液态与毛玻璃可共存：液态优先覆盖固定几个控件，毛玻璃补齐
            // 其余表面；两个开关互不联动，开启顺序无关。
            value: s?.liquidGlass ?? false,
            onChanged: (v) => n.setLiquidGlass(v),
          ),
          if (s?.liquidGlass ?? false)
            _tile(
              context,
              icon: Icons.tune_outlined,
              title: tr('液态玻璃效果'),
              subtitle: tr('调整液态玻璃渲染强度与耗电'),
              trailing: Text(switch (s?.liquidGlassQuality ??
                  LiquidGlassQuality.medium) {
                LiquidGlassQuality.low => tr('低 · 性能优先'),
                LiquidGlassQuality.high => tr('高 · 极致渲染'),
                LiquidGlassQuality.medium => tr('中 · 均衡'),
              }),
              onTap: () => _pickLiquidGlassQuality(context, ref, s),
            ),
        ],
      ),
      // 导航栏与底栏样式：由「常规」页迁入外观。
      _sectionHeader(context, tr('导航栏与底栏')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.navigation_outlined,
            title: tr('导航栏位置'),
            trailing: Text(switch (s?.navBarPosition ?? NavBarPosition.bottom) {
              NavBarPosition.bottom => tr('底部导航'),
              NavBarPosition.side => tr('侧边悬浮'),
            }),
            onTap: () => _pickNavBarPosition(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.screen_rotation_alt_outlined,
            title: tr('竖屏切换动画'),
            subtitle: tr('覆盖：新页盖住旧页；平滑：新旧两页平行平移'),
            trailing: Text(switch (s?.pageTransitionStyle ??
                PageTransitionStyle.cover) {
              PageTransitionStyle.cover => tr('覆盖'),
              PageTransitionStyle.smooth => tr('平滑'),
            }),
            onTap: () => _pickPageTransitionStyle(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.animation_outlined,
            title: tr('横屏切换动画'),
            subtitle: tr('横屏下首页/我的在右侧容器切换时淡进淡出'),
            value: s?.landscapeTransitionEnabled ?? true,
            onChanged: (v) => n.setLandscapeTransitionEnabled(v),
          ),
          if ((s?.navBarPosition ?? NavBarPosition.bottom) ==
              NavBarPosition.bottom)
            _switchTile(
              context,
              icon: Icons.subtitles_outlined,
              title: tr('悬浮式底栏'),
              value: s?.floatingNavBar ?? true,
              onChanged: (v) => n.setFloatingNavBar(v),
            ),
          _switchTile(
            context,
            icon: Icons.manage_search_outlined,
            title: tr('悬浮顶部栏'),
            subtitle: tr('首页、我的页与横屏顶栏改为悬浮显示（控件独立悬浮），应用液态玻璃时同步生效'),
            value: s?.floatingSearchBar ?? false,
            onChanged: (v) => n.setFloatingSearchBar(v),
          ),
          _switchTile(
            context,
            icon: Icons.crop_landscape_outlined,
            title: tr('横屏使用摄像头区域'),
            subtitle: tr('横屏时各页面铺满到摄像头(挖孔)区域，不再留黑边'),
            value: s?.landscapeCameraArea ?? true,
            onChanged: (v) => n.setLandscapeCameraArea(v),
          ),
          if ((s?.navBarPosition ?? NavBarPosition.side) == NavBarPosition.side)
            _tile(
              context,
              icon: Icons.swap_vert_outlined,
              title: tr('侧边栏展开方向'),
              trailing: Text(switch (s?.sideBarExpandDirection ??
                  SideBarExpandDirection.down) {
                SideBarExpandDirection.down => tr('向下展开'),
                SideBarExpandDirection.up => tr('向上展开'),
              }),
              onTap: () => _pickSideBarExpandDirection(context, ref, s),
            ),
        ],
      ),
      // 播放页样式：高级模式（现代毛玻璃）/ 传统模式（经典布局）。
      _sectionHeader(context, tr('播放页')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.grid_view_outlined,
            title: tr('播放页样式'),
            subtitle: tr('切换正在播放页的布局风格'),
            trailing: Text(switch (s?.playerStyle ?? PlayerStyle.advanced) {
              PlayerStyle.advanced => tr('高级模式'),
              PlayerStyle.traditional => tr('传统模式'),
            }),
            onTap: () => _pickPlayerStyle(context, ref, s),
          ),
          // 播放页液态玻璃：仅高级模式（玻璃材质卡片）下可用。
          if ((s?.playerStyle ?? PlayerStyle.advanced) == PlayerStyle.advanced)
            _switchTile(
              context,
              icon: Icons.sync_alt_outlined,
              title: tr('播放页液态玻璃'),
              subtitle: tr('播放页控制卡使用液态玻璃材质'),
              value: s?.playerLiquidGlass ?? true,
              onChanged: (v) => n.setPlayerLiquidGlass(v),
            ),
        ],
      ),
      _sectionHeader(context, tr('列表')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.view_list_outlined,
            title: tr('列表大小'),
            subtitle: tr('歌曲 / 歌手 / 专辑 / 歌单列表项尺寸'),
            trailing: Text(listSizeLabel(
                s?.listSize ?? ListSize.medium)),
            onTap: () => _pickListSize(context, ref, s),
          ),
        ],
      ),
    ];
  }

  // ---- 歌词 ----
  List<Widget> _lyrics(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, tr('歌词显示')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.translate_outlined,
            title: tr('显示翻译'),
            value: s?.showLyricsTranslation ?? true,
            onChanged: (v) => n.setShowLyricsTranslation(v),
          ),
          _switchTile(
            context,
            icon: Icons.spellcheck_outlined,
            title: tr('逐字动效'),
            value: s?.enableWordEffect ?? true,
            onChanged: (v) => n.setEnableWordEffect(v),
          ),
        ],
      ),
      _sectionHeader(context, tr('悬浮歌词')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: tr('悬浮歌词窗'),
            subtitle: tr('在其他应用上层显示卡拉OK逐字歌词'),
            value: s?.floatingLyricsEnabled ?? false,
            onChanged: (v) => _toggleFloatingLyrics(context, ref, n, v),
          ),
          // 以下设置项始终显示，未开启时置灰（与 RwaS 一致）。
          _tile(
            context,
            icon: Icons.palette_outlined,
            title: tr('文字颜色'),
            trailing: _floatingLyricsColorPicker(context, s, n),
          ),
          _tile(
            context,
            icon: Icons.opacity_outlined,
            title: tr('不透明度'),
            trailing: _floatingLyricsOpacitySlider(s, n),
          ),
          _tile(
            context,
            icon: Icons.text_fields_outlined,
            title: tr('字号'),
            trailing: _floatingLyricsFontSlider(s, n),
          ),
          _tile(
            context,
            icon: Icons.subtitles_outlined,
            title: tr('副行字号'),
            trailing: _floatingLyricsSecondarySlider(s, n),
          ),
          _switchTile(
            context,
            icon: Icons.font_download_outlined,
            title: tr('使用歌词字体'),
            subtitle: tr('应用播放页设置的自定义歌词字体'),
            value: s?.floatingLyricsUseLyricFont ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsUseLyricFont(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.translate_outlined,
            title: tr('显示翻译'),
            value: s?.floatingLyricsShowTranslation ?? true,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsShowTranslation(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.spellcheck_outlined,
            title: tr('显示罗马音'),
            value: s?.floatingLyricsShowRomanization ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsShowRomanization(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.queue_music_outlined,
            title: tr('显示背景歌词'),
            value: s?.floatingLyricsShowBackground ?? true,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsShowBackground(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.pause_outlined,
            title: tr('暂停时隐藏'),
            value: s?.floatingLyricsHideWhenPaused ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsHideWhenPaused(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.screen_lock_landscape_outlined,
            title: tr('横屏时隐藏'),
            value: s?.floatingLyricsHideInLandscape ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsHideInLandscape(v)
                : null,
          ),
          _tile(
            context,
            icon: Icons.width_full_outlined,
            title: tr('宽度'),
            trailing: _floatingLyricsWidthSlider(s, n),
          ),
          _tile(
            context,
            icon: Icons.swap_horiz_outlined,
            title: tr('水平位置'),
            trailing: _floatingLyricsXSlider(context, s, n),
          ),
          _tile(
            context,
            icon: Icons.swap_vert_outlined,
            title: tr('垂直位置'),
            trailing: _floatingLyricsYSlider(context, s, n),
          ),
          _switchTile(
            context,
            icon: Icons.lock_outline,
            title: tr('锁定位置'),
            subtitle: tr('锁定后不可拖动，通知栏解锁'),
            value: s?.floatingLyricsLocked ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsLocked(v)
                : null,
          ),
          _tile(
            context,
            icon: Icons.center_focus_strong_outlined,
            title: tr('重置位置'),
            trailing: const SizedBox.shrink(),
            onTap: (s?.floatingLyricsEnabled ?? false)
                ? () => _resetFloatingLyricsPosition()
                : null,
          ),
        ],
      ),
      _sectionHeader(context, tr('状态栏歌词')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.notifications_active_outlined,
            title: tr('状态栏歌词'),
            subtitle: tr('把当前歌词行推送到系统通知栏 / 锁屏展示'),
            value: s?.statusBarLyricsEnabled ?? false,
            onChanged: (v) => n.setStatusBarLyricsEnabled(v),
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
      _sectionHeader(context, tr('播放')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.volume_up_outlined,
            title: exclusivePlaying ? tr('音量（直出已锁定）') : tr('音量'),
            trailing: _volumeSlider(s, n, locked: exclusivePlaying),
            subtitle: exclusivePlaying
                ? tr('Bit-perfect / DSD 直出中，音量由 DAC 控制')
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.mouse_outlined,
            title: tr('双击播放歌曲'),
            subtitle: tr('开启后双击歌曲播放，关闭后单击播放'),
            value: (s?.songClickAction ?? 'single') == 'double',
            onChanged: (v) => n.setSongClickAction(v ? 'double' : 'single'),
          ),
        ],
      ),
      _sectionHeader(context, tr('音量平衡 (ReplayGain)')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.balance_outlined,
            title: tr('音量平衡'),
            subtitle: tr('按歌曲内置的 ReplayGain 标签调整增益，让不同歌曲响度一致；无标签的歌曲保持原音量'),
            value: s?.volumeBalanceEnabled ?? false,
            onChanged: (v) => n.setVolumeBalanceEnabled(v),
          ),
          if (s?.volumeBalanceEnabled ?? false) ...[
            _tile(
              context,
              icon: Icons.tune_outlined,
              title: tr('整体增益偏移'),
              trailing: _gainOffsetSlider(s, n),
            ),
            _switchTile(
              context,
              icon: Icons.shield_outlined,
              title: tr('防削波破音保护'),
              subtitle: tr('增益可能超出 0 dB 极限时自动压低；无峰值标签的歌曲不提升音量'),
              value: s?.volumeBalancePreventClipping ?? true,
              onChanged: (v) => n.setVolumeBalancePreventClipping(v),
            ),
          ],
        ],
      ),
      // 以下两组原属「音源」页，随重构并入播放页，与桌面端播放设置对齐。
      _sectionHeader(context, tr('在线音质')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.high_quality_outlined,
            title: tr('在线默认音质'),
            trailing: Text(s?.onlineDefaultQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, s, isOnline: true),
          ),
          _tile(
            context,
            icon: Icons.play_disabled_outlined,
            title: tr('起播失败行为'),
            subtitle: tr('在线音源完全无法播放时的处理方式'),
            trailing: Text(
              _failureBehaviorLabel(s?.onlineFailureBehavior ?? 'skip'),
            ),
            onTap: () => _pickFailureBehavior(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.vertical_align_bottom_outlined,
            title: tr('音质回退行为'),
            subtitle: tr('默认音质播放失败时如何切换音质档位'),
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
            title: tr('播放失败自动换源'),
            subtitle: tr('在线播放失败时自动在其他落雪音源搜索并播放同一首歌'),
            value: s?.autoSwitchSourceOnFailure ?? false,
            onChanged: (v) => n.setAutoSwitchSourceOnFailure(v),
          ),
        ],
      ),
      // 分享链接设置，与桌面端「播放 → 在线播放」下的分享设置对齐。
      _sectionHeader(context, tr('分享')),
      _CardGroup(
        children: [
          _shareValidityTile(context, s, n),
          _tile(
            context,
            icon: Icons.link_outlined,
            title: tr('分享链接播放失败行为'),
            subtitle:
                tr('通过分享链接播放的歌曲起播失败时：暂停播放，或按来源信息走插件换源重播同一首歌'),
            trailing: Text(
              _sharePlaybackFailureBehaviorLabel(
                s?.sharePlaybackFailureBehavior ?? 'pause',
              ),
            ),
            onTap: () => _pickShareFailureBehavior(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, tr('输出')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.speaker_outlined,
            title: tr('输出设备'),
            subtitle: tr('USB 独占 / DSD 直出到所选设备，可查看设备支持格式'),
            trailing: Text(_outputDeviceLabel(s?.usbExclusiveDeviceId ?? -1)),
            onTap: () => _pickOutputDevice(context, ref),
          ),
          _switchTile(
            context,
            icon: Icons.usb_outlined,
            title: tr('USB 独占输出 (Bit-perfect)'),
            subtitle:
                tr('绕过系统混音器直达 USB DAC，仅本地音乐生效；均衡器与音效走原生 DSP 管线，无 USB DAC 或启动失败时自动回退'),
            value: s?.usbExclusiveOutput ?? false,
            onChanged: (v) => n.setUsbExclusiveOutput(v),
          ),
          _switchTile(
            context,
            icon: Icons.high_quality,
            title: tr('Bit-perfect 直出'),
            subtitle:
                tr('USB 独占输出时按源位深整数直出 DAC：绕过响度归一化/均衡器/音效/音量，仅保留安全限幅；DSD 仍需开启上方「DSD 原生直出」'),
            value: s?.bitPerfectOutput ?? false,
            onChanged: (v) => n.setBitPerfectOutput(v),
          ),
          _switchTile(
            context,
            icon: Icons.graphic_eq_outlined,
            title: tr('DSD 原生直出'),
            subtitle:
                tr('dsf/dff 本地文件按 DoP 打包直送 DSD-DAC，绕过解码与所有音效；需 USB DSD-DAC 支持，失败自动回退普通播放，直出时音量与均衡器自动锁定'),
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
      _sectionHeader(context, tr('下载')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.folder_outlined,
            title: tr('下载路径'),
            trailing: Text(
              s?.downloadPath == null || s!.downloadPath.isEmpty ? tr('默认') : tr('自定义'),
            ),
            onTap: () => _pickDownloadPath(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.download_outlined,
            title: tr('下载音质'),
            trailing: Text(s?.downloadQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, s, isOnline: false),
          ),
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: tr('同时下载歌词'),
            value: s?.downloadLyrics ?? false,
            onChanged: (v) => n.setDownloadLyrics(v),
          ),
          _tile(
            context,
            icon: Icons.speed_outlined,
            title: tr('批量并发数'),
            trailing: Text('${s?.downloadConcurrency ?? 3}'),
            onTap: () => _pickConcurrency(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.label_outline,
            title: tr('文件名样式'),
            trailing: Text(
              _fileNameStyleLabel(s?.downloadFileNameStyle ?? 'artist-title'),
            ),
            onTap: () => _pickFileNameStyle(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.file_copy_outlined,
            title: tr('覆盖同名文件'),
            subtitle: tr('关闭时同名文件自动追加序号，避免覆盖'),
            value: s?.overwriteExisting ?? false,
            onChanged: (v) => n.setOverwriteExisting(v),
          ),
          _tile(
            context,
            icon: Icons.download_done_outlined,
            title: tr('下载管理'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/download'),
          ),
        ],
      ),
      _sectionHeader(context, tr('下载后嵌入')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.info_outline,
            title: tr('嵌入元数据'),
            value: s?.embedDownloadMetadata ?? true,
            onChanged: (v) => n.setEmbedDownloadMetadata(v),
          ),
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: tr('嵌入歌词'),
            subtitle: tr('需同时开启「同时下载歌词」'),
            value: s?.embedDownloadLyrics ?? true,
            onChanged: (v) => n.setEmbedDownloadLyrics(v),
          ),
          _switchTile(
            context,
            icon: Icons.image_outlined,
            title: tr('嵌入封面'),
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
      _sectionHeader(context, tr('应用备份')),
      const _AppBackupGroup(),
      _sectionHeader(context, tr('日志')),
      const _LogGroup(),
      _sectionHeader(context, tr('系统')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.screen_lock_rotation_outlined,
            title: tr('保持屏幕常亮'),
            value: s?.keepScreenOn ?? true,
            onChanged: (v) => n.setKeepScreenOn(v),
          ),
        ],
      ),
      _sectionHeader(context, tr('导航')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.arrow_back_outlined,
            title: tr('预测返回手势'),
            subtitle: tr('开启后所有页面支持安卓系统预测返回动画（需 Android 13+ 手势导航）'),
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

  // 自绘行布局替代 ListTile：大字体缩放/小屏（DPI 调大）下行宽不足时，
  // ListTile 会把 trailing 值文本挤出卡片边界（截断/与副标题挤压）。
  // 标题/副标题走 Expanded 自动换行；trailing 保持自然宽度右对齐（顶到
  // chevron），仅当超过行宽 50% 上限时由 FittedBox 等比缩小兜底。
  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget trailing,
    VoidCallback? onTap,
    String? subtitle,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: LayoutBuilder(builder: (context, cons) {
            return Row(
              children: [
                Icon(icon),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: cons.maxWidth * 0.5),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: trailing,
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
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
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _themeLabel(AppSettings? s) {
    return Text(switch (s?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.system => tr('跟随系统'),
      ThemeModePreference.light => tr('浅色'),
      ThemeModePreference.dark => tr('深色'),
    });
  }

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

  // ---- 悬浮歌词 ----

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
            title:   Text(tr('悬浮歌词需要悬浮窗权限')),
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
          await FloatingLyricsController.openPermissionSettings();
          // 授权返回后由系统回调，这里先置为开启（控制器会在权限就绪时显示）。
          await n.setFloatingLyricsEnabled(true);
        }
        return;
      }
      await n.setFloatingLyricsEnabled(true);
    } else {
      await n.setFloatingLyricsEnabled(false);
    }
  }

  Widget _floatingLyricsColorPicker(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final enabled = s?.floatingLyricsEnabled ?? false;
    final current = s?.floatingLyricsTextColor ?? 0xFFFFFFFF;
    final scheme = Theme.of(context).colorScheme;
    final isCustom = !FloatingLyricsController.quickColors.contains(current);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in FloatingLyricsController.quickColors)
          GestureDetector(
            onTap: enabled ? () => n.setFloatingLyricsTextColor(c) : null,
            child: Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(
                  color: current == c
                      ? scheme.primary
                      : scheme.outlineVariant,
                  width: current == c ? 2.5 : 1,
                ),
              ),
            ),
          ),
        // 自定义颜色入口：已选自定义色时显示该色，否则显示「+」。
        GestureDetector(
          onTap: enabled ? () => _pickFloatingLyricsColor(context, ref, s) : null,
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: isCustom ? Color(current) : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                color: isCustom ? scheme.primary : scheme.outlineVariant,
                width: isCustom ? 2.5 : 1,
              ),
            ),
            child: isCustom
                ? null
                : Icon(Icons.add, size: 14, color: scheme.outline),
          ),
        ),
      ],
    );
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

  /// 水平位置微调：-100~100 映射到原生可拖范围（物理像素），与原生 clamp 一致。
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

  /// 垂直位置微调：0~100 映射到状态栏下到屏幕底的可拖范围（物理像素）。
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
    'stop' => tr('停止播放'),
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

  Future<void> _pickPlayerStyle(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final cur = s?.playerStyle ?? PlayerStyle.advanced;
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
    final cur = s?.frostedGlassLevel ?? FrostedGlassLevel.strongest;
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
            label: tr('低 · 性能优先'),
            subtitle: tr('纯高斯模糊+描边，续航最好'),
            value: LiquidGlassQuality.low,
            icon: Icons.battery_saver_outlined),
        ModernChoiceOption(
            label: tr('中 · 均衡'),
            subtitle: tr('轻量片元着色器（默认）'),
            value: LiquidGlassQuality.medium,
            icon: Icons.tune_outlined),
        ModernChoiceOption(
            label: tr('高 · 极致渲染'),
            subtitle: tr('完整折射与色散管线，观感最强'),
            value: LiquidGlassQuality.high,
            icon: Icons.auto_awesome_outlined),
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
    final cur = s?.onlineFailureBehavior ?? 'skip';
    final choice = await showSheetDialog<_Choice>(
      context,
      (_) => _choiceSheet(
        context,
          [_Choice(tr('跳到下一首'), 'skip'), _Choice(tr('停止播放'), 'stop')],
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
              Text(tr('下载路径'), style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              tr('留空使用默认下载目录'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration:   InputDecoration(
                labelText: tr('路径'),
                hintText: tr('例如 /storage/emulated/0/Music'),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'default'),
                  child:   Text(tr('恢复默认')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child:   Text(tr('确定')),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
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
      ),
    );
  }
}

/// 带 -/+ 步进按钮的滑块行：左「−」右「＋」，中间为滑块，右侧显示当前值，
/// 便于对悬浮歌词位置等连续值做精细微调。
class _StepperSliderRow extends StatelessWidget {
  const _StepperSliderRow({
    required this.slider,
    required this.enabled,
    required this.readValue,
    required this.step,
    required this.min,
    required this.max,
    required this.onAdjust,
    this.format,
    this.valueWidth = 40,
  });

  final Widget slider;
  final bool enabled;
  final double Function() readValue;
  final double step;
  final double min;
  final double max;
  final void Function(double value) onAdjust;
  final String Function(double)? format;
  final double valueWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget stepButton(IconData icon, double delta) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        padding: EdgeInsets.zero,
        iconSize: 16,
        style: IconButton.styleFrom(
          backgroundColor: enabled
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          foregroundColor: enabled ? scheme.onSurfaceVariant : scheme.outline,
        ),
        icon: Icon(icon),
        onPressed: enabled
            ? () => onAdjust((readValue() + delta).clamp(min, max))
            : null,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        stepButton(Icons.remove, -step),
        const SizedBox(width: 6),
        SizedBox(width: 120, child: slider),
        const SizedBox(width: 6),
        stepButton(Icons.add, step),
        if (format != null) ...[
          const SizedBox(width: 8),
          SizedBox(
            width: valueWidth,
            child: Text(
              format!(readValue()),
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ],
    );
  }
}

/// 分组圆角卡片包裹容器（纯白卡片）。
class _CardGroup extends ConsumerWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    // 毛玻璃表面：跟随全局开关，与顶栏底栏一致。
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide.none,
        ),
        child: Column(children: items),
      ),
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

/// 颜色选择弹层：预设色网格 + 自定义 HSV 调色盘。
/// 预设点击即选中关闭；自定义区支持 SV 二维取色板、色相条与 Hex 输入。
/// 主题色与悬浮歌词颜色共用，通过 [title]/[presets] 区分。
class _AccentColorSheet extends StatefulWidget {
  _AccentColorSheet({
    required this.current,
    this.title = '主题色',
    this.presets,
  });
  final int current;
  final String title;
  final Map<int, String>? presets;

  static Map<int, String> get _defaultPresets => <int, String>{
    0xFFEC4141: tr('经典红'),
    0xFFF9735B: tr('珊瑚'),
    0xFFF59E0B: tr('琥珀'),
    0xFF22C55E: tr('翡翠'),
    0xFF06B6D4: tr('青绿'),
    0xFF3B82F6: tr('湖蓝'),
    0xFF8B5CF6: tr('鸢尾紫'),
    0xFFEC4899: tr('蔷薇'),
  };

  /// 与 RawS-Music DesktopLyricService.QUICK_COLORS 一致的歌词颜色预设。
  static Map<int, String> get lyricPresets => <int, String>{
    0xFFFFFFFF: tr('纯白'),
    0xFFBFBFBF: tr('银灰'),
    0xFF91CDFF: tr('天蓝'),
    0xFFA6EBCB: tr('薄荷'),
    0xFFB388FF: tr('淡紫'),
    0xFFFFBCD6: tr('粉红'),
    0xFFFFE096: tr('暖黄'),
  };

  @override
  State<_AccentColorSheet> createState() => _AccentColorSheetState();
}

class _AccentColorSheetState extends State<_AccentColorSheet> {
  late HSVColor _hsv;
  final _hexCtrl = TextEditingController();
  bool _hexError = false;

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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(widget.title), style: const TextStyle(fontWeight: FontWeight.w600)),
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
                for (final entry in (widget.presets ?? _AccentColorSheet._defaultPresets).entries)
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
                    tr('自定义颜色'),
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
                      errorText: _hexError ? tr('格式应为 #RRGGBB') : null,
                      border: const OutlineInputBorder(),
                    ),
                    onEditingComplete: _commitHex,
                    onSubmitted: (_) => _commitHex(),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _color.toARGB32()),
                  child:   Text(tr('应用')),
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
        title:   Text(tr('播放缓存上限')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration:   InputDecoration(
            hintText: tr('输入 1 - 10240 MB'),
            suffixText: ' MB',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:   Text(tr('取消')),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              chosen = (v ?? 500).clamp(_kMinMB, _kMaxMB);
              Navigator.of(ctx).pop();
            },
            child:   Text(tr('确定')),
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
          title:   Text(tr('播放缓存上限')),
          subtitle:   Text(tr('在线播放的临时音源文件最大缓存量')),
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
          title:   Text(tr('清理在线播放缓存')),
          subtitle: Text(
            cur == null
                ? tr('读取中…')
                : tr('当前 {cur} / 上限 {max}', {'cur': _fmtBytes(cur), 'max': _fmtBytes(max)}),
          ),
          trailing: TextButton(
            onPressed: (cur ?? 0) == 0 ? null : _clear,
            child: Text(_busy ? tr('清理中…') : tr('清理')),
          ),
        ),
      ],
    );
  }
}

/// 高级设置 → 日志：导出全部/错误日志并分享、一键清理。
class _LogGroup extends ConsumerStatefulWidget {
  const _LogGroup();

  @override
  ConsumerState<_LogGroup> createState() => _LogGroupState();
}

class _LogGroupState extends ConsumerState<_LogGroup> {
  bool _busy = false;

  void _toast(String msg) {
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
  }

  /// 导出日志（全部或仅错误）并调起系统分享。
  Future<void> _export({required bool onlyErrors}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final manager = ApplicationLogManager.instance;
      final logs = ref.read(applicationLogsProvider);
      if (logs.isEmpty ||
          (onlyErrors && !logs.any((e) => e.level == LogLevel.error))) {
        if (mounted) _toast(onlyErrors ? tr('暂无错误日志') : tr('暂无日志'));
        return;
      }
      final content = manager.formatExport(onlyErrors: onlyErrors);
      final docs = await getApplicationDocumentsDirectory();
      final fileName = onlyErrors
          ? 'xianyu_error_logs_${DateTime.now().millisecondsSinceEpoch}.txt'
          : 'xianyu_all_logs_${DateTime.now().millisecondsSinceEpoch}.txt';
      final file = File('${docs.path}/$fileName');
      await file.writeAsString(content, flush: true);
      if (!mounted) return;
      _toast(onlyErrors ? tr('错误日志已导出') : tr('全部日志已导出'));
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: tr('弦予音乐{type}日志', {'type': onlyErrors ? tr('错误') : ''})),
      );
    } catch (e) {
      if (mounted) _toast(tr('导出失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLogs() async {
    if (_busy) return;
    // 无日志时直接忽略，避免弹出无意义的确认框。
    if (ref.read(applicationLogsProvider).isEmpty) {
      _toast(tr('暂无日志'));
      return;
    }
    final confirmed = await showPredictiveDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('清理日志')),
        content:   Text(tr('确定要清空全部应用日志吗？此操作不可恢复。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('清理')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ApplicationLogManager.instance.clear();
    if (mounted) _toast(tr('日志已清理'));
  }

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String title,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.primary),
      title: Text(title),
      trailing: Icon(Icons.chevron_right,
          size: 18, color: scheme.outline),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(applicationLogsProvider);
    final errorCount = logs.where((e) => e.level == LogLevel.error).length;
    return _CardGroup(
      children: [
        _action(
          context,
          icon: Icons.description_outlined,
          title: logs.isEmpty ? tr('导出全部日志') : '导出全部日志（${logs.length} 条）',
          onTap: _busy ? () {} : () => _export(onlyErrors: false),
        ),
        _action(
          context,
          icon: Icons.error_outline,
          title: errorCount == 0 ? tr('导出错误日志') : '导出错误日志（$errorCount 条）',
          // 无错误日志时置灰不可点。
          onTap: errorCount == 0 || _busy
              ? null
              : () => _export(onlyErrors: true),
        ),
        _action(
          context,
          icon: Icons.delete_sweep_outlined,
          title: tr('清理日志'),
          onTap: _busy ? () {} : _clearLogs,
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
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
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
      _toast(tr('备份已导出'));
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: tr('弦予音乐应用备份')),
      );
    } catch (e) {
      if (!mounted) return;
      _toast(tr('导出失败：{e}', {'e': e}));
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
          _toast(tr('无法读取所选文件'));
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
        if (options.$1) tr('歌单 {n}', {'n': result.importedPlaylists}),
        if (options.$2) tr('收藏 {n}', {'n': result.importedFavorites}),
        if (options.$3)
          tr('插件 {n}', {'n': result.importedPlugins}) + (result.skippedPlugins > 0 ? tr('（跳过 {n}）', {'n': result.skippedPlugins}) : ''),
        if (options.$4 && result.settingsApplied) tr('设置'),
      ];
      _toast(parts.isEmpty ? tr('未导入任何内容') : tr('导入完成：{parts}', {'parts': parts.join('，')}));
      if (result.errors.isNotEmpty && mounted) {
        await showPredictiveDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title:   Text(tr('部分内容导入失败')),
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
                child:   Text(tr('知道了')),
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
      _toast(tr('导入失败：{e}', {'e': e}));
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
                title:   Text(tr('导入应用备份')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (summary.createdAt.isNotEmpty)
                      Text(
                          tr('备份时间：{time}', {'time': summary.createdAt.length >= 19 ? summary.createdAt.substring(0, 19).replaceAll('T', ' ') : summary.createdAt}),
                          style: const TextStyle(fontSize: 12.5)),
                    const SizedBox(height: 6),
                    Text(
                      tr('歌单 {n} 个（{songs} 首）\n', {'n': summary.playlistCount, 'songs': summary.totalSongs}) +
                      tr('收藏 {n} 首、收藏集 {m} 个\n', {'n': summary.favoriteCount, 'm': summary.favoriteCollectionCount}) +
                      tr('插件 {n} 个', {'n': summary.pluginCount}) + (summary.hasSettings ? tr('\n含设置') : ''),
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                      Text(tr('选择导入内容：'), style: TextStyle(fontSize: 12.5)),
                    _backupCheck(tr('歌单'), playlists, summary.playlistCount > 0,
                        (v) => setDialog(() => playlists = v ?? false)),
                    _backupCheck(tr('收藏'), favorites,
                        summary.favoriteCount + summary.favoriteCollectionCount > 0,
                        (v) => setDialog(() => favorites = v ?? false)),
                    _backupCheck(tr('插件'), plugins, summary.pluginCount > 0,
                        (v) => setDialog(() => plugins = v ?? false)),
                    _backupCheck(
                        tr('设置（覆盖当前设置）'),
                        settings,
                        summary.hasSettings,
                        (v) => setDialog(() => settings = v ?? false)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child:   Text(tr('取消')),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(ctx, (playlists, favorites, plugins, settings)),
                    child:   Text(tr('导入')),
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
          title:   Text(tr('导出应用备份')),
          subtitle:   Text(tr('歌单、收藏、插件、设置备份为 JSON 并分享')),
          trailing: trailing,
          onTap: _busy ? null : _exportBackup,
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore_outlined),
          title:   Text(tr('导入应用备份')),
          subtitle:   Text(tr('从备份文件恢复（支持选择导入内容）')),
          trailing: trailing,
          onTap: _busy ? null : _importBackup,
        ),
      ],
    );
  }
}
