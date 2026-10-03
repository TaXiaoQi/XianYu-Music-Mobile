import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../lyrics/lyric_font.dart';
part 'settings.methods.dart';

enum ThemeModePreference {
  system,
  light,
  dark,
}

enum NavBarPosition {
  bottom,
  side,
}

enum SideBarExpandDirection {
  down,
  up,
}

enum PageTransitionStyle {
  cover,

  smooth,
}

enum PerformanceMode {
  auto,
  full,
  performance,
}

enum PlayerStyle {
  advanced,
  traditional,
}

enum LiquidGlassQuality {
  low,
  medium,
  high,
}

enum FrostedGlassLevel {
  strongest,
  medium,
  light,
}

bool performancePriority(AppSettings s) => switch (s.performanceMode) {
      PerformanceMode.full => false,
      PerformanceMode.performance => true,
      PerformanceMode.auto =>
        (Platform.numberOfProcessors <= 4),
    };

enum AppLanguage {
  system,
  zhCN,
  zhTW,
  en,
}

enum ListSize {
  compact,
  medium,
  large;
}

enum AppFontSize {
  system(1.0, followsSystem: true),
  small(0.9),
  standard(1.0),
  large(1.1),
  larger(1.25);

  const AppFontSize(this.scale, {this.followsSystem = false});

  final double scale;

  final bool followsSystem;
}

/// 整套 UI 缩放档位值（与 uiScaleIndex 对应：小/标准/大/特大）
const kUiScaleValues = [0.85, 1.0, 1.15, 1.3];

/// 整套 UI 缩放系数：越界档位回退标准
double uiScaleOf(int index) =>
    (index >= 0 && index < kUiScaleValues.length)
        ? kUiScaleValues[index]
        : 1.0;

const kSupportedScanFormats = ['flac', 'mp3', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'aiff', 'dsf', 'dff', 'ape', 'wv', 'qmc'];

List<String> _mergeScanFormats(List<String>? saved) {
  if (saved == null) return kSupportedScanFormats;
  return {...saved, ...kSupportedScanFormats}.toList(growable: false);
}

enum WallpaperTextColor { follow, light, dark }

enum WallpaperMediaType { image, video }

class CustomBackground {
  final bool enabled;
  final String imagePath;
  final WallpaperMediaType mediaType;

  /// 动态图片（实况照）内嵌提取出的视频：非空时 imagePath 为静帧、
  /// mediaType 在 image/video 间切换展示形态（编辑器提供切换 UI）
  final String motionVideoPath;
  final int blur;
  final int opacity;
  final int maskAlpha;
  final int scale;
  final int translateX;
  final int translateY;
  final int landscapeScale;
  final int landscapeTranslateX;
  final int landscapeTranslateY;
  final WallpaperTextColor textMode;
  final int widgetAlpha;

  const CustomBackground({
    this.enabled = false,
    this.imagePath = '',
    this.mediaType = WallpaperMediaType.image,
    this.motionVideoPath = '',
    this.blur = 20,
    this.opacity = 100,
    this.maskAlpha = 40,
    this.scale = 100,
    this.translateX = 0,
    this.translateY = 0,
    this.landscapeScale = 100,
    this.landscapeTranslateX = 0,
    this.landscapeTranslateY = 0,
    this.textMode = WallpaperTextColor.follow,
    this.widgetAlpha = 30,
  });

  static const none = CustomBackground();

  bool get active => enabled && imagePath.isNotEmpty;

  CustomBackground copyWith({
    bool? enabled,
    String? imagePath,
    WallpaperMediaType? mediaType,
    String? motionVideoPath,
    int? blur,
    int? opacity,
    int? maskAlpha,
    int? scale,
    int? translateX,
    int? translateY,
    int? landscapeScale,
    int? landscapeTranslateX,
    int? landscapeTranslateY,
    WallpaperTextColor? textMode,
    int? widgetAlpha,
  }) {
    return CustomBackground(
      enabled: enabled ?? this.enabled,
      imagePath: imagePath ?? this.imagePath,
      mediaType: mediaType ?? this.mediaType,
      motionVideoPath: motionVideoPath ?? this.motionVideoPath,
      blur: blur ?? this.blur,
      opacity: opacity ?? this.opacity,
      maskAlpha: maskAlpha ?? this.maskAlpha,
      scale: scale ?? this.scale,
      translateX: translateX ?? this.translateX,
      translateY: translateY ?? this.translateY,
      landscapeScale: landscapeScale ?? this.landscapeScale,
      landscapeTranslateX:
          landscapeTranslateX ?? this.landscapeTranslateX,
      landscapeTranslateY:
          landscapeTranslateY ?? this.landscapeTranslateY,
      textMode: textMode ?? this.textMode,
      widgetAlpha: widgetAlpha ?? this.widgetAlpha,
    );
  }
}

class AppSettings {
  const AppSettings({
    this.volume = 1.0,
    this.playMode = 0,
    this.lastTab = 0,
    this.keepScreenOn = true,
    this.themeMode = ThemeModePreference.system,
    this.accentColor = 0xFFEC4141,
    this.customBackground = CustomBackground.none,
    this.showQualityBadges = true,
    this.enableScrollToTopButton = true,
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
    this.downloadBehavior = 'default',
    this.downloadQualityFallbackBehavior = 'lower',
    this.onlineDefaultMvQuality = '720p',
    this.onlineMvQualityFallbackBehavior = 'lower',
    this.downloadMvQuality = '720p',
    this.downloadMvQualityFallbackBehavior = 'lower',
    this.keepSourceFilename = false,
    this.downloadLyricsFormat = 'lrc',
    this.downloadLyricsStyle = 'word-by-word',
    this.organizeRule = '{Artist}/{Album}/{Title}',
    this.lyricFontSize = 1,
    this.lyricOffsetMs = 0,
    this.showLyricsRomaji = false,
    this.lyricAlignment = 'center',
    this.lyricFontName = '',
    this.lyricFontPath = '',
    this.liquidGlass = false,
    this.playerLiquidGlass = false,
    this.frostedGlass = false,
    this.frostedGlassLevel = FrostedGlassLevel.light,
    this.liquidGlassQuality = LiquidGlassQuality.medium,
    this.performanceMode = PerformanceMode.auto,
    this.hapticStrength = 1,
    this.updateCheckMode = 'startup',
    this.streamCacheSizeMB = 500,
    this.scanFormats = kSupportedScanFormats,
    this.floatingNavBar = false,
    this.floatingSearchBar = false,
    this.navBarPosition = NavBarPosition.bottom,
    this.pageTransitionStyle = PageTransitionStyle.cover,
    this.landscapeTransitionEnabled = true,
    this.sideBarExpandDirection = SideBarExpandDirection.down,
    this.usbExclusiveOutput = false,
    this.bitPerfectOutput = false,
    this.dsdNativePassthrough = false,
    this.skipSilenceEnabled = false,
    this.skipSilenceThresholdDb = -45.0,
    this.skipSilenceKeepMs = 500,
    this.gaplessEnabled = true,
    this.crossfadeEnabled = false,
    this.crossfadeSeconds = 5,
    this.volumeBalanceEnabled = false,
    this.volumeBalanceGainOffsetDb = 0,
    this.volumeBalancePreventClipping = true,
    this.autoResumeAfterInterruption = true,
    this.onlineFailureBehavior = 'pause',
    this.onlineQualityFallbackBehavior = 'lower',
    this.usbExclusiveDeviceId = -1,
    this.songClickAction = 'single',
    this.enablePredictiveBack = false,
    this.language = AppLanguage.system,
    this.listSize = ListSize.medium,
    this.fontSize = AppFontSize.system,
    this.uiScaleIndex = 1,
    this.shareLinkValidityMinutes = 120,
    this.sharePlaybackFailureBehavior = 'pause',
    this.playerStyle = PlayerStyle.traditional,
    this.landscapeAutoHideChrome = true,
    this.landscapeTapToHideChrome = true,
    this.floatingLyricsEnabled = false,
    this.floatingLyricsLocked = false,
    this.floatingLyricsTextColor = 0xFFFFFFFF,
    // 0 = 跟随主色（未播放部分按主色降低透明度渲染，即历史行为）
    this.floatingLyricsUnplayedColor = 0,
    this.floatingLyricsOpacity = 100,
    this.floatingLyricsFontScale = 100,
    this.floatingLyricsSecondaryScale = 88,
    this.floatingLyricsShowTranslation = true,
    this.floatingLyricsShowRomanization = false,
    this.floatingLyricsShowBackground = true,
    this.floatingLyricsHideWhenPaused = false,
    this.floatingLyricsHideInLandscape = false,
    this.landscapeCameraArea = true,
    this.floatingLyricsWidthPercent = 92,
    this.floatingLyricsUseLyricFont = false,
    this.statusBarLyricsEnabled = false,
    this.floatingLyricsX = 0,
    this.floatingLyricsY = 96,
    this.watchLinkageEnabled = true,
    this.watchLinkTransferMode = 'ask',
    this.watchLinkAutoTransfer = false,
    this.watchLinkAskDate = '',
    this.watchLinkAskGranted = false,
    this.watchLinkCloudEnabled = true,
    this.watchLinkCloudKey = '',
    this.dlnaRendererEnabled = false,
    this.dlnaRendererName = '',
    this.showRealSourceName = false,
  });

  final double volume;
  final int playMode;
  final int lastTab;
  final bool keepScreenOn;
  final ThemeModePreference themeMode;
  final int accentColor;
  final CustomBackground customBackground;
  final bool showQualityBadges;

  final bool enableScrollToTopButton;
  final String onlineDefaultQuality;
  final int libraryMinDurationSeconds;
  final bool showLyricsTranslation;

  final bool showLyricsRomaji;

  final String lyricFontName;

  final String lyricFontPath;

  final bool enableWordEffect;
  final String downloadPath;
  final String downloadQuality;
  final bool downloadLyrics;

  final int downloadConcurrency;

  final bool overwriteExisting;

  final String downloadFileNameStyle;

  final bool embedDownloadMetadata;

  final bool embedDownloadLyrics;

  final bool embedDownloadCover;

  final String downloadBehavior;

  final String downloadQualityFallbackBehavior;

  final String onlineDefaultMvQuality;

  final String onlineMvQualityFallbackBehavior;

  final String downloadMvQuality;

  final String downloadMvQualityFallbackBehavior;

  final bool keepSourceFilename;

  final String downloadLyricsFormat;

  final String downloadLyricsStyle;

  final String organizeRule;
  final int lyricFontSize;
  final int lyricOffsetMs;

  final String lyricAlignment;
  final bool liquidGlass;
  final bool playerLiquidGlass;

  final bool frostedGlass;

  final FrostedGlassLevel frostedGlassLevel;

  final LiquidGlassQuality liquidGlassQuality;

  final PerformanceMode performanceMode;
  final int hapticStrength;
  final String updateCheckMode;
  final int streamCacheSizeMB;

  final List<String> scanFormats;

  final bool floatingNavBar;

  final bool floatingSearchBar;

  final NavBarPosition navBarPosition;

  final PageTransitionStyle pageTransitionStyle;

  final bool landscapeTransitionEnabled;

  final SideBarExpandDirection sideBarExpandDirection;

  final bool usbExclusiveOutput;

  final bool bitPerfectOutput;

  final bool dsdNativePassthrough;

  /// 跳过静音：静音段只保留 [skipSilenceKeepMs]，多出来的丢掉。
  final bool skipSilenceEnabled;
  /// 静音判定阈值（dBFS，负值）。
  final double skipSilenceThresholdDb;
  /// 静音段保留时长（毫秒）。
  final int skipSilenceKeepMs;

  /// 无缝播放：本地曲目之间不留缝（采样率/声道不一致时自动退回普通切歌）。
  final bool gaplessEnabled;

    /// 曲间交叉淡入淡出：本地曲目之间按等功率曲线交叠换曲。
    final bool crossfadeEnabled;

    /// 交叉时长（秒，1–12）。
    final int crossfadeSeconds;

  final bool volumeBalanceEnabled;

  final double volumeBalanceGainOffsetDb;

  final bool volumeBalancePreventClipping;

  final bool autoResumeAfterInterruption;

  final String onlineFailureBehavior;

  final String onlineQualityFallbackBehavior;

  final int usbExclusiveDeviceId;

  final String songClickAction;

  final bool enablePredictiveBack;

  final AppLanguage language;

  final ListSize listSize;

  final AppFontSize fontSize;

  /// 整套 UI 缩放档位索引（0 小 / 1 标准 / 2 大 / 3 特大）
  final int uiScaleIndex;

  final int shareLinkValidityMinutes;

  final String sharePlaybackFailureBehavior;

  final PlayerStyle playerStyle;

  final bool landscapeAutoHideChrome;

  final bool landscapeTapToHideChrome;

  final bool floatingLyricsEnabled;

  final bool floatingLyricsLocked;

  final int floatingLyricsTextColor;

  /// 桌面歌词未播放文字颜色；0 表示跟随主色（按主色降透明度渲染）
  final int floatingLyricsUnplayedColor;

  final int floatingLyricsOpacity;

  final int floatingLyricsFontScale;

  final int floatingLyricsSecondaryScale;

  final bool floatingLyricsShowTranslation;

  final bool floatingLyricsShowRomanization;

  final bool floatingLyricsShowBackground;

  final bool floatingLyricsHideWhenPaused;

  final bool floatingLyricsHideInLandscape;

  final bool landscapeCameraArea;

  final int floatingLyricsWidthPercent;

  final bool floatingLyricsUseLyricFont;

  final bool statusBarLyricsEnabled;

  final int floatingLyricsX;

  final int floatingLyricsY;

  final bool watchLinkageEnabled;

  final String watchLinkTransferMode;

  final bool watchLinkAutoTransfer;

  final String watchLinkAskDate;

  final bool watchLinkAskGranted;

  final bool watchLinkCloudEnabled;

  final String watchLinkCloudKey;

  final bool dlnaRendererEnabled;

  final String dlnaRendererName;

  final bool showRealSourceName;

  AppSettings copyWith({
    double? volume,
    int? playMode,
    int? lastTab,
    bool? keepScreenOn,
    ThemeModePreference? themeMode,
    int? accentColor,
    CustomBackground? customBackground,
    bool? showQualityBadges,
    bool? enableScrollToTopButton,
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
    String? downloadBehavior,
    String? downloadQualityFallbackBehavior,
    String? onlineDefaultMvQuality,
    String? onlineMvQualityFallbackBehavior,
    String? downloadMvQuality,
    String? downloadMvQualityFallbackBehavior,
    bool? keepSourceFilename,
    String? downloadLyricsFormat,
    String? downloadLyricsStyle,
    String? organizeRule,
    int? lyricFontSize,
    int? lyricOffsetMs,
    String? lyricAlignment,
    bool? liquidGlass,
    bool? playerLiquidGlass,
    bool? frostedGlass,
    FrostedGlassLevel? frostedGlassLevel,
    LiquidGlassQuality? liquidGlassQuality,
    PerformanceMode? performanceMode,
    int? hapticStrength,
    String? updateCheckMode,
    int? streamCacheSizeMB,
    List<String>? scanFormats,
    bool? floatingNavBar,
    bool? floatingSearchBar,
    NavBarPosition? navBarPosition,
    PageTransitionStyle? pageTransitionStyle,
    bool? landscapeTransitionEnabled,
    SideBarExpandDirection? sideBarExpandDirection,
    bool? usbExclusiveOutput,
    bool? bitPerfectOutput,
    bool? dsdNativePassthrough,
    bool? skipSilenceEnabled,
    double? skipSilenceThresholdDb,
    int? skipSilenceKeepMs,
    bool? gaplessEnabled,
    bool? crossfadeEnabled,
    int? crossfadeSeconds,
    bool? volumeBalanceEnabled,
    double? volumeBalanceGainOffsetDb,
    bool? volumeBalancePreventClipping,
    bool? autoResumeAfterInterruption,
    String? onlineFailureBehavior,
    String? onlineQualityFallbackBehavior,
    int? usbExclusiveDeviceId,
    String? songClickAction,
    bool? enablePredictiveBack,
    AppLanguage? language,
    ListSize? listSize,
    AppFontSize? fontSize,
    int? uiScaleIndex,
    int? shareLinkValidityMinutes,
    String? sharePlaybackFailureBehavior,
    PlayerStyle? playerStyle,
    bool? landscapeAutoHideChrome,
    bool? landscapeTapToHideChrome,
    bool? floatingLyricsEnabled,
    bool? floatingLyricsLocked,
    int? floatingLyricsTextColor,
    int? floatingLyricsUnplayedColor,
    int? floatingLyricsOpacity,
    int? floatingLyricsFontScale,
    int? floatingLyricsSecondaryScale,
    bool? floatingLyricsShowTranslation,
    bool? floatingLyricsShowRomanization,
    bool? floatingLyricsShowBackground,
    bool? floatingLyricsHideWhenPaused,
    bool? floatingLyricsHideInLandscape,
    bool? landscapeCameraArea,
    int? floatingLyricsWidthPercent,
    bool? floatingLyricsUseLyricFont,
    bool? statusBarLyricsEnabled,
    int? floatingLyricsX,
    int? floatingLyricsY,
    bool? watchLinkageEnabled,
    String? watchLinkTransferMode,
    bool? watchLinkAutoTransfer,
    String? watchLinkAskDate,
    bool? watchLinkAskGranted,
    bool? watchLinkCloudEnabled,
    String? watchLinkCloudKey,
    bool? dlnaRendererEnabled,
    String? dlnaRendererName,
    bool? showRealSourceName,
  }) {
    return AppSettings(
      volume: volume ?? this.volume,
      playMode: playMode ?? this.playMode,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      customBackground: customBackground ?? this.customBackground,
      showQualityBadges: showQualityBadges ?? this.showQualityBadges,
      enableScrollToTopButton:
          enableScrollToTopButton ?? this.enableScrollToTopButton,
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
      downloadBehavior: downloadBehavior ?? this.downloadBehavior,
      downloadQualityFallbackBehavior:
          downloadQualityFallbackBehavior ??
          this.downloadQualityFallbackBehavior,
      onlineDefaultMvQuality: onlineDefaultMvQuality ?? this.onlineDefaultMvQuality,
      onlineMvQualityFallbackBehavior:
          onlineMvQualityFallbackBehavior ?? this.onlineMvQualityFallbackBehavior,
      downloadMvQuality: downloadMvQuality ?? this.downloadMvQuality,
      downloadMvQualityFallbackBehavior:
          downloadMvQualityFallbackBehavior ?? this.downloadMvQualityFallbackBehavior,
      keepSourceFilename: keepSourceFilename ?? this.keepSourceFilename,
      downloadLyricsFormat: downloadLyricsFormat ?? this.downloadLyricsFormat,
      downloadLyricsStyle: downloadLyricsStyle ?? this.downloadLyricsStyle,
      organizeRule: organizeRule ?? this.organizeRule,
      lyricFontSize: lyricFontSize ?? this.lyricFontSize,
      lyricOffsetMs: lyricOffsetMs ?? this.lyricOffsetMs,
      lyricAlignment: lyricAlignment ?? this.lyricAlignment,
      liquidGlass: liquidGlass ?? this.liquidGlass,
      playerLiquidGlass: playerLiquidGlass ?? this.playerLiquidGlass,
      frostedGlass: frostedGlass ?? this.frostedGlass,
      frostedGlassLevel: frostedGlassLevel ?? this.frostedGlassLevel,
      liquidGlassQuality:
          liquidGlassQuality ?? this.liquidGlassQuality,
      performanceMode: performanceMode ?? this.performanceMode,
      hapticStrength: hapticStrength ?? this.hapticStrength,
      updateCheckMode: updateCheckMode ?? this.updateCheckMode,
      streamCacheSizeMB: streamCacheSizeMB ?? this.streamCacheSizeMB,
      scanFormats: scanFormats ?? this.scanFormats,
      floatingNavBar: floatingNavBar ?? this.floatingNavBar,
      floatingSearchBar: floatingSearchBar ?? this.floatingSearchBar,
      navBarPosition: navBarPosition ?? this.navBarPosition,
      pageTransitionStyle:
          pageTransitionStyle ?? this.pageTransitionStyle,
      landscapeTransitionEnabled:
          landscapeTransitionEnabled ?? this.landscapeTransitionEnabled,
      sideBarExpandDirection:
          sideBarExpandDirection ?? this.sideBarExpandDirection,
      usbExclusiveOutput: usbExclusiveOutput ?? this.usbExclusiveOutput,
      bitPerfectOutput: bitPerfectOutput ?? this.bitPerfectOutput,
      dsdNativePassthrough:
          dsdNativePassthrough ?? this.dsdNativePassthrough,
      skipSilenceEnabled: skipSilenceEnabled ?? this.skipSilenceEnabled,
      skipSilenceThresholdDb:
          skipSilenceThresholdDb ?? this.skipSilenceThresholdDb,
      skipSilenceKeepMs: skipSilenceKeepMs ?? this.skipSilenceKeepMs,
      gaplessEnabled: gaplessEnabled ?? this.gaplessEnabled,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeSeconds: crossfadeSeconds ?? this.crossfadeSeconds,
      volumeBalanceEnabled: volumeBalanceEnabled ?? this.volumeBalanceEnabled,
      volumeBalanceGainOffsetDb:
          volumeBalanceGainOffsetDb ?? this.volumeBalanceGainOffsetDb,
      volumeBalancePreventClipping:
          volumeBalancePreventClipping ?? this.volumeBalancePreventClipping,
      autoResumeAfterInterruption:
          autoResumeAfterInterruption ?? this.autoResumeAfterInterruption,
      onlineFailureBehavior:
          onlineFailureBehavior ?? this.onlineFailureBehavior,
      onlineQualityFallbackBehavior:
          onlineQualityFallbackBehavior ?? this.onlineQualityFallbackBehavior,
      usbExclusiveDeviceId: usbExclusiveDeviceId ?? this.usbExclusiveDeviceId,
      songClickAction: songClickAction ?? this.songClickAction,
      enablePredictiveBack: enablePredictiveBack ?? this.enablePredictiveBack,
      language: language ?? this.language,
      listSize: listSize ?? this.listSize,
      fontSize: fontSize ?? this.fontSize,
      uiScaleIndex: uiScaleIndex ?? this.uiScaleIndex,
      shareLinkValidityMinutes: shareLinkValidityMinutes ?? this.shareLinkValidityMinutes,
      sharePlaybackFailureBehavior:
          sharePlaybackFailureBehavior ?? this.sharePlaybackFailureBehavior,
      playerStyle: playerStyle ?? this.playerStyle,
      landscapeAutoHideChrome:
          landscapeAutoHideChrome ?? this.landscapeAutoHideChrome,
      landscapeTapToHideChrome:
          landscapeTapToHideChrome ?? this.landscapeTapToHideChrome,
      floatingLyricsEnabled:
          floatingLyricsEnabled ?? this.floatingLyricsEnabled,
      floatingLyricsLocked: floatingLyricsLocked ?? this.floatingLyricsLocked,
      floatingLyricsTextColor:
          floatingLyricsTextColor ?? this.floatingLyricsTextColor,
      floatingLyricsUnplayedColor:
          floatingLyricsUnplayedColor ?? this.floatingLyricsUnplayedColor,
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
      landscapeCameraArea:
          landscapeCameraArea ?? this.landscapeCameraArea,
      floatingLyricsWidthPercent:
          floatingLyricsWidthPercent ?? this.floatingLyricsWidthPercent,
      floatingLyricsUseLyricFont:
          floatingLyricsUseLyricFont ?? this.floatingLyricsUseLyricFont,
      statusBarLyricsEnabled:
          statusBarLyricsEnabled ?? this.statusBarLyricsEnabled,
      floatingLyricsX: floatingLyricsX ?? this.floatingLyricsX,
      floatingLyricsY: floatingLyricsY ?? this.floatingLyricsY,
      watchLinkageEnabled: watchLinkageEnabled ?? this.watchLinkageEnabled,
      watchLinkTransferMode:
          watchLinkTransferMode ?? this.watchLinkTransferMode,
      watchLinkAutoTransfer:
          watchLinkAutoTransfer ?? this.watchLinkAutoTransfer,
      watchLinkAskDate: watchLinkAskDate ?? this.watchLinkAskDate,
      watchLinkAskGranted: watchLinkAskGranted ?? this.watchLinkAskGranted,
      watchLinkCloudEnabled:
          watchLinkCloudEnabled ?? this.watchLinkCloudEnabled,
      watchLinkCloudKey: watchLinkCloudKey ?? this.watchLinkCloudKey,
      dlnaRendererEnabled: dlnaRendererEnabled ?? this.dlnaRendererEnabled,
      dlnaRendererName: dlnaRendererName ?? this.dlnaRendererName,
      showRealSourceName: showRealSourceName ?? this.showRealSourceName,
    );
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  // ---- 设置存储服务装配 ----
  /// AsyncNotifier.state 带 @protected，扩展/服务不能直接触碰。
  /// 状态提交与落盘经此处注入的闭包收口，替代 ignore_for_file 压制。
  late final SettingsStore _settingsStore = SettingsStore(
    current: () => state.valueOrNull ?? const AppSettings(),
    commit: (next) async {
      state = AsyncData(next);
      await _settingsStore.persist(next);
    },
  );

  @override
  Future<AppSettings> build() async {
    final prefs = await _prefs();
    final savedName = prefs.getString('lyricFontName') ?? '';
    final savedPath = prefs.getString('lyricFontPath') ?? '';
    unawaited(LyricFontManager.loadSavedFont(savedName, savedPath));
    final liquidGlass = prefs.getBool('liquidGlass') ?? false;
    final frostedGlass = prefs.getBool('frostedGlass') ?? false;

    return AppSettings(
      volume: prefs.getDouble('volume') ?? 1.0,
      playMode: prefs.getInt('playMode') ?? 0,
      lastTab: prefs.getInt('lastTab') ?? 0,
      keepScreenOn: prefs.getBool('keepScreenOn') ?? true,
      themeMode: _themeFromInt(prefs.getInt('themeMode') ?? 0),
      accentColor: prefs.getInt('accentColor') ?? 0xFFEC4141,
      showQualityBadges: prefs.getBool('showQualityBadges') ?? true,
      enableScrollToTopButton:
          prefs.getBool('enableScrollToTopButton') ?? true,
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
      downloadBehavior: prefs.getString('downloadBehavior') ?? 'default',
      downloadQualityFallbackBehavior:
          prefs.getString('downloadQualityFallbackBehavior') ?? 'lower',
      onlineDefaultMvQuality: prefs.getString('onlineDefaultMvQuality') ?? '720p',
      onlineMvQualityFallbackBehavior:
          prefs.getString('onlineMvQualityFallbackBehavior') ?? 'lower',
      downloadMvQuality: prefs.getString('downloadMvQuality') ?? '720p',
      downloadMvQualityFallbackBehavior:
          prefs.getString('downloadMvQualityFallbackBehavior') ?? 'lower',
      keepSourceFilename: prefs.getBool('keepSourceFilename') ?? false,
      downloadLyricsFormat: prefs.getString('downloadLyricsFormat') ?? 'lrc',
      downloadLyricsStyle: prefs.getString('downloadLyricsStyle') ?? 'word-by-word',
      organizeRule: prefs.getString('organizeRule') ?? '{Artist}/{Album}/{Title}',
      lyricFontSize: prefs.getInt('lyricFontSize') ?? 1,
      lyricOffsetMs: prefs.getInt('lyricOffsetMs') ?? 0,
      lyricAlignment: prefs.getString('lyricAlignment') ?? 'center',
      liquidGlass: liquidGlass,
      frostedGlass: frostedGlass,
      frostedGlassLevel: _fglFromString(prefs.getString('frostedGlassLevel') ?? 'light'),
      playerLiquidGlass: prefs.getBool('playerLiquidGlass') ?? false,
      liquidGlassQuality:
          _lgqFromString(prefs.getString('liquidGlassQuality') ?? 'medium'),
      performanceMode: _perfFromString(prefs.getString('performanceMode') ?? 'auto'),
      hapticStrength: prefs.getInt('hapticStrength') ?? 1,
      updateCheckMode: prefs.getString('updateCheckMode') ?? 'startup',
      streamCacheSizeMB: prefs.getInt('streamCacheSizeMB') ?? 500,
      scanFormats: _mergeScanFormats(prefs.getStringList('scanFormats')),
      floatingNavBar: prefs.getBool('floatingNavBar') ?? false,
      floatingSearchBar: prefs.getBool('floatingSearchBar') ?? false,
      navBarPosition:
          (prefs.getString('navBarPosition') ?? 'bottom') == 'side'
              ? NavBarPosition.side
              : NavBarPosition.bottom,
      pageTransitionStyle:
          (prefs.getString('pageTransitionStyle') ?? 'cover') == 'smooth'
              ? PageTransitionStyle.smooth
              : PageTransitionStyle.cover,
      landscapeTransitionEnabled:
          prefs.getBool('landscapeTransitionEnabled') ?? true,
      sideBarExpandDirection:
          (prefs.getString('sideBarExpandDirection') ?? 'down') == 'up'
              ? SideBarExpandDirection.up
              : SideBarExpandDirection.down,
      usbExclusiveOutput: prefs.getBool('usbExclusiveOutput') ?? false,
      bitPerfectOutput: prefs.getBool('bitPerfectOutput') ?? false,
      dsdNativePassthrough: prefs.getBool('dsdNativePassthrough')
          ?? false,
      skipSilenceEnabled: prefs.getBool('skipSilenceEnabled') ?? false,
      skipSilenceThresholdDb:
          prefs.getDouble('skipSilenceThresholdDb') ?? -45.0,
      skipSilenceKeepMs: prefs.getInt('skipSilenceKeepMs') ?? 500,
      gaplessEnabled: prefs.getBool('gaplessEnabled') ?? true,
      crossfadeEnabled: prefs.getBool('crossfadeEnabled') ?? false,
      crossfadeSeconds: prefs.getInt('crossfadeSeconds') ?? 5,
      volumeBalanceEnabled: prefs.getBool('volumeBalanceEnabled') ?? false,
      volumeBalanceGainOffsetDb:
          prefs.getDouble('volumeBalanceGainOffsetDb') ?? 0,
      volumeBalancePreventClipping:
          prefs.getBool('volumeBalancePreventClipping') ?? true,
      autoResumeAfterInterruption:
          prefs.getBool('autoResumeAfterInterruption') ?? true,
      onlineFailureBehavior:
          prefs.getString('onlineFailureBehavior') == 'autoswitch'
              ? 'autoswitch'
              : prefs.getString('onlineFailureBehavior') == 'skip'
                  ? 'skip'
                  : 'pause',
      onlineQualityFallbackBehavior:
          prefs.getString('onlineQualityFallbackBehavior') ?? 'lower',
      usbExclusiveDeviceId: prefs.getInt('usbExclusiveDeviceId') ?? -1,
      songClickAction: prefs.getString('songClickAction') ?? 'single',
      enablePredictiveBack: prefs.getBool('enablePredictiveBack') ?? false,
      language: _langFromString(prefs.getString('language') ?? 'system'),
      listSize: _listSizeFromString(prefs.getString('listSize') ?? 'medium'),
      fontSize: _fontSizeFromString(prefs.getString('fontSize') ?? 'standard'),
      uiScaleIndex: prefs.getInt('uiScaleIndex') ?? 1,
      shareLinkValidityMinutes:
          prefs.getInt('shareLinkValidityMinutes') ?? 120,
      sharePlaybackFailureBehavior:
          prefs.getString('sharePlaybackFailureBehavior') ?? 'pause',
      playerStyle: _playerStyleFromString(
          prefs.getString('playerStyle') ?? 'traditional'),
      landscapeAutoHideChrome:
          prefs.getBool('landscapeAutoHideChrome') ?? true,
      landscapeTapToHideChrome:
          prefs.getBool('landscapeTapToHideChrome') ?? true,
      floatingLyricsEnabled:
          prefs.getBool('floatingLyricsEnabled') ?? false,
      floatingLyricsLocked: prefs.getBool('floatingLyricsLocked') ?? false,
      floatingLyricsTextColor:
          prefs.getInt('floatingLyricsTextColor') ?? 0xFFFFFFFF,
      floatingLyricsUnplayedColor:
          prefs.getInt('floatingLyricsUnplayedColor') ?? 0,
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
      landscapeCameraArea: prefs.getBool('landscapeCameraArea') ?? true,
      floatingLyricsWidthPercent:
          prefs.getInt('floatingLyricsWidthPercent') ?? 92,
      floatingLyricsUseLyricFont:
          prefs.getBool('floatingLyricsUseLyricFont') ?? false,
      statusBarLyricsEnabled:
          prefs.getBool('statusBarLyricsEnabled') ?? false,
      floatingLyricsX: prefs.getInt('floatingLyricsX') ?? 0,
      floatingLyricsY: prefs.getInt('floatingLyricsY') ?? 96,
      watchLinkageEnabled: prefs.getBool('watchLinkageEnabled') ?? true,
      watchLinkTransferMode:
          prefs.getString('watchLinkTransferMode') ?? 'ask',
      watchLinkAutoTransfer:
          prefs.getBool('watchLinkAutoTransfer') ?? false,
      watchLinkAskDate: prefs.getString('watchLinkAskDate') ?? '',
      watchLinkAskGranted: prefs.getBool('watchLinkAskGranted') ?? false,
      watchLinkCloudEnabled:
          prefs.getBool('watchLinkCloudEnabled') ?? true,
      watchLinkCloudKey: prefs.getString('watchLinkCloudKey') ?? '',
      dlnaRendererEnabled: prefs.getBool('dlnaRendererEnabled') ?? false,
      dlnaRendererName: prefs.getString('dlnaRendererName') ?? '',
      showRealSourceName: prefs.getBool('showRealSourceName') ?? false,
      customBackground: CustomBackground(
        enabled: prefs.getBool('customBackgroundEnabled') ?? false,
        imagePath: prefs.getString('customBackgroundImagePath') ?? '',
        mediaType: WallpaperMediaType
            .values[prefs.getInt('customBackgroundMediaType') ?? 0],
        motionVideoPath:
            prefs.getString('customBackgroundMotionVideoPath') ?? '',
        blur: prefs.getInt('customBackgroundBlur') ?? 20,
        opacity: prefs.getInt('customBackgroundOpacity') ?? 100,
        maskAlpha: prefs.getInt('customBackgroundMaskAlpha') ?? 40,
        scale: prefs.getInt('customBackgroundScale') ?? 100,
        translateX: prefs.getInt('customBackgroundTranslateX') ?? 0,
        translateY: prefs.getInt('customBackgroundTranslateY') ?? 0,
        landscapeScale: prefs.getInt('customBackgroundLandscapeScale') ?? 100,
        landscapeTranslateX:
            prefs.getInt('customBackgroundLandscapeTranslateX') ?? 0,
        landscapeTranslateY:
            prefs.getInt('customBackgroundLandscapeTranslateY') ?? 0,
        textMode: WallpaperTextColor
            .values[prefs.getInt('customBackgroundTextMode') ?? 0],
        widgetAlpha: prefs.getInt('customBackgroundWidgetAlpha') ?? 30,
      ),
    );
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);