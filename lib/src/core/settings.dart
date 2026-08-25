import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../lyrics/lyric_font.dart';

/// 主题模式
enum ThemeModePreference {
  system,
  light,
  dark,
}

/// 底栏/导航条显示位置（底部 / 侧边）
enum NavBarPosition {
  bottom,
  side,
}

/// 侧边栏展开方向（向下 / 向上）
enum SideBarExpandDirection {
  down,
  up,
}

/// 性能模式：auto 自动按设备强弱判断 / full 满特效 / performance 性能优先（降级动效）。
enum PerformanceMode {
  auto,
  full,
  performance,
}

/// 播放页样式：advanced 高级模式（默认，现代毛玻璃）/ traditional 传统模式（经典 QQ 音乐式）。
enum PlayerStyle {
  advanced,
  traditional,
}

/// 判断是否应开启「动效降级」（性能模式生效）。
/// 自动档按 CPU 核心数粗判，单核偏弱设备自动降级；手动档直接覆盖。
bool performancePriority(AppSettings s) => switch (s.performanceMode) {
      PerformanceMode.full => false,
      PerformanceMode.performance => true,
      PerformanceMode.auto =>
        // 低核设备（≤4）默认走性能优先；更高核设备保留满特效。
        (Platform.numberOfProcessors <= 4),
    };

/// 应用界面语言（system 跟随系统，zhCN 简体，zhTW 繁体，en 英文）。
enum AppLanguage {
  system,
  zhCN,
  zhTW,
  en,
}

/// 列表项尺寸：最小(compact) / 中等(medium，默认) / 最大(large)。
enum ListSize {
  compact,
  medium,
  large;
}

/// 支持的扫描格式大类（与 Rust is_ext_allowed 对应）。
const kSupportedScanFormats = ['flac', 'mp3', 'wav', 'aac', 'm4a', 'ogg', 'aiff', 'dsf', 'dff'];

/// 全局设置（小而美：仅移动端必需项，key 语义与桌面端一致）。
class AppSettings {
  const AppSettings({
    this.volume = 1.0,
    this.playMode = 0, // 0 顺序(列表循环) 1 单曲循环 2 随机
    this.lastTab = 0,
    this.keepScreenOn = true,
    this.themeMode = ThemeModePreference.system,
    this.accentColor = 0xFFEC4141,
    this.showQualityBadges = true,
    this.onlineDefaultQuality = '320k',
    this.libraryMinDurationSeconds = 0,
    this.showLyricsTranslation = true,
    this.enableWordEffect = true,
    this.downloadPath = '',
    this.downloadQuality = '320k',
    this.downloadLyrics = false,
    this.downloadConcurrency = 3,
    this.overwriteExisting = false,
    this.downloadFileNameStyle = 'artist-title',
    this.embedDownloadMetadata = true,
    this.embedDownloadLyrics = true,
    this.embedDownloadCover = true,
    this.organizeRule = '{Artist}/{Album}/{Title}',
    this.lyricFontSize = 1,
    this.lyricOffsetMs = 0,
    this.showLyricsRomaji = false,
    this.lyricFontName = '',
    this.lyricFontPath = '',
    this.liquidGlass = false,
    this.playerLiquidGlass = false,
    this.frostedGlass = false,
    this.performanceMode = PerformanceMode.auto,
    this.hapticStrength = 1,
    this.streamCacheSizeMB = 500,
    this.scanFormats = kSupportedScanFormats,
    this.floatingNavBar = false,
    this.navBarPosition = NavBarPosition.bottom,
    this.sideBarExpandDirection = SideBarExpandDirection.down,
    this.usbExclusiveOutput = false,
    this.dsdNativePassthrough = false,
    this.volumeBalanceEnabled = false,
    this.volumeBalanceGainOffsetDb = 0,
    this.volumeBalancePreventClipping = true,
    this.onlineFailureBehavior = 'skip',
    this.onlineQualityFallbackBehavior = 'lower',
    this.autoSwitchSourceOnFailure = false,
    this.usbExclusiveDeviceId = -1,
    this.songClickAction = 'single',
    this.enablePredictiveBack = true,
    this.language = AppLanguage.system,
    this.listSize = ListSize.medium,
    // 分享链接有效时长（分钟）：5~24*60，默认 2 小时。
    this.shareLinkValidityMinutes = 120,
    // 分享链接播放失败行为：pause 暂停播放 / replace 替换播放（走插件索引）。
    this.sharePlaybackFailureBehavior = 'pause',
    // 播放页样式：traditional 传统模式（默认）/ advanced 高级模式。
    this.playerStyle = PlayerStyle.traditional,
    // 悬浮歌词窗（移植自 RawS-Music 外部歌词体系）。
    this.floatingLyricsEnabled = false,
    this.floatingLyricsLocked = false,
    this.floatingLyricsTextColor = 0xFFFFFFFF,
    this.floatingLyricsOpacity = 100,
    this.floatingLyricsFontScale = 100,
    this.floatingLyricsSecondaryScale = 88,
    this.floatingLyricsShowTranslation = true,
    this.floatingLyricsShowRomanization = false,
    this.floatingLyricsShowBackground = true,
    this.floatingLyricsHideWhenPaused = false,
    this.floatingLyricsHideInLandscape = false,
    this.floatingLyricsWidthPercent = 92,
    this.floatingLyricsUseLyricFont = false,
    this.floatingLyricsX = 0,
    this.floatingLyricsY = 96,
  });

  final double volume;
  final int playMode;
  final int lastTab;
  final bool keepScreenOn;
  final ThemeModePreference themeMode;
  final int accentColor;
  final bool showQualityBadges;
  final String onlineDefaultQuality;
  final int libraryMinDurationSeconds;
  final bool showLyricsTranslation;

  /// 歌词显示罗马音（音源提供 romaji 时使用）。
  final bool showLyricsRomaji;

  /// 自定义歌词字体名（FontLoader 注册后的 family，空则用系统字体）。
  final String lyricFontName;

  /// 自定义歌词字体文件路径（用于卸载/重新加载）。
  final String lyricFontPath;

  final bool enableWordEffect;
  final String downloadPath;
  final String downloadQuality;
  final bool downloadLyrics;

  /// 批量下载同时进行数（1-5），超出部分排队等待。
  final int downloadConcurrency;

  /// 同名目标文件已存在时是否覆盖（否则自动追加序号改名）。
  final bool overwriteExisting;

  /// 下载文件名样式：artist-title / title-artist / title-artist-album。
  final String downloadFileNameStyle;

  /// 下载后是否把标题/歌手/专辑等元数据写入音频文件 tag。
  final bool embedDownloadMetadata;

  /// 下载后是否把歌词嵌入音频文件 tag（需同时开启下载歌词）。
  final bool embedDownloadLyrics;

  /// 下载后是否把封面嵌入音频文件 tag。
  final bool embedDownloadCover;

  final String organizeRule;
  final int lyricFontSize;
  final int lyricOffsetMs;
  final bool liquidGlass;
  final bool playerLiquidGlass;

  /// 安卓原生毛玻璃材质：顶栏与固定底栏使用 BackdropFilter 高斯模糊磨砂。false 时回退纯色。
  final bool frostedGlass;
  /// 性能模式：auto 自动 / full 满特效 / performance 性能优先。决定动效是否降级。
  final PerformanceMode performanceMode;
  /// 触觉反馈力度：0=轻，1=正常，2=重。
  final int hapticStrength;
  /// 在线播放流式缓存上限（MB）。
  final int streamCacheSizeMB;

  final List<String> scanFormats;

  /// 底栏样式：true 为悬浮毛玻璃胶囊，false 为固定式底栏。
  final bool floatingNavBar;

  /// 导航条位置：bottom 底部，side 侧边（选择侧边时悬浮底栏与液态玻璃关闭/禁用）。
  final NavBarPosition navBarPosition;

  /// 侧边栏展开方向：down 向下展开，up 向上展开。仅在侧边栏模式生效。
  final SideBarExpandDirection sideBarExpandDirection;

  /// USB 独占输出（AAudio exclusive，bit-perfect 直达 USB DAC）。
  /// 仅本地音乐生效；在线歌曲与失败场景自动回退普通播放。
  final bool usbExclusiveOutput;

  /// DSD 原生直出（DoP 打包，bit-perfect 直达 DSD-DAC）。
  /// 开启后 dsf/dff 本地文件在播放态走 AAudio 独占 I24 独占流，绕过解码器与 DSP。
  final bool dsdNativePassthrough;

  /// 音量平衡（ReplayGain 响度均衡）总开关。
  /// 播放本地/缓存文件时按内置 ReplayGain 标签调整增益，使不同歌曲响度一致。
  final bool volumeBalanceEnabled;

  /// 音量平衡整体增益偏移（dB，-12 ~ 6）。
  final double volumeBalanceGainOffsetDb;

  /// 防削波破音保护：增益可能超出 0 dB 极限时自动压低；无峰值标签的正增益降级为不提升。
  final bool volumeBalancePreventClipping;

  /// 在线歌曲起播失败时的行为：skip 跳到下一首 / stop 停止播放。
  final String onlineFailureBehavior;

  /// 在线歌曲默认音质播放失败时的音质回退：
  /// pause 严格不回退 / lower 向下降级 / higher 向上升级。
  final String onlineQualityFallbackBehavior;

  /// 在线播放失败时自动切换其他落雪音源播放同一首歌（仅在线歌曲生效）。
  final bool autoSwitchSourceOnFailure;

  /// USB 独占输出所选目标设备 ID（AAudio setDeviceId）。-1 = 系统默认设备。
  final int usbExclusiveDeviceId;

  /// 歌曲播放触发方式：single 单击播放 / double 双击播放。
  final String songClickAction;

  /// 是否启用安卓系统预测返回动画（Android 13+ 手势导航下生效）。
  final bool enablePredictiveBack;

  /// 应用界面语言。
  final AppLanguage language;

  /// 歌曲/歌手/专辑/歌单列表项尺寸。
  final ListSize listSize;

  /// 分享链接有效时长（分钟）：分享到服务端后过期丢弃，范围 5~24*60，默认 120（2 小时）。
  final int shareLinkValidityMinutes;

  /// 分享链接播放失败行为：pause 暂停播放（默认）/ replace 替换播放（走客户端插件索引换源重播）。
  final String sharePlaybackFailureBehavior;

  /// 播放页样式：advanced 高级模式（现代毛玻璃）/ traditional 传统模式（经典布局）。
  final PlayerStyle playerStyle;

  /// 悬浮歌词窗总开关。
  final bool floatingLyricsEnabled;

  /// 悬浮歌词窗锁定（不可拖动，通知解锁）。
  final bool floatingLyricsLocked;

  /// 悬浮歌词文字颜色（ARGB）。
  final int floatingLyricsTextColor;

  /// 悬浮歌词不透明度（0-100）。
  final int floatingLyricsOpacity;

  /// 悬浮歌词主文字字号百分比（100 = 默认）。
  final int floatingLyricsFontScale;

  /// 悬浮歌词副行（翻译/罗马音/背景）字号百分比。
  final int floatingLyricsSecondaryScale;

  /// 悬浮歌词显示翻译。
  final bool floatingLyricsShowTranslation;

  /// 悬浮歌词显示罗马音。
  final bool floatingLyricsShowRomanization;

  /// 悬浮歌词显示背景/副歌歌词。
  final bool floatingLyricsShowBackground;

  /// 暂停时隐藏悬浮歌词窗。
  final bool floatingLyricsHideWhenPaused;

  /// 横屏时隐藏悬浮歌词窗。
  final bool floatingLyricsHideInLandscape;

  /// 悬浮歌词窗宽度占屏百分比（40-100）。
  final int floatingLyricsWidthPercent;

  /// 悬浮歌词窗使用自定义歌词字体。
  final bool floatingLyricsUseLyricFont;

  /// 悬浮歌词窗位置 X。
  final int floatingLyricsX;

  /// 悬浮歌词窗位置 Y。
  final int floatingLyricsY;

  AppSettings copyWith({
    double? volume,
    int? playMode,
    int? lastTab,
    bool? keepScreenOn,
    ThemeModePreference? themeMode,
    int? accentColor,
    bool? showQualityBadges,
    String? onlineDefaultQuality,
    int? libraryMinDurationSeconds,
    bool? showLyricsTranslation,
    bool? showLyricsRomaji,
    String? lyricFontName,
    String? lyricFontPath,
    bool? enableWordEffect,
    String? downloadPath,
    String? downloadQuality,
    bool? downloadLyrics,
    int? downloadConcurrency,
    bool? overwriteExisting,
    String? downloadFileNameStyle,
    bool? embedDownloadMetadata,
    bool? embedDownloadLyrics,
    bool? embedDownloadCover,
    String? organizeRule,
    int? lyricFontSize,
    int? lyricOffsetMs,
    bool? liquidGlass,
    bool? playerLiquidGlass,
    bool? frostedGlass,
    PerformanceMode? performanceMode,
    int? hapticStrength,
    int? streamCacheSizeMB,
    List<String>? scanFormats,
    bool? floatingNavBar,
    NavBarPosition? navBarPosition,
    SideBarExpandDirection? sideBarExpandDirection,
    bool? usbExclusiveOutput,
    bool? dsdNativePassthrough,
    bool? volumeBalanceEnabled,
    double? volumeBalanceGainOffsetDb,
    bool? volumeBalancePreventClipping,
    String? onlineFailureBehavior,
    String? onlineQualityFallbackBehavior,
    bool? autoSwitchSourceOnFailure,
    int? usbExclusiveDeviceId,
    String? songClickAction,
    bool? enablePredictiveBack,
    AppLanguage? language,
    ListSize? listSize,
    int? shareLinkValidityMinutes,
    String? sharePlaybackFailureBehavior,
    PlayerStyle? playerStyle,
    bool? floatingLyricsEnabled,
    bool? floatingLyricsLocked,
    int? floatingLyricsTextColor,
    int? floatingLyricsOpacity,
    int? floatingLyricsFontScale,
    int? floatingLyricsSecondaryScale,
    bool? floatingLyricsShowTranslation,
    bool? floatingLyricsShowRomanization,
    bool? floatingLyricsShowBackground,
    bool? floatingLyricsHideWhenPaused,
    bool? floatingLyricsHideInLandscape,
    int? floatingLyricsWidthPercent,
    bool? floatingLyricsUseLyricFont,
    int? floatingLyricsX,
    int? floatingLyricsY,
  }) {
    return AppSettings(
      volume: volume ?? this.volume,
      playMode: playMode ?? this.playMode,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      showQualityBadges: showQualityBadges ?? this.showQualityBadges,
      onlineDefaultQuality: onlineDefaultQuality ?? this.onlineDefaultQuality,
      libraryMinDurationSeconds:
          libraryMinDurationSeconds ?? this.libraryMinDurationSeconds,
      showLyricsTranslation:
          showLyricsTranslation ?? this.showLyricsTranslation,
      showLyricsRomaji: showLyricsRomaji ?? this.showLyricsRomaji,
      lyricFontName: lyricFontName ?? this.lyricFontName,
      lyricFontPath: lyricFontPath ?? this.lyricFontPath,
      enableWordEffect: enableWordEffect ?? this.enableWordEffect,
      downloadPath: downloadPath ?? this.downloadPath,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      downloadLyrics: downloadLyrics ?? this.downloadLyrics,
      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
      overwriteExisting: overwriteExisting ?? this.overwriteExisting,
      downloadFileNameStyle:
          downloadFileNameStyle ?? this.downloadFileNameStyle,
      embedDownloadMetadata:
          embedDownloadMetadata ?? this.embedDownloadMetadata,
      embedDownloadLyrics: embedDownloadLyrics ?? this.embedDownloadLyrics,
      embedDownloadCover: embedDownloadCover ?? this.embedDownloadCover,
      organizeRule: organizeRule ?? this.organizeRule,
      lyricFontSize: lyricFontSize ?? this.lyricFontSize,
      lyricOffsetMs: lyricOffsetMs ?? this.lyricOffsetMs,
      liquidGlass: liquidGlass ?? this.liquidGlass,
      playerLiquidGlass: playerLiquidGlass ?? this.playerLiquidGlass,
      frostedGlass: frostedGlass ?? this.frostedGlass,
      performanceMode: performanceMode ?? this.performanceMode,
      hapticStrength: hapticStrength ?? this.hapticStrength,
      streamCacheSizeMB: streamCacheSizeMB ?? this.streamCacheSizeMB,
      scanFormats: scanFormats ?? this.scanFormats,
      floatingNavBar: floatingNavBar ?? this.floatingNavBar,
      navBarPosition: navBarPosition ?? this.navBarPosition,
      sideBarExpandDirection:
          sideBarExpandDirection ?? this.sideBarExpandDirection,
      usbExclusiveOutput: usbExclusiveOutput ?? this.usbExclusiveOutput,
      dsdNativePassthrough:
          dsdNativePassthrough ?? this.dsdNativePassthrough,
      volumeBalanceEnabled: volumeBalanceEnabled ?? this.volumeBalanceEnabled,
      volumeBalanceGainOffsetDb:
          volumeBalanceGainOffsetDb ?? this.volumeBalanceGainOffsetDb,
      volumeBalancePreventClipping:
          volumeBalancePreventClipping ?? this.volumeBalancePreventClipping,
      onlineFailureBehavior:
          onlineFailureBehavior ?? this.onlineFailureBehavior,
      onlineQualityFallbackBehavior:
          onlineQualityFallbackBehavior ?? this.onlineQualityFallbackBehavior,
      autoSwitchSourceOnFailure:
          autoSwitchSourceOnFailure ?? this.autoSwitchSourceOnFailure,
      usbExclusiveDeviceId: usbExclusiveDeviceId ?? this.usbExclusiveDeviceId,
      songClickAction: songClickAction ?? this.songClickAction,
      enablePredictiveBack: enablePredictiveBack ?? this.enablePredictiveBack,
      language: language ?? this.language,
      listSize: listSize ?? this.listSize,
      shareLinkValidityMinutes:
          shareLinkValidityMinutes ?? this.shareLinkValidityMinutes,
      sharePlaybackFailureBehavior:
          sharePlaybackFailureBehavior ?? this.sharePlaybackFailureBehavior,
      playerStyle: playerStyle ?? this.playerStyle,
      floatingLyricsEnabled:
          floatingLyricsEnabled ?? this.floatingLyricsEnabled,
      floatingLyricsLocked: floatingLyricsLocked ?? this.floatingLyricsLocked,
      floatingLyricsTextColor:
          floatingLyricsTextColor ?? this.floatingLyricsTextColor,
      floatingLyricsOpacity:
          floatingLyricsOpacity ?? this.floatingLyricsOpacity,
      floatingLyricsFontScale:
          floatingLyricsFontScale ?? this.floatingLyricsFontScale,
      floatingLyricsSecondaryScale:
          floatingLyricsSecondaryScale ?? this.floatingLyricsSecondaryScale,
      floatingLyricsShowTranslation:
          floatingLyricsShowTranslation ?? this.floatingLyricsShowTranslation,
      floatingLyricsShowRomanization:
          floatingLyricsShowRomanization ?? this.floatingLyricsShowRomanization,
      floatingLyricsShowBackground:
          floatingLyricsShowBackground ?? this.floatingLyricsShowBackground,
      floatingLyricsHideWhenPaused:
          floatingLyricsHideWhenPaused ?? this.floatingLyricsHideWhenPaused,
      floatingLyricsHideInLandscape:
          floatingLyricsHideInLandscape ?? this.floatingLyricsHideInLandscape,
      floatingLyricsWidthPercent:
          floatingLyricsWidthPercent ?? this.floatingLyricsWidthPercent,
      floatingLyricsUseLyricFont:
          floatingLyricsUseLyricFont ?? this.floatingLyricsUseLyricFont,
      floatingLyricsX: floatingLyricsX ?? this.floatingLyricsX,
      floatingLyricsY: floatingLyricsY ?? this.floatingLyricsY,
    );
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await _prefs();
    // 启动时重新注册已保存的自定义歌词字体（fire-and-forget，失败静默）。
    final savedName = prefs.getString('lyricFontName') ?? '';
    final savedPath = prefs.getString('lyricFontPath') ?? '';
    unawaited(LyricFontManager.loadSavedFont(savedName, savedPath));
    // 液态玻璃 与 毛玻璃材质 二选一（互斥）：毛玻璃（顶栏+底栏高斯模糊）优先。
    final liquidGlass = prefs.getBool('liquidGlass') ?? false;
    final frostedGlass =
        (prefs.getBool('frostedGlass') ?? false) && !liquidGlass;

    return AppSettings(
      volume: prefs.getDouble('volume') ?? 1.0,
      playMode: prefs.getInt('playMode') ?? 0,
      lastTab: prefs.getInt('lastTab') ?? 0,
      keepScreenOn: prefs.getBool('keepScreenOn') ?? true,
      themeMode: _themeFromInt(prefs.getInt('themeMode') ?? 0),
      accentColor: prefs.getInt('accentColor') ?? 0xFFEC4141,
      showQualityBadges: prefs.getBool('showQualityBadges') ?? true,
      onlineDefaultQuality:
          prefs.getString('onlineDefaultQuality') ?? '320k',
      libraryMinDurationSeconds:
          prefs.getInt('libraryMinDurationSeconds') ?? 0,
      showLyricsTranslation:
          prefs.getBool('showLyricsTranslation') ?? true,
      showLyricsRomaji: prefs.getBool('showLyricsRomaji') ?? false,
      lyricFontName: prefs.getString('lyricFontName') ?? '',
      lyricFontPath: prefs.getString('lyricFontPath') ?? '',
      enableWordEffect: prefs.getBool('enableWordEffect') ?? true,
      downloadPath: prefs.getString('downloadPath') ?? '',
      downloadQuality: prefs.getString('downloadQuality') ?? '320k',
      downloadLyrics: prefs.getBool('downloadLyrics') ?? false,
      downloadConcurrency: prefs.getInt('downloadConcurrency') ?? 3,
      overwriteExisting: prefs.getBool('overwriteExisting') ?? false,
      downloadFileNameStyle:
          prefs.getString('downloadFileNameStyle') ?? 'artist-title',
      embedDownloadMetadata:
          prefs.getBool('embedDownloadMetadata') ?? true,
      embedDownloadLyrics: prefs.getBool('embedDownloadLyrics') ?? true,
      embedDownloadCover: prefs.getBool('embedDownloadCover') ?? true,
      organizeRule: prefs.getString('organizeRule') ?? '{Artist}/{Album}/{Title}',
      lyricFontSize: prefs.getInt('lyricFontSize') ?? 1,
      lyricOffsetMs: prefs.getInt('lyricOffsetMs') ?? 0,
      liquidGlass: liquidGlass,
      playerLiquidGlass: prefs.getBool('playerLiquidGlass') ?? false,
      frostedGlass: frostedGlass,
      performanceMode: _perfFromString(prefs.getString('performanceMode') ?? 'auto'),
      hapticStrength: prefs.getInt('hapticStrength') ?? 1,
      streamCacheSizeMB: prefs.getInt('streamCacheSizeMB') ?? 500,
      scanFormats: prefs.getStringList('scanFormats') ?? kSupportedScanFormats,
      floatingNavBar: prefs.getBool('floatingNavBar') ?? false,
      navBarPosition:
          (prefs.getString('navBarPosition') ?? 'bottom') == 'side'
              ? NavBarPosition.side
              : NavBarPosition.bottom,
      sideBarExpandDirection:
          (prefs.getString('sideBarExpandDirection') ?? 'down') == 'up'
              ? SideBarExpandDirection.up
              : SideBarExpandDirection.down,
      usbExclusiveOutput: prefs.getBool('usbExclusiveOutput') ?? false,
      dsdNativePassthrough: prefs.getBool('dsdNativePassthrough') ?? false,
      volumeBalanceEnabled: prefs.getBool('volumeBalanceEnabled') ?? false,
      volumeBalanceGainOffsetDb:
          prefs.getDouble('volumeBalanceGainOffsetDb') ?? 0,
      volumeBalancePreventClipping:
          prefs.getBool('volumeBalancePreventClipping') ?? true,
      onlineFailureBehavior:
          prefs.getString('onlineFailureBehavior') ?? 'skip',
      onlineQualityFallbackBehavior:
          prefs.getString('onlineQualityFallbackBehavior') ?? 'lower',
      autoSwitchSourceOnFailure:
          prefs.getBool('autoSwitchSourceOnFailure') ?? false,
      usbExclusiveDeviceId: prefs.getInt('usbExclusiveDeviceId') ?? -1,
      songClickAction: prefs.getString('songClickAction') ?? 'single',
      enablePredictiveBack: prefs.getBool('enablePredictiveBack') ?? true,
      language: _langFromString(prefs.getString('language') ?? 'system'),
      listSize: _listSizeFromString(prefs.getString('listSize') ?? 'medium'),
      shareLinkValidityMinutes:
          prefs.getInt('shareLinkValidityMinutes') ?? 120,
      sharePlaybackFailureBehavior:
          prefs.getString('sharePlaybackFailureBehavior') ?? 'pause',
      playerStyle: _playerStyleFromString(
          prefs.getString('playerStyle') ?? 'traditional'),
      floatingLyricsEnabled:
          prefs.getBool('floatingLyricsEnabled') ?? false,
      floatingLyricsLocked: prefs.getBool('floatingLyricsLocked') ?? false,
      floatingLyricsTextColor:
          prefs.getInt('floatingLyricsTextColor') ?? 0xFFFFFFFF,
      floatingLyricsOpacity: prefs.getInt('floatingLyricsOpacity') ?? 100,
      floatingLyricsFontScale:
          prefs.getInt('floatingLyricsFontScale') ?? 100,
      floatingLyricsSecondaryScale:
          prefs.getInt('floatingLyricsSecondaryScale') ?? 88,
      floatingLyricsShowTranslation:
          prefs.getBool('floatingLyricsShowTranslation') ?? true,
      floatingLyricsShowRomanization:
          prefs.getBool('floatingLyricsShowRomanization') ?? false,
      floatingLyricsShowBackground:
          prefs.getBool('floatingLyricsShowBackground') ?? true,
      floatingLyricsHideWhenPaused:
          prefs.getBool('floatingLyricsHideWhenPaused') ?? false,
      floatingLyricsHideInLandscape:
          prefs.getBool('floatingLyricsHideInLandscape') ?? false,
      floatingLyricsWidthPercent:
          prefs.getInt('floatingLyricsWidthPercent') ?? 92,
      floatingLyricsUseLyricFont:
          prefs.getBool('floatingLyricsUseLyricFont') ?? false,
      floatingLyricsX: prefs.getInt('floatingLyricsX') ?? 0,
      floatingLyricsY: prefs.getInt('floatingLyricsY') ?? 96,
    );
  }

  ListSize _listSizeFromString(String v) => switch (v) {
        'compact' => ListSize.compact,
        'large' => ListSize.large,
        _ => ListSize.medium,
      };

  PlayerStyle _playerStyleFromString(String v) => switch (v) {
        'traditional' => PlayerStyle.traditional,
        _ => PlayerStyle.advanced,
      };

  AppLanguage _langFromString(String v) => switch (v) {
        'zhTW' => AppLanguage.zhTW,
        'en' => AppLanguage.en,
        'zhCN' => AppLanguage.zhCN,
        _ => AppLanguage.system,
      };

  PerformanceMode _perfFromString(String v) => switch (v) {
        'full' => PerformanceMode.full,
        'performance' => PerformanceMode.performance,
        _ => PerformanceMode.auto,
      };

  ThemeModePreference _themeFromInt(int v) {
    switch (v) {
      case 1:
        return ThemeModePreference.light;
      case 2:
        return ThemeModePreference.dark;
      default:
        return ThemeModePreference.system;
    }
  }

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<void> _save(AppSettings next) async {
    state = AsyncData(next);
    final prefs = await _prefs();
    await Future.wait([
      prefs.setDouble('volume', next.volume),
      prefs.setInt('playMode', next.playMode),
      prefs.setInt('lastTab', next.lastTab),
      prefs.setBool('keepScreenOn', next.keepScreenOn),
      prefs.setInt('themeMode', next.themeMode.index),
      prefs.setInt('accentColor', next.accentColor),
      prefs.setBool('showQualityBadges', next.showQualityBadges),
      prefs.setString('onlineDefaultQuality', next.onlineDefaultQuality),
      prefs.setInt(
          'libraryMinDurationSeconds', next.libraryMinDurationSeconds),
      prefs.setBool('showLyricsTranslation', next.showLyricsTranslation),
      prefs.setBool('showLyricsRomaji', next.showLyricsRomaji),
      prefs.setString('lyricFontName', next.lyricFontName),
      prefs.setString('lyricFontPath', next.lyricFontPath),
      prefs.setBool('enableWordEffect', next.enableWordEffect),
      prefs.setString('downloadPath', next.downloadPath),
      prefs.setString('downloadQuality', next.downloadQuality),
      prefs.setBool('downloadLyrics', next.downloadLyrics),
      prefs.setInt('downloadConcurrency', next.downloadConcurrency),
      prefs.setBool('overwriteExisting', next.overwriteExisting),
      prefs.setString(
          'downloadFileNameStyle', next.downloadFileNameStyle),
      prefs.setBool('embedDownloadMetadata', next.embedDownloadMetadata),
      prefs.setBool('embedDownloadLyrics', next.embedDownloadLyrics),
      prefs.setBool('embedDownloadCover', next.embedDownloadCover),
      prefs.setString('organizeRule', next.organizeRule),
      prefs.setInt('lyricFontSize', next.lyricFontSize),
      prefs.setInt('lyricOffsetMs', next.lyricOffsetMs),
      prefs.setBool('liquidGlass', next.liquidGlass),
      prefs.setBool('playerLiquidGlass', next.playerLiquidGlass),
      prefs.setBool('frostedGlass', next.frostedGlass),
      prefs.setString('performanceMode', next.performanceMode.name),
      prefs.setInt('hapticStrength', next.hapticStrength),
      prefs.setInt('streamCacheSizeMB', next.streamCacheSizeMB),
      prefs.setStringList('scanFormats', next.scanFormats),
      prefs.setBool('floatingNavBar', next.floatingNavBar),
      prefs.setString('navBarPosition', next.navBarPosition.name),
      prefs.setString(
          'sideBarExpandDirection', next.sideBarExpandDirection.name),
      prefs.setBool('usbExclusiveOutput', next.usbExclusiveOutput),
      prefs.setBool('dsdNativePassthrough', next.dsdNativePassthrough),
      prefs.setBool('volumeBalanceEnabled', next.volumeBalanceEnabled),
      prefs.setDouble('volumeBalanceGainOffsetDb', next.volumeBalanceGainOffsetDb),
      prefs.setBool('volumeBalancePreventClipping', next.volumeBalancePreventClipping),
      prefs.setString('onlineFailureBehavior', next.onlineFailureBehavior),
      prefs.setString('onlineQualityFallbackBehavior', next.onlineQualityFallbackBehavior),
      prefs.setBool('autoSwitchSourceOnFailure', next.autoSwitchSourceOnFailure),
      prefs.setInt('usbExclusiveDeviceId', next.usbExclusiveDeviceId),
      prefs.setString('songClickAction', next.songClickAction),
      prefs.setBool('enablePredictiveBack', next.enablePredictiveBack),
      prefs.setString('language', next.language.name),
      prefs.setString('listSize', next.listSize.name),
      prefs.setInt('shareLinkValidityMinutes', next.shareLinkValidityMinutes),
      prefs.setString(
          'sharePlaybackFailureBehavior', next.sharePlaybackFailureBehavior),
      prefs.setString('playerStyle', next.playerStyle.name),
      prefs.setBool('floatingLyricsEnabled', next.floatingLyricsEnabled),
      prefs.setBool('floatingLyricsLocked', next.floatingLyricsLocked),
      prefs.setInt('floatingLyricsTextColor', next.floatingLyricsTextColor),
      prefs.setInt('floatingLyricsOpacity', next.floatingLyricsOpacity),
      prefs.setInt('floatingLyricsFontScale', next.floatingLyricsFontScale),
      prefs.setInt(
          'floatingLyricsSecondaryScale', next.floatingLyricsSecondaryScale),
      prefs.setBool(
          'floatingLyricsShowTranslation', next.floatingLyricsShowTranslation),
      prefs.setBool(
          'floatingLyricsShowRomanization', next.floatingLyricsShowRomanization),
      prefs.setBool(
          'floatingLyricsShowBackground', next.floatingLyricsShowBackground),
      prefs.setBool(
          'floatingLyricsHideWhenPaused', next.floatingLyricsHideWhenPaused),
      prefs.setBool(
          'floatingLyricsHideInLandscape', next.floatingLyricsHideInLandscape),
      prefs.setInt('floatingLyricsWidthPercent', next.floatingLyricsWidthPercent),
      prefs.setBool('floatingLyricsUseLyricFont', next.floatingLyricsUseLyricFont),
      prefs.setInt('floatingLyricsX', next.floatingLyricsX),
      prefs.setInt('floatingLyricsY', next.floatingLyricsY),
    ]);
  }

  Future<void> setVolume(double v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volume: v));
  Future<void> setPlayMode(int m) => _save((state.valueOrNull ?? const AppSettings()).copyWith(playMode: m));
  Future<void> setLastTab(int t) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lastTab: t));
  Future<void> setKeepScreenOn(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(keepScreenOn: v));
  Future<void> setEnablePredictiveBack(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(enablePredictiveBack: v));
  Future<void> setThemeMode(ThemeModePreference m) => _save((state.valueOrNull ?? const AppSettings()).copyWith(themeMode: m));
  Future<void> setAccentColor(int c) => _save((state.valueOrNull ?? const AppSettings()).copyWith(accentColor: c));
  Future<void> setShowQualityBadges(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(showQualityBadges: v));
  Future<void> setOnlineDefaultQuality(String q) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineDefaultQuality: q));
  Future<void> setLibraryMinDurationSeconds(int s) => _save((state.valueOrNull ?? const AppSettings()).copyWith(libraryMinDurationSeconds: s));
  Future<void> setShowLyricsTranslation(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(showLyricsTranslation: v));
  Future<void> setShowLyricsRomaji(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(showLyricsRomaji: v));
  Future<void> setLyricFontName(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricFontName: v));
  Future<void> setLyricFontPath(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricFontPath: v));
  Future<void> setEnableWordEffect(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(enableWordEffect: v));
  Future<void> setDownloadPath(String p) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadPath: p));
  Future<void> setDownloadQuality(String q) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadQuality: q));
  Future<void> setDownloadLyrics(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadLyrics: v));
  Future<void> setDownloadConcurrency(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadConcurrency: v));
  Future<void> setOverwriteExisting(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(overwriteExisting: v));
  Future<void> setDownloadFileNameStyle(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadFileNameStyle: v));
  Future<void> setEmbedDownloadMetadata(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(embedDownloadMetadata: v));
  Future<void> setEmbedDownloadLyrics(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(embedDownloadLyrics: v));
  Future<void> setEmbedDownloadCover(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(embedDownloadCover: v));
  Future<void> setOrganizeRule(String r) => _save((state.valueOrNull ?? const AppSettings()).copyWith(organizeRule: r));
  Future<void> setLyricFontSize(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricFontSize: v));
  Future<void> setLyricOffsetMs(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricOffsetMs: v));
  Future<void> setLiquidGlass(bool v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(liquidGlass: v, frostedGlass: v ? false : null));
  Future<void> setFrostedGlass(bool v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(frostedGlass: v, liquidGlass: v ? false : null));
  Future<void> setPlayerLiquidGlass(bool v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(playerLiquidGlass: v));
  Future<void> setPerformanceMode(PerformanceMode m) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(performanceMode: m));
  Future<void> setHapticStrength(int v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(hapticStrength: v));
  Future<void> setStreamCacheSizeMB(int v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(streamCacheSizeMB: v));
  Future<void> setScanFormats(List<String> v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(scanFormats: v));
  Future<void> setFloatingNavBar(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingNavBar: v));
  Future<void> setNavBarPosition(NavBarPosition pos) => _save((state.valueOrNull ?? const AppSettings()).copyWith(navBarPosition: pos));
  Future<void> setSideBarExpandDirection(SideBarExpandDirection dir) => _save((state.valueOrNull ?? const AppSettings()).copyWith(sideBarExpandDirection: dir));
  Future<void> setUsbExclusiveOutput(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(usbExclusiveOutput: v));
  Future<void> setDsdNativePassthrough(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(dsdNativePassthrough: v));
  Future<void> setVolumeBalanceEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalanceEnabled: v));
  Future<void> setVolumeBalanceGainOffsetDb(double v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalanceGainOffsetDb: v));
  Future<void> setVolumeBalancePreventClipping(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalancePreventClipping: v));
  Future<void> setOnlineFailureBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineFailureBehavior: v));
  Future<void> setOnlineQualityFallbackBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineQualityFallbackBehavior: v));
  Future<void> setAutoSwitchSourceOnFailure(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(autoSwitchSourceOnFailure: v));
  Future<void> setUsbExclusiveDeviceId(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(usbExclusiveDeviceId: v));
  Future<void> setSongClickAction(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(songClickAction: v));
  Future<void> setLanguage(AppLanguage v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(language: v));
  Future<void> setListSize(ListSize v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(listSize: v));
  Future<void> setShareLinkValidityMinutes(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(shareLinkValidityMinutes: v));
  Future<void> setSharePlaybackFailureBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(sharePlaybackFailureBehavior: v));
  Future<void> setPlayerStyle(PlayerStyle v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(playerStyle: v));
  Future<void> setFloatingLyricsEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsEnabled: v));
  Future<void> setFloatingLyricsLocked(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsLocked: v));
  Future<void> setFloatingLyricsTextColor(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsTextColor: v));
  Future<void> setFloatingLyricsOpacity(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsOpacity: v));
  Future<void> setFloatingLyricsFontScale(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsFontScale: v));
  Future<void> setFloatingLyricsSecondaryScale(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsSecondaryScale: v));
  Future<void> setFloatingLyricsShowTranslation(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsShowTranslation: v));
  Future<void> setFloatingLyricsShowRomanization(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsShowRomanization: v));
  Future<void> setFloatingLyricsShowBackground(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsShowBackground: v));
  Future<void> setFloatingLyricsHideWhenPaused(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsHideWhenPaused: v));
  Future<void> setFloatingLyricsHideInLandscape(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsHideInLandscape: v));
  Future<void> setFloatingLyricsWidthPercent(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsWidthPercent: v));
  Future<void> setFloatingLyricsUseLyricFont(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsUseLyricFont: v));
  Future<void> setFloatingLyricsPosition(int x, int y) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsX: x, floatingLyricsY: y));

  /// 整体保存（自动同步合并后调用）。
  Future<void> saveAll(AppSettings next) => _save(next);
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);