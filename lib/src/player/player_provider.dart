import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as as_pkg;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../auth/account_api.dart';
import '../core/app_logger.dart';
import '../core/application_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../download/download_provider.dart';
import '../effects/sound_effect_provider.dart';
import '../favorites/favorites_provider.dart';
import '../home/home_providers.dart';
import '../library/saf_channel.dart';
import '../online/online_meta_store.dart';
import '../online/online_search_provider.dart';
import '../online/cover_proxy.dart';
import '../plugin/plugin_backup_import.dart';
import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../recent/recent_provider.dart';
import '../remote/remote_library_service.dart';
import '../rust/api.dart';
import '../widgets/app_toast.dart';
import '../widgets/cover_image.dart';
import '../navigation/routes.dart';
import 'mv_auto_sync.dart';
import 'audio_head_cache.dart';
import 'mv_provider.dart';
import 'sleep_timer.dart';
import 'audio_proxy_server.dart';
import 'media_url.dart';
import 'cast_provider.dart';
import 'online_quality_probe.dart';
import 'online_precache.dart';
import '../i18n/i18n.dart';

part 'player_provider.queue.dart';
part 'player_provider.report.dart';
part 'player_provider.session.dart';
part 'player_provider.audio_chain.dart';
part 'player_provider.quality.dart';
part 'player_provider.online.dart';
part 'player_provider.source.dart';
part 'player_provider.cast.dart';

XianYuAudioHandler? audioHandler;

final Map<String, int> _qualitySizeByUrl = {};

final Set<String> _prewarmKeys = {};

PlayerNotifier? activePlayerNotifier;

class XianYuAudioHandler extends as_pkg.BaseAudioHandler with as_pkg.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  void syncMediaItem(QueueItem item, double durationSecs) {
    _lastSyncItem = item;
    _lastSyncDuration = durationSecs;
    mediaItem.add(_buildMediaItem(item, durationSecs, _artUriFor(item)));
    unawaited(_materializeOnlineArt(item));
  }

  void syncQueue(List<QueueItem> items, Map<String, String> artCache) {
    queue.add([
      for (final item in items)
        _buildMediaItem(
          item,
          _lastSyncItem?.path == item.path ? _lastSyncDuration : 0,
          _artUriForWithCache(item, artCache),
        ),
    ]);
  }

  Uri? _artUriForWithCache(QueueItem item, Map<String, String> artCache) {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      final cached = artCache[url];
      if (cached != null && File(cached).existsSync()) return Uri.file(cached);
      final art = _artFileCache[url];
      if (art != null && File(art).existsSync()) return Uri.file(art);
      // 需代理的 CDN 不交 http URL：避免直连低清图与高清物化结果竞态。
      if (!CoverProxy.needsProxy(url)) return Uri.tryParse(url);
      return null;
    }
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    return null;
  }

  QueueItem? _lastSyncItem;
  double _lastSyncDuration = 0;

  final Map<String, String> _artFileCache = {};
  final Set<String> _artMaterializing = {};

  Uri? _artUriFor(QueueItem item) {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      final cached = _artFileCache[url];
      if (cached != null) {
        if (File(cached).existsSync()) return Uri.file(cached);
        _artFileCache.remove(url);
      }
      // 需代理的 CDN 不交 http URL：系统直连下载既无 Referer 易 403，
      // 又可能与随后落盘的高清封面竞态（低清结果后到会覆盖通知）。
      if (!CoverProxy.needsProxy(url)) return Uri.tryParse(url);
      return null;
    }
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    return null;
  }

  as_pkg.MediaItem _buildMediaItem(
      QueueItem item, double durationSecs, Uri? artUri) {
    return as_pkg.MediaItem(
      id: item.path,
      album: item.album.isEmpty ? tr('弦予音乐') : item.album,
      title: item.title,
      artist: item.artist.isEmpty ? tr('未知歌手') : item.artist,
      duration:
          durationSecs > 0 ? Duration(milliseconds: (durationSecs * 1000).round()) : null,
      artUri: artUri,
    );
  }

  /// 把常见 CDN 的缩略图 URL 升级为高清候选；认不出的规则返回 null
  /// （视为已是原图）。只做可安全升级的替换，失败由调用方回退原 URL。
  String? _hdCoverUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host;
    // 网易云：?param=200y200 → 1024y1024（官方图片服务参数，超原图上限自动适配）
    if (host.endsWith('126.net') || host.endsWith('163.com')) {
      final param = uri.queryParameters['param'];
      if (param != null && RegExp(r'^\d+y\d+$').hasMatch(param)) {
        return uri
            .replace(queryParameters: <String, String>{
              ...uri.queryParameters,
              'param': '1024y1024',
            })
            .toString();
      }
      return null;
    }
    // 酷我 / 咪咕：路径中的尺寸段（/300x300/、/W300h300/）删掉即为原图
    if (host.endsWith('kuwo.cn') || host.endsWith('migu.cn')) {
      final cleaned = url
          .replaceFirst(RegExp(r'/\d+x\d+/'), '/')
          .replaceFirst(RegExp(r'/[Ww]\d+[Hh]\d+/'), '/');
      return cleaned == url ? null : cleaned;
    }
    return null;
  }

  Future<void> _materializeOnlineArt(QueueItem item) async {
    if (!Platform.isAndroid) return;
    final url = item.coverUrl;
    if (url == null || url.isEmpty) return;
    final cached = _artFileCache[url];
    if (cached != null) {
      if (File(cached).existsSync()) return;
      _artFileCache.remove(url);
    }
    if (!_artMaterializing.add(url)) return;
    try {
      // 优先拉高清候选，失败再回退原 URL；落盘 key 仍用原 URL 的哈希。
      final hd = _hdCoverUrl(url);
      var bytes = hd == null ? null : await CoverProxy.fetch(hd);
      bytes ??= await CoverProxy.fetch(url);
      if (bytes == null || bytes.isEmpty) return;
      final dir = await getTemporaryDirectory();
      final key = md5.convert(utf8.encode(url)).toString();
      final file = File('${dir.path}/media_art_$key.jpg');
      await file.writeAsBytes(bytes, flush: true);
      _artFileCache[url] = file.path;
      if (_lastSyncItem?.path == item.path) {
        mediaItem.add(
          _buildMediaItem(item, _lastSyncDuration, Uri.file(file.path)),
        );
      }
    } catch (_) {
    } finally {
      _artMaterializing.remove(url);
    }
  }

  void syncPlaybackState({
    required bool isPlaying,
    required double positionSecs,
    required double durationSecs,
    required bool isFavorite,
    required int playMode,
    int? queueIndex,
  }) {
    playbackState.add(
      as_pkg.PlaybackState(
        controls: [
          as_pkg.MediaControl.skipToPrevious,
          if (isPlaying) as_pkg.MediaControl.pause else as_pkg.MediaControl.play,
          as_pkg.MediaControl.skipToNext,
          as_pkg.MediaControl(
            androidIcon: isFavorite
                ? 'drawable/ic_notif_favorite_filled'
                : 'drawable/ic_notif_favorite',
            label: isFavorite ? tr('取消收藏') : tr('收藏'),
            action: as_pkg.MediaAction.custom,
            customAction: const as_pkg.CustomMediaAction(name: 'toggleFavorite'),
          ),
          as_pkg.MediaControl(
            androidIcon: _playModeIcon(playMode),
            label: _playModeLabel(playMode),
            action: as_pkg.MediaAction.custom,
            customAction: const as_pkg.CustomMediaAction(name: 'cyclePlayMode'),
          ),
        ],
        systemActions: const {
          as_pkg.MediaAction.seek,
          as_pkg.MediaAction.seekForward,
          as_pkg.MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: as_pkg.AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: Duration(milliseconds: (positionSecs * 1000).round()),
        bufferedPosition: Duration(milliseconds: (positionSecs * 1000).round()),
        speed: 1.0,
        queueIndex: queueIndex,
      ),
    );
  }

  String _playModeIcon(int mode) => switch (mode) {
        1 => 'drawable/ic_notif_mode_repeat_one',
        2 => 'drawable/ic_notif_mode_shuffle',
        _ => 'drawable/ic_notif_mode_repeat',
      };

  String _playModeLabel(int mode) => switch (mode) {
        1 => tr('单曲循环'),
        2 => tr('随机播放'),
        _ => tr('列表循环'),
      };

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'toggleFavorite':
        await _notifier?.toggleFavoriteFromSystem();
      case 'cyclePlayMode':
        await _notifier?.cyclePlayMode();
    }
  }

  @override
  Future<void> play() => _notifier?.resumeFromSystem() ?? Future.value();

  @override
  Future<void> pause() =>
      _notifier?.pauseFromSystem(origin: 'mediasession.pause') ??
      Future.value();

  @override
  Future<void> skipToNext() => _notifier?.next() ?? Future.value();

  @override
  Future<void> skipToPrevious() => _notifier?.previous() ?? Future.value();

  @override
  Future<void> seek(Duration position) =>
      _notifier?.seek(position.inMilliseconds / 1000.0) ?? Future.value();

  @override
  Future<void> stop() =>
      _notifier?.pauseFromSystem(origin: 'mediasession.stop') ??
      Future.value();

  @override
  Future<void> onTaskRemoved() async {
    await _notifier?.pauseFromSystem(origin: 'mediasession.taskRemoved');
    await super.stop();
    exit(0);
  }
}

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

const Object _noChange = Object();

typedef BeforePlayGate = Future<void> Function();

class _StartOnlineTimeoutException implements Exception {
  _StartOnlineTimeoutException(this.message);

  final String message;

  @override
  String toString() => message;
}

BeforePlayGate? beforePlayGate;

class _GatedAudioPlayer extends AudioPlayer {
  _GatedAudioPlayer() : super(handleInterruptions: false);

  @override
  Future<void> play() async {
    final gate = beforePlayGate;
    if (gate != null) await gate();
    return super.play();
  }

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) {
    LastAudioSource.recordUrl(url, headers);
    return super.setUrl(
      url,
      headers: headers,
      initialPosition: initialPosition,
      preload: preload,
      tag: tag,
    );
  }

  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) {
    LastAudioSource.recordFilePath(filePath);
    return super.setFilePath(
      filePath,
      initialPosition: initialPosition,
      preload: preload,
      tag: tag,
    );
  }
}

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
    activePlayerNotifier = this;
    audioHandler?.bindNotifier(this);
    _ref.read(sleepTimerProvider.notifier).onFire = (_) => _sleepFadeOutAndPause();
    _subscribePlayerStreams();
    _init();
  }

  final Ref _ref;
  AudioPlayer _player = _GatedAudioPlayer();

  // ---- 状态出口 ----
  /// StateNotifier.state 带 @protected，extension（part 文件）不是子类，
  /// 直接访问会触发 invalid_use_of_protected_member。与 riverpod
  /// StateController 同款做法：在此把 state 重新公开，part 文件统一
  /// 走此出口读写状态，替代 ignore_for_file 压制。
  @override
  PlaybackState get state => super.state;

  @override
  set state(PlaybackState next) => super.state = next;

  bool _rebuildingPlayer = false;
  String? _activeProbeKey;
  final Random _rand = Random();
  StreamSubscription<Duration?>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<dynamic>? _stateSub;
  StreamSubscription<ProcessingState>? _procSub;
  StreamSubscription<dynamic>? _errSub;
  StreamSubscription<dynamic>? _interruptionSub;
  bool _interruptedByInterruption = false;
  Timer? _listenTimer;
  double _lastStatPos = -1;
  bool _playbackErrorHandling = false;
  bool _onTrackEndBusy = false;
  Timer? _exclusiveTimer;
  Timer? _sfxSyncTimer;
  DateTime _dspFailUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _dspSkipNextStart = false;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  int _skipDepth = 0;
  Timer? _stallTimer;
  double _stallLastPos = -1;
  int _stallTicks = 0;
  final Map<String, DateTime> _failedOnlineSources = {};

  int _playEpoch = 0;
  final Set<String> _failedSources = {};
  String? _switchCtxKey;
  DateTime? _lastAutoSwitchAt;
  String? _lastAutoSwitchPath;
  final Map<String, Map<String, dynamic>> _crossFormatHealCache = {};
  final Set<String> _onlineReSearchDone = {};
  bool _shareLinkPlayback = false;
  String? _sessionQualityOverride;
  double? _replayAnchorSecs;

  static const MethodChannel _diagChannel = MethodChannel('xianyu/diag');

  Future<void> _dumpPlayerThreads() async {
    try {
      final out = await _diagChannel.invokeMethod<String>('threadDump');
      AppLog.warn('exodump', '播放器线程堆栈快照:\n${out ?? 'null'}');
    } catch (e) {
      AppLog.warn('exodump', '线程转储失败: $e');
    }
  }

  double? _restoredOnlinePending;
  double? _restoredLocalPending;
  /// 已预排给 Rust 的「下一首」下标（-1 = 未预排）；无缝拼接发生时按它推进队列。
  int _gaplessNextIndex = -1;
  /// 已预排的路径，避免对同一首重复下发预排。
  String? _gaplessNextPath;
  /// 最近一次看到的无缝拼接次数（来自 device_info 的 transitionSeq）。
  int _lastTransitionSeq = 0;
  DateTime? _trackStartTime;
  double _accumulatedTime = 0;
  bool _currentPlayCountRecorded = false;

  // ---- 统计上报服务装配 ----
  late final PlayStatsReporter statsReporter = PlayStatsReporter(_ref);

  /// 听歌时长累计口径：服务端快照 + 本地会话增量；达到阈值即落库。
  void _flushPlayStats() {
    final item = state.current;
    if (item == null) return;
    double currentSession = 0;
    final pos = state.position;
    if (_trackStartTime != null && state.isPlaying && pos > 0) {
      final delta = _lastStatPos >= 0 ? pos - _lastStatPos : 0.0;
      if (delta > 0) {
        final wallSec =
            DateTime.now().difference(_trackStartTime!).inMilliseconds / 1000.0;
        if (delta <= wallSec + 2) currentSession = delta;
      }
    }
    _lastStatPos = pos;
    final totalDuration = _accumulatedTime + currentSession;
    final shouldPersist =
        totalDuration >= 10 || (_currentPlayCountRecorded && totalDuration > 0);

    if (shouldPersist) {
      final countAsPlay = !_currentPlayCountRecorded;
      if (countAsPlay) _currentPlayCountRecorded = true;
      statsReporter.recordPlayStats(
        item,
        totalDuration,
        countAsPlay: countAsPlay,
        fallbackDurationMs: (state.duration * 1000).toInt(),
      );
      _accumulatedTime = 0;
    } else {
      _accumulatedTime = totalDuration;
    }
    _trackStartTime = state.isPlaying ? DateTime.now() : null;
  }

  final Map<String, String> _notifCoverCache = {};
  final Map<String, Future<String>> _notifCoverPending = {};
  // 本地歌通知封面高清化：path → 内嵌原图缓存文件（Rust get_song_cover 产物）。
  final Map<String, String> _hdCoverCache = {};
  final Set<String> _hdCoverPending = {};
  final Set<String> _preloadedCovers = {};
  bool _notifPermissionAsked = false;

  final List<String> _shuffleHistory = [];
  final List<String> _shuffleFuture = [];
  String? _lastPrecachedRemotePath;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _persistSession();
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台刷新听歌时长：服务端快照可能在后台期间被桌面端上报推进
      _ref.invalidate(listenStatsProvider);
    }
  }

  void _subscribePlayerStreams() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _procSub?.cancel();
    _errSub?.cancel();
    _posSub = _player.positionStream.listen((p) {
      final pos = p.inMilliseconds / 1000.0;
      final anchor = _replayAnchorSecs;
      if (anchor != null) {
        if (pos < anchor) return;
        _replayAnchorSecs = null;
      }
      state = state.copyWith(position: pos);
      _persistPositionDebounced();
      _maybePrecacheNextRemote(pos);
    });
    _durSub = _player.durationStream.listen((d) {
      final dur = (d ?? Duration.zero).inMilliseconds / 1000.0;
      if (dur <= 0 && state.duration > 0) return;
      state = state.copyWith(duration: dur);
      _syncToSystemMediaSession();
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      final playing = ps.playing;
      if (!playing &&
          ps.processingState == ProcessingState.idle &&
          _replayAnchorSecs != null) {
        return;
      }
      if (playing != state.isPlaying) {
        if (!playing) {
          AppLog.warn('playgate',
              'player PAUSED proc=${ps.processingState} origin=$_pauseOrigin');
        } else {
          AppLog.info('playgate', 'player PLAY proc=${ps.processingState}');
        }
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
      }
    });
    _procSub = _player.processingStateStream.listen((ps) {
      if (ps == ProcessingState.completed) {
        _onTrackEnd();
      }
    });
    _errSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _onPlaybackError(e);
      },
    );
  }

  Future<void> _init() async {
    AudioSession.instance.then((session) async {
      try {
        await session.configure(const AudioSessionConfiguration.music());
      } catch (e) {
        AppLog.warn('audio_session', 'configure failed: $e');
      }
      _interruptionSub = session.interruptionEventStream.listen((event) async {
        if (!event.begin) {
          if (_interruptedByInterruption) {
            _interruptedByInterruption = false;
            final auto = _ref.read(settingsProvider).valueOrNull
                    ?.autoResumeAfterInterruption ??
                true;
            if (auto && !state.isPlaying && state.current != null) {
              await _resumeAfterInterruption();
            }
          }
          return;
        }
        if (event.type == AudioInterruptionType.duck) return;
        if (event.type == AudioInterruptionType.unknown && mvSuppressFocusLoss) {
          AppLog.warn('playgate', 'ignore focus loss (mv active)');
          return;
        }
        if (state.isPlaying) {
          _interruptedByInterruption = true;
          await _pauseForInterruption();
        }
      });
    });
    _listenTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (state.isPlaying) {
        _flushPlayStats();
      }
    });
    _stallTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _checkStalledProgress();
    });
    _ref.listen(soundEffectProvider.select((s) => s.settings), (_, s) {
      _applyEffectSpeedPitch(s);
      _syncExclusiveEffects(s);
    });
    // 跳过静音：设置一改就下发给正在跑的 Rust 管线；管线没起来时不发，
    // 起播时会随启动请求一起带上（见 _tryStartExclusive/_tryStartDspPipeline）。
    _ref.listen(
      settingsProvider.select((s) => (
            s.valueOrNull?.skipSilenceEnabled ?? false,
            s.valueOrNull?.skipSilenceThresholdDb ?? -45.0,
            s.valueOrNull?.skipSilenceKeepMs ?? 500,
          )),
      (prev, next) {
        if (prev == next) return;
        _pushSkipSilence(next.$1, next.$2, next.$3);
      },
    );
    // 曲间淡入淡出：设置一变就下发给正在跑的管线；管线没起来时不发，
    // 起播后 _startExclusivePolling 会补齐（见 _pushCrossfade）。
    _ref.listen(
      settingsProvider.select((s) => (
            s.valueOrNull?.crossfadeEnabled ?? false,
            s.valueOrNull?.crossfadeSeconds ?? 5,
          )),
      (prev, next) {
        if (prev == next) return;
        _pushCrossfade(next.$1, next.$2);
      },
    );
    // 关掉「无缝播放」时要把已预排的下一首撤掉：否则槽里那一首还会被拼接，
    // 表现为「开关关了但当场不生效」（开关只影响下一次预排）。
    _ref.listen(
      settingsProvider.select((s) => s.valueOrNull?.gaplessEnabled ?? true),
      (prev, next) {
        if (prev == next || next) return;
        _gaplessNextIndex = -1;
        _gaplessNextPath = null;
        if (state.usbExclusive || state.dspActive) {
          try {
            cancelUsbExclusiveNext();
          } catch (_) {}
        }
      },
    );
    _ref.listen(favoritesProvider, (_, _) {
      _syncToSystemMediaSession();
    });
    // 下载完成联运：正在播的在线歌被下载完成 → 无缝换本地源（保进度续播）。
    // 只在 history 新增 songPath 命中当前曲目时触发，重播/删除不触发。
    _ref.listen(
      downloadProvider
          .select((s) => s.history.map((h) => h.songPath).toSet()),
      (prev, next) {
        if (prev == null || next.length <= prev.length) return;
        final cur = state.current;
        if (cur == null || !cur.isOnline) return;
        if (!next.contains(cur.path) || prev.contains(cur.path)) return;
        unawaited(_switchCurrentToLocalAfterDownload());
      },
    );
    _ref.listen(volumeProvider, (_, v) {
      try {
        _player.setVolume(_effectiveVolume());
      } catch (_) {}
      if (state.usbExclusive || state.dspActive) {
        try {
          setUsbExclusiveVolume(volume: _mvAudioOverride ? 0.0 : v);
        } catch (_) {}
      }
    });
    _ref.listen(
      settingsProvider.select((s) => s.valueOrNull?.usbExclusiveOutput ?? false),
      (prev, next) {
        if (prev != next) _onExclusiveSettingChanged(next);
      },
    );
    _ref.listen(
      settingsProvider.select((s) => s.valueOrNull?.usbExclusiveDeviceId ?? -1),
      (prev, next) {
        if (prev != next) _onOutputDeviceChanged();
      },
    );
    _ref.listen(
      settingsProvider.select((s) => (
            s.valueOrNull?.volumeBalanceEnabled ?? false,
            s.valueOrNull?.volumeBalanceGainOffsetDb ?? 0,
            s.valueOrNull?.volumeBalancePreventClipping ?? true,
          )),
      (prev, next) {
        if (prev != next) _onVolumeBalanceSettingChanged();
      },
    );
    await _restoreSession();
  }

  /// 正在播的在线歌刚下载完成：保进度换本地源。
  /// 走 _playAt 重分派（会命中本地优先总闸）；暂停中切源后维持暂停。
  Future<void> _switchCurrentToLocalAfterDownload() async {
    final cur = state.current;
    if (cur == null || !cur.isOnline) return;
    final local = await _ref
        .read(downloadProvider.notifier)
        .localFileFor(cur.path);
    if (local == null) return;
    final pos = state.position;
    final playing = state.isPlaying;
    final idx = state.queueIndex;
    AppLog.info('play',
        '[download-switch] ${cur.title} 下载完成，切本地源 $local @${pos.toStringAsFixed(1)}s');
    if (idx < 0 || idx >= state.queue.length) return;
    await _playAt(idx, startAtSecs: pos, continueStatsSession: true);
    if (!playing && state.isPlaying) {
      try {
        await _pauseForInterruption();
      } catch (_) {}
    }
  }

  Future<void> _playAt(
    int index, {
    double startAtSecs = 0,
    bool continueStatsSession = false,
    bool skipOnFailure = true,
  }) async {
    if (index < 0 || index >= state.queue.length) return;
    _playEpoch++;
    final epoch = _playEpoch;
    final wasPlaying = state.isPlaying;
    _replayAnchorSecs =
        (continueStatsSession && startAtSecs > 0) ? startAtSecs : null;

    AppLog.info('play', '_playAt index=$index path=${state.queue[index].path}');
    unawaited(_ensureNotificationPermission());
    _flushPlayStats();
    if (!continueStatsSession) {
      _currentPlayCountRecorded = false;
      _accumulatedTime = 0;
    }

    _restoredOnlinePending = null;
    _restoredLocalPending = null;
    var item = state.queue[index];
    // 本地优先总闸（对齐桌面端下载联运）：在线歌已下载且本地文件仍在
    // → 直接换本地源，不再走在线解析；未下载的歌零磁盘 IO。
    // 队列里的播链不动，本地文件被清理后自然回退在线。
    // 精确播链键未命中时再走跨源模糊匹配（同一首歌其他源的本地文件）。
    if (item.isOnline) {
      final dl = _ref.read(downloadProvider.notifier);
      var local = await dl.localFileFor(item.path);
      local ??= await dl.localFileFuzzyFor(
        title: item.title,
        artist: item.artist,
        durationMs: item.durationMs,
        excludeSongPath: item.path,
      );
      if (local != null && local != item.path) {
        AppLog.info('play', '[local-first] ${item.title} -> $local');
        item = item.withLocalFile(local);
      }
    }
    if (item.isOnline &&
        _skipDepth < state.queue.length &&
        _isOnlineSourceFailed(item)) {
      AppLog.info('play', '[playAt] 快速跳过已失败音源歌曲 path=${item.path}');
      _skipDepth++;
      final next = _pickNextIndex();
      if (next >= 0 && next != index) {
        await _playAt(next);
        return;
      }
      _skipDepth = 0;
      state = state.copyWith(
        queueIndex: index,
        current: item,
        isPlaying: false,
        resolving: false,
        error: tr('该音源的歌曲在当前设备上无法播放，请更换音源或重新搜索添加'),
      );
      _syncToSystemMediaSession();
      _showPlaybackToast(tr('该音源的歌曲均无法播放，已停止'));
      _replayAnchorSecs = null;
      return;
    }
    final prev = state.current;
    if (_activeProbeKey != null && (prev == null || prev.path != item.path)) {
      onlineQualityProbeRegistry.invalidate(_activeProbeKey!);
      _activeProbeKey = null;
    }
    if (!item.isOnline && item.coverUrl?.isNotEmpty != true) {
      try {
        await _resolveNotificationCover(item);
      } catch (_) {}
      if (epoch != _playEpoch) return;
    }
    final sameSongReplay = continueStatsSession;
    state = state.copyWith(
      queueIndex: index,
      current: item,
      isPlaying: sameSongReplay ? state.isPlaying : false,
      position: sameSongReplay && startAtSecs > 0 ? startAtSecs : 0,
      duration: item.durationMs > 0
          ? item.durationMs / 1000.0
          : (sameSongReplay ? null : 0),
      resolving: item.isOnline,
      error: null,
    );
    _syncToSystemMediaSession();
    _precacheNextCover();
    try {
        if (_ref.read(dlnaCastProvider).isCasting) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          await _castFollowPlay(item, epoch, startAtSecs: startAtSecs);
          if (epoch != _playEpoch) return;
        } else if (item.isOnline) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          if (sameSongReplay && startAtSecs > 0) {
            _replayAnchorSecs = startAtSecs;
          }
          try {
            await _player.stop();
          } catch (_) {}
          if (epoch != _playEpoch) return;
          await _playOnline(
            item,
            startAtSecs: startAtSecs,
            startPlayback: !continueStatsSession || wasPlaying,
          );
          if (epoch != _playEpoch) return;
        } else if (_isRemotePath(item.path)) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          try {
            await _player.stop();
          } catch (_) {}
          if (epoch != _playEpoch) return;
          _rgGain = 1.0;
          await _playRemote(item);
          if (epoch != _playEpoch) return;
        } else {
        var target = item.path;
        if (target.startsWith('http://') || target.startsWith('https://')) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          try {
            await _player.stop();
          } catch (_) {}
          await _startOnlineUrl(target, item: item, startAtSecs: startAtSecs);
        } else if (SafChannel.isSafPath(target)) {
          final tmp = await getTemporaryDirectory();
          target = await SafChannel.ensureLocalPlaybackCopy(
              target, p.join(tmp.path, 'saf_playback'));
        }
        await _updateRgGain(target);
        final s = _ref.read(settingsProvider).valueOrNull;
        final isDsd = _isDsdPath(target);
        final exclusiveCapable =
            !_isTranscodePath(target) || _isNativeExclusiveFormat(target);
        final useExclusive = exclusiveCapable &&
            ((s?.usbExclusiveOutput ?? false) ||
                (isDsd && (s?.dsdNativePassthrough ?? false)));
        var started = false;
        if (useExclusive) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          started = await _tryStartExclusive(target,
              startAtSecs: startAtSecs, isPlaying: true);
          if (epoch != _playEpoch) {
            await _stopExclusive();
            return;
          }
        }
        if (!started) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          try {
            await _player.stop();
          } catch (_) {}
          if (_isTranscodePath(target)) {
            final result =
                await RemoteLibraryService(_ref).transcodeToWav(target);
            target = result.path;
            await _updateRgGain(target);
          }
          started = await _tryStartDspPipeline(target,
              startAtSecs: startAtSecs, isPlaying: true);
          if (epoch != _playEpoch) {
            await _stopExclusive();
            return;
          }
        }
        if (!started) {
          await _setLocalSource(target);
          if (startAtSecs > 0) {
            try {
              await seek(startAtSecs);
            } catch (_) {}
          }
          await _player.setVolume(_effectiveVolume());
          if (epoch != _playEpoch) return;
          await _player.play();
        }
      }
      _skipDepth = 0;
      if (epoch != _playEpoch) return;
      state = state.copyWith(resolving: false, error: null);
      if (!continueStatsSession) {
        statsReporter.reportBehavior(item, 'play', 0);
        statsReporter.recordRecentPlay(item);
        statsReporter.recordHistory(item);
      }
      _trackStartTime = DateTime.now();
      _replayAnchorSecs = null;
      _syncToSystemMediaSession();
      unawaited(Future(() => _preloadQueueCovers()));
    } catch (e) {
      if (epoch != _playEpoch) {
        _shareLinkPlayback = false;
        return;
      }
      _replayAnchorSecs = null;
      state = state.copyWith(isPlaying: false, resolving: false);
      try {
        await _stopExclusive();
      } catch (_) {}
      try {
        await _player.stop();
      } catch (_) {}
      if (!skipOnFailure) {
        final msg = e is PluginEngineException
            ? e.message
            : tr('播放失败：{e}', {'e': e.toString()});
        state = state.copyWith(error: msg);
        _syncToSystemMediaSession();
        rethrow;
      }
      if (item.isOnline &&
          !_shareLinkPlayback &&
          _skipDepth < state.queue.length) {
        final recovered = await _reSearchOnlineSource(item);
        if (recovered) {
          _shareLinkPlayback = false;
          return;
        }
      }
      if (item.isOnline && _skipDepth < state.queue.length) {
        final allowSwitch = !_shareLinkPlayback
            ? true
            : (_ref
                        .read(settingsProvider)
                        .valueOrNull
                        ?.sharePlaybackFailureBehavior ??
                    'pause') ==
                'replace';
        if (allowSwitch) {
          final switched = await _autoSwitchSource(item, force: _shareLinkPlayback);
          if (switched) {
            _shareLinkPlayback = false;
            return;
          }
        }
      }
      if (item.isOnline && _skipDepth < state.queue.length) {
        final behavior = _ref
                .read(settingsProvider)
                .valueOrNull
                ?.onlineFailureBehavior ??
            'skip';
        if (behavior == 'skip') {
          _markOnlineSourceFailed(item);
          _skipDepth++;
          final next = _pickNextIndex();
          if (next >= 0 && next != index) {
            await _playAt(next);
            return;
          }
        }
      }
      if (item.isOnline) {
        final msg = e is PluginEngineException
            ? e.message
            : tr('播放失败：{e}', {'e': e.toString()});
        state = state.copyWith(error: msg);
        _showPlaybackToast(tr('在线播放失败：{e}', {'e': e.toString()}));
      } else {
        AppLog.error('play', '本地播放失败 path=${item.path} error=$e');
        state = state.copyWith(
            error: e is PluginEngineException
                ? e.message
                : tr('本地播放失败：{e}', {'e': e.toString()}));
      }
      _syncToSystemMediaSession();
    }
    _shareLinkPlayback = false;
    if (!item.isOnline) _persistSession();
  }

  Future<void> _playOnline(
    QueueItem item, {
    double startAtSecs = 0,
    bool startPlayback = true,
  }) async {
    final json = item.onlineSongJson;
    AppLog.info('play', '[playOnline] ${item.title} path=${item.path} '
        'onlineSongJson=${json?.isNotEmpty ?? false}');
    if (json != null && json.isNotEmpty) {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final s0 = _ref.read(settingsProvider).valueOrNull;
      final fb0 = s0?.onlineQualityFallbackBehavior ?? 'lower';
      final preferred = _sessionQualityOverride ??
          s0?.onlineDefaultQuality ??
          item.onlineQuality ??
          '320k';
      final candidates = _qualityCandidates(preferred, fb0);
      AppLog.info('play', '[playOnline] pluginId=${songJson['pluginId']} '
          'source=${songJson['source']} format=${songJson['format']} '
          'preferred=$preferred candidates=$candidates');

      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.ensure(
          key, _buildResolveCallback(songJson, item));
      _activeProbeKey = key;

      final start = await probe
          .startBest(preferred, candidates)
          .timeout(const Duration(seconds: 45), onTimeout: () => null);
      AppLog.info('play',
          '[playOnline] probe startBest result=${start == null ? 'NULL' : 'url=${start.url} q=${start.quality}'} '
          'available=${probe.availableQualities} probing=${probe.probing}');
      if (start != null) {
        state = state.copyWith(resolving: false);
        try {
          await _startOnlineUrl(start.url,
              headers: start.headers,
              item: item,
              ekey: start.ekey,
              cek: start.cek,
              startAtSecs: startAtSecs,
              isPlaying: startPlayback);
          state = state.copyWith(currentQuality: start.quality);
        } on _StartOnlineTimeoutException {
          final lowerChain = _lowerQualityChain(start.quality, candidates);
          if (lowerChain.isEmpty) rethrow;
          AppLog.warn('play', '[playOnline] 起播超时，降级音质重试 '
              'q=${start.quality} -> $lowerChain');
          final retry = await probe
              .startBest(lowerChain.first, lowerChain)
              .timeout(const Duration(seconds: 45), onTimeout: () => null);
          if (retry == null) rethrow;
          AppLog.info('play',
              '[playOnline] 降级重试 q=${retry.quality} url=${retry.url}');
          await _startOnlineUrl(retry.url,
              headers: retry.headers,
              item: item,
              ekey: retry.ekey,
              cek: retry.cek,
              startAtSecs: startAtSecs,
              isPlaying: startPlayback);
          state = state.copyWith(currentQuality: retry.quality);
        }
        _refreshQualityMenuState(probe);
        unawaited(_prewarmOnlineSizes(item));
        _probeMvsAround(item);
        return;
      }
      final reason = probe.lastFailureReason;
      throw StateError(reason == null
          ? tr('无法获取播放链接')
          : _shortResolveReason(reason));
    }
    final url = await _resolveOnlineUrl(item);
    if (url == null) throw StateError(tr('无法获取播放链接'));
    final infoJson = item.onlineInfoJson;
    if (infoJson != null && infoJson.isNotEmpty) {
      try {
        final infoMap = jsonDecode(infoJson) as Map<String, dynamic>;
        final seedKey = _songProbeKey(infoMap, item);
        onlineQualityProbeRegistry.seed(
            seedKey, url.quality ?? '320k', url.url,
            headers: url.headers, ekey: url.ekey, cek: url.cek);
      } catch (_) {
      }
    }
    state = state.copyWith(
      resolving: false,
      currentQuality: url.quality,
    );
    await _startOnlineUrl(url.url,
        headers: url.headers,
        item: item,
        ekey: url.ekey,
        cek: url.cek,
        startAtSecs: startAtSecs,
        isPlaying: startPlayback);
    unawaited(_prewarmOnlineSizes(item));
    _probeMvsAround(item);
  }

  void _probeMvsAround(QueueItem item) {
    try {
      final notifier = _ref.read(mvProvider.notifier);
      final idx = state.queueIndex;
      final upcoming = <QueueItem>[item];
      if (idx >= 0 && state.playMode != 1) {
        final n = state.queue.length;
        for (var k = 1; k <= 4 && n > 0; k++) {
          final it = state.queue[(idx + k) % n];
          if (it.isOnline && it.onlineSongJson != null) upcoming.add(it);
        }
      }
      unawaited(notifier.probeQueueMvs(upcoming));
    } catch (_) {}
  }

  static int? _parseQualitySize(dynamic size) {
    if (size is num) return size > 0 ? size.toInt() : null;
    if (size is! String) return null;
    final s = size.trim().toLowerCase();
    if (s.isEmpty ||
        s == '0' ||
        s == '未知' ||
        s == 'unknown' ||
        s == '--' ||
        s == '-') {
      return null;
    }
    final m = RegExp(r'^([\d.]+)\s*([kmgt]?b?)$').firstMatch(s);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || v <= 0) return null;
    final unit = m.group(2)!;
    final mult = switch (unit) {
      'k' || 'kb' => 1024.0,
      'm' || 'mb' => 1024.0 * 1024,
      'g' || 'gb' => 1024.0 * 1024 * 1024,
      't' || 'tb' => 1024.0 * 1024 * 1024 * 1024,
      _ => 1.0,
    };
    return (v * mult).round();
  }

  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  static List<String> _qualityCandidates(
    String preferred, [
    String fallback = 'lower',
  ]) {
    final avail = _qualityLadder;
    final result = <String>[];
    if (avail.contains(preferred)) result.add(preferred);
    final idx = avail.indexOf(preferred);
    if (idx != -1) {
      if (fallback == 'higher') {
        for (var i = idx + 1; i < avail.length; i++) {
          result.add(avail[i]);
        }
      } else if (fallback == 'lower') {
        for (var i = idx - 1; i >= 0; i--) {
          result.add(avail[i]);
        }
      }
    }
    if (fallback == 'pause') return result.isNotEmpty ? result : [preferred];
    if (result.isEmpty && avail.isNotEmpty) result.add(avail.first);
    return result;
  }

  static String _normSongText(String input) {
    var s = input.toLowerCase();
    s = s.replaceAll(RegExp(r'[（(【\[][^）)】\]]*[）)】\]]'), '');
    s = s.replaceAll(RegExp(r"[\s'’`·・~～!！?？.。,，、]"), '');
    return s.trim();
  }

  static String _firstArtistOf(String artist) {
    final parts = artist.split(RegExp(r'[/、,&]'));
    return parts.isEmpty ? '' : parts.first.trim();
  }

  static int _intervalStrToMs(String interval) {
    final m = RegExp(r'^(\d+):(\d+)$').firstMatch(interval.trim());
    if (m == null) return 0;
    return (int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)) * 1000;
  }

  static List<String> _lowerQualityChain(
    String current,
    List<String> candidates,
  ) {
    final curRank = _qualityLadder.indexOf(current);
    if (curRank < 0) return const [];
    return candidates
        .where((q) => _qualityLadder.indexOf(q) < curRank)
        .toList(growable: false);
  }

  static bool _isPlayableUrl(String? url) =>
      url != null && RegExp(r'^https?://').hasMatch(url);

  static bool _isRemotePath(String path) => path.startsWith('remote://');

  static bool _isTranscodePath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.ape') ||
        lower.endsWith('.wv') ||
        lower.endsWith('.aif') ||
        lower.endsWith('.aiff')) {
      return true;
    }
    return const [
      '.mgg', '.mgg0', '.mggl', '.mflac', '.mflac0',
      '.qmc0', '.qmc2', '.qmc3', '.qmcflac', '.qmcogg',
    ].any(lower.endsWith);
  }

  static bool _isNativeExclusiveFormat(String path) {
    final lower = path.toLowerCase();
    if (_isDsdPath(lower)) return true;
    if (lower.endsWith('.aif') || lower.endsWith('.aiff')) return true;
    return const [
      '.mgg', '.mgg0', '.mggl', '.mflac', '.mflac0',
      '.qmc0', '.qmc2', '.qmc3', '.qmcflac', '.qmcogg',
    ].any(lower.endsWith);
  }

  static bool _isDsdPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.dsf') ||
        lower.endsWith('.dff') ||
        lower.endsWith('.dsd');
  }

  // ==================== 音量平衡 ====================

  double _rgGain = 1.0;

  bool _mvAudioOverride = false;

  double _mvSongGain = 1.0;

  static const int _decryptCacheMax = 48;
  final Map<String, String> _decryptPathCache = {};

  static bool _matchOnlineTitle(String a, String b) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_（）()【】\[\].、，,·/\\+&]'), '');
    final na = norm(a);
    final nb = norm(b);
    if (na == nb) return true;
    if (na.length >= 3 && nb.length >= 3) {
      return na.contains(nb) || nb.contains(na);
    }
    return false;
  }

  Future<void> toggleFavoriteFromSystem() async {
    final item = state.current;
    if (item == null) return;
    await _ref.read(favoritesProvider.notifier).toggle(item);
    _syncToSystemMediaSession();
  }

  Future<void> resumeFromSystem() async {
    if (state.isPlaying) return;
    await toggle();
  }

  /// 睡眠定时淡出因子（1.0 = 不淡出），睡眠定时到点时在约 1.2s 内降到 0。
  ///
  /// 乘进 [_effectiveVolume] 而不去写裸音量：这套栈里音量是**算出来的**
  /// （用户音量 × 均衡/RG 增益），裸写会被别处多次 `setVolume(_effectiveVolume())`
  /// 重算覆盖、也会冲掉均衡增益；作为因子进入计算则处处自动生效。
  double _sleepFade = 1.0;
  bool _sleepFadeBusy = false;

  Future<void> _sleepFadeOutAndPause() async {
    if (_sleepFadeBusy) return;
    _sleepFadeBusy = true;
    try {
      // Keep the user's effective volume and all DSP/RG gains intact; only
      // multiply a temporary fade factor into _effectiveVolume().
      for (var step = 20; step >= 0; step--) {
        _sleepFade = step / 20;
        await _player.setVolume(_effectiveVolume());
        if (step != 0) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
      }
      await pauseFromSystem(origin: 'sleepTimer');
    } finally {
      _sleepFade = 1.0;
      try {
        await _player.setVolume(_effectiveVolume());
      } catch (_) {}
      _sleepFadeBusy = false;
    }
  }

  /// 暂停来源标签：release（AOT）下 StackTrace.current 的前几行是崩溃横幅
  /// （`*** ***` / pid-tid / os 行），取前 3~4 行拿不到任何真实调用帧，
  /// 诊断形同虚设。改为显式传递来源，日志里直接可读。
  String _pauseOrigin = 'unknown';

  Future<void> pauseFromSystem({String origin = 'unknown'}) async {
    if (!state.isPlaying) return;
    _pauseOrigin = origin;
    final st =
        StackTrace.current.toString().split('\n').take(3).join(' <- ');
    AppLog.warn('playgate', 'pauseFromSystem[$origin] $st');
    await toggle();
  }

  DateTime _lastUserPauseAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get lastUserPauseAt => _lastUserPauseAt;

  Future<void> resumeAfterMvPause() async {
    AppLog.warn('playgate', 'resume after mv focus-fight pause');
    await _player.play();
  }

  bool mvSuppressFocusLoss = false;

  Future<void> _pauseForInterruption() async {
    if (_ref.read(dlnaCastProvider).isCasting) return;
    // 走 _player.pause() 不经 toggle，必须在这里自己标注来源：日志里
    // 「player PAUSED origin=interruption」即可与其它暂停路径区分
    _pauseOrigin = 'audioInterruption';
    AppLog.warn('playgate', 'interruption pause origin=$_pauseOrigin');
    try {
      if (state.usbExclusive || state.dspActive) {
        await pauseUsbExclusive();
      } else {
        await _player.pause();
      }
    } catch (e) {
      AppLog.warn('playgate', 'interruption pause failed: $e');
    }
    state = state.copyWith(isPlaying: false);
    _syncToSystemMediaSession();
    _persistSession();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _showPlaybackToast(tr('音频输出被其他应用占用，已暂停'));
    }
  }

  Future<void> _resumeAfterInterruption() async {
    if (_ref.read(dlnaCastProvider).isCasting) return;
    try {
      _trackStartTime = DateTime.now();
      if (state.usbExclusive || state.dspActive) {
        await resumeUsbExclusive();
      } else {
        await _player.play();
      }
    } catch (e) {
      AppLog.warn('playgate', 'interruption resume failed: $e');
      return;
    }
    state = state.copyWith(isPlaying: true);
    _syncToSystemMediaSession();
    _persistSession();
  }

  Future<void> toggle({String origin = 'unknown'}) async {
    if (state.current == null) return;
    if (origin != 'unknown') _pauseOrigin = origin;
    AppLog.info('playgate',
        'toggle cur=${state.isPlaying ? "play->pause" : "pause->play"} '
        'origin=$_pauseOrigin');
    _pauseOrigin = 'unknown';
    if (_ref.read(dlnaCastProvider).isCasting) {
      final cast = _ref.read(dlnaCastProvider.notifier);
      if (state.isPlaying) {
        _flushPlayStats();
        await cast.castPause();
        state = state.copyWith(isPlaying: false);
      } else {
        _trackStartTime = DateTime.now();
        await cast.castResume();
        state = state.copyWith(isPlaying: true);
      }
      _syncToSystemMediaSession();
      return;
    }
    if (state.usbExclusive || state.dspActive) {
      if (state.isPlaying) {
        _flushPlayStats();
        _lastUserPauseAt = DateTime.now();
        await pauseUsbExclusive();
        state = state.copyWith(isPlaying: false);
      } else {
        _trackStartTime = DateTime.now();
        await resumeUsbExclusive();
        state = state.copyWith(isPlaying: true);
      }
      _syncToSystemMediaSession();
      _persistSession();
      return;
    }
    if (state.isPlaying) {
      _flushPlayStats();
      _lastUserPauseAt = DateTime.now();
      await _player.pause();
    } else {
      _trackStartTime = DateTime.now();
      final pendingPos = _restoredOnlinePending;
      if (pendingPos != null) {
        _restoredOnlinePending = null;
        final idx = state.queueIndex;
        if (idx >= 0 && idx < state.queue.length) {
          try {
            await _playAt(idx, startAtSecs: pendingPos, skipOnFailure: false);
          } catch (_) {
          }
          _persistSession();
          return;
        }
      }
      final pendingLocalPos = _restoredLocalPending;
      if (pendingLocalPos != null) {
        _restoredLocalPending = null;
        final idx = state.queueIndex;
        if (idx >= 0 && idx < state.queue.length) {
          await _playAt(idx, startAtSecs: pendingLocalPos);
          _persistSession();
          return;
        }
      }
      await _player.play();
    }
    _syncToSystemMediaSession();
    _persistSession();
  }

  Future<void> seek(double secs) async {
    final st = StackTrace.current.toString().split('\n').take(4).join(' <- ');
    AppLog.info('play', '[seek] t=$secs $st');
    if (_ref.read(dlnaCastProvider).isCasting) {
      await _ref.read(dlnaCastProvider.notifier).castSeek(secs);
      state = state.copyWith(position: secs);
      _syncToSystemMediaSession();
      return;
    }
    if (_restoredOnlinePending != null) {
      _restoredOnlinePending = secs;
      state = state.copyWith(position: secs);
      _syncToSystemMediaSession();
      return;
    }
    if (state.usbExclusive || state.dspActive) {
      await seekUsbExclusive(timeSecs: secs, isPlaying: state.isPlaying);
      state = state.copyWith(position: secs);
      _syncToSystemMediaSession();
      return;
    }
    await _player.seek(Duration(milliseconds: (secs * 1000).round()));
    _syncToSystemMediaSession();
  }

  Future<void> next() async {
    final i = _pickNextIndex();
    if (i >= 0) await _playAt(i);
  }

  Future<void> previous() async {
    if (state.position > 3) {
      await seek(0);
      return;
    }
    final n = state.queue.length;
    if (n == 0) return;
    if (state.playMode == 2) {
      final i = _randomPrevIndex();
      if (i >= 0) await _playAt(i);
      return;
    }
    final i = state.queueIndex <= 0 ? n - 1 : state.queueIndex - 1;
    await _playAt(i);
  }

  void _showPlaybackToast(String message) {
    final overlay = appNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    showXianYuToastByOverlay(overlay, message);
  }

  Future<void> _onPlaybackError(Object e) async {
    if (_playbackErrorHandling) return;
    final item = state.current;
    if (item == null) return;
    AppLog.error('play', '播放器错误 path=${item.path} error=$e');
    _playbackErrorHandling = true;
    try {
      state = state.copyWith(isPlaying: false);
      _syncToSystemMediaSession();
      if (item.isOnline) {
        final behavior = _ref
                .read(settingsProvider)
                .valueOrNull
                ?.onlineFailureBehavior ??
            'skip';
        final switched = await _autoSwitchSource(item);
        if (switched) return;
        if (state.current?.path != item.path) return;
        if (behavior == 'skip') {
          _markOnlineSourceFailed(item);
          _skipDepth++;
          final next = _pickNextIndex();
          if (next >= 0 && next != state.queueIndex) {
            await _playAt(next);
            return;
          }
        }
        state = state.copyWith(
          error: tr('播放失败：{e}', {'e': e.toString()}),
          isPlaying: false,
        );
        _showPlaybackToast(behavior == 'autoswitch'
            ? tr('在线播放失败，已自动换源无果，请重试或更换音源')
            : tr('在线播放失败：{e}', {'e': e.toString()}));
        _syncToSystemMediaSession();
      } else {
        if (state.current?.path != item.path) return;
        state = state.copyWith(
          error: tr('本地播放失败：{e}', {'e': e.toString()}),
          isPlaying: false,
        );
        _syncToSystemMediaSession();
      }
    } finally {
      _playbackErrorHandling = false;
    }
  }

  Future<void> _handleBrokenOnlineStream(QueueItem item) async {
    if (_playbackErrorHandling) return;
    _playbackErrorHandling = true;
    try {
      state = state.copyWith(isPlaying: false, resolving: true);
      final behavior = _ref
              .read(settingsProvider)
              .valueOrNull
              ?.onlineFailureBehavior ??
          'skip';
      final switched = await _autoSwitchSource(item);
      if (switched) return;
      if (state.current?.path != item.path) return;
      if (behavior == 'skip') {
        _markOnlineSourceFailed(item);
        _skipDepth++;
        final next = _pickNextIndex();
        if (next >= 0 && next != state.queueIndex) {
          await _playAt(next);
          return;
        }
      }
      final msg = behavior == 'autoswitch'
          ? tr('在线音源已失效，未能自动换源')
          : tr('在线音源已失效');
      state = state.copyWith(
        error: msg,
        isPlaying: false,
        resolving: false,
      );
      _showPlaybackToast(msg);
      _syncToSystemMediaSession();
    } finally {
      _playbackErrorHandling = false;
    }
  }

  void _checkStalledProgress() {
    if (state.usbExclusive || state.dspActive) return;
    if (!state.isPlaying ||
        _playbackErrorHandling ||
        _onTrackEndBusy ||
        state.resolving ||
        _ref.read(dlnaCastProvider).isCasting) {
      _resetStallTracking();
      return;
    }
    final item = state.current;
    if (item == null) return;
    final pos = state.position;
    if (pos <= 0 || _stallLastPos < 0 || (pos - _stallLastPos).abs() >= 0.05) {
      _stallLastPos = pos;
      _stallTicks = 0;
    } else {
      _stallTicks++;
    }
    final dur = state.duration;
    if (dur > 0 && pos >= dur - 0.3) {
      _resetStallTracking();
      AppLog.warn('play',
          '[stall] 进度到达末尾未收到 completed，兜底切歌 pos=$pos dur=$dur');
      unawaited(_onTrackEnd());
      return;
    }
    final unknownDur = dur <= 0;
    final nearEnd = dur > 0 && pos >= dur - 3;
    final required = item.isOnline ? 12 : 4;
    if (_stallTicks >= required && (unknownDur || nearEnd)) {
      _resetStallTracking();
      AppLog.warn('play',
          '[stall] 进度停滞判定为播放结束 pos=$pos dur=$dur '
          'online=${item.isOnline} ticks=$required');
      unawaited(_onTrackEnd());
    }
  }

  void _resetStallTracking() {
    _stallLastPos = -1;
    _stallTicks = 0;
  }

  String? _onlineSourceKey(QueueItem item) {
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json != null && json.isNotEmpty) {
      try {
        final m = jsonDecode(json) as Map<String, dynamic>;
        final pid = m['pluginId'];
        if (pid is String && pid.isNotEmpty) return 'plugin:$pid';
        final src = m['source'];
        if (src is String && src.isNotEmpty) return 'lx:$src';
      } catch (_) {}
    }
    final src = item.source;
    if (src != null && src.isNotEmpty) return 'lx:$src';
    return null;
  }

  void _markOnlineSourceFailed(QueueItem item) {
    final key = _onlineSourceKey(item);
    if (key == null) return;
    _failedOnlineSources[key] = DateTime.now();
    if (_failedOnlineSources.length > 32) {
      _failedOnlineSources.remove(_failedOnlineSources.keys.first);
    }
  }

  bool _isOnlineSourceFailed(QueueItem item) {
    final key = _onlineSourceKey(item);
    if (key == null) return false;
    final t = _failedOnlineSources[key];
    if (t == null) return false;
    if (DateTime.now().difference(t) > const Duration(minutes: 10)) {
      _failedOnlineSources.remove(key);
      return false;
    }
    return true;
  }

  Future<void> _onTrackEnd() async {
    if (_onTrackEndBusy) return;
    _onTrackEndBusy = true;
    try {
      await _onTrackEndInner();
    } finally {
      _onTrackEndBusy = false;
    }
  }

  Future<void> _onTrackEndInner() async {
    final ended = state.current;
    if (ended != null &&
        ended.isOnline &&
        !_playbackErrorHandling &&
        _skipDepth < state.queue.length) {
      final declaredMs = ended.durationMs;
      final actualMs = state.duration * 1000.0;
      if (declaredMs >= 30000 &&
          actualMs > 0 &&
          actualMs < declaredMs * 0.5 &&
          actualMs < 15000) {
        AppLog.warn('play', '[onTrackEnd] 在线流异常完成 '
            'declared=${declaredMs}ms actual=${actualMs}ms path=${ended.path}');
        await _handleBrokenOnlineStream(ended);
        return;
      }
    }
    if (ended != null) statsReporter.reportBehavior(ended, 'complete', 0);
    _flushPlayStats();
    if (state.playMode == 1) {
      await seek(0);
      await _player.play();
      _trackStartTime = DateTime.now();
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      // 队列播完自动停：不经 toggle，自行标注来源
      _pauseOrigin = 'queueEnded';
      await _player.pause();
      if (state.current != null) await seek(0);
      return;
    }
    await _playAt(next);
  }

  @override
  void dispose() {
    _ref.read(sleepTimerProvider.notifier).onFire = null;
    _listenTimer?.cancel();
    _stallTimer?.cancel();
    _exclusiveTimer?.cancel();
    _sfxSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _procSub?.cancel();
    _errSub?.cancel();
    _interruptionSub?.cancel();
    try {
      stopUsbExclusivePlayback();
    } catch (_) {}
    _player.dispose();
    super.dispose();
  }
}

final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ?? 1.0;
});

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>(
  (ref) => PlayerNotifier(ref),
);
