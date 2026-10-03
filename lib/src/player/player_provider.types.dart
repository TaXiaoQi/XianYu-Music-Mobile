part of 'player_provider.dart';

class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String? onlineSongJson;
  final String? onlineQuality;
  final String? coverUrl;
  final String? coverPath;
  final String? source;
  final String? onlineInfoJson;
  final bool fromDailyRecommend;
  /// DLNA 直传歌词地址（桌面端经 httpd 伺服的 xianyu:lyric），仅被投曲目携带
  final String? lyricUrl;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.onlineSongJson,
    this.onlineQuality,
    this.coverUrl,
    this.coverPath,
    this.source,
    this.onlineInfoJson,
    this.fromDailyRecommend = false,
    this.lyricUrl,
  });

  bool get isOnline =>
      path.startsWith('lx://') ||
      path.startsWith('plugin://') ||
      onlineInfoJson != null;

  /// 本地优先：播链歌已下载到本地时，把播放源换成对应本地文件。
  /// 清空在线信息使 isOnline 判定走本地播放管线（不再在线解析），
  /// 保留标题/歌手/专辑/封面等展示元数据；队列里的播链原样保留，
  /// 本地文件被清理后重新播放会回退在线。
  QueueItem withLocalFile(String filePath) => QueueItem(
        path: filePath,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        coverUrl: coverUrl,
        coverPath: coverPath,
        fromDailyRecommend: fromDailyRecommend,
        lyricUrl: lyricUrl,
      );

  QueueItem copyWith({String? coverPath}) => QueueItem(
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        onlineSongJson: onlineSongJson,
        onlineQuality: onlineQuality,
        coverUrl: coverUrl,
        coverPath: coverPath ?? this.coverPath,
        source: source,
        onlineInfoJson: onlineInfoJson,
        fromDailyRecommend: fromDailyRecommend,
        lyricUrl: lyricUrl,
      );

  QueueItem copyWithQuality(String quality) => QueueItem(
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        onlineSongJson: onlineSongJson,
        onlineQuality: quality,
        coverUrl: coverUrl,
        coverPath: coverPath,
        source: source,
        onlineInfoJson: onlineInfoJson,
        fromDailyRecommend: fromDailyRecommend,
        lyricUrl: lyricUrl,
      );

  QueueItem copyWithOnlineSource({
    String? onlineSongJson,
    String? source,
    String? onlineInfoJson,
    String? onlineQuality,
  }) => QueueItem(
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        onlineSongJson: onlineSongJson ?? this.onlineSongJson,
        onlineQuality: onlineQuality ?? this.onlineQuality,
        coverUrl: coverUrl,
        coverPath: coverPath,
        source: source ?? this.source,
        onlineInfoJson: onlineInfoJson ?? this.onlineInfoJson,
        fromDailyRecommend: fromDailyRecommend,
        lyricUrl: lyricUrl,
      );
}

class PlaybackState {
  final QueueItem? current;
  final List<QueueItem> queue;
  final int queueIndex;
  final bool isPlaying;
  final double position;
  final double duration;
  final int playMode;
  final bool resolving;
  final String? error;
  final bool usbExclusive;
  final bool dspActive;
  final String? currentQuality;
  final List<String> availableQualities;
  final bool qualityMenuProbing;
  /// 当前 Rust 管线的**输出**采样率/声道数（0=未知）；来自 AAudio 流实际参数。
  final int outSampleRate;
  final int outChannels;
  /// 当前是否 bit-perfect 直出（输出与源一致、未经响度/EQ/音效/音量）。
  final bool outBitPerfect;
  const PlaybackState({
    this.current,
    this.queue = const [],
    this.queueIndex = -1,
    this.isPlaying = false,
    this.position = 0,
    this.duration = 0,
    this.playMode = 0,
    this.resolving = false,
    this.error,
    this.usbExclusive = false,
    this.dspActive = false,
    this.currentQuality,
    this.availableQualities = const [],
    this.qualityMenuProbing = false,
    this.outSampleRate = 0,
    this.outChannels = 0,
    this.outBitPerfect = false,
  });

  PlaybackState copyWith({
    QueueItem? current,
    List<QueueItem>? queue,
    int? queueIndex,
    bool? isPlaying,
    double? position,
    double? duration,
    int? playMode,
    bool? resolving,
    Object? error = _noChange,
    bool? usbExclusive,
    bool? dspActive,
    String? currentQuality,
    List<String>? availableQualities,
    bool? qualityMenuProbing,
    int? outSampleRate,
    int? outChannels,
    bool? outBitPerfect,
  }) {
    return PlaybackState(
      current: current ?? this.current,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playMode: playMode ?? this.playMode,
      resolving: resolving ?? this.resolving,
      error: error == _noChange ? this.error : error as String?,
      usbExclusive: usbExclusive ?? this.usbExclusive,
      dspActive: dspActive ?? this.dspActive,
      currentQuality: currentQuality ?? this.currentQuality,
      availableQualities: availableQualities ?? this.availableQualities,
      qualityMenuProbing:
          qualityMenuProbing ?? this.qualityMenuProbing,
      outSampleRate: outSampleRate ?? this.outSampleRate,
      outChannels: outChannels ?? this.outChannels,
      outBitPerfect: outBitPerfect ?? this.outBitPerfect,
    );
  }
}
