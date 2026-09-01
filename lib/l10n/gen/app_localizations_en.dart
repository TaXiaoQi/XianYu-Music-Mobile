// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'XianYu Music';

  @override
  String get appTagline => 'Clean local & online music player';

  @override
  String get navHome => 'Discover';

  @override
  String get navLibrary => 'Local';

  @override
  String get navMine => 'Mine';

  @override
  String get navEffects => 'Effects';

  @override
  String get navSearch => 'Search';

  @override
  String get navSettings => 'Settings';

  @override
  String get commonOk => 'OK';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonClose => 'Close';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonDone => 'Done';

  @override
  String get commonBack => 'Back';

  @override
  String get commonSearch => 'Search';

  @override
  String get commonMore => 'More';

  @override
  String get commonEmpty => 'Nothing here';

  @override
  String get commonUnknown => 'Unknown';

  @override
  String get homePlayAll => 'Play all';

  @override
  String get homeRecently => 'Recently played';

  @override
  String get homeGridLibrary => 'Local music';

  @override
  String get homeGridRecent => 'Recent';

  @override
  String get homeGridDownload => 'Downloads';

  @override
  String get homeGridSetting => 'Settings';

  @override
  String get homeGridFavorite => 'Favorites';

  @override
  String get homeGridHistory => 'History';

  @override
  String get homeTopList => 'Most played';

  @override
  String get libraryTitle => 'Local';

  @override
  String get libraryAllSongs => 'All songs';

  @override
  String get libraryAlbums => 'Albums';

  @override
  String get libraryArtists => 'Artists';

  @override
  String get libraryFolders => 'Folders';

  @override
  String get libraryPlaylists => 'Playlists';

  @override
  String get libraryImportFolder => 'Import as playlist';

  @override
  String get libraryDuplicate => 'Deduplicate';

  @override
  String get librarySort => 'Sort';

  @override
  String get libraryStats => 'Stats';

  @override
  String librarySongCount(Object count) {
    return '$count songs';
  }

  @override
  String get libraryTotalDuration => 'Total duration';

  @override
  String get libraryMyPlaylists => 'My playlists';

  @override
  String get effectsTitle => 'Effects';

  @override
  String get effectsPreset => 'Preset';

  @override
  String get effectsEqualizer => 'Equalizer';

  @override
  String get effectsReverb => 'Reverb';

  @override
  String get effectsSpatial => 'Spatial audio';

  @override
  String get effectsSpeed => 'Speed';

  @override
  String get effectsPitch => 'Pitch';

  @override
  String get effectsPreservePitch => 'Preserve pitch';

  @override
  String get effectsCustom => 'Custom';

  @override
  String get effectsSavePreset => 'Save preset';

  @override
  String get effectsEditPreset => 'Edit preset';

  @override
  String get effectsDeletePreset => 'Delete preset';

  @override
  String get effectsReset => 'Reset';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchKeyword => 'Search songs, artists or albums';

  @override
  String get searchHistory => 'Search history';

  @override
  String get searchTrending => 'Trending';

  @override
  String get searchResultSongs => 'Songs';

  @override
  String get searchResultAlbums => 'Albums';

  @override
  String get searchResultArtists => 'Artists';

  @override
  String get searchNoResult => 'No matching results';

  @override
  String get searchClearHistory => 'Clear history';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAccount => 'Account & Security';

  @override
  String get settingsPlayback => 'Playback';

  @override
  String get settingsQuality => 'Audio quality';

  @override
  String get settingsDownload => 'Downloads';

  @override
  String get settingsEffects => 'Effects';

  @override
  String get settingsLyrics => 'Lyrics';

  @override
  String get settingsTheme => 'Appearance';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsSync => 'Sync';

  @override
  String get playerSongList => 'Up next';

  @override
  String get playerLyrics => 'Lyrics';

  @override
  String get playerComment => 'Comments';

  @override
  String get playerSwitchToNext => 'Next';

  @override
  String get playerSwitchToPrev => 'Previous';

  @override
  String get playerPlayModeSequential => 'Sequential';

  @override
  String get playerPlayModeShuffle => 'Shuffle';

  @override
  String get playerPlayModeRepeatOne => 'Repeat one';

  @override
  String get playerReadyToPlay => 'Ready';

  @override
  String get downloadTitle => 'Downloads';

  @override
  String get downloadAll => 'All';

  @override
  String get downloadDownloading => 'Downloading';

  @override
  String get downloadCompleted => 'Completed';

  @override
  String get downloadFailed => 'Failed';

  @override
  String get downloadPaused => 'Paused';

  @override
  String get downloadStartAll => 'Start all';

  @override
  String get downloadPauseAll => 'Pause all';

  @override
  String get downloadClearCompleted => 'Clear completed';

  @override
  String get downloadQuality => 'Download quality';

  @override
  String get downloadPath => 'Download folder';

  @override
  String get downloadConcurrency => 'Concurrent downloads';

  @override
  String get downloadConfirm => 'Confirm download';

  @override
  String get login => 'Log in';

  @override
  String get logout => 'Log out';

  @override
  String get register => 'Sign up';

  @override
  String get syncPlugins => 'Plugin sync';

  @override
  String get syncProgress => 'Sync progress';

  @override
  String get syncHistory => 'Play history sync';
}
