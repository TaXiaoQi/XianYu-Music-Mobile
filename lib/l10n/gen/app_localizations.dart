import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In zh, this message translates to:
  /// **'闲鱼音乐'**
  String get appTitle;

  /// No description provided for @appTagline.
  ///
  /// In zh, this message translates to:
  /// **'纯净本地 · 在线音乐播放器'**
  String get appTagline;

  /// No description provided for @navHome.
  ///
  /// In zh, this message translates to:
  /// **'首页'**
  String get navHome;

  /// No description provided for @navLibrary.
  ///
  /// In zh, this message translates to:
  /// **'音乐库'**
  String get navLibrary;

  /// No description provided for @navMine.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get navMine;

  /// No description provided for @navEffects.
  ///
  /// In zh, this message translates to:
  /// **'音效'**
  String get navEffects;

  /// No description provided for @navSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get navSearch;

  /// No description provided for @navSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get navSettings;

  /// No description provided for @commonOk.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get commonOk;

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get commonConfirm;

  /// No description provided for @commonClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get commonClose;

  /// No description provided for @commonRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get commonRetry;

  /// No description provided for @commonLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get commonLoading;

  /// No description provided for @commonDone.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get commonDone;

  /// No description provided for @commonBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get commonBack;

  /// No description provided for @commonSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get commonSearch;

  /// No description provided for @commonMore.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get commonMore;

  /// No description provided for @commonEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无内容'**
  String get commonEmpty;

  /// No description provided for @commonUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get commonUnknown;

  /// No description provided for @homePlayAll.
  ///
  /// In zh, this message translates to:
  /// **'播放全部'**
  String get homePlayAll;

  /// No description provided for @homeRecently.
  ///
  /// In zh, this message translates to:
  /// **'最近播放'**
  String get homeRecently;

  /// No description provided for @homeGridLibrary.
  ///
  /// In zh, this message translates to:
  /// **'本地音乐'**
  String get homeGridLibrary;

  /// No description provided for @homeGridRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近播放'**
  String get homeGridRecent;

  /// No description provided for @homeGridDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载管理'**
  String get homeGridDownload;

  /// No description provided for @homeGridSetting.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get homeGridSetting;

  /// No description provided for @homeGridFavorite.
  ///
  /// In zh, this message translates to:
  /// **'我的收藏'**
  String get homeGridFavorite;

  /// No description provided for @homeGridHistory.
  ///
  /// In zh, this message translates to:
  /// **'播放历史'**
  String get homeGridHistory;

  /// No description provided for @homeTopList.
  ///
  /// In zh, this message translates to:
  /// **'最多播放'**
  String get homeTopList;

  /// No description provided for @libraryTitle.
  ///
  /// In zh, this message translates to:
  /// **'音乐库'**
  String get libraryTitle;

  /// No description provided for @libraryAllSongs.
  ///
  /// In zh, this message translates to:
  /// **'全部歌曲'**
  String get libraryAllSongs;

  /// No description provided for @libraryAlbums.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get libraryAlbums;

  /// No description provided for @libraryArtists.
  ///
  /// In zh, this message translates to:
  /// **'歌手'**
  String get libraryArtists;

  /// No description provided for @libraryFolders.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get libraryFolders;

  /// No description provided for @libraryPlaylists.
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get libraryPlaylists;

  /// No description provided for @libraryImportFolder.
  ///
  /// In zh, this message translates to:
  /// **'导入为歌单'**
  String get libraryImportFolder;

  /// No description provided for @libraryDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'去重'**
  String get libraryDuplicate;

  /// No description provided for @librarySort.
  ///
  /// In zh, this message translates to:
  /// **'排序'**
  String get librarySort;

  /// No description provided for @libraryStats.
  ///
  /// In zh, this message translates to:
  /// **'统计'**
  String get libraryStats;

  /// No description provided for @librarySongCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 首'**
  String librarySongCount(Object count);

  /// No description provided for @libraryTotalDuration.
  ///
  /// In zh, this message translates to:
  /// **'总时长'**
  String get libraryTotalDuration;

  /// No description provided for @libraryMyPlaylists.
  ///
  /// In zh, this message translates to:
  /// **'我的歌单'**
  String get libraryMyPlaylists;

  /// No description provided for @effectsTitle.
  ///
  /// In zh, this message translates to:
  /// **'音效'**
  String get effectsTitle;

  /// No description provided for @effectsPreset.
  ///
  /// In zh, this message translates to:
  /// **'预设'**
  String get effectsPreset;

  /// No description provided for @effectsEqualizer.
  ///
  /// In zh, this message translates to:
  /// **'均衡器'**
  String get effectsEqualizer;

  /// No description provided for @effectsReverb.
  ///
  /// In zh, this message translates to:
  /// **'混响'**
  String get effectsReverb;

  /// No description provided for @effectsSpatial.
  ///
  /// In zh, this message translates to:
  /// **'空间音效'**
  String get effectsSpatial;

  /// No description provided for @effectsSpeed.
  ///
  /// In zh, this message translates to:
  /// **'变速'**
  String get effectsSpeed;

  /// No description provided for @effectsPitch.
  ///
  /// In zh, this message translates to:
  /// **'变调'**
  String get effectsPitch;

  /// No description provided for @effectsPreservePitch.
  ///
  /// In zh, this message translates to:
  /// **'变速保调'**
  String get effectsPreservePitch;

  /// No description provided for @effectsCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get effectsCustom;

  /// No description provided for @effectsSavePreset.
  ///
  /// In zh, this message translates to:
  /// **'保存预设'**
  String get effectsSavePreset;

  /// No description provided for @effectsEditPreset.
  ///
  /// In zh, this message translates to:
  /// **'编辑预设'**
  String get effectsEditPreset;

  /// No description provided for @effectsDeletePreset.
  ///
  /// In zh, this message translates to:
  /// **'删除预设'**
  String get effectsDeletePreset;

  /// No description provided for @effectsReset.
  ///
  /// In zh, this message translates to:
  /// **'重置'**
  String get effectsReset;

  /// No description provided for @searchTitle.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get searchTitle;

  /// No description provided for @searchKeyword.
  ///
  /// In zh, this message translates to:
  /// **'输入歌曲、歌手或专辑'**
  String get searchKeyword;

  /// No description provided for @searchHistory.
  ///
  /// In zh, this message translates to:
  /// **'搜索历史'**
  String get searchHistory;

  /// No description provided for @searchTrending.
  ///
  /// In zh, this message translates to:
  /// **'热搜'**
  String get searchTrending;

  /// No description provided for @searchResultSongs.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get searchResultSongs;

  /// No description provided for @searchResultAlbums.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get searchResultAlbums;

  /// No description provided for @searchResultArtists.
  ///
  /// In zh, this message translates to:
  /// **'歌手'**
  String get searchResultArtists;

  /// No description provided for @searchNoResult.
  ///
  /// In zh, this message translates to:
  /// **'未找到相关结果'**
  String get searchNoResult;

  /// No description provided for @searchClearHistory.
  ///
  /// In zh, this message translates to:
  /// **'清空历史'**
  String get searchClearHistory;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// No description provided for @settingsAccount.
  ///
  /// In zh, this message translates to:
  /// **'账号与安全'**
  String get settingsAccount;

  /// No description provided for @settingsPlayback.
  ///
  /// In zh, this message translates to:
  /// **'播放设置'**
  String get settingsPlayback;

  /// No description provided for @settingsQuality.
  ///
  /// In zh, this message translates to:
  /// **'音质设置'**
  String get settingsQuality;

  /// No description provided for @settingsDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载设置'**
  String get settingsDownload;

  /// No description provided for @settingsEffects.
  ///
  /// In zh, this message translates to:
  /// **'音效设置'**
  String get settingsEffects;

  /// No description provided for @settingsLyrics.
  ///
  /// In zh, this message translates to:
  /// **'歌词设置'**
  String get settingsLyrics;

  /// No description provided for @settingsTheme.
  ///
  /// In zh, this message translates to:
  /// **'外观主题'**
  String get settingsTheme;

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguage;

  /// No description provided for @settingsAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settingsAbout;

  /// No description provided for @settingsSync.
  ///
  /// In zh, this message translates to:
  /// **'同步'**
  String get settingsSync;

  /// No description provided for @playerSongList.
  ///
  /// In zh, this message translates to:
  /// **'播放列表'**
  String get playerSongList;

  /// No description provided for @playerLyrics.
  ///
  /// In zh, this message translates to:
  /// **'歌词'**
  String get playerLyrics;

  /// No description provided for @playerComment.
  ///
  /// In zh, this message translates to:
  /// **'评论'**
  String get playerComment;

  /// No description provided for @playerSwitchToNext.
  ///
  /// In zh, this message translates to:
  /// **'下一首'**
  String get playerSwitchToNext;

  /// No description provided for @playerSwitchToPrev.
  ///
  /// In zh, this message translates to:
  /// **'上一首'**
  String get playerSwitchToPrev;

  /// No description provided for @playerPlayModeSequential.
  ///
  /// In zh, this message translates to:
  /// **'顺序播放'**
  String get playerPlayModeSequential;

  /// No description provided for @playerPlayModeShuffle.
  ///
  /// In zh, this message translates to:
  /// **'随机播放'**
  String get playerPlayModeShuffle;

  /// No description provided for @playerPlayModeRepeatOne.
  ///
  /// In zh, this message translates to:
  /// **'单曲循环'**
  String get playerPlayModeRepeatOne;

  /// No description provided for @playerReadyToPlay.
  ///
  /// In zh, this message translates to:
  /// **'准备就绪'**
  String get playerReadyToPlay;

  /// No description provided for @downloadTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载管理'**
  String get downloadTitle;

  /// No description provided for @downloadAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get downloadAll;

  /// No description provided for @downloadDownloading.
  ///
  /// In zh, this message translates to:
  /// **'下载中'**
  String get downloadDownloading;

  /// No description provided for @downloadCompleted.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get downloadCompleted;

  /// No description provided for @downloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get downloadFailed;

  /// No description provided for @downloadPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get downloadPaused;

  /// No description provided for @downloadStartAll.
  ///
  /// In zh, this message translates to:
  /// **'全部开始'**
  String get downloadStartAll;

  /// No description provided for @downloadPauseAll.
  ///
  /// In zh, this message translates to:
  /// **'全部暂停'**
  String get downloadPauseAll;

  /// No description provided for @downloadClearCompleted.
  ///
  /// In zh, this message translates to:
  /// **'清除已完成'**
  String get downloadClearCompleted;

  /// No description provided for @downloadQuality.
  ///
  /// In zh, this message translates to:
  /// **'下载音质'**
  String get downloadQuality;

  /// No description provided for @downloadPath.
  ///
  /// In zh, this message translates to:
  /// **'下载目录'**
  String get downloadPath;

  /// No description provided for @downloadConcurrency.
  ///
  /// In zh, this message translates to:
  /// **'并发下载数'**
  String get downloadConcurrency;

  /// No description provided for @downloadConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认下载'**
  String get downloadConfirm;

  /// No description provided for @login.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get login;

  /// No description provided for @logout.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get logout;

  /// No description provided for @register.
  ///
  /// In zh, this message translates to:
  /// **'注册'**
  String get register;

  /// No description provided for @syncPlugins.
  ///
  /// In zh, this message translates to:
  /// **'插件同步'**
  String get syncPlugins;

  /// No description provided for @syncProgress.
  ///
  /// In zh, this message translates to:
  /// **'同步进度'**
  String get syncProgress;

  /// No description provided for @syncHistory.
  ///
  /// In zh, this message translates to:
  /// **'播放历史同步'**
  String get syncHistory;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
