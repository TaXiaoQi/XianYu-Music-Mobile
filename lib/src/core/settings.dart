import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    this.downloadLyrics = true,
    this.organizeRule = '{Artist}/{Album}/{Title}',
    this.lyricFontSize = 1,
    this.lyricOffsetMs = 0,
    this.liquidGlass = true,
    this.playerLiquidGlass = true,
    this.scanFormats = kSupportedScanFormats,
    this.floatingNavBar = true,
    this.navBarPosition = NavBarPosition.bottom,
    this.sideBarExpandDirection = SideBarExpandDirection.down,
    this.usbExclusiveOutput = false,
    this.dsdNativePassthrough = false,
    this.volumeBalanceEnabled = false,
    this.volumeBalanceGainOffsetDb = 0,
    this.volumeBalancePreventClipping = true,
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
  final bool enableWordEffect;
  final String downloadPath;
  final String downloadQuality;
  final bool downloadLyrics;
  final String organizeRule;
  final int lyricFontSize;
  final int lyricOffsetMs;
  final bool liquidGlass;
  final bool playerLiquidGlass;
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
    bool? enableWordEffect,
    String? downloadPath,
    String? downloadQuality,
    bool? downloadLyrics,
    String? organizeRule,
    int? lyricFontSize,
    int? lyricOffsetMs,
    bool? liquidGlass,
    bool? playerLiquidGlass,
    List<String>? scanFormats,
    bool? floatingNavBar,
    NavBarPosition? navBarPosition,
    SideBarExpandDirection? sideBarExpandDirection,
    bool? usbExclusiveOutput,
    bool? dsdNativePassthrough,
    bool? volumeBalanceEnabled,
    double? volumeBalanceGainOffsetDb,
    bool? volumeBalancePreventClipping,
  }) {
    return AppSettings(
      volume: volume ?? this.volume,
      playMode: playMode ?? this.playMode,
      lastTab: lastTab ?? this.lastTab,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      showQualityBadges: showQualityBadges ?? this.showQualityBadges,
      onlineDefaultQuality: onlineDefaultQuality ?? this.onlineDefaultQuality,
      libraryMinDurationSeconds:
          libraryMinDurationSeconds ?? this.libraryMinDurationSeconds,
      showLyricsTranslation:
          showLyricsTranslation ?? this.showLyricsTranslation,
      enableWordEffect: enableWordEffect ?? this.enableWordEffect,
      downloadPath: downloadPath ?? this.downloadPath,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      downloadLyrics: downloadLyrics ?? this.downloadLyrics,
      organizeRule: organizeRule ?? this.organizeRule,
      lyricFontSize: lyricFontSize ?? this.lyricFontSize,
      lyricOffsetMs: lyricOffsetMs ?? this.lyricOffsetMs,
      liquidGlass: liquidGlass ?? this.liquidGlass,
      playerLiquidGlass: playerLiquidGlass ?? this.playerLiquidGlass,
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
    );
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await _prefs();
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
      enableWordEffect: prefs.getBool('enableWordEffect') ?? true,
      downloadPath: prefs.getString('downloadPath') ?? '',
      downloadQuality: prefs.getString('downloadQuality') ?? '320k',
      downloadLyrics: prefs.getBool('downloadLyrics') ?? true,
      organizeRule: prefs.getString('organizeRule') ?? '{Artist}/{Album}/{Title}',
      lyricFontSize: prefs.getInt('lyricFontSize') ?? 1,
      lyricOffsetMs: prefs.getInt('lyricOffsetMs') ?? 0,
      liquidGlass: prefs.getBool('liquidGlass') ?? true,
      playerLiquidGlass: prefs.getBool('playerLiquidGlass') ?? true,
      scanFormats: prefs.getStringList('scanFormats') ?? kSupportedScanFormats,
      floatingNavBar: prefs.getBool('floatingNavBar') ?? true,
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
    );
  }

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
      prefs.setBool('enableWordEffect', next.enableWordEffect),
      prefs.setString('downloadPath', next.downloadPath),
      prefs.setString('downloadQuality', next.downloadQuality),
      prefs.setBool('downloadLyrics', next.downloadLyrics),
      prefs.setString('organizeRule', next.organizeRule),
      prefs.setInt('lyricFontSize', next.lyricFontSize),
      prefs.setInt('lyricOffsetMs', next.lyricOffsetMs),
      prefs.setBool('liquidGlass', next.liquidGlass),
      prefs.setBool('playerLiquidGlass', next.playerLiquidGlass),
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
    ]);
  }

  Future<void> setVolume(double v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volume: v));
  Future<void> setPlayMode(int m) => _save((state.valueOrNull ?? const AppSettings()).copyWith(playMode: m));
  Future<void> setLastTab(int t) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lastTab: t));
  Future<void> setKeepScreenOn(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(keepScreenOn: v));
  Future<void> setThemeMode(ThemeModePreference m) => _save((state.valueOrNull ?? const AppSettings()).copyWith(themeMode: m));
  Future<void> setAccentColor(int c) => _save((state.valueOrNull ?? const AppSettings()).copyWith(accentColor: c));
  Future<void> setShowQualityBadges(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(showQualityBadges: v));
  Future<void> setOnlineDefaultQuality(String q) => _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineDefaultQuality: q));
  Future<void> setLibraryMinDurationSeconds(int s) => _save((state.valueOrNull ?? const AppSettings()).copyWith(libraryMinDurationSeconds: s));
  Future<void> setShowLyricsTranslation(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(showLyricsTranslation: v));
  Future<void> setEnableWordEffect(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(enableWordEffect: v));
  Future<void> setDownloadPath(String p) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadPath: p));
  Future<void> setDownloadQuality(String q) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadQuality: q));
  Future<void> setDownloadLyrics(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(downloadLyrics: v));
  Future<void> setOrganizeRule(String r) => _save((state.valueOrNull ?? const AppSettings()).copyWith(organizeRule: r));
  Future<void> setLyricFontSize(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricFontSize: v));
  Future<void> setLyricOffsetMs(int v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(lyricOffsetMs: v));
  Future<void> setLiquidGlass(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(liquidGlass: v));
  Future<void> setPlayerLiquidGlass(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(playerLiquidGlass: v));
  Future<void> setScanFormats(List<String> v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(scanFormats: v));
  Future<void> setFloatingNavBar(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(floatingNavBar: v));
  Future<void> setNavBarPosition(NavBarPosition pos) => _save((state.valueOrNull ?? const AppSettings()).copyWith(navBarPosition: pos));
  Future<void> setSideBarExpandDirection(SideBarExpandDirection dir) => _save((state.valueOrNull ?? const AppSettings()).copyWith(sideBarExpandDirection: dir));
  Future<void> setUsbExclusiveOutput(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(usbExclusiveOutput: v));
  Future<void> setDsdNativePassthrough(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(dsdNativePassthrough: v));
  Future<void> setVolumeBalanceEnabled(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalanceEnabled: v));
  Future<void> setVolumeBalanceGainOffsetDb(double v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalanceGainOffsetDb: v));
  Future<void> setVolumeBalancePreventClipping(bool v) => _save((state.valueOrNull ?? const AppSettings()).copyWith(volumeBalancePreventClipping: v));

  /// 整体保存（自动同步合并后调用）。
  Future<void> saveAll(AppSettings next) => _save(next);
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);