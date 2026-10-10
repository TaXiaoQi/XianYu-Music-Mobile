part of 'settings.dart';

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

/// 设置持久化服务：把「状态提交 + SharedPreferences 落盘」从 120+ 个
/// setter 中抽出。当前值读取与状态提交经 [SettingsNotifier] 类体注入的
/// 闭包收口，服务本身不触碰 AsyncNotifier.state（@protected）。
class SettingsStore {
  SettingsStore({
    required AppSettings Function() current,
    required Future<void> Function(AppSettings) commit,
  }) : _current = current,
       _commit = commit;

  final AppSettings Function() _current;
  final Future<void> Function(AppSettings) _commit;

  /// 应用变换并提交（状态 + 落盘）
  Future<void> update(AppSettings Function(AppSettings) transform) =>
      _commit(transform(_current()));

  /// 直接提交（状态 + 落盘），供批量写入（如云端设置合并）使用
  Future<void> save(AppSettings next) => _commit(next);

  /// 仅落盘，不写状态（由 Notifier 的提交闭包在状态写入后调用）
  Future<void> persist(AppSettings next) async {
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
      prefs.setInt('libraryMinDurationSeconds', next.libraryMinDurationSeconds),
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
      prefs.setString('downloadFileNameStyle', next.downloadFileNameStyle),
      prefs.setBool('embedDownloadMetadata', next.embedDownloadMetadata),
      prefs.setBool('embedDownloadLyrics', next.embedDownloadLyrics),
      prefs.setBool('embedDownloadCover', next.embedDownloadCover),
      prefs.setString('downloadBehavior', next.downloadBehavior),
      prefs.setString(
        'downloadQualityFallbackBehavior',
        next.downloadQualityFallbackBehavior,
      ),
      prefs.setString('onlineDefaultMvQuality', next.onlineDefaultMvQuality),
      prefs.setString(
        'onlineMvQualityFallbackBehavior',
        next.onlineMvQualityFallbackBehavior,
      ),
      prefs.setString('downloadMvQuality', next.downloadMvQuality),
      prefs.setString(
        'downloadMvQualityFallbackBehavior',
        next.downloadMvQualityFallbackBehavior,
      ),
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
      prefs.setBool('playerFlowingBackground', next.playerFlowingBackground),
      prefs.setString('liquidGlassQuality', next.liquidGlassQuality.name),
      prefs.setString('performanceMode', next.performanceMode.name),
      prefs.setInt('hapticStrength', next.hapticStrength),
      prefs.setString('updateCheckMode', next.updateCheckMode),
      prefs.setInt('streamCacheSizeMB', next.streamCacheSizeMB),
      prefs.setStringList('scanFormats', next.scanFormats),
      prefs.setBool('floatingNavBar', next.floatingNavBar),
      prefs.setBool('floatingSearchBar', next.floatingSearchBar),
      prefs.setString('navBarPosition', next.navBarPosition.name),
      prefs.setString('pageTransitionStyle', next.pageTransitionStyle.name),
      prefs.setBool(
        'landscapeTransitionEnabled',
        next.landscapeTransitionEnabled,
      ),
      prefs.setString(
        'sideBarExpandDirection',
        next.sideBarExpandDirection.name,
      ),
      prefs.setBool('usbExclusiveOutput', next.usbExclusiveOutput),
      prefs.setBool('bitPerfectOutput', next.bitPerfectOutput),
      prefs.setBool('dsdNativePassthrough', next.dsdNativePassthrough),
      prefs.setBool('skipSilenceEnabled', next.skipSilenceEnabled),
      prefs.setDouble('skipSilenceThresholdDb', next.skipSilenceThresholdDb),
      prefs.setInt('skipSilenceKeepMs', next.skipSilenceKeepMs),
      prefs.setBool('gaplessEnabled', next.gaplessEnabled),
      prefs.setBool('crossfadeEnabled', next.crossfadeEnabled),
      prefs.setInt('crossfadeSeconds', next.crossfadeSeconds),
      prefs.setBool('volumeBalanceEnabled', next.volumeBalanceEnabled),
      prefs.setDouble(
        'volumeBalanceGainOffsetDb',
        next.volumeBalanceGainOffsetDb,
      ),
      prefs.setBool(
        'volumeBalancePreventClipping',
        next.volumeBalancePreventClipping,
      ),
      prefs.setBool(
        'autoResumeAfterInterruption',
        next.autoResumeAfterInterruption,
      ),
      prefs.setBool('showRealQualitySizes', next.showRealQualitySizes),
      prefs.setString('onlineFailureBehavior', next.onlineFailureBehavior),
      prefs.setString(
        'onlineQualityFallbackBehavior',
        next.onlineQualityFallbackBehavior,
      ),
      prefs.setInt('usbExclusiveDeviceId', next.usbExclusiveDeviceId),
      prefs.setString('songClickAction', next.songClickAction),
      prefs.setBool('enablePredictiveBack', next.enablePredictiveBack),
      prefs.setString('language', next.language.name),
      prefs.setString('listSize', next.listSize.name),
      prefs.setString('fontSize', next.fontSize.name),
      prefs.setInt('uiScaleIndex', next.uiScaleIndex),
      prefs.setInt('shareLinkValidityMinutes', next.shareLinkValidityMinutes),
      prefs.setString(
        'sharePlaybackFailureBehavior',
        next.sharePlaybackFailureBehavior,
      ),
      prefs.setString('playerStyle', next.playerStyle.name),
      prefs.setBool('landscapeAutoHideChrome', next.landscapeAutoHideChrome),
      prefs.setBool('landscapeTapToHideChrome', next.landscapeTapToHideChrome),
      prefs.setBool('floatingLyricsEnabled', next.floatingLyricsEnabled),
      prefs.setBool('floatingLyricsLocked', next.floatingLyricsLocked),
      prefs.setInt('floatingLyricsTextColor', next.floatingLyricsTextColor),
      prefs.setInt(
        'floatingLyricsUnplayedColor',
        next.floatingLyricsUnplayedColor,
      ),
      prefs.setInt('floatingLyricsOpacity', next.floatingLyricsOpacity),
      prefs.setInt('floatingLyricsFontScale', next.floatingLyricsFontScale),
      prefs.setInt(
        'floatingLyricsSecondaryScale',
        next.floatingLyricsSecondaryScale,
      ),
      prefs.setBool(
        'floatingLyricsShowTranslation',
        next.floatingLyricsShowTranslation,
      ),
      prefs.setBool(
        'floatingLyricsShowNextLine',
        next.floatingLyricsShowNextLine,
      ),
      prefs.setBool(
        'floatingLyricsShowRomanization',
        next.floatingLyricsShowRomanization,
      ),
      prefs.setBool(
        'floatingLyricsShowBackground',
        next.floatingLyricsShowBackground,
      ),
      prefs.setBool(
        'floatingLyricsHideWhenPaused',
        next.floatingLyricsHideWhenPaused,
      ),
      prefs.setBool(
        'floatingLyricsHideInLandscape',
        next.floatingLyricsHideInLandscape,
      ),
      prefs.setBool('landscapeCameraArea', next.landscapeCameraArea),
      prefs.setInt(
        'floatingLyricsWidthPercent',
        next.floatingLyricsWidthPercent,
      ),
      prefs.setBool(
        'floatingLyricsUseLyricFont',
        next.floatingLyricsUseLyricFont,
      ),
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
      prefs.setString(
        'customBackgroundImagePath',
        next.customBackground.imagePath,
      ),
      prefs.setInt(
        'customBackgroundMediaType',
        next.customBackground.mediaType.index,
      ),
      prefs.setString(
        'customBackgroundMotionVideoPath',
        next.customBackground.motionVideoPath,
      ),
      prefs.setInt('customBackgroundBlur', next.customBackground.blur),
      prefs.setInt('customBackgroundOpacity', next.customBackground.opacity),
      prefs.setInt(
        'customBackgroundMaskAlpha',
        next.customBackground.maskAlpha,
      ),
      prefs.setInt('customBackgroundScale', next.customBackground.scale),
      prefs.setInt(
        'customBackgroundTranslateX',
        next.customBackground.translateX,
      ),
      prefs.setInt(
        'customBackgroundTranslateY',
        next.customBackground.translateY,
      ),
      prefs.setInt(
        'customBackgroundLandscapeScale',
        next.customBackground.landscapeScale,
      ),
      prefs.setInt(
        'customBackgroundLandscapeTranslateX',
        next.customBackground.landscapeTranslateX,
      ),
      prefs.setInt(
        'customBackgroundLandscapeTranslateY',
        next.customBackground.landscapeTranslateY,
      ),
      prefs.setInt(
        'customBackgroundTextMode',
        next.customBackground.textMode.index,
      ),
      prefs.setInt(
        'customBackgroundWidgetAlpha',
        next.customBackground.widgetAlpha,
      ),
    ]);
  }
}

extension SettingsNotifierMethods on SettingsNotifier {
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
    'advanced' => PlayerStyle.advanced,
    _ => PlayerStyle.traditional,
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
    _ => FrostedGlassLevel.medium,
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

  Future<void> _save(AppSettings next) => _settingsStore.save(next);

  Future<void> setVolume(double v) =>
      _settingsStore.update((s) => s.copyWith(volume: v));
  Future<void> setPlayMode(int m) =>
      _settingsStore.update((s) => s.copyWith(playMode: m));
  Future<void> setLastTab(int t) =>
      _settingsStore.update((s) => s.copyWith(lastTab: t));
  Future<void> setWatchLinkageEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(watchLinkageEnabled: v));
  Future<void> setWatchLinkTransferMode(String m) =>
      _settingsStore.update((s) => s.copyWith(watchLinkTransferMode: m));
  Future<void> setWatchLinkCloudEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(watchLinkCloudEnabled: v));
  Future<void> setWatchLinkCloudKey(String k) =>
      _settingsStore.update((s) => s.copyWith(watchLinkCloudKey: k));
  Future<void> setWatchLinkTransferRemembered({required bool autoTransfer}) =>
      _settingsStore.update(
        (s) => s.copyWith(
          watchLinkTransferMode: 'remember',
          watchLinkAutoTransfer: autoTransfer,
        ),
      );
  Future<void> setWatchLinkAskChoice({
    required String date,
    required bool granted,
  }) => _settingsStore.update(
    (s) => s.copyWith(watchLinkAskDate: date, watchLinkAskGranted: granted),
  );
  Future<void> resetWatchLinkAuthorization() => _settingsStore.update(
    (s) => s.copyWith(
      watchLinkTransferMode: 'ask',
      watchLinkAskDate: '',
      watchLinkAskGranted: false,
    ),
  );
  Future<void> setDlnaRendererEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(dlnaRendererEnabled: v));
  Future<void> setDlnaRendererName(String v) =>
      _settingsStore.update((s) => s.copyWith(dlnaRendererName: v));
  Future<void> setShowRealSourceName(bool v) =>
      _settingsStore.update((s) => s.copyWith(showRealSourceName: v));
  Future<void> setKeepScreenOn(bool v) =>
      _settingsStore.update((s) => s.copyWith(keepScreenOn: v));
  Future<void> setEnablePredictiveBack(bool v) =>
      _settingsStore.update((s) => s.copyWith(enablePredictiveBack: v));
  Future<void> setThemeMode(ThemeModePreference m) =>
      _settingsStore.update((s) => s.copyWith(themeMode: m));
  Future<void> setAccentColor(int c) =>
      _settingsStore.update((s) => s.copyWith(accentColor: c));
  Future<void> setShowQualityBadges(bool v) =>
      _settingsStore.update((s) => s.copyWith(showQualityBadges: v));
  Future<void> setEnableScrollToTopButton(bool v) =>
      _settingsStore.update((s) => s.copyWith(enableScrollToTopButton: v));
  Future<void> setOnlineDefaultQuality(String q) =>
      _settingsStore.update((s) => s.copyWith(onlineDefaultQuality: q));
  Future<void> setLibraryMinDurationSeconds(int s) =>
      _settingsStore.update((st) => st.copyWith(libraryMinDurationSeconds: s));
  Future<void> setShowLyricsTranslation(bool v) =>
      _settingsStore.update((s) => s.copyWith(showLyricsTranslation: v));
  Future<void> setShowLyricsRomaji(bool v) =>
      _settingsStore.update((s) => s.copyWith(showLyricsRomaji: v));
  Future<void> setLyricFontName(String v) =>
      _settingsStore.update((s) => s.copyWith(lyricFontName: v));
  Future<void> setLyricFontPath(String v) =>
      _settingsStore.update((s) => s.copyWith(lyricFontPath: v));
  Future<void> setEnableWordEffect(bool v) =>
      _settingsStore.update((s) => s.copyWith(enableWordEffect: v));
  Future<void> setDownloadPath(String p) =>
      _settingsStore.update((s) => s.copyWith(downloadPath: p));
  Future<void> setDownloadQuality(String q) =>
      _settingsStore.update((s) => s.copyWith(downloadQuality: q));
  Future<void> setDownloadLyrics(bool v) =>
      _settingsStore.update((s) => s.copyWith(downloadLyrics: v));
  Future<void> setDownloadConcurrency(int v) =>
      _settingsStore.update((s) => s.copyWith(downloadConcurrency: v));
  Future<void> setOverwriteExisting(bool v) =>
      _settingsStore.update((s) => s.copyWith(overwriteExisting: v));
  Future<void> setDownloadFileNameStyle(String v) =>
      _settingsStore.update((s) => s.copyWith(downloadFileNameStyle: v));
  Future<void> setEmbedDownloadMetadata(bool v) =>
      _settingsStore.update((s) => s.copyWith(embedDownloadMetadata: v));
  Future<void> setEmbedDownloadLyrics(bool v) =>
      _settingsStore.update((s) => s.copyWith(embedDownloadLyrics: v));
  Future<void> setEmbedDownloadCover(bool v) =>
      _settingsStore.update((s) => s.copyWith(embedDownloadCover: v));
  Future<void> setDownloadBehavior(String v) =>
      _settingsStore.update((s) => s.copyWith(downloadBehavior: v));
  Future<void> setDownloadQualityFallbackBehavior(String v) => _settingsStore
      .update((s) => s.copyWith(downloadQualityFallbackBehavior: v));
  Future<void> setOnlineDefaultMvQuality(String q) =>
      _settingsStore.update((s) => s.copyWith(onlineDefaultMvQuality: q));
  Future<void> setOnlineMvQualityFallbackBehavior(String v) => _settingsStore
      .update((s) => s.copyWith(onlineMvQualityFallbackBehavior: v));
  Future<void> setDownloadMvQuality(String q) =>
      _settingsStore.update((s) => s.copyWith(downloadMvQuality: q));
  Future<void> setDownloadMvQualityFallbackBehavior(String v) => _settingsStore
      .update((s) => s.copyWith(downloadMvQualityFallbackBehavior: v));
  Future<void> setKeepSourceFilename(bool v) =>
      _settingsStore.update((s) => s.copyWith(keepSourceFilename: v));
  Future<void> setDownloadLyricsFormat(String v) =>
      _settingsStore.update((s) => s.copyWith(downloadLyricsFormat: v));
  Future<void> setDownloadLyricsStyle(String v) =>
      _settingsStore.update((s) => s.copyWith(downloadLyricsStyle: v));
  Future<void> setOrganizeRule(String r) =>
      _settingsStore.update((s) => s.copyWith(organizeRule: r));
  Future<void> setLyricFontSize(int v) =>
      _settingsStore.update((s) => s.copyWith(lyricFontSize: v));
  Future<void> setLyricOffsetMs(int v) =>
      _settingsStore.update((s) => s.copyWith(lyricOffsetMs: v));
  Future<void> setLyricAlignment(String v) =>
      _settingsStore.update((s) => s.copyWith(lyricAlignment: v));
  Future<void> setLiquidGlass(bool v) => _settingsStore.update(
    (s) => s.copyWith(
      liquidGlass: v,
      floatingNavBar: v ? true : null,
      playerLiquidGlass: v ? true : false,
    ),
  );
  Future<void> setPlayerLiquidGlass(bool v) =>
      _settingsStore.update((s) => s.copyWith(playerLiquidGlass: v));
  Future<void> setPlayerFlowingBackground(bool v) =>
      _settingsStore.update((s) => s.copyWith(playerFlowingBackground: v));
  Future<void> setFrostedGlass(bool v) =>
      _settingsStore.update((s) => s.copyWith(frostedGlass: v));
  Future<void> setFrostedGlassLevel(FrostedGlassLevel l) =>
      _settingsStore.update((s) => s.copyWith(frostedGlassLevel: l));
  Future<void> setLiquidGlassQuality(LiquidGlassQuality q) =>
      _settingsStore.update((s) => s.copyWith(liquidGlassQuality: q));
  Future<void> setPerformanceMode(PerformanceMode m) =>
      _settingsStore.update((s) => s.copyWith(performanceMode: m));
  Future<void> setHapticStrength(int v) =>
      _settingsStore.update((s) => s.copyWith(hapticStrength: v));
  Future<void> setUpdateCheckMode(String v) =>
      _settingsStore.update((s) => s.copyWith(updateCheckMode: v));
  Future<void> setStreamCacheSizeMB(int v) =>
      _settingsStore.update((s) => s.copyWith(streamCacheSizeMB: v));
  Future<void> setScanFormats(List<String> v) =>
      _settingsStore.update((s) => s.copyWith(scanFormats: v));
  Future<void> setFloatingNavBar(bool v) =>
      _settingsStore.update((s) => s.copyWith(floatingNavBar: v));
  Future<void> setFloatingSearchBar(bool v) =>
      _settingsStore.update((s) => s.copyWith(floatingSearchBar: v));
  Future<void> setNavBarPosition(NavBarPosition pos) =>
      _settingsStore.update((s) => s.copyWith(navBarPosition: pos));
  Future<void> setPageTransitionStyle(PageTransitionStyle style) =>
      _settingsStore.update((s) => s.copyWith(pageTransitionStyle: style));
  Future<void> setLandscapeTransitionEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(landscapeTransitionEnabled: v));
  Future<void> setSideBarExpandDirection(SideBarExpandDirection dir) =>
      _settingsStore.update((s) => s.copyWith(sideBarExpandDirection: dir));
  Future<void> setUsbExclusiveOutput(bool v) =>
      _settingsStore.update((s) => s.copyWith(usbExclusiveOutput: v));

  Future<void> setAutoResumeAfterInterruption(bool v) =>
      _settingsStore.update((s) => s.copyWith(autoResumeAfterInterruption: v));
  Future<void> setShowRealQualitySizes(bool v) =>
      _settingsStore.update((s) => s.copyWith(showRealQualitySizes: v));
  Future<void> setBitPerfectOutput(bool v) =>
      _settingsStore.update((s) => s.copyWith(bitPerfectOutput: v));
  Future<void> setSkipSilenceEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(skipSilenceEnabled: v));
  Future<void> setSkipSilenceThresholdDb(double v) =>
      _settingsStore.update((s) => s.copyWith(skipSilenceThresholdDb: v));
  Future<void> setSkipSilenceKeepMs(int v) =>
      _settingsStore.update((s) => s.copyWith(skipSilenceKeepMs: v));
  Future<void> setGaplessEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(gaplessEnabled: v));
  Future<void> setCrossfadeEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(crossfadeEnabled: v));
  Future<void> setCrossfadeSeconds(int v) =>
      _settingsStore.update((s) => s.copyWith(crossfadeSeconds: v));
  Future<void> setDsdNativePassthrough(bool v) =>
      _settingsStore.update((s) => s.copyWith(dsdNativePassthrough: v));
  Future<void> setVolumeBalanceEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(volumeBalanceEnabled: v));
  Future<void> setVolumeBalanceGainOffsetDb(double v) =>
      _settingsStore.update((s) => s.copyWith(volumeBalanceGainOffsetDb: v));
  Future<void> setVolumeBalancePreventClipping(bool v) =>
      _settingsStore.update((s) => s.copyWith(volumeBalancePreventClipping: v));
  Future<void> setOnlineFailureBehavior(String v) =>
      _settingsStore.update((s) => s.copyWith(onlineFailureBehavior: v));
  Future<void> setOnlineQualityFallbackBehavior(String v) => _settingsStore
      .update((s) => s.copyWith(onlineQualityFallbackBehavior: v));
  Future<void> setUsbExclusiveDeviceId(int v) =>
      _settingsStore.update((s) => s.copyWith(usbExclusiveDeviceId: v));
  Future<void> setSongClickAction(String v) =>
      _settingsStore.update((s) => s.copyWith(songClickAction: v));
  Future<void> setLanguage(AppLanguage v) =>
      _settingsStore.update((s) => s.copyWith(language: v));
  Future<void> setListSize(ListSize v) =>
      _settingsStore.update((s) => s.copyWith(listSize: v));
  Future<void> setFontSize(AppFontSize v) =>
      _settingsStore.update((s) => s.copyWith(fontSize: v));
  Future<void> setUiScaleIndex(int v) =>
      _settingsStore.update((s) => s.copyWith(uiScaleIndex: v));
  Future<void> setShareLinkValidityMinutes(int v) =>
      _settingsStore.update((s) => s.copyWith(shareLinkValidityMinutes: v));
  Future<void> setSharePlaybackFailureBehavior(String v) =>
      _settingsStore.update((s) => s.copyWith(sharePlaybackFailureBehavior: v));
  Future<void> setPlayerStyle(PlayerStyle v) =>
      _settingsStore.update((s) => s.copyWith(playerStyle: v));

  Future<void> setLandscapeAutoHideChrome(bool v) =>
      _settingsStore.update((s) => s.copyWith(landscapeAutoHideChrome: v));

  Future<void> setLandscapeTapToHideChrome(bool v) =>
      _settingsStore.update((s) => s.copyWith(landscapeTapToHideChrome: v));

  /// 开启桌面歌词时重置固定效果：上次会话的锁定不再沿用，恢复可拖动；
  /// 关闭时保留锁定与位置不动
  Future<void> setFloatingLyricsEnabled(bool v) => _settingsStore.update(
    (s) => s.copyWith(
      floatingLyricsEnabled: v,
      floatingLyricsLocked: v ? false : null,
    ),
  );

  Future<void> setStatusBarLyricsEnabled(bool v) =>
      _settingsStore.update((s) => s.copyWith(statusBarLyricsEnabled: v));
  Future<void> setFloatingLyricsLocked(bool v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsLocked: v));
  Future<void> setFloatingLyricsTextColor(int v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsTextColor: v));
  Future<void> setFloatingLyricsUnplayedColor(int v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsUnplayedColor: v));
  Future<void> setFloatingLyricsOpacity(int v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsOpacity: v));
  Future<void> setFloatingLyricsFontScale(int v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsFontScale: v));
  Future<void> setFloatingLyricsSecondaryScale(int v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsSecondaryScale: v));
  Future<void> setFloatingLyricsShowTranslation(bool v) => _settingsStore
      .update((s) => s.copyWith(floatingLyricsShowTranslation: v));
  Future<void> setFloatingLyricsShowNextLine(bool v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsShowNextLine: v));
  Future<void> setFloatingLyricsShowRomanization(bool v) => _settingsStore
      .update((s) => s.copyWith(floatingLyricsShowRomanization: v));
  Future<void> setFloatingLyricsShowBackground(bool v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsShowBackground: v));
  Future<void> setFloatingLyricsHideWhenPaused(bool v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsHideWhenPaused: v));
  Future<void> setFloatingLyricsHideInLandscape(bool v) => _settingsStore
      .update((s) => s.copyWith(floatingLyricsHideInLandscape: v));
  Future<void> setLandscapeCameraArea(bool v) =>
      _settingsStore.update((s) => s.copyWith(landscapeCameraArea: v));
  Future<void> setFloatingLyricsWidthPercent(int v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsWidthPercent: v));
  Future<void> setFloatingLyricsUseLyricFont(bool v) =>
      _settingsStore.update((s) => s.copyWith(floatingLyricsUseLyricFont: v));
  Future<void> setFloatingLyricsPosition(int x, int y) => _settingsStore.update(
    (s) => s.copyWith(floatingLyricsX: x, floatingLyricsY: y),
  );

  Future<void> setCustomBackground(CustomBackground v) =>
      _settingsStore.update((s) => s.copyWith(customBackground: v));

  Future<void> saveAll(AppSettings next) => _save(next);
}
