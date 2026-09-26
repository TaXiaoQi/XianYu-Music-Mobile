import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../lyrics/lyric_font.dart';

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
    this.frostedGlass = true,
    this.frostedGlassLevel = FrostedGlassLevel.strongest,
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
    this.shareLinkValidityMinutes = 120,
    this.sharePlaybackFailureBehavior = 'pause',
    this.playerStyle = PlayerStyle.traditional,
    this.landscapeAutoHideChrome = true,
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

  final int shareLinkValidityMinutes;

  final String sharePlaybackFailureBehavior;

  final PlayerStyle playerStyle;

  final bool landscapeAutoHideChrome;

  final bool floatingLyricsEnabled;

  final bool floatingLyricsLocked;

  final int floatingLyricsTextColor;

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
    int? shareLinkValidityMinutes,
    String? sharePlaybackFailureBehavior,
    PlayerStyle? playerStyle,
    bool? landscapeAutoHideChrome,
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
      shareLinkValidityMinutes: shareLinkValidityMinutes ?? this.shareLinkValidityMinutes,
      sharePlaybackFailureBehavior:
          sharePlaybackFailureBehavior ?? this.sharePlaybackFailureBehavior,
      playerStyle: playerStyle ?? this.playerStyle,
      landscapeAutoHideChrome:
          landscapeAutoHideChrome ?? this.landscapeAutoHideChrome,
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
  @override
  Future<AppSettings> build() async {
    final prefs = await _prefs();
    final savedName = prefs.getString('lyricFontName') ?? '';
    final savedPath = prefs.getString('lyricFontPath') ?? '';
    unawaited(LyricFontManager.loadSavedFont(savedName, savedPath));
    final liquidGlass = prefs.getBool('liquidGlass') ?? false;
    final frostedGlass = prefs.getBool('frostedGlass') ?? true;

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
      frostedGlassLevel: _fglFromString(prefs.getString('frostedGlassLevel') ?? 'strongest'),
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
      volumeBalanceEnabled: prefs.getBool('volumeBalanceEnabled') ?? false,
      volumeBalanceGainOffsetDb:
          prefs.getDouble('volumeBalanceGainOffsetDb') ?? 0,
      volumeBalancePreventClipping:
          prefs.getBool('volumeBalancePreventClipping') ?? true,
      autoResumeAfterInterruption:
          prefs.getBool('autoResumeAfterInterruption') ?? true,
      // 'stop' 选项已移除（与 pause 语义重复），存量值归一为 'pause'
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
      shareLinkValidityMinutes:
          prefs.getInt('shareLinkValidityMinutes') ?? 120,
      sharePlaybackFailureBehavior:
          prefs.getString('sharePlaybackFailureBehavior') ?? 'pause',
      playerStyle: _playerStyleFromString(
          prefs.getString('playerStyle') ?? 'traditional'),
      landscapeAutoHideChrome:
          prefs.getBool('landscapeAutoHideChrome') ?? true,
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

  ListSize _listSizeFromString(String v) => switch (v) {
        'compact' => ListSize.compact,
        'large' => ListSize.large,
        _ => ListSize.medium,
      };

  AppFontSize _fontSizeFromString(String v) => switch (v) {
        'system' => AppFontSize.system,
        'small' => AppFontSize.small,
        'large' => AppFontSize.large,
        'larger' => AppFontSize.larger,
        _ => AppFontSize.system,
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

  LiquidGlassQuality _lgqFromString(String v) => switch (v) {
        'low' => LiquidGlassQuality.low,
        'high' => LiquidGlassQuality.high,
        _ => LiquidGlassQuality.medium,
      };

  FrostedGlassLevel _fglFromString(String v) => switch (v) {
        'light' => FrostedGlassLevel.light,
        'medium' => FrostedGlassLevel.medium,
        _ => FrostedGlassLevel.strongest,
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
      prefs.setBool('enableScrollToTopButton', next.enableScrollToTopButton),
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
      prefs.setString('downloadBehavior', next.downloadBehavior),
      prefs.setString(
          'downloadQualityFallbackBehavior',
          next.downloadQualityFallbackBehavior),
      prefs.setString('onlineDefaultMvQuality', next.onlineDefaultMvQuality),
      prefs.setString(
          'onlineMvQualityFallbackBehavior',
          next.onlineMvQualityFallbackBehavior),
      prefs.setString('downloadMvQuality', next.downloadMvQuality),
      prefs.setString(
          'downloadMvQualityFallbackBehavior',
          next.downloadMvQualityFallbackBehavior),
      prefs.setBool('keepSourceFilename', next.keepSourceFilename),
      prefs.setString('downloadLyricsFormat', next.downloadLyricsFormat),
      prefs.setString('downloadLyricsStyle', next.downloadLyricsStyle),
      prefs.setString('organizeRule', next.organizeRule),
      prefs.setInt('lyricFontSize', next.lyricFontSize),
      prefs.setInt('lyricOffsetMs', next.lyricOffsetMs),
      prefs.setString('lyricAlignment', next.lyricAlignment),
      prefs.setBool('liquidGlass', next.liquidGlass),
      prefs.setBool('frostedGlass', next.frostedGlass),
      prefs.setString('frostedGlassLevel', next.frostedGlassLevel.name),
      prefs.setBool('playerLiquidGlass', next.playerLiquidGlass),
      prefs.setString('liquidGlassQuality', next.liquidGlassQuality.name),
      prefs.setString('performanceMode', next.performanceMode.name),
      prefs.setInt('hapticStrength', next.hapticStrength),
      prefs.setString('updateCheckMode', next.updateCheckMode),
      prefs.setInt('streamCacheSizeMB', next.streamCacheSizeMB),
      prefs.setStringList('scanFormats', next.scanFormats),
      prefs.setBool('floatingNavBar', next.floatingNavBar),
      prefs.setBool('floatingSearchBar', next.floatingSearchBar),
      prefs.setString('navBarPosition', next.navBarPosition.name),
      prefs.setString(
          'pageTransitionStyle', next.pageTransitionStyle.name),
      prefs.setBool(
          'landscapeTransitionEnabled', next.landscapeTransitionEnabled),
      prefs.setString(
          'sideBarExpandDirection', next.sideBarExpandDirection.name),
      prefs.setBool('usbExclusiveOutput', next.usbExclusiveOutput),
      prefs.setBool('bitPerfectOutput', next.bitPerfectOutput),
      prefs.setBool('dsdNativePassthrough', next.dsdNativePassthrough),
      prefs.setBool('volumeBalanceEnabled', next.volumeBalanceEnabled),
      prefs.setDouble('volumeBalanceGainOffsetDb', next.volumeBalanceGainOffsetDb),
      prefs.setBool('volumeBalancePreventClipping', next.volumeBalancePreventClipping),
      prefs.setBool('autoResumeAfterInterruption', next.autoResumeAfterInterruption),
      prefs.setString('onlineFailureBehavior', next.onlineFailureBehavior),
      prefs.setString('onlineQualityFallbackBehavior', next.onlineQualityFallbackBehavior),
      prefs.setInt('usbExclusiveDeviceId', next.usbExclusiveDeviceId),
      prefs.setString('songClickAction', next.songClickAction),
      prefs.setBool('enablePredictiveBack', next.enablePredictiveBack),
      prefs.setString('language', next.language.name),
      prefs.setString('listSize', next.listSize.name),
      prefs.setString('fontSize', next.fontSize.name),
      prefs.setInt('shareLinkValidityMinutes', next.shareLinkValidityMinutes),
      prefs.setString(
          'sharePlaybackFailureBehavior', next.sharePlaybackFailureBehavior),
      prefs.setString('playerStyle', next.playerStyle.name),
      prefs.setBool('landscapeAutoHideChrome', next.landscapeAutoHideChrome),
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
      prefs.setBool('landscapeCameraArea', next.landscapeCameraArea),
      prefs.setInt('floatingLyricsWidthPercent', next.floatingLyricsWidthPercent),
      prefs.setBool('floatingLyricsUseLyricFont', next.floatingLyricsUseLyricFont),
      prefs.setBool('statusBarLyricsEnabled', next.statusBarLyricsEnabled),
      prefs.setInt('floatingLyricsX', next.floatingLyricsX),
      prefs.setInt('floatingLyricsY', next.floatingLyricsY),
      prefs.setBool('watchLinkageEnabled', next.watchLinkageEnabled),
      prefs.setString('watchLinkTransferMode', next.watchLinkTransferMode),
      prefs.setBool('watchLinkAutoTransfer', next.watchLinkAutoTransfer),
      prefs.setString('watchLinkAskDate', next.watchLinkAskDate),
      prefs.setBool('watchLinkAskGranted', next.watchLinkAskGranted),
      prefs.setBool('watchLinkCloudEnabled', next.watchLinkCloudEnabled),
      prefs.setString('watchLinkCloudKey', next.watchLinkCloudKey),
      prefs.setBool('dlnaRendererEnabled', next.dlnaRendererEnabled),
      prefs.setString('dlnaRendererName', next.dlnaRendererName),
      prefs.setBool('showRealSourceName', next.showRealSourceName),
      prefs.setBool('customBackgroundEnabled', next.customBackground.enabled),
      prefs.setString('customBackgroundImagePath', next.customBackground.imagePath),
      prefs.setInt('customBackgroundMediaType', next.customBackground.mediaType.index),
      prefs.setInt('customBackgroundBlur', next.customBackground.blur),
      prefs.setInt('customBackgroundOpacity', next.customBackground.opacity),
      prefs.setInt('customBackgroundMaskAlpha', next.customBackground.maskAlpha),
      prefs.setInt('customBackgroundScale', next.customBackground.scale),
      prefs.setInt('customBackgroundTranslateX', next.customBackground.translateX),
      prefs.setInt('customBackgroundTranslateY', next.customBackground.translateY),
      prefs.setInt('customBackgroundLandscapeScale', next.customBackground.landscapeScale),
      prefs.setInt('customBackgroundLandscapeTranslateX', next.customBackground.landscapeTranslateX),
      prefs.setInt('customBackgroundLandscapeTranslateY', next.customBackground.landscapeTranslateY),
      prefs.setInt('customBackgroundTextMode', next.customBackground.textMode.index),
      prefs.setInt(
          'customBackgroundWidgetAlpha', next.customBackground.widgetAlpha),
    ]);
  }

  Future<void> setVolume(double v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volume: v));
  Future<void> setPlayMode(int m) => _save((state.valueOrNull ?? const AppSettings()).copyWith(playMode: m));
  Future<void> setLastTab(int t) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lastTab: t));
  Future<void> setWatchLinkageEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(watchLinkageEnabled: v));
  Future<void> setWatchLinkTransferMode(String m) => _save((state.valueOrNull ?? const AppSettings()).copyWith(watchLinkTransferMode: m));
  Future<void> setWatchLinkCloudEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(watchLinkCloudEnabled: v));
  Future<void> setWatchLinkCloudKey(String k) => _save((state.valueOrNull ?? const AppSettings()).copyWith(watchLinkCloudKey: k));
  Future<void> setWatchLinkTransferRemembered({required bool autoTransfer}) => _save((state.valueOrNull ?? const AppSettings()).copyWith(watchLinkTransferMode: 'remember', watchLinkAutoTransfer: autoTransfer));
  Future<void> setWatchLinkAskChoice({required String date, required bool granted}) => _save((state.valueOrNull ?? const AppSettings()).copyWith(watchLinkAskDate: date, watchLinkAskGranted: granted));
  Future<void> resetWatchLinkAuthorization() => _save((state.valueOrNull ?? const AppSettings()).copyWith(watchLinkTransferMode: 'ask', watchLinkAskDate: '', watchLinkAskGranted: false));
  Future<void> setDlnaRendererEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(dlnaRendererEnabled: v));
  Future<void> setDlnaRendererName(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(dlnaRendererName: v));
  Future<void> setShowRealSourceName(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(showRealSourceName: v));
  Future<void> setKeepScreenOn(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(keepScreenOn: v));
  Future<void> setEnablePredictiveBack(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(enablePredictiveBack: v));
  Future<void> setThemeMode(ThemeModePreference m) => _save((state.valueOrNull ?? const AppSettings()).copyWith(themeMode: m));
  Future<void> setAccentColor(int c) => _save((state.valueOrNull ?? const AppSettings()).copyWith(accentColor: c));
  Future<void> setShowQualityBadges(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(showQualityBadges: v));
  Future<void> setEnableScrollToTopButton(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(enableScrollToTopButton: v));
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
  Future<void> setDownloadBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadBehavior: v));
  Future<void> setDownloadQualityFallbackBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadQualityFallbackBehavior: v));
  Future<void> setOnlineDefaultMvQuality(String q) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineDefaultMvQuality: q));
  Future<void> setOnlineMvQualityFallbackBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineMvQualityFallbackBehavior: v));
  Future<void> setDownloadMvQuality(String q) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadMvQuality: q));
  Future<void> setDownloadMvQualityFallbackBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadMvQualityFallbackBehavior: v));
  Future<void> setKeepSourceFilename(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(keepSourceFilename: v));
  Future<void> setDownloadLyricsFormat(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadLyricsFormat: v));
  Future<void> setDownloadLyricsStyle(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadLyricsStyle: v));
  Future<void> setOrganizeRule(String r) => _save((state.valueOrNull ?? const AppSettings()).copyWith(organizeRule: r));
  Future<void> setLyricFontSize(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricFontSize: v));
  Future<void> setLyricOffsetMs(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricOffsetMs: v));
  Future<void> setLyricAlignment(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricAlignment: v));
  Future<void> setLiquidGlass(bool v) => _save((state.valueOrNull ??
        const AppSettings())
      .copyWith(
    liquidGlass: v,
    floatingNavBar: v ? true : null,
    playerLiquidGlass: v ? true : false,
  ));
  Future<void> setPlayerLiquidGlass(bool v) => _save((state.valueOrNull ??
        const AppSettings())
      .copyWith(playerLiquidGlass: v));
  Future<void> setFrostedGlass(bool v) => _save((state.valueOrNull ??
        const AppSettings())
      .copyWith(
    frostedGlass: v,
  ));
  Future<void> setFrostedGlassLevel(FrostedGlassLevel l) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(frostedGlassLevel: l));
  Future<void> setLiquidGlassQuality(LiquidGlassQuality q) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(liquidGlassQuality: q));
  Future<void> setPerformanceMode(PerformanceMode m) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(performanceMode: m));
  Future<void> setHapticStrength(int v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(hapticStrength: v));
  Future<void> setUpdateCheckMode(String v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(updateCheckMode: v));
  Future<void> setStreamCacheSizeMB(int v) => _save((state.valueOrNull ??
          const AppSettings())
      .copyWith(streamCacheSizeMB: v));
  Future<void> setScanFormats(List<String> v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(scanFormats: v));
  Future<void> setFloatingNavBar(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(
        floatingNavBar: v,
      ));
  Future<void> setFloatingSearchBar(bool v) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(floatingSearchBar: v));
  Future<void> setNavBarPosition(NavBarPosition pos) => _save((state.valueOrNull ?? const AppSettings()).copyWith(navBarPosition: pos));
  Future<void> setPageTransitionStyle(PageTransitionStyle style) => _save((state.valueOrNull ?? const AppSettings()).copyWith(pageTransitionStyle: style));
  Future<void> setLandscapeTransitionEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(landscapeTransitionEnabled: v));
  Future<void> setSideBarExpandDirection(SideBarExpandDirection dir) => _save((state.valueOrNull ?? const AppSettings()).copyWith(sideBarExpandDirection: dir));
  Future<void> setUsbExclusiveOutput(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(usbExclusiveOutput: v));

  Future<void> setAutoResumeAfterInterruption(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(autoResumeAfterInterruption: v));
  Future<void> setBitPerfectOutput(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(bitPerfectOutput: v));
  Future<void> setDsdNativePassthrough(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(dsdNativePassthrough: v));
  Future<void> setVolumeBalanceEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalanceEnabled: v));
  Future<void> setVolumeBalanceGainOffsetDb(double v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalanceGainOffsetDb: v));
  Future<void> setVolumeBalancePreventClipping(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalancePreventClipping: v));
  Future<void> setOnlineFailureBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineFailureBehavior: v));
  Future<void> setOnlineQualityFallbackBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineQualityFallbackBehavior: v));
  Future<void> setUsbExclusiveDeviceId(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(usbExclusiveDeviceId: v));
  Future<void> setSongClickAction(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(songClickAction: v));
  Future<void> setLanguage(AppLanguage v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(language: v));
  Future<void> setListSize(ListSize v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(listSize: v));
  Future<void> setFontSize(AppFontSize v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(fontSize: v));
  Future<void> setShareLinkValidityMinutes(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(shareLinkValidityMinutes: v));
  Future<void> setSharePlaybackFailureBehavior(String v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(sharePlaybackFailureBehavior: v));
  Future<void> setPlayerStyle(PlayerStyle v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(playerStyle: v));

  Future<void> setLandscapeAutoHideChrome(bool v) =>
      _save((state.valueOrNull ?? const AppSettings())
          .copyWith(landscapeAutoHideChrome: v));
  Future<void> setFloatingLyricsEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsEnabled: v));

  Future<void> setStatusBarLyricsEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(statusBarLyricsEnabled: v));
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
  Future<void> setLandscapeCameraArea(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(landscapeCameraArea: v));
  Future<void> setFloatingLyricsWidthPercent(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsWidthPercent: v));
  Future<void> setFloatingLyricsUseLyricFont(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsUseLyricFont: v));
  Future<void> setFloatingLyricsPosition(int x, int y) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingLyricsX: x, floatingLyricsY: y));

  Future<void> setCustomBackground(CustomBackground v) => _save(
      (state.valueOrNull ?? const AppSettings()).copyWith(
          customBackground: v));

  Future<void> saveAll(AppSettings next) => _save(next);
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);