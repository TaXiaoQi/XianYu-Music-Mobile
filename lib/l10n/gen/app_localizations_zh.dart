// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '闲鱼音乐';

  @override
  String get appTagline => '纯净本地 · 在线音乐播放器';

  @override
  String get navHome => '主界面';

  @override
  String get navLibrary => '音乐库';

  @override
  String get navEffects => '音效';

  @override
  String get navSearch => '搜索';

  @override
  String get navSettings => '设置';

  @override
  String get commonOk => '确定';

  @override
  String get commonCancel => '取消';

  @override
  String get commonConfirm => '确认';

  @override
  String get commonClose => '关闭';

  @override
  String get commonRetry => '重试';

  @override
  String get commonLoading => '加载中…';

  @override
  String get commonDone => '完成';

  @override
  String get commonBack => '返回';

  @override
  String get commonSearch => '搜索';

  @override
  String get commonMore => '更多';

  @override
  String get commonEmpty => '暂无内容';

  @override
  String get commonUnknown => '未知';

  @override
  String get homePlayAll => '播放全部';

  @override
  String get homeRecently => '最近播放';

  @override
  String get homeGridLibrary => '本地音乐';

  @override
  String get homeGridRecent => '最近播放';

  @override
  String get homeGridDownload => '下载管理';

  @override
  String get homeGridSetting => '设置';

  @override
  String get homeGridFavorite => '我的收藏';

  @override
  String get homeGridHistory => '播放历史';

  @override
  String get homeTopList => '最多播放';

  @override
  String get libraryTitle => '音乐库';

  @override
  String get libraryAllSongs => '全部歌曲';

  @override
  String get libraryAlbums => '专辑';

  @override
  String get libraryArtists => '歌手';

  @override
  String get libraryFolders => '文件夹';

  @override
  String get libraryPlaylists => '歌单';

  @override
  String get libraryImportFolder => '导入为歌单';

  @override
  String get libraryDuplicate => '去重';

  @override
  String get librarySort => '排序';

  @override
  String get libraryStats => '统计';

  @override
  String librarySongCount(Object count) {
    return '$count 首';
  }

  @override
  String get libraryTotalDuration => '总时长';

  @override
  String get libraryMyPlaylists => '我的歌单';

  @override
  String get effectsTitle => '音效';

  @override
  String get effectsPreset => '预设';

  @override
  String get effectsEqualizer => '均衡器';

  @override
  String get effectsReverb => '混响';

  @override
  String get effectsSpatial => '空间音效';

  @override
  String get effectsSpeed => '变速';

  @override
  String get effectsPitch => '变调';

  @override
  String get effectsPreservePitch => '变速保调';

  @override
  String get effectsCustom => '自定义';

  @override
  String get effectsSavePreset => '保存预设';

  @override
  String get effectsEditPreset => '编辑预设';

  @override
  String get effectsDeletePreset => '删除预设';

  @override
  String get effectsReset => '重置';

  @override
  String get searchTitle => '搜索';

  @override
  String get searchKeyword => '输入歌曲、歌手或专辑';

  @override
  String get searchHistory => '搜索历史';

  @override
  String get searchTrending => '热搜';

  @override
  String get searchResultSongs => '歌曲';

  @override
  String get searchResultAlbums => '专辑';

  @override
  String get searchResultArtists => '歌手';

  @override
  String get searchNoResult => '未找到相关结果';

  @override
  String get searchClearHistory => '清空历史';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsAccount => '账号与安全';

  @override
  String get settingsPlayback => '播放设置';

  @override
  String get settingsQuality => '音质设置';

  @override
  String get settingsDownload => '下载设置';

  @override
  String get settingsEffects => '音效设置';

  @override
  String get settingsLyrics => '歌词设置';

  @override
  String get settingsTheme => '外观主题';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsAbout => '关于';

  @override
  String get settingsSync => '同步';

  @override
  String get playerSongList => '播放列表';

  @override
  String get playerLyrics => '歌词';

  @override
  String get playerComment => '评论';

  @override
  String get playerSwitchToNext => '下一首';

  @override
  String get playerSwitchToPrev => '上一首';

  @override
  String get playerPlayModeSequential => '顺序播放';

  @override
  String get playerPlayModeShuffle => '随机播放';

  @override
  String get playerPlayModeRepeatOne => '单曲循环';

  @override
  String get playerReadyToPlay => '准备就绪';

  @override
  String get downloadTitle => '下载管理';

  @override
  String get downloadAll => '全部';

  @override
  String get downloadDownloading => '下载中';

  @override
  String get downloadCompleted => '已完成';

  @override
  String get downloadFailed => '失败';

  @override
  String get downloadPaused => '已暂停';

  @override
  String get downloadStartAll => '全部开始';

  @override
  String get downloadPauseAll => '全部暂停';

  @override
  String get downloadClearCompleted => '清除已完成';

  @override
  String get downloadQuality => '下载音质';

  @override
  String get downloadPath => '下载目录';

  @override
  String get downloadConcurrency => '并发下载数';

  @override
  String get downloadConfirm => '确认下载';

  @override
  String get login => '登录';

  @override
  String get logout => '退出登录';

  @override
  String get register => '注册';

  @override
  String get syncPlugins => '插件同步';

  @override
  String get syncProgress => '同步进度';

  @override
  String get syncHistory => '播放历史同步';
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');

  @override
  String get appTitle => '閒魚音樂';

  @override
  String get appTagline => '純淨本地 · 線上音樂播放器';

  @override
  String get navHome => '主介面';

  @override
  String get navLibrary => '音樂庫';

  @override
  String get navEffects => '音效';

  @override
  String get navSearch => '搜尋';

  @override
  String get navSettings => '設定';

  @override
  String get commonOk => '確定';

  @override
  String get commonCancel => '取消';

  @override
  String get commonConfirm => '確認';

  @override
  String get commonClose => '關閉';

  @override
  String get commonRetry => '重試';

  @override
  String get commonLoading => '載入中…';

  @override
  String get commonDone => '完成';

  @override
  String get commonBack => '返回';

  @override
  String get commonSearch => '搜尋';

  @override
  String get commonMore => '更多';

  @override
  String get commonEmpty => '暫無內容';

  @override
  String get commonUnknown => '未知';

  @override
  String get homePlayAll => '播放全部';

  @override
  String get homeRecently => '最近播放';

  @override
  String get homeGridLibrary => '本地音樂';

  @override
  String get homeGridRecent => '最近播放';

  @override
  String get homeGridDownload => '下載管理';

  @override
  String get homeGridSetting => '設定';

  @override
  String get homeGridFavorite => '我的收藏';

  @override
  String get homeGridHistory => '播放紀錄';

  @override
  String get homeTopList => '最多播放';

  @override
  String get libraryTitle => '音樂庫';

  @override
  String get libraryAllSongs => '全部歌曲';

  @override
  String get libraryAlbums => '專輯';

  @override
  String get libraryArtists => '歌手';

  @override
  String get libraryFolders => '資料夾';

  @override
  String get libraryPlaylists => '歌單';

  @override
  String get libraryImportFolder => '匯入為歌單';

  @override
  String get libraryDuplicate => '去重';

  @override
  String get librarySort => '排序';

  @override
  String get libraryStats => '統計';

  @override
  String librarySongCount(Object count) {
    return '$count 首';
  }

  @override
  String get libraryTotalDuration => '總時長';

  @override
  String get libraryMyPlaylists => '我的歌單';

  @override
  String get effectsTitle => '音效';

  @override
  String get effectsPreset => '預設';

  @override
  String get effectsEqualizer => '等化器';

  @override
  String get effectsReverb => '迴響';

  @override
  String get effectsSpatial => '空間音效';

  @override
  String get effectsSpeed => '變速';

  @override
  String get effectsPitch => '變調';

  @override
  String get effectsPreservePitch => '變速保調';

  @override
  String get effectsCustom => '自訂';

  @override
  String get effectsSavePreset => '儲存預設';

  @override
  String get effectsEditPreset => '編輯預設';

  @override
  String get effectsDeletePreset => '刪除預設';

  @override
  String get effectsReset => '重設';

  @override
  String get searchTitle => '搜尋';

  @override
  String get searchKeyword => '輸入歌曲、歌手或專輯';

  @override
  String get searchHistory => '搜尋紀錄';

  @override
  String get searchTrending => '熱搜';

  @override
  String get searchResultSongs => '歌曲';

  @override
  String get searchResultAlbums => '專輯';

  @override
  String get searchResultArtists => '歌手';

  @override
  String get searchNoResult => '未找到相關結果';

  @override
  String get searchClearHistory => '清空紀錄';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsAccount => '帳號與安全';

  @override
  String get settingsPlayback => '播放設定';

  @override
  String get settingsQuality => '音質設定';

  @override
  String get settingsDownload => '下載設定';

  @override
  String get settingsEffects => '音效設定';

  @override
  String get settingsLyrics => '歌詞設定';

  @override
  String get settingsTheme => '外觀主題';

  @override
  String get settingsLanguage => '語言';

  @override
  String get settingsAbout => '關於';

  @override
  String get settingsSync => '同步';

  @override
  String get playerSongList => '播放清單';

  @override
  String get playerLyrics => '歌詞';

  @override
  String get playerComment => '評論';

  @override
  String get playerSwitchToNext => '下一首';

  @override
  String get playerSwitchToPrev => '上一首';

  @override
  String get playerPlayModeSequential => '循序播放';

  @override
  String get playerPlayModeShuffle => '隨機播放';

  @override
  String get playerPlayModeRepeatOne => '單曲循環';

  @override
  String get playerReadyToPlay => '準備就緒';

  @override
  String get downloadTitle => '下載管理';

  @override
  String get downloadAll => '全部';

  @override
  String get downloadDownloading => '下載中';

  @override
  String get downloadCompleted => '已完成';

  @override
  String get downloadFailed => '失敗';

  @override
  String get downloadPaused => '已暫停';

  @override
  String get downloadStartAll => '全部開始';

  @override
  String get downloadPauseAll => '全部暫停';

  @override
  String get downloadClearCompleted => '清除已完成';

  @override
  String get downloadQuality => '下載音質';

  @override
  String get downloadPath => '下載目錄';

  @override
  String get downloadConcurrency => '並發下載數';

  @override
  String get downloadConfirm => '確認下載';

  @override
  String get login => '登入';

  @override
  String get logout => '登出';

  @override
  String get register => '註冊';

  @override
  String get syncPlugins => '外掛同步';

  @override
  String get syncProgress => '同步進度';

  @override
  String get syncHistory => '播放紀錄同步';
}
