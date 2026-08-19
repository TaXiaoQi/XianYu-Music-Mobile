import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式
enum ThemeModePreference {
  system,
  light,
  dark,
}

/// 扫描支持的主流音频格式大类（与 Rust 白名单展开对应）。
const kSupportedScanFormats = <String>[
  'flac',
  'mp3',
  'wav',
  'aac',
  'm4a',
  'ogg',
  'aiff',
];

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
    this.scanFormats = kSupportedScanFormats,
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
  final List<String> scanFormats;

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
    List<String>? scanFormats,
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
      scanFormats: scanFormats ?? this.scanFormats,
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
      scanFormats:
          prefs.getStringList('scanFormats') ?? kSupportedScanFormats,
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
      prefs.setStringList('scanFormats', next.scanFormats),
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
  Future<void> setScanFormats(List<String> f) => _save((state.valueOrNull ?? const AppSettings()).copyWith(scanFormats: f));
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);