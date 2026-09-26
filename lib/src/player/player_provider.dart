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
import 'audio_proxy_server.dart';
import 'media_url.dart';
import 'cast_provider.dart';
import 'online_quality_probe.dart';
import 'online_precache.dart';
import '../i18n/i18n.dart';

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

  /// 把整个播放队列同步给系统媒体会话，使系统 MediaSession/鸿蒙播控中心
  /// 能拿到当前在播项的队列下标（active item id），否则鸿蒙判定会话「未在播放」。
  /// 队列元素与 [syncPlaybackState] 的 queueIndex 按下标对齐。
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
      return Uri.tryParse(url);
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
      return Uri.tryParse(url);
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
      final bytes = await CoverProxy.fetch(url);
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
  Future<void> pause() => _notifier?.pauseFromSystem() ?? Future.value();

  @override
  Future<void> skipToNext() => _notifier?.next() ?? Future.value();

  @override
  Future<void> skipToPrevious() => _notifier?.previous() ?? Future.value();

  @override
  Future<void> seek(Duration position) =>
      _notifier?.seek(position.inMilliseconds / 1000.0) ?? Future.value();

  @override
  Future<void> stop() => _notifier?.pauseFromSystem() ?? Future.value();

  @override
  Future<void> onTaskRemoved() async {
    await _notifier?.pauseFromSystem();
    await super.stop();
    // 划掉多任务卡片=彻底退出。audio_service 前台服务/悬浮歌词/DSP 引擎
    // 全在同一进程，仅 stop 服务后进程仍存活，荣耀 MagicOS 会把空进程
    // 重新挂回最近任务（表现为"划了又回来，要再滑一次"）。直接退出进程，
    // 通知、悬浮窗随进程回收，卡片不再回挂。
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
  });

  bool get isOnline =>
      path.startsWith('lx://') ||
      path.startsWith('plugin://') ||
      onlineInfoJson != null;

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
    );
  }
}

const Object _noChange = Object();

typedef BeforePlayGate = Future<void> Function();

/// 在线起播 10s 超时（load 挂死）。与普通失败区分，供 _playOnline
/// 做同曲降级音质重试，避免被误当作「换候选/跳歌」以外的失败。
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

  // 记录最近一次起播音源，供 MV 频谱对齐（mv_auto_sync）取当前歌曲音频。
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
    // 初始订阅五路流（位置/时长/播放态/处理态/错误）。此前订阅内联在 _init 里，
    // 抽出 _subscribePlayerStreams 供楔死重建复用后，构造里漏了初始调用——
    // 表现为进度条不走、播放状态不广播、通知栏播控失效。
    _subscribePlayerStreams();
    _init();
  }

  final Ref _ref;
  // 非.final：平台主线程被挂死的 ExoPlayer release 阻塞时（楔死），需整体
  // 重建播放器实例（新 UUID 不与原生残留注册撞号）才能恢复，见 _rebuildPlayer。
  AudioPlayer _player = _GatedAudioPlayer();
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
  // DSP 管线失败冷却：一次失败禁 60s 后自动重试（失败是立即报错，
  // 重试仅毫秒级开销），避免一次瞬时/环境性失败把 DSP 禁用到会话结束
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
  bool _shareLinkPlayback = false;
  String? _sessionQualityOverride;
  // 同曲重播（切音质）锚定门：加载新直链的窗口期内 _player.stop() 会让
  // positionStream 吐 0、playerStateStream 吐 playing=false，若放行会把 UI
  // 进度冲归零、按钮翻暂停（对齐桌面 reanchorPlaybackClock + requestId 守卫：
  // 桌面同曲重播全程保持进度与播放态显示，无跳变）。门在 _playAt 起播请求
  // 生命周期内有效：位置事件 < 锚点一律吞掉，播放态仅吞 idle（stop 所致），
  // 真实起播（ready/buffering 的 playing=true 或位置 ≥ 锚点）自然放行。
  double? _replayAnchorSecs;

  static const MethodChannel _diagChannel = MethodChannel('xianyu/diag');

  /// ExoPlayer 卡死现场转储：问题设备在用户手上无 adb，将原生播放器相关
  /// 线程（ExoPlayer Loader/媒体编解码/音频）堆栈写入 App 日志，随「导出
  /// 日志」回收。栈帧落在 socketRead=网络层挂、MediaCodec=解码初始化挂、
  /// Object.wait(LoadControl)=缓冲逻辑，一望即知。
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
  DateTime? _trackStartTime;
  double _accumulatedTime = 0;
  bool _currentPlayCountRecorded = false;
  final Map<String, String> _notifCoverCache = {};
  final Map<String, Future<String>> _notifCoverPending = {};
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
    }
  }

  /// 订阅当前 _player 的五路流（位置/时长/播放态/处理态/错误）。
  /// 楔死重建换新实例后必须重跑，否则 UI 与统计全部失聪。
  void _subscribePlayerStreams() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _procSub?.cancel();
    _errSub?.cancel();
    _posSub = _player.positionStream.listen((p) {
      final pos = p.inMilliseconds / 1000.0;
      // 同曲重播加载窗口：新源尚未就绪时的归零/回跳位置事件一律吞掉，
      // 保持 UI 锚定在续播点（首个 ≥ 锚点的事件放行并撤门）
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
      // 播放器没载入音源时这里会收到 null。冷启动恢复会话时时长来自元数据，
      // 被这一条冲成 0 会连带把进度条画成满格（position 被 clamp 到 max=1.0），
      // 要手动点一次播放才恢复。已经拿到正时长时忽略 0。
      if (dur <= 0 && state.duration > 0) return;
      state = state.copyWith(duration: dur);
      _syncToSystemMediaSession();
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      final playing = ps.playing;
      // 同曲重播加载窗口：stop() 引发的 idle+playing=false 不放行，避免
      // UI 播放态被翻成暂停；真实暂停（loading/ready 态）不受影响
      if (!playing &&
          ps.processingState == ProcessingState.idle &&
          _replayAnchorSecs != null) {
        return;
      }
      if (playing != state.isPlaying) {
        if (!playing) {
          final st = StackTrace.current
              .toString()
              .split('\n')
              .take(4)
              .join(' <- ');
          AppLog.warn('playgate',
              'player PAUSED proc=${ps.processingState} $st');
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

  /// 楔死探测：向 xianyu/diag 发一次 ping（原生主线程执行，notImplemented
  /// 也算响应）。2s 内无任何回包说明主线程被挂死的 ExoPlayer release/dispose
  /// 阻塞——表现为 setUrl 静默挂到起播超时（proc=idle、buffered=0、exodump
  /// 无任何加载任务）。用 diag 通道而非 player 自身调用：stop 后平台可能
  /// 已降级到 idle 代理，player 调用会「假成功」探测不到楔死。
  Future<void> _probeAndRebuild(String reason) async {
    if (_rebuildingPlayer) return;
    try {
      await const MethodChannel('xianyu/diag')
          .invokeMethod<Object>('ping')
          .timeout(const Duration(seconds: 2));
      return; // 主线程有响应，不重建
    } on TimeoutException {
      // 主线程无响应 → 楔死，走重建
    } catch (_) {
      return; // notImplemented/MissingPlugin 等错误同样证明通道有响应
    }
    await _rebuildPlayer(reason);
  }

  /// 重建播放器实例：旧实例 native 侧可能已永久挂死，且其 dispose 通道调用
  /// 不可信，因此直接弃用换新（新 UUID 不与原生残留注册撞号，主线程恢复后
  /// 即可正常工作）。dispose 用超时保护，绝不阻塞重建本身。
  Future<void> _rebuildPlayer(String reason) async {
    if (_rebuildingPlayer) return;
    _rebuildingPlayer = true;
    try {
      final old = _player;
      AppLog.warn('play', '[player-rebuild] 重建播放器通道 reason=$reason');
      unawaited(old.dispose().catchError((_) {}).timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              AppLog.warn('play', '[player-rebuild] 旧实例 dispose 挂起，放弃等待');
            },
          ));
      _player = _GatedAudioPlayer();
      _subscribePlayerStreams();
      try {
        await _player.setVolume(_effectiveVolume())
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    } finally {
      _rebuildingPlayer = false;
    }
  }

  Future<void> _init() async {
    AudioSession.instance.then((session) async {
      // 声明为音乐媒体会话（USAGE_MEDIA + CONTENT_TYPE_MUSIC）。不配置时系统
      // 收到 CONTENT_TYPE_UNKNOWN，鸿蒙播控中心/系统媒体卡片不会把它当音乐播控源，
      // 表现为通知栏可见但控制中心「未在播放」。
      try {
        await session.configure(const AudioSessionConfiguration.music());
      } catch (e) {
        AppLog.warn('audio_session', 'configure failed: $e');
      }
      _interruptionSub = session.interruptionEventStream.listen((event) async {
        if (!event.begin) {
          // 临时打断（来电/导航语音）结束：仅当打断期间暂停过且设置允许时
          // 自动恢复。永久焦点丢失（type=unknown）不会有结束事件。
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
    _ref.listen(favoritesProvider, (_, _) {
      _syncToSystemMediaSession();
    });
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

  Future<void> _onExclusiveSettingChanged(bool enabled) async {
    final item = state.current;
    if (item == null || item.isOnline || _isRemotePath(item.path)) return;
    final pos = state.position;
    final playing = state.isPlaying;
    var target = item.path;
    if (SafChannel.isSafPath(target)) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          target, p.join(tmp.path, 'saf_playback'));
    }
    if (enabled) {
      if (state.usbExclusive) return;
      final ok =
          await _tryStartExclusive(target, startAtSecs: pos, isPlaying: playing);
      if (ok) {
        try {
          await _player.stop();
        } catch (_) {}
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
      }
    } else {
      if (!state.usbExclusive) return;
      await _stopExclusive();
      final ok =
          await _tryStartDspPipeline(target, startAtSecs: pos, isPlaying: playing);
      if (ok) {
        try {
          await _player.stop();
        } catch (_) {}
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
        return;
      }
      try {
        await _updateRgGain(target);
        await _setLocalSource(target);
        await _player.setVolume(_effectiveVolume());
        await _player.seek(Duration(milliseconds: (pos * 1000).round()));
        if (playing) {
          await _player.play();
        } else {
          await _player.pause();
        }
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
      } catch (e) {
        AppLogger.instance
            .log('exclusive', '关闭 USB 独占后恢复普通播放失败: $e');
        state = state.copyWith(isPlaying: false);
        _syncToSystemMediaSession();
      }
    }
  }

  Future<void> _onOutputDeviceChanged() async {
    if (!state.usbExclusive && !state.dspActive) return;
    final item = state.current;
    if (item == null || item.isOnline || _isRemotePath(item.path)) return;
    final pos = state.position;
    final playing = state.isPlaying;
    var target = item.path;
    if (SafChannel.isSafPath(target)) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          target, p.join(tmp.path, 'saf_playback'));
    }
    final wantExclusive =
        _ref.read(settingsProvider).valueOrNull?.usbExclusiveOutput ?? false;
    await _stopExclusive();
    var ok = false;
    if (wantExclusive) {
      ok = await _tryStartExclusive(target,
          startAtSecs: pos, isPlaying: playing);
    } else {
      ok = await _tryStartDspPipeline(target,
          startAtSecs: pos, isPlaying: playing);
    }
    if (ok) {
      try {
        await _player.stop();
      } catch (_) {}
      state = state.copyWith(isPlaying: playing);
      _syncToSystemMediaSession();
      return;
    }
    try {
      await _updateRgGain(target);
      await _setLocalSource(target);
      await _player.setVolume(_effectiveVolume());
      await _player.seek(Duration(milliseconds: (pos * 1000).round()));
      if (playing) {
        await _player.play();
      } else {
        await _player.pause();
      }
      state = state.copyWith(isPlaying: playing);
      _syncToSystemMediaSession();
    } catch (_) {}
  }

  Future<bool> _tryStartExclusive(
    String path, {
    required double startAtSecs,
    required bool isPlaying,
  }) async {
    // 独占/共享 DSP 分支不经 _GatedAudioPlayer：本地文件在此兜底记录
    //（http 代理 URL 由 _startOnlineUrl 记录，此处不覆盖）。
    if (!path.startsWith('http')) {
      LastAudioSource.recordFilePath(path);
    }
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      final settings = _ref.read(settingsProvider).valueOrNull;
      final bitPerfect = settings?.bitPerfectOutput ?? false;
      final dsd = settings?.dsdNativePassthrough ?? false;
      await startUsbExclusivePlayback(
        path: path,
        deviceId: settings?.usbExclusiveDeviceId ?? -1,
        volume: _mvAudioOverride ? 0.0 : _ref.read(volumeProvider),
        startTimeSecs: startAtSecs,
        isPlaying: isPlaying,
        volumeBalanceGain: bitPerfect ? 1.0 : _effectiveBalanceGain(),
        equalizerSettingsJson: bitPerfect ? '' : jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: bitPerfect ? '' : jsonEncode(sfx.toRustJson()),
        bitPerfect: bitPerfect,
        dsdNativePassthrough: dsd,
        sharedMode: false,
      );
      state = state.copyWith(usbExclusive: true, isPlaying: isPlaying);
      _startExclusivePolling();
      _syncToSystemMediaSession();
      return true;
    } catch (e) {
      state = state.copyWith(usbExclusive: false);
      AppLogger.instance.log('exclusive', 'USB 独占输出启动失败，回退普通播放: $e');
      return false;
    }
  }

  Future<bool> _tryStartDspPipeline(
    String path, {
    required double startAtSecs,
    required bool isPlaying,
    // 在线流缓存直读（对齐桌面端 StreamingTempFile 模型）：Some 时 Rust 管线
    // 经流缓存 Reader 解码（复用预热线程，单上游连接），path 仅作回退记录。
    String? streamCacheUrl,
    Map<String, String>? streamCacheHeaders,
  }) async {
    if (DateTime.now().isBefore(_dspFailUntil)) {
      AppLog.warn('play', '[dsp] 跳过接管: 失败冷却中(至 $_dspFailUntil)');
      return false;
    }
    if (_dspSkipNextStart) {
      _dspSkipNextStart = false;
      AppLog.warn('play', '[dsp] 跳过接管: skipNextStart 标志(管线曾异常退出)');
      return false;
    }
    if (!path.startsWith('http')) {
      LastAudioSource.recordFilePath(path);
    }
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      final settings = _ref.read(settingsProvider).valueOrNull;
      final deviceName = await startUsbExclusivePlayback(
        path: path,
        deviceId: settings?.usbExclusiveDeviceId ?? -1,
        volume: _mvAudioOverride ? 0.0 : _ref.read(volumeProvider),
        startTimeSecs: startAtSecs,
        isPlaying: isPlaying,
        volumeBalanceGain: _effectiveBalanceGain(),
        equalizerSettingsJson: jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: jsonEncode(sfx.toRustJson()),
        bitPerfect: false,
        dsdNativePassthrough: false,
        sharedMode: true,
        streamCacheUrl: streamCacheUrl,
        streamCacheHeaders: streamCacheHeaders == null
            ? null
            : jsonEncode(streamCacheHeaders),
      );
      state = state.copyWith(usbExclusive: false, dspActive: true, isPlaying: isPlaying);
      _startExclusivePolling();
      _syncToSystemMediaSession();
      AppLog.info('play', '[dsp] 共享管线接管成功: $deviceName');
      return true;
    } catch (e) {
      state = state.copyWith(dspActive: false);
      // 失败进入 60s 冷却，之后自动重试（成功即恢复接管）
      _dspFailUntil = DateTime.now().add(const Duration(seconds: 60));
      AppLog.warn('play', '[dsp] 启动失败(60s冷却后重试) 回退ExoPlayer: $e');
      return false;
    }
  }

  Future<void> _stopExclusive() async {
    _stopExclusivePolling();
    try {
      await stopUsbExclusivePlayback();
    } catch (_) {}
    if (state.usbExclusive || state.dspActive) {
      state = state.copyWith(usbExclusive: false, dspActive: false);
    }
  }

  void _startExclusivePolling() {
    _stopExclusivePolling();
    _exclusiveTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _pollExclusive(),
    );
  }

  void _stopExclusivePolling() {
    _exclusiveTimer?.cancel();
    _exclusiveTimer = null;
  }

  Future<void> _pollExclusive() async {
    if (!state.usbExclusive && !state.dspActive) return;
    try {
      final pos = await getUsbExclusivePositionSecs();
      state = state.copyWith(position: pos);
      _syncToSystemMediaSession();
      _persistPositionDebounced();
      _maybePrecacheNextRemote(pos);
      final infoStr = await getUsbExclusiveDeviceInfo();
      final info = jsonDecode(infoStr) as Map<String, dynamic>;
      final engineDur = (info['durationSecs'] as num?)?.toDouble() ?? 0.0;
      if (engineDur > 0) {
        state = state.copyWith(duration: engineDur);
      }
      final dur = state.duration;
      if (info['active'] != true) {
        final lastErr = (info['lastError'] as String?)?.trim() ?? '';
        AppLog.warn('play',
            '[dsp] 轮询发现 active=false pos=${pos.toStringAsFixed(1)} lastError=$lastErr');
        if (dur > 0 && pos >= dur - 0.3) {
          await _onExclusiveTrackEnd();
        } else {
          await _onExclusiveDisconnect();
        }
        return;
      }
      if (dur > 0 && pos >= dur - 0.3) {
        await _onExclusiveTrackEnd();
      }
    } catch (_) {}
  }

  Future<void> _onExclusiveDisconnect() async {
    final cur = state.current;
    _flushPlayStats();
    AppLog.warn('play',
        '[dsp] 管线提前退出(active=false) 自动重播回退 cur=${cur?.title}');
    if (cur != null) _reportBehavior(cur, 'usb_disconnect', 0);
    await _stopExclusive();
    _dspSkipNextStart = true;
    if (cur == null) return;
    await _playAt(state.queueIndex);
  }

  Future<void> _onExclusiveTrackEnd() async {
    final ended = state.current;
    if (ended != null) _reportBehavior(ended, 'complete', 0);
    _flushPlayStats();
    await _stopExclusive();
    if (state.playMode == 1) {
      await _playAt(state.queueIndex);
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      state = state.copyWith(isPlaying: false, position: 0);
      _syncToSystemMediaSession();
      return;
    }
    await _playAt(next);
  }

  void _syncExclusiveEffects(SoundEffectSettings s) {
    if (!state.usbExclusive && !state.dspActive) return;
    _sfxSyncTimer?.cancel();
    _sfxSyncTimer = Timer(const Duration(milliseconds: 50), () async {
      try {
        await setUsbExclusiveEqualizer(
            settingsJson: jsonEncode(s.toEqualizerRustJson()));
        await setUsbExclusiveSoundEffect(
            settingsJson: jsonEncode(s.toRustJson()));
      } catch (_) {}
    });
  }

  Future<void> _applyEffectSpeedPitch(SoundEffectSettings s) async {
    if (state.usbExclusive || state.dspActive) return;
    try {
      final rate = s.playbackRate.clamp(50.0, 200.0) / 100.0;
      await _player.setSpeed(rate);
      if (s.preservesPitch) {
        await _player.setPitch(1.0);
      } else {
        final pitch = s.pitchShift.clamp(50.0, 200.0) / 100.0;
        await _player.setPitch(pitch);
      }
    } catch (_) {
    }
  }

  void _syncToSystemMediaSession() {
    final cur = state.current;
    if (cur != null) {
      var item = cur;
      if (!cur.isOnline && cur.coverUrl?.isNotEmpty != true) {
        final cp = cur.coverPath;
        final coverPathLive = cp != null &&
            cp.isNotEmpty &&
            !cp.startsWith('http') &&
            File(cp).existsSync();
        if (!coverPathLive) {
          final cached = _notifCoverCache[cur.path];
          if (cached != null && cached.isNotEmpty) {
            item = cur.copyWith(coverPath: cached);
          }
        }
      }
      audioHandler?.syncMediaItem(item, state.duration);
      // 同步整个队列 + 当前项下标，让系统 MediaSession/鸿蒙播控中心
      // 能把会话判定为「正在播放」（active item id 对齐队列下标，否则 -1）。
      if (state.queue.isNotEmpty) {
        audioHandler?.syncQueue(state.queue, _notifCoverCache);
      }
      audioHandler?.syncPlaybackState(
        isPlaying: state.isPlaying,
        positionSecs: state.position,
        durationSecs: state.duration,
        isFavorite: _ref.read(favoritesProvider).contains(cur.path),
        playMode: state.playMode,
        queueIndex: state.queueIndex,
      );
    }
  }

  Future<void> _resolveNotificationCover(QueueItem item) async {
    if (item.isOnline) return;
    if (item.coverUrl?.isNotEmpty == true) return;
    final cp = item.coverPath;
    if (cp != null && cp.isNotEmpty && !cp.startsWith('http')) {
      if (File(cp).existsSync()) return;
      AppLog.info('media_cover', 'coverPath 失效，走缩略图兜底: $cp');
    }
    final pending = _notifCoverPending[item.path];
    if (pending != null) {
      await pending;
      return;
    }
    final fut = _resolveNotificationCoverInner(item);
    _notifCoverPending[item.path] = fut;
    try {
      await fut;
    } finally {
      _notifCoverPending.remove(item.path);
    }
  }

  List<QueueItem> peekUpcomingItems(int count) {
    final n = state.queue.length;
    if (n == 0 || count <= 0 || state.playMode == 1) return const [];
    if (state.playMode == 2) {
      if (_shuffleFuture.isEmpty) return const [];
      final i = state.queue.indexWhere((q) => q.path == _shuffleFuture.last);
      return i >= 0 ? [state.queue[i]] : const [];
    }
    final start = state.queueIndex < 0 ? 0 : state.queueIndex + 1;
    final take = count < n ? count : n;
    return List.generate(
      take,
      (k) => state.queue[(start + k) % n],
      growable: false,
    );
  }

  Future<String?> resolveLinkCoverPath(QueueItem item) async {
    if (item.isOnline || item.coverUrl?.isNotEmpty == true) return null;
    try {
      await _resolveNotificationCover(item);
    } catch (_) {
      return null;
    }
    final p = _notifCoverCache[item.path];
    if (p == null || p.isEmpty) return null;
    return File(p).existsSync() ? p : null;
  }

  Future<String> _resolveNotificationCoverInner(QueueItem item) async {
    if (_notifCoverCache.containsKey(item.path)) {
      return _notifCoverCache[item.path] ?? '';
    }
    _notifCoverCache[item.path] = '';
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final cacheRoot = await _ref.read(coverCacheRootProvider.future);
      var p = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: item.path,
      );
      if (p.isEmpty && SafChannel.isSafPath(item.path)) {
        final healed =
            await SafChannel.extractCoverToCache(item.path, cacheRoot);
        if (healed.isNotEmpty) {
          p = await getSongCoverThumbnail(
            dbPath: dbPath,
            cacheRoot: cacheRoot,
            path: item.path,
          );
        }
      }
      _notifCoverCache[item.path] = p;
      if (p.isNotEmpty && state.current?.path == item.path) {
        _syncToSystemMediaSession();
      } else if (p.isEmpty) {
        AppLog.info('media_cover', '缩略图兜底为空: ${item.path}');
      }
      return p;
    } catch (e) {
      AppLog.info('media_cover', '缩略图兜底异常: $e');
      return '';
    }
  }

  void _preloadQueueCovers() {
    final targets = <QueueItem>{};
    for (var k = 1; k <= 6 && state.queueIndex + k < state.queue.length; k++) {
      targets.add(state.queue[state.queueIndex + k]);
    }
    if (state.playMode == 2 && state.queue.length > 1) {
      for (var i = 0; i < 3; i++) {
        final idx = _rand.nextInt(state.queue.length);
        if (idx != state.queueIndex) targets.add(state.queue[idx]);
      }
    }
    for (final item in targets) {
      if (!_preloadedCovers.add(item.path)) continue;
      if (_preloadedCovers.length > 64) {
        _preloadedCovers.remove(_preloadedCovers.first);
      }
      Future(() => _preloadOneCover(item));
    }
  }

  Future<void> _preloadOneCover(QueueItem item) async {
    try {
      if (item.isOnline) {
        final url = item.coverUrl;
        if (url != null && url.isNotEmpty && CoverProxy.needsProxy(url)) {
          await CoverProxy.fetch(url);
        }
        return;
      }
      if (item.coverUrl?.isNotEmpty == true) return;
      final dbPath = await _ref.read(dbPathProvider.future);
      final cacheRoot = await _ref.read(coverCacheRootProvider.future);
      await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: item.path,
      );
    } catch (_) {
    }
  }

  Future<void> _restoreSession() async {
    try {
      String jsonStr = '';
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        jsonStr = await loadPlaybackSession(dbPath: dbPath);
      } catch (e) {
        AppLogger.instance.log('session', '读取数据库播放会话失败: $e');
      }

      if (jsonStr.isEmpty || jsonStr == 'null') {
        AppLog.info('session', 'restore skip: empty session');
        return;
      }

      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final String curPath = data['currentSongPath'] as String? ?? '';
      final List rawQueue = data['playQueuePaths'] as List? ?? [];
      final Map rawMeta = data['queueSongMeta'] as Map? ?? {};
      final int mode = (data['playMode'] as num?)?.toInt() ?? 0;
      final double pos = (data['currentPositionSecs'] as num?)?.toDouble() ?? 0;
      // 被杀前是否在播（_persistSession 已持久化）。进程被系统 LMK 杀掉
      // （典型场景：切相机等内存大户）重启后据此自动续播，避免「回来发现
      // 播放被重置到暂停」的割裂感。
      final bool wasPlaying = data['isPlaying'] as bool? ?? false;

      if (rawQueue.isEmpty || curPath.isEmpty) {
        AppLog.info('session',
            'restore skip: queue=${rawQueue.length} curPath=$curPath');
        return;
      }

      final List<QueueItem> queue = [];
      for (final p in rawQueue) {
        final pathStr = p as String;
        final meta = rawMeta[pathStr] as Map<String, dynamic>?;
        if (meta != null) {
          queue.add(QueueItem(
            path: pathStr,
            title: meta['title'] as String? ?? _titleFromPath(pathStr),
            artist: meta['artist'] as String? ?? '',
            album: meta['album'] as String? ?? '',
            durationMs: (meta['durationMs'] as num?)?.toInt() ?? 0,
            coverUrl: meta['coverUrl'] as String?,
            coverPath: meta['coverPath'] as String?,
            source: meta['source'] as String?,
            onlineSongJson: meta['onlineSongJson'] as String?,
            onlineQuality: meta['onlineQuality'] as String?,
            onlineInfoJson: meta['onlineInfoJson'] as String?,
            fromDailyRecommend: meta['fromDailyRecommend'] as bool? ?? false,
          ));
        } else {
          queue.add(QueueItem(
            path: pathStr,
            title: _titleFromPath(pathStr),
            artist: '',
            album: '',
          ));
        }
      }

      final curIdx = queue.indexWhere((q) => q.path == curPath);
      final currentItem = curIdx >= 0 ? queue[curIdx] : queue.first;

      state = PlaybackState(
        queue: queue,
        queueIndex: curIdx >= 0 ? curIdx : 0,
        current: currentItem,
        isPlaying: false,
        position: pos,
        // 时长必须一起恢复：进度条是按 position/duration 画的，duration 留 0
        // 会让 position 被 clamp 到满格、右侧时间还显示成 00:01，
        // 看起来像进度条坏了，直到起播后拿到真实时长才恢复。
        duration: currentItem.durationMs / 1000.0,
        playMode: mode,
      );

      if (!currentItem.isOnline && currentItem.coverUrl?.isNotEmpty != true) {
        try {
          await _resolveNotificationCover(currentItem);
        } catch (_) {}
      }
      _syncToSystemMediaSession();

      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await _player.setVolume(vol);

      if (!currentItem.isOnline) {
        if (_isRemotePath(currentItem.path)) {
          final cached = await _preloadRemote(currentItem);
          await _updateRgGain(cached);
          await seek(pos);
          await _player.setVolume(_effectiveVolume());
          if (wasPlaying) unawaited(_player.play());
        } else if (SafChannel.isSafPath(currentItem.path)) {
          _restoredLocalPending = pos;
          // SAF 路径不能直接预载，复用 _playAt 续播。
          if (wasPlaying) {
            unawaited(Future.delayed(const Duration(milliseconds: 800), () {
              final idx = state.queueIndex;
              if (idx >= 0 && idx < state.queue.length) {
                _playAt(idx, startAtSecs: pos);
              }
            }));
          }
        } else {
          await _updateRgGain(currentItem.path);
          final useExclusive =
              _ref.read(settingsProvider).valueOrNull?.usbExclusiveOutput ?? false;
          var restored = false;
          if (useExclusive) {
            restored = await _tryStartExclusive(currentItem.path,
                startAtSecs: pos, isPlaying: wasPlaying);
          }
          if (!restored) {
            var path = currentItem.path;
            // http 直链（DLNA 被投等）不能喂 DSP：request.path 直连内网地址
            // 会被 SSRF 校验拒绝，还白置 60s 冷却；也不可 setFilePath——
            // Uri.file 会把 scheme 冒号编码成 http%3A//（ExoPlayer no protocol）。
            final isHttpSource =
                path.startsWith('http://') || path.startsWith('https://');
            if (_isTranscodePath(path) && !isHttpSource) {
              try {
                path =
                    (await RemoteLibraryService(_ref).transcodeToWav(path)).path;
                await _updateRgGain(path);
              } catch (e) {
                AppLogger.instance.log('session', '转码预载失败: $e');
              }
            }
            if (!isHttpSource) {
              restored = await _tryStartDspPipeline(path,
                  startAtSecs: pos, isPlaying: wasPlaying);
            }
            if (!restored) {
              try {
                await _setLocalSource(path);
                await seek(pos);
                if (wasPlaying) unawaited(_player.play());
              } catch (e) {
                AppLogger.instance.log('session', '本地曲目预加载失败: $e');
              }
              await _player.setVolume(_effectiveVolume());
            }
          }
        }
      } else {
        _restoredOnlinePending = pos;
        // 在线歌冷启动需重新解析直链，统一走 _playAt 入口续播；稍等
        // 启动链（AudioService/设置流）就绪再续播，避免时序撞车。
        if (wasPlaying) {
          _restoredOnlinePending = null;
          unawaited(Future.delayed(const Duration(milliseconds: 800), () {
            final idx = state.queueIndex;
            if (idx >= 0 && idx < state.queue.length) {
              _playAt(idx, startAtSecs: pos, skipOnFailure: false)
                  .catchError((Object e) {
                // 失败已在 _playAt 内置错误态，只吞 rethrow
              });
            }
          }));
        }
      }
      AppLog.info('session',
          'restored queue=${queue.length} cur="${currentItem.title}" '
          'pos=${pos.toStringAsFixed(1)} '
          'dur=${state.duration.toStringAsFixed(1)} '
          'online=${currentItem.isOnline}');
    } catch (e) {
      AppLogger.instance.log('session', '恢复播放会话异常: $e');
    }
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  void _persistPositionDebounced() {
    final current = state.current;
    if (current == null) return;
    final now = DateTime.now();
    if (now.difference(_lastPosPersist).inSeconds < 5) return;
    _lastPosPersist = now;
    final pos = state.position;
    final isPlaying = state.isPlaying;
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await updatePlaybackPosition(
          dbPath: dbPath,
          positionSecs: pos,
          isPlaying: isPlaying,
        );
      } catch (e) {
        AppLog.warn('session', 'position save failed: $e');
      }
    });
  }

  Future<void> _ensureNotificationPermission() async {
    if (_notifPermissionAsked) return;
    _notifPermissionAsked = true;
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) await Permission.notification.request();
    } catch (_) {}
  }

  Future<void> playQueue(List<QueueItem> items,
      {int startIndex = 0, bool shareLinkPlayback = false}) async {
    if (items.isEmpty) return;
    AppLog.info('play', 'playQueue ${items.length} 首 startIndex=$startIndex');
    _shareLinkPlayback = shareLinkPlayback;
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    state = state.copyWith(
      queue: items,
      queueIndex: startIndex,
      current: items[startIndex],
    );
    try {
      await _playAt(startIndex);
    } catch (e, st) {
      AppLog.error('play', 'playQueue 异常: $e\n$st');
      state = state.copyWith(isPlaying: false, resolving: false);
    }
  }

  Future<void> _playAt(
    int index, {
    double startAtSecs = 0,
    // 对齐桌面端 playSong 选项：同一首换源续播（切音质）时保持统计会话
    // 连续——切换前收听增量照常入账，但不重置累计时长与播放计数。
    bool continueStatsSession = false,
    // 失败时是否走「自动换源/跳下一首」；切音质失败应停在当前歌报错，
    // 而不是被拉去别的歌。
    bool skipOnFailure = true,
  }) async {
    if (index < 0 || index >= state.queue.length) return;
    _playEpoch++;
    final epoch = _playEpoch;
    // 起播前播放态快照：切音质链路里 stop() 的 idle+playing=false 事件可能
    // 在 _playOnline 读取前就把 state.isPlaying 翻成 false（锚定门被旧源
    // 存活期位置事件提前撤掉时），届时再读会误判为暂停态导致新源不带
    // play() 起播——表现为切音质后直接暂停
    final wasPlaying = state.isPlaying;
    // 同曲重播（切音质）设锚定门；普通起播/切歌清门
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
    final item = state.queue[index];
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
    // 同曲重播：对齐桌面 reanchorPlaybackClock——UI 进度锚定在续播点并
    // 保持播放态，加载窗口期不归零、歌词不回卷；普通切歌仍归零
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
          // 投放中同曲重播（切音质）：起始位置经 castMedia 的 startAtSecs
          // 内建链路直达，普通起播 startAtSecs=0 行为不变
          await _castFollowPlay(item, epoch, startAtSecs: startAtSecs);
          if (epoch != _playEpoch) return;
        } else if (item.isOnline) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          // 锚定门在此之前会被旧源存活期的位置事件（pos≥锚点）提前撤掉，
          // stop 前重设：挡住 stop 引发的 idle+playing=false 翻转 UI 播放态
          if (sameSongReplay && startAtSecs > 0) {
            _replayAnchorSecs = startAtSecs;
          }
          try {
            await _player.stop();
          } catch (_) {}
          if (epoch != _playEpoch) return;
          // 暂停态同曲重播（切音质）不强制起播，维持之前的暂停承诺；
          // 正常起播/会话恢复恒为播放。用 stop 前的快照而非实时
          // state.isPlaying（stop 的 idle 事件可能已将其翻转）
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
        // http 直链（DLNA 被投条目重播等）：直喂 DSP 会被 SSRF 内网校验拒绝
        // （发送端 httpd 就是内网地址），统一走在线管线（回环代理 + 流缓存），
        // 与 playExternalUri 同路；DSP 失败时 _startOnlineUrl 内部自动回退。
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
      // 同一首换源续播（切音质）：不重复记历史/最近播放/播放上报
      if (!continueStatsSession) {
        _reportBehavior(item, 'play', 0);
        _recordRecentPlay(item);
        _recordHistory(item);
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
        // 切音质等同曲重播失败：不自动换源、不跳下一首，停在当前曲目报错，
        // 异常上抛由调用方回滚会话级音质覆盖。
        final msg = e is PluginEngineException
            ? e.message
            : tr('播放失败：{e}', {'e': e.toString()});
        state = state.copyWith(error: msg);
        _syncToSystemMediaSession();
        rethrow;
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
          // 二次超时自动降级音质重试：当前音质的 CDN 节点可能挂死
          // （如 kg hw 节点对特定文件无响应），probe 已解析的更低音质
          // 是不同直链，重试有机会成功。重试再超时则透传走失败流程。
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

  /// 起播成功后批量探测当前歌与队列后续在线歌的 MV 可用性（真实解析
  /// 结论决定 MV 入口显隐，对齐音质预探测的思路）。
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

  Future<void> _prewarmOnlineSizes(QueueItem item) async {
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json == null || json.isEmpty) return;
    String key;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      key = _songProbeKey(songJson, item);
    } catch (_) {
      return;
    }
    if (!_prewarmKeys.add(key)) return;
    if (_prewarmKeys.length > 16) _prewarmKeys.remove(_prewarmKeys.first);
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final probe = onlineQualityProbeRegistry.ensure(
          key, _buildResolveCallback(songJson, item));
      final declared = await _declaredQualities(songJson);
      final targets = declared.isNotEmpty
          ? kQualityLadder.reversed.where(declared.contains).toList()
          : kQualityLadder.reversed
              .where((q) => isLosslessQuality(q) || q == '320k' || q == '128k')
              .toList();
      await Future.wait(targets.map(probe.probe).toList())
          .timeout(const Duration(seconds: 30));
      await qualitySizes();
    } catch (_) {
      _prewarmKeys.remove(key);
    }
  }

  /// 把探测失败的原始错误压成一句短提示（完整文本仍在日志里）。
  String _shortResolveReason(String raw) {
    if (raw.contains('熔断')) return '音源熔断中，稍后自动重试';
    if (raw.contains('鉴权') || raw.contains('卡密') || raw.contains('不支持')) {
      return '音源鉴权失败';
    }
    if (raw.contains('超时') || raw.toLowerCase().contains('timeout')) {
      return '音源请求超时';
    }
    if (raw.contains('rate') || raw.contains('限') || raw.contains('429')) {
      return '音源请求被限流';
    }
    final s = raw.trim();
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }

  String _songProbeKey(Map<String, dynamic> songJson, QueueItem item) {
    final pid = songJson['pluginId'];
    final src = songJson['source'];
    final mid = songJson['songmid'] ?? songJson['id'];
    if (pid != null) {
      return 'plugin:$pid:${mid ?? songJson['title'] ?? item.title}';
    }
    return 'lx:$src:${mid ?? item.title}';
  }

  Future<List<String>> _declaredQualities(Map<String, dynamic> songJson) async {
    final out = <String>{};
    final pid = songJson['pluginId'];
    if (pid is String && pid.isNotEmpty) {
      final musicInfo = songJson['musicInfo'];
      if (musicInfo is Map) {
        final types = musicInfo['_types'];
        if (types is Map) {
          for (final k in types.keys) {
            final norm = PluginEngine.normalizeQualityKey(k);
            if (norm != null) out.add(norm);
          }
        }
      }
      if (out.isEmpty) {
        try {
          final engine = _ref.read(pluginEngineProvider).valueOrNull;
          final meta = engine?.metadataOf(pid);
          final raw = meta?['supportedQualities'];
          AppLog.debug('quality', '[quality] declared pid=$pid meta=${meta == null ? 'null' : 'ok'} '
              'supportedQualities=$raw');
          if (raw is List) {
            for (final dq in raw) {
              final norm = PluginEngine.normalizeQualityKey(dq);
              if (norm != null) out.add(norm);
            }
          }
        } catch (_) {}
      }
      if (out.isEmpty) {
        out.addAll(const {'128k', '320k', 'flac'});
      }
    } else {
      final types = songJson['_types'];
      if (types is Map) {
        for (final k in types.keys) {
          final norm = PluginEngine.normalizeQualityKey(k);
          if (norm != null) out.add(norm);
        }
      }
    }
    final result = kQualityLadder.where(out.contains).toList();
    AppLog.debug('quality', '[quality] _declaredQualities pid=$pid result=$result');
    return result;
  }

  Future<ResolvedMediaUrl?> Function(String) _buildResolveCallback(
      Map<String, dynamic> songJson, QueueItem item) {
    final hasPlugin = songJson.containsKey('pluginId');
    return (String q) async {
      if (hasPlugin) {
        final u = await _resolvePluginUrl(songJson, q, itemPath: item.path);
        if (u != null && _isPlayableUrl(u.url)) return u;
        final musicInfo =
            songJson['musicInfo'] as Map<String, dynamic>? ?? {};
        final fallbackInfo = <String, dynamic>{
          if ((songJson['source'] as String?)?.isNotEmpty ?? false)
            'source': songJson['source'],
          ...musicInfo,
        };
        final lx = await _lxResolveQuality(jsonEncode(fallbackInfo), q);
        if (lx != null) return lx;
        return null;
      }
      return _lxResolveQuality(jsonEncode(songJson), q);
    };
  }

  Future<ResolvedMediaUrl?> _lxResolveQuality(
      String songInfoJson, String quality) async {
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final songInfo = jsonDecode(songInfoJson) as Map<String, dynamic>;
      final resolved = await engine
          .resolveLxUrl(songInfo, quality)
          .timeout(const Duration(seconds: 8));
      final url = resolved?['url'] as String?;
      if (!_isPlayableUrl(url)) {
        AppLog.warn('lx', '[lxResolve] 插件 $quality 无结果/非法直链: $url');
        return null;
      }
      AppLog.info('lx', '[lxResolve] 插件 $quality 命中');
      return ResolvedMediaUrl(
        url: url!,
        headers: resolved?['headers'] as Map<String, String>?,
      );
    } catch (e) {
      AppLog.error('lx', '[lxResolve] 插件 $quality 异常: $e');
      return null;
    }
  }

  void _refreshQualityMenuState(SongQualityProbe probe) {
    state = state.copyWith(
      availableQualities: probe.availableQualities,
      qualityMenuProbing: probe.probing,
    );
  }

  Future<bool> switchQuality(String quality) async {
    final item = state.current;
    if (item == null || !item.isOnline) return false;
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json == null || json.isEmpty) return false;
    // 与桌面端 selectQuality 同构：设会话级音质覆盖后按同一首经统一入口
    // _playAt 重播，复用其输出仲裁（先停 DSP/USB 管线与旧源，避免双声与
    // 双进度源打架）、候选降级链与超时兜底，进度无缝续播。
    if (quality == state.currentQuality) return true;
    final prevOverride = _sessionQualityOverride;
    _sessionQualityOverride = quality;
    try {
      // 预解析目标音质直链（此间旧源继续出声）：对齐桌面端「旧源播到
      // 新源就绪才停」的无缝观感。结果缓存在 probe 内，_playAt 里
      // _playOnline 的 startBest 命中缓存瞬时返回，静音窗口只剩换源与
      // 起播缓冲；解析失败静默，降级链交由 _playAt 常规流程处理
      await _prewarmQuality(item, quality);
      // 预解析期间旧源持续走带，续播点取停旧源前的实时位置而非点击时刻，
      // 避免长解析（秒级）导致切完进度跳回
      final resumePos = state.position;
      await _playAt(
        state.queueIndex,
        startAtSecs: resumePos,
        continueStatsSession: true,
        skipOnFailure: false,
      );
      // 切档期间用户可能已切歌：当前曲目已变则按失败处理（不回写队列）
      if (state.current?.path != item.path) return false;
      final picked = state.currentQuality;
      if (picked != null && picked.isNotEmpty) {
        // 降级链可能命中的是比请求档更低的可用档，按实际生效档回写；
        // 以窗口期后的 state.current 为基，避免用捕获时的旧对象覆盖
        // 期间其它链路（如歌词补全）已 patch 过的字段
        final updated = (state.current ?? item).copyWithQuality(picked);
        state = state.copyWith(
          current: updated,
          queue: state.queue
              .map((e) => e.path == item.path ? updated : e)
              .toList(),
        );
      }
      return true;
    } catch (_) {
      _sessionQualityOverride = prevOverride;
      return false;
    }
  }

  /// 切音质前预解析目标音质直链并缓存到 probe：让旧源在解析期间继续
  /// 出声，网络耗时不落入静音窗口。失败静默返回 null，正式起播链路
  /// （startBest 降级链 + 超时兜底）自会处理。
  ///
  /// 解析命中后进一步预热流缓存：注册请求头并预启动 Rust 流式下载写盘，
  /// 把「代理建条目 → CDN 握手 → 记录 Content-Length → 首块字节落盘」
  /// 整段握手挪进旧源继续出声的窗口——停旧源后 _startOnlineUrl 的 Range
  /// 请求到达时，_tryServeFromCache 面对的是已存活、总长已记录的缓存
  /// 条目（省掉最长 3s 的 _waitForCacheTotal 空转），伺服直达或短暂等
  /// 下载推进即回退直连，静音窗口从秒级压到亚秒级。
  Future<void> _prewarmQuality(QueueItem item, String quality) async {
    final json = item.onlineSongJson;
    if (json == null || json.isEmpty) return;
    QualityProbeResult? resolved;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.ensure(
          key, _buildResolveCallback(songJson, item));
      resolved = await probe
          .probe(quality)
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
    } catch (_) {}
    final res = resolved;
    // 加密流（ekey/cek）走下载解密临时文件路径，不经流缓存伺服；
    // 预启动下载反而可能与解密拉流对同一 URL 开双上游连接
    if (res == null || res.url.isEmpty || res.ekey != null || res.cek != null) {
      return;
    }
    try {
      // 与 _startOnlineUrl 完全同构的 URL/头部归一，确保缓存键一致命中
      final clean = sanitizeMediaUrl(res.url);
      if (clean.isEmpty || !clean.startsWith('http')) return;
      final h = await withBilibiliStreamCookie(
            clean,
            normalizeMediaRequestHeaders(clean, res.headers),
            dataDir: _ref.read(appDataDirProvider.future),
          ) ??
          const <String, String>{};
      AudioHeadCache.instance.registerHeaders(clean, h);
      await AudioProxyServer.instance.ensureStarted();
      // 预启动即返回：下载与旧源播放并行推进，不阻塞切换
      unawaited(streamCacheBeginUrlDownload(
          url: clean, headers: jsonEncode(h)));
    } catch (_) {}
  }

  Future<List<String>> qualityOptions() =>
      _probeQualityOptions(forDownload: false);

  Future<List<String>> downloadQualityOptions() =>
      _probeQualityOptions(forDownload: true);

  Future<Map<String, QualitySizeInfo>> qualitySizes() async {
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    if (item == null || json == null || json.isEmpty) return const {};
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.peek(key);
      if (probe == null) return const {};

      final shown = state.availableQualities;
      if (shown.isNotEmpty) {
        final have = {
          for (final r in probe.resolved) r.requested ?? r.quality
        };
        final missing = shown.where((q) => !have.contains(q)).toList();
        if (missing.isNotEmpty) {
          await Future.wait(missing.map(probe.probe))
              .timeout(const Duration(seconds: 20),
                  onTimeout: () => <QualityProbeResult?>[]);
        }
      }

      final entries = probe.resolved;
      if (entries.isEmpty) return const {};
      final metaSizes = _metadataQualitySizes(songJson);
      final out = <String, QualitySizeInfo>{};
      final keys = <String>[
        ...shown,
        for (final r in entries)
          if (r.requested != null && !shown.contains(r.requested!))
            r.requested!,
      ];
      for (final q in keys) {
        final entry = _entryForShown(entries, q);
        if (entry != null) {
          final cached = _qualitySizeByUrl[entry.url];
          if (cached != null) {
            out[q] = QualitySizeInfo(url: entry.url, bytes: cached);
            continue;
          }
          try {
            final raw = await probeUrlSize(url: entry.url);
            final info = jsonDecode(raw);
            final size = info is Map<String, dynamic> ? info['size'] : null;
            if (size is num && size > 0) {
              if (_qualitySizeByUrl.length > 200) _qualitySizeByUrl.clear();
              _qualitySizeByUrl[entry.url] = size.toInt();
              out[q] = QualitySizeInfo(url: entry.url, bytes: size.toInt());
              continue;
            }
          } catch (_) {
          }
        }
        final meta = metaSizes[q];
        if (meta != null) {
          out[q] = QualitySizeInfo(url: entry?.url ?? '', bytes: meta);
        }
      }
      return out;
    } catch (e) {
      AppLog.debug('quality', '[quality] 体积探测失败: $e');
      return const {};
    }
  }

  QualityProbeResult? _entryForShown(
      List<QualityProbeResult> entries, String q) {
    for (final r in entries) {
      if (r.requested == q) return r;
    }
    for (final r in entries) {
      if (r.quality == q) return r;
    }
    return null;
  }

  Map<String, int> _metadataQualitySizes(Map<String, dynamic> songJson) {
    final out = <String, int>{};
    void scan(dynamic raw) {
      if (raw is! Map) return;
      final m = raw.cast<String, dynamic>();
      for (final entry in m.entries) {
        final norm = PluginEngine.normalizeQualityKey(entry.key);
        if (norm == null || out.containsKey(norm)) continue;
        final v = entry.value;
        final size = v is Map ? v['size'] : null;
        final bytes = _parseQualitySize(size);
        if (bytes != null) out[norm] = bytes;
      }
    }

    final musicInfo = songJson['musicInfo'];
    if (musicInfo is Map) {
      final info = musicInfo.cast<String, dynamic>();
      final rawData = info['rawData'];
      if (rawData is Map) {
        scan(rawData.cast<String, dynamic>()['qualities']);
      }
      scan(info['qualities']);
      scan(info['_types']);
      scan(info['lx_types']);
    }
    scan(songJson['qualities']);
    scan(songJson['_types']);
    scan(songJson['lx_types']);
    return out;
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

  Future<List<String>> _probeQualityOptions(
      {required bool forDownload}) async {
    // 音质弹窗可能在 widget build 流程中调用本方法，
    // 先让出当前帧，避免 building 期间同步修改 provider 抛异常
    await Future<void>.delayed(Duration.zero);
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    AppLog.debug('quality', '[quality] _probeQualityOptions item=${item?.title} '
        'onlineSongJson=${item?.onlineSongJson?.isNotEmpty ?? false} '
        'onlineInfoJson=${item?.onlineInfoJson?.isNotEmpty ?? false}');
    if (json == null || json.isEmpty) return const [];
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item!);
      final probe = onlineQualityProbeRegistry
          .ensure(key, _buildResolveCallback(songJson, item));
      _activeProbeKey = key;
      state = state.copyWith(qualityMenuProbing: true);

      final declared = await _declaredQualities(songJson);
      if (declared.isNotEmpty) {
        final base = kQualityLadder.reversed.where(declared.contains).toList();
        AppLog.debug('quality', '[quality] declared non-empty base=$base');
        state = state.copyWith(
          availableQualities: base,
          qualityMenuProbing: true,
        );
        unawaited(_probeInBackground(probe, declared, base));
        return base;
      }

      final targets = kQualityLadder.reversed
          .where((q) => isLosslessQuality(q) || q == '320k' || q == '128k')
          .toList();
      AppLog.debug('quality', '[quality] declared empty, probing targets=$targets');
      await Future.wait(targets.map(probe.probe).toList());

      final opts = <String>{...probe.availableQualities};
      if (state.currentQuality != null) opts.add(state.currentQuality!);
      final ordered =
          kQualityLadder.reversed.where(opts.contains).toList();
      AppLog.info('quality', '[quality] probe done opts=$ordered');
      if (ordered.isEmpty) probe.markFailed();
      state = state.copyWith(
        availableQualities: ordered,
        qualityMenuProbing: false,
      );
      return ordered;
    } catch (e) {
      AppLog.error('quality', '[quality] _probeQualityOptions error: $e');
      state = state.copyWith(qualityMenuProbing: false);
      return state.availableQualities;
    }
  }

  Future<void> _probeInBackground(
    SongQualityProbe probe,
    List<String> targets,
    List<String> base,
  ) async {
    try {
      if (await _tryBakaTrustProbe(probe, targets, base)) {
        state = state.copyWith(
          availableQualities: probe.availableQualities,
          qualityMenuProbing: false,
        );
        return;
      }

      if (await _currentIsPluginSong()) {
        final groups = <String, List<String>>{};
        for (final q in targets) {
          groups
              .putIfAbsent(PluginEngine.qualityKeyToMfQuality(q), () => [])
              .add(q);
        }
        await Future.wait(groups.values.map((grp) async {
          final rep = grp.reduce((a, b) =>
              kQualityLadder.indexOf(a) > kQualityLadder.indexOf(b) ? a : b);
          try {
            final res =
                await probe.probe(rep).timeout(const Duration(seconds: 15));
            if (res != null && res.url.isNotEmpty) {
              probe.trustDeclared(grp);
            }
          } catch (_) {
          }
        }));
      } else {
        await Future.wait(targets.map(probe.probe).toList())
            .timeout(const Duration(seconds: 30));
      }

      final opts = <String>{...probe.availableQualities};
      if (state.currentQuality != null) opts.add(state.currentQuality!);
      if (opts.isEmpty) opts.addAll(base);
      final ordered =
          kQualityLadder.reversed.where(opts.contains).toList();
      if (ordered.isEmpty) probe.markFailed();
      state = state.copyWith(
        availableQualities: ordered,
        qualityMenuProbing: false,
      );
    } catch (_) {
      state = state.copyWith(qualityMenuProbing: false);
    }
  }

  Future<bool> _currentIsPluginSong() async {
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    if (item == null || json == null || json.isEmpty) return false;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final pid = songJson['pluginId'] as String?;
      return pid != null && pid.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryBakaTrustProbe(
    SongQualityProbe probe,
    List<String> targets,
    List<String> base,
  ) async {
    if (targets.isEmpty || base.isEmpty) return false;
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    if (item == null || json == null || json.isEmpty) return false;
    final String? pluginId;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      pluginId = songJson['pluginId'] as String?;
    } catch (_) {
      return false;
    }
    if (pluginId == null || pluginId.isEmpty) return false;
    final engine = _ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null || !engine.isBakaPlugin(pluginId)) return false;

    final top = targets.reduce((a, b) =>
        kQualityLadder.indexOf(a) > kQualityLadder.indexOf(b) ? a : b);
    final res = await probe.probe(top).timeout(const Duration(seconds: 10));
    if (res == null || res.url.isEmpty) return false;
    if (res.quality != top) {
      AppLog.info('quality', '[quality] Baka 最高档 $top 实际返回 ${res.quality}，回退逐档实测');
      return false;
    }
    probe.trustDeclared(base);
    final ordered = probe.availableQualities;
    AppLog.info('quality', '[quality] Baka 信任模式命中，声明档全量可用 $ordered');
    return true;
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

  /// 降级重试链：候选中严格低于当前音质的档位（保持原顺序）。
  /// 当前音质不在阶梯上（如自定义档）时无从降级，返回空。
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

  // ==================== 音量平衡（ReplayGain 响度均衡） ====================

  double _rgGain = 1.0;

  /// MV 音频接管时置 true：外部歌曲音频被静音，交由 MV 自带音轨出声。
  bool _mvAudioOverride = false;

  /// MV 交叉淡化进行中的歌曲通道增益（1.0 正常，0.0 完全静音）。
  double _mvSongGain = 1.0;

  /// 设置 MV 音频接管开关。接管时交由 MV 自带音轨出声，退出时还原歌曲通道。
  /// 本身不瞬静也不瞬切：歌曲通道与 USB/DSP 管线音量始终跟随 `setMvSongGain`
  /// 的增益，由调用方驱动交叉淡化。
  /// DSP 共享管线 / USB 独占输出不经 _player，需同步作用到 Rust 管线音量，
  /// 否则接管后歌曲照常从该管线出声，与 MV 音轨叠播。
  Future<void> setMvAudioOverride(bool value) async {
    if (_mvAudioOverride == value) return;
    _mvAudioOverride = value;
    if (!value) _mvSongGain = 1.0;
    await _player.setVolume(_effectiveVolume());
    if (state.usbExclusive || state.dspActive) {
      try {
        await setUsbExclusiveVolume(
            volume: _ref.read(volumeProvider) * _mvSongGain);
      } catch (_) {}
    }
  }

  /// MV 交叉淡化：调节歌曲通道增益（1.0 正常，0.0 静音），与 MV 音轨音量
  /// 反向同步变化，形成等功率交叉淡化。USB/DSP 管线音量按比例同步缩放。
  Future<void> setMvSongGain(double gain) async {
    _mvSongGain = gain.clamp(0.0, 1.0);
    await _player.setVolume(_effectiveVolume());
    if (state.usbExclusive || state.dspActive) {
      try {
        await setUsbExclusiveVolume(
            volume: _ref.read(volumeProvider) * _mvSongGain);
      } catch (_) {}
    }
  }

  double _effectiveVolume() =>
      (_ref.read(volumeProvider) *
              _effectiveBalanceGain() *
              (_mvAudioOverride ? _mvSongGain : 1.0))
          .clamp(0.0, 4.0);

  double _effectiveBalanceGain() {
    final s = _ref.read(settingsProvider).valueOrNull;
    return (s?.volumeBalanceEnabled ?? false) ? _rgGain : 1.0;
  }

  Future<Duration?> _setLocalSource(String path) async {
    var target = path;
    // DLNA 被投直链等 http 源误入本地回退时必须走 setUrl：setFilePath 经
    // Uri.file 会把 scheme 冒号编码成 http%3A//（ExoPlayer 报 no protocol）。
    if (target.startsWith('http://') || target.startsWith('https://')) {
      return _player.setUrl(target);
    }
    if (path.startsWith('content://')) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          path, p.join(tmp.path, 'saf_playback'));
    }
    if (target.startsWith('content://')) {
      return _player.setUrl(target);
    }
    return _player.setFilePath(target);
  }

  Future<void> _updateRgGain(String? path) async {
    final s = _ref.read(settingsProvider).valueOrNull;
    if (s?.volumeBalanceEnabled != true ||
        path == null ||
        path.isEmpty ||
        path.startsWith('http')) {
      _rgGain = 1.0;
      return;
    }
    try {
      _rgGain = await loudnessPlaybackGainForFile(
        filePath: path,
        gainOffsetDb: s?.volumeBalanceGainOffsetDb ?? 0,
        preventClipping: s?.volumeBalancePreventClipping ?? true,
      );
    } catch (_) {
      _rgGain = 1.0;
    }
  }

  Future<void> _onVolumeBalanceSettingChanged() async {
    final item = state.current;
    if (item == null) return;
    if (item.isOnline) {
      _rgGain = 1.0;
    } else if (_isRemotePath(item.path)) {
      try {
        final plan = await RemoteLibraryService(_ref).playbackSource(item.path);
        await _updateRgGain(plan.isCached ? plan.cachedPath : null);
      } catch (_) {
        _rgGain = 1.0;
      }
    } else {
      await _updateRgGain(item.path);
    }
    if (state.usbExclusive || state.dspActive) {
      try {
        await setUsbExclusiveVolumeBalanceGain(gain: _effectiveBalanceGain());
      } catch (_) {}
    } else if (!item.isOnline && !state.dspActive) {
      try {
        await _player.setVolume(_effectiveVolume());
      } catch (_) {}
    }
  }

  Future<void> _playRemote(QueueItem item) async {
    final service = RemoteLibraryService(_ref);

    if (_isDsdPath(item.path)) {
      final s = _ref.read(settingsProvider).valueOrNull;
      if (!(s?.usbExclusiveOutput ?? false) ||
          !(s?.dsdNativePassthrough ?? false)) {
        throw StateError(
            tr('远程 DSD 需开启「USB 独占输出」与「DSD 原生直通」'));
      }
      try {
        await _player.stop();
      } catch (_) {}
      await service.precacheRemote(item.path);
      final plan = await service.playbackSource(item.path);
      if (!plan.isCached) {
        throw StateError(tr('远程 DSD 缓存失败'));
      }
      final ok = await _tryStartExclusive(plan.cachedPath!,
          startAtSecs: 0, isPlaying: true);
      if (!ok) {
        throw StateError(tr('USB 独占输出启动失败，无法播放 DSD'));
      }
      return;
    }

    if (_isTranscodePath(item.path)) {
      final result = await service.transcodeToWav(item.path);
      try {
        await _player.stop();
      } catch (_) {}
      await _player.setFilePath(result.path);
      await _updateRgGain(result.path);
      await _player.setVolume(_effectiveVolume());
      await _player.play();
      return;
    }

    final plan = await service.playbackSource(item.path);
    try {
      await _player.stop();
    } catch (_) {}
    if (plan.isCached) {
      await _player.setFilePath(plan.cachedPath!);
      await _updateRgGain(plan.cachedPath);
    } else {
      if (!RegExp(r'^https?://').hasMatch(plan.url)) {
        throw StateError(tr('远程源配置缺失或已失效'));
      }
      await _player.setUrl(plan.url, headers: plan.headers);
      _rgGain = 1.0;
    }
    await _player.setVolume(_effectiveVolume());
    await _player.play();
  }

  void _precacheNextCover() {
    final n = state.queue.length;
    if (n == 0 || state.playMode == 1) return;
    final curIdx = state.queueIndex;
    final List<int> targets;
    if (state.playMode == 2) {
      if (_shuffleFuture.isEmpty) return;
      targets = <int>[];
      for (var k = 1; k <= 3 && k <= _shuffleFuture.length; k++) {
        final i = state.queue
            .indexWhere((q) => q.path == _shuffleFuture[_shuffleFuture.length - k]);
        if (i >= 0 && i != curIdx) targets.add(i);
      }
    } else {
      final start = curIdx < 0 ? 0 : curIdx;
      targets = <int>[
        for (var k = 1; k <= 3; k++)
          if ((start + k) % n != curIdx) (start + k) % n,
      ];
    }
    if (targets.isEmpty) return;
    final items = [for (final i in targets) state.queue[i]];
    unawaited(Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        final cacheRoot = await _ref.read(coverCacheRootProvider.future);
        for (final item in items) {
          await CoverImage.prewarm(
            songPath: item.path,
            networkUrl: item.coverUrl,
            dbPath: dbPath,
            cacheRoot: cacheRoot,
          );
        }
      } catch (_) {}
    }));
  }

  void _maybePrecacheNextRemote(double pos) {
    final cur = state.current;
    if (cur == null || cur.isOnline || !_isRemotePath(cur.path)) return;
    final dur = state.duration;
    if (dur <= 0 || pos < dur * 0.6) return;
    if (state.playMode == 1) return;

    int next;
    if (state.playMode == 2) {
      if (_shuffleFuture.isEmpty) return;
      final path = _shuffleFuture.last;
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i < 0) return;
      next = i;
    } else {
      final n = state.queue.length;
      if (n == 0) return;
      next = state.queueIndex < 0 ? 0 : (state.queueIndex + 1) % n;
    }
    final nextItem = state.queue[next];
    if (nextItem.isOnline || !_isRemotePath(nextItem.path)) return;
    if (_lastPrecachedRemotePath == nextItem.path) return;
    _lastPrecachedRemotePath = nextItem.path;
    final service = RemoteLibraryService(_ref);
    unawaited(Future(() async {
      try {
        await service.precacheRemote(nextItem.path);
        AppLog.info('play', '已预缓存下一首远程歌曲: ${nextItem.path}');
      } catch (e) {
        AppLog.warn('play', '预缓存下一首失败: $e');
      }
    }));
  }

  Future<String?> _preloadRemote(QueueItem item) async {
    try {
      final service = RemoteLibraryService(_ref);
      final plan = await service.playbackSource(item.path);
      if (plan.isCached) {
        await _player.setFilePath(plan.cachedPath!);
        return plan.cachedPath;
      }
    } catch (_) {}
    return null;
  }

  String precacheProbeKey(Map<String, dynamic> songJson, QueueItem item) =>
      _songProbeKey(songJson, item);

  SongQualityProbe precacheProbeEnsure(
    Map<String, dynamic> songJson,
    QueueItem item,
    String key,
  ) =>
      onlineQualityProbeRegistry.ensure(
        key,
        _buildResolveCallback(songJson, item),
      );

  List<String> precacheCandidates(String preferred, String fallback) =>
      _qualityCandidates(preferred, fallback);

  void _triggerOnlinePrecache(QueueItem item) {
    try {
      if (!item.isOnline) return;
      final s = _ref.read(settingsProvider).valueOrNull;
      final preferred = _sessionQualityOverride ??
          s?.onlineDefaultQuality ??
          item.onlineQuality ??
          '320k';
      final fb = s?.onlineQualityFallbackBehavior ?? 'lower';
      OnlinePrecache.instance.schedule(
        ref: _ref,
        notifier: this,
        queue: state.queue,
        queueIndex: state.queueIndex,
        playMode: state.playMode,
        currentPath: state.current?.path ?? item.path,
        preferred: preferred,
        fallback: fb,
      );
    } catch (_) {
    }
  }

  Future<void> _startOnlineUrl(
    String url, {
    Map<String, String>? headers,
    required QueueItem item,
    String? ekey,
    String? cek,
    // 切音质复用本方法：从该秒数续播；isPlaying=false 时载入但不自动播
    double startAtSecs = 0,
    bool isPlaying = true,
  }) async {
    final clean = sanitizeMediaUrl(url);
    if (clean.isEmpty) throw StateError(tr('无效的播放链接'));
    final h = await withBilibiliStreamCookie(
          clean,
          normalizeMediaRequestHeaders(clean, headers),
          dataDir: _ref.read(appDataDirProvider.future),
        ) ??
        <String, String>{};
    if (ekey != null && ekey.isNotEmpty) {
      await _startEncryptedFile(clean, h, item, ekey,
          startAtSecs: startAtSecs, isPlaying: isPlaying);
      return;
    }
    if (cek != null && cek.isNotEmpty) {
      // CENC 加密流（如网易 dolby）：复用 ekey 的「下载到临时文件 + 解密」
      // 离线模式，解密由 Rust 侧按 CENC（AES-CTR 样本级）执行。
      await _startEncryptedFile(clean, h, item, cek,
          isCenc: true, startAtSecs: startAtSecs, isPlaying: isPlaying);
      return;
    }
    // DSP 共享管线分支不经 _GatedAudioPlayer，这里兜底记录真实直链 + 请求头
    //（若 DSP 失败走 setUrl，会被后者以代理 URL 覆盖，两路均可还原直链）。
    LastAudioSource.recordUrl(clean, h);
    await AudioProxyServer.instance.ensureStarted();
    AudioHeadCache.instance.registerHeaders(clean, h);
    final proxyUrl = AudioProxyServer.instance.proxyUrlFor(clean);
    if (proxyUrl != null) {
      try {
        await _player.stop();
      } catch (_) {}
      // DSP 直读流缓存：对齐桌面端 StreamingTempFile 模型——出声主体不再是
      // 代理 HTTP 流，而是 Rust 流缓存文件 Reader（复用预热线程，单上游连接）。
      // 代理仅保留给 ExoPlayer 兜底分支。
      final ok = await _tryStartDspPipeline(proxyUrl,
          streamCacheUrl: clean,
          streamCacheHeaders: h,
          startAtSecs: startAtSecs, isPlaying: isPlaying);
      if (ok) {
        _triggerOnlinePrecache(item);
        return;
      }
    }
    // 代理路径：头注入/缓存伺服/流量收口；10s 超时回退直链作兜底。
    final playUrl = AudioProxyServer.instance.playUrlFor(clean);
    try {
      await _player.setUrl(playUrl,
              headers: h,
              initialPosition: startAtSecs > 0
                  ? Duration(milliseconds: (startAtSecs * 1000).round())
                  : null)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // 起播超时：先抓现场（状态+线程堆栈随日志导出可离线定位）。
      // 修复：不再对同一 player 二次 setUrl——首次 load 挂死时 just_audio
      // 的串行锁会让后续 setUrl/pause/stop 全部排队挂死，导致旧源声音
      // 叠加且暂停失效（双 ExoPlayer 线程组并存）。改为 fail-fast 交上层
      // 走播放失败流程（换候选/跳歌），并尝试 2s 内 stop 打断挂死 load。
      AppLog.warn('play',
          '[startOnlineUrl] 起播超时(10s) proc=${_player.processingState} '
          'buffered=${_player.bufferedPosition.inMilliseconds}ms '
          'dur=${_player.duration?.inMilliseconds}ms url=$clean');
      // 诊断探针只在超时后跑：正常链路必须只有预热缓存一条上游连接，
      // 额外直连会被按 token 限并发的 CDN（酷狗）抢走伺服槽位。
      unawaited(_diagProbeUrl(clean, h));
      await _dumpPlayerThreads();
      unawaited(_player
          .stop()
          .then((_) => AppLog.info('play', '[startOnlineUrl] 超时后 stop 成功'))
          .catchError((_) {})
          .timeout(const Duration(seconds: 2), onTimeout: () {
        AppLog.warn('play', '[startOnlineUrl] 超时后 stop 也挂起（控制通道被占）');
      }));
      // 超时 + stop 假成功常意味着原生主线程被挂死 release 阻塞（ExoPlayer
      // 无任何加载任务、setUrl 静默挂满 10s）：探测楔死并重建播放器通道。
      unawaited(_probeAndRebuild('[startOnlineUrl] 起播超时'));
      throw _StartOnlineTimeoutException(tr('音源起播超时，已跳过'));
    } on PlatformException catch (e) {
      // 原生注册表异常（如 Platform player already exists）：此前未捕获会
      // 冒泡成未处理异常刷 *** 堆栈。走正常失败流程并探测楔死。
      AppLog.error('play', '[startOnlineUrl] 平台通道异常 code=${e.code}');
      unawaited(_probeAndRebuild('平台通道异常 ${e.code}'));
      throw StateError(tr('播放器通道异常'));
    }
    final declaredMs = item.durationMs;
    final actualMs = _player.duration?.inMilliseconds ?? 0;
    if (declaredMs >= 30000 && actualMs > 0 && actualMs < 5000) {
      AppLog.warn('play', '[startOnlineUrl] 直链实际时长异常 '
          'declared=${declaredMs}ms actual=${actualMs}ms url=$clean');
      throw StateError(tr('直链已失效（返回内容与歌曲不符）'));
    }
    await _player.setVolume(_effectiveVolume());
    if (isPlaying) {
      await _player.play();
    }
    _triggerOnlinePrecache(item);
  }

  // 诊断探针(B)：绕过本地代理直连真实 URL，测远端到底回不回字节、速率多少——
  // 据此区分「代理层卡」还是「网络/OS 节流」。仅打日志，不影响播放链路。
  Future<void> _diagProbeUrl(String url, Map<String, String>? headers) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final sw = Stopwatch()..start();
    try {
      final req = await client.getUrl(Uri.parse(url));
      (headers ?? {}).forEach((k, v) {
        try {
          req.headers.set(k, v);
        } catch (_) {}
      });
      final res = await req.close().timeout(const Duration(seconds: 8));
      final type = res.headers.contentType?.toString() ?? '-';
      final len = res.contentLength;
      AppLog.warn('probe',
          'conn ok t=${sw.elapsedMilliseconds}ms status=${res.statusCode} type=$type len=$len');
      var got = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 3))) {
        got += chunk.length;
        if (sw.elapsedMilliseconds >= 3000) break;
      }
      final secs = sw.elapsedMilliseconds ~/ 1000 + 1;
      AppLog.warn('probe',
          'bytes=$got in ${sw.elapsedMilliseconds}ms rate=${(got ~/ secs) ~/ 1024}KB/s');
    } catch (e) {
      AppLog.warn('probe', 'probe failed after ${sw.elapsedMilliseconds}ms: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _startEncryptedFile(
    String url,
    Map<String, String>? headers,
    QueueItem item,
    String key, {
    bool isCenc = false,
    double startAtSecs = 0,
    bool isPlaying = true,
  }) async {
    try {
      await _player.stop();
    } catch (_) {}
    final plainPath =
        await _decryptUrlToTemp(url, headers, key, isCenc: isCenc);
    await _player.setFilePath(plainPath);
    if (startAtSecs > 0) {
      try {
        await _player
            .seek(Duration(milliseconds: (startAtSecs * 1000).round()));
      } catch (_) {}
    }
    await _player.setVolume(_effectiveVolume());
    if (isPlaying) {
      await _player.play();
    }
    _triggerOnlinePrecache(item);
  }

  static const int _decryptCacheMax = 48;
  final Map<String, String> _decryptPathCache = {};

  Future<String> _decryptUrlToTemp(
    String url,
    Map<String, String>? headers,
    String key, {
    bool isCenc = false,
  }) async {
    final cached = _decryptPathCache[url];
    if (cached != null) {
      final f = File(cached);
      if (f.existsSync() && f.lengthSync() > 0) return cached;
    }
    final dir = Directory(p.join((await getTemporaryDirectory()).path,
        'xianyu_decrypt'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    final list = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .toList()
      ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (var i = 0; i < list.length - _decryptCacheMax + 1; i++) {
      try {
        list[i].deleteSync();
      } catch (_) {}
    }
    final dest = p.join(dir.path,
        'dec_${sha256.convert(utf8.encode(url)).toString().substring(0, 24)}.tmp');
    if (File(dest).existsSync()) {
      try {
        final f = File(dest);
        if (f.lengthSync() > 0) {
          _decryptPathCache[url] = dest;
          return dest;
        }
        f.deleteSync();
      } catch (_) {}
    }
    final plainPath = await downloadOnlineSong(
      url: url,
      destPath: dest,
      ekey: isCenc ? null : key,
      cek: isCenc ? key : null,
      headersJson: jsonEncode(headers ?? <String, String>{}),
    );
    _decryptPathCache[url] = plainPath;
    if (_decryptPathCache.length > _decryptCacheMax) {
      final key0 = _decryptPathCache.keys.first;
      _decryptPathCache.remove(key0);
    }
    return plainPath;
  }

  Future<ResolvedMediaUrl?> _tryLxResolve(
      String songInfoJson, List<String> candidates) async {
    try {
      return await _tryLxResolveInner(songInfoJson, candidates)
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      return null;
    }
  }

  Future<ResolvedMediaUrl?> _tryLxResolveInner(
      String songInfoJson, List<String> candidates) async {
    final engine = await _ref.read(pluginEngineProvider.future);
    final songInfo = jsonDecode(songInfoJson) as Map<String, dynamic>;
    for (final quality in candidates) {
      try {
        final resolved = await engine.resolveLxUrl(songInfo, quality);
        if (resolved == null) continue;
        final url = resolved['url'] as String?;
        if (_isPlayableUrl(url)) {
          return ResolvedMediaUrl(
            url: url!,
            quality: quality,
            headers: resolved['headers'] as Map<String, String>?,
          );
        }
      } catch (_) {}
    }
    return null;
  }

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
      _recordPlayStats(
        item,
        totalDuration,
        countAsPlay: countAsPlay,
      );
      _accumulatedTime = 0;
    } else {
      _accumulatedTime = totalDuration;
    }
    _trackStartTime = state.isPlaying ? DateTime.now() : null;
  }

  void _recordHistory(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
      } catch (e) {
        AppLog.warn('stats', 'add_to_history 失败: $e');
      }
    });
  }

  void _recordPlayStats(QueueItem item, double listenedSecs,
      {bool countAsPlay = true}) {
    if (listenedSecs <= 0) return;
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        final payloadJson = jsonEncode({
          'songPath': item.path,
          'listenedMs': (listenedSecs * 1000).toInt(),
          'durationMs': item.durationMs > 0
              ? item.durationMs
              : (state.duration * 1000).toInt(),
          'title': item.title,
          'artist': item.artist,
          'album': item.album,
          'countAsPlay': countAsPlay,
        });
        await statsRecordPlay(dbPath: dbPath, payloadJson: payloadJson);
        _ref.invalidate(listenStatsProvider);
        _ref.invalidate(mostPlayedProvider);
      } catch (_) {
      }
    });
  }

  Future<ResolvedMediaUrl?> _resolveOnlineUrl(QueueItem item) async {
    final infoJson = item.onlineInfoJson;
    if (infoJson == null) return null;
    final s = _ref.read(settingsProvider).valueOrNull;
    final preferred = _sessionQualityOverride ??
        s?.onlineDefaultQuality ??
        '320k';
    final fb = s?.onlineQualityFallbackBehavior ?? 'lower';
    return _tryLxResolve(infoJson, _qualityCandidates(preferred, fb));
  }

  Future<bool> _autoSwitchSource(QueueItem item, {bool force = false}) async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    final now = DateTime.now();
    if (_lastAutoSwitchAt != null &&
        _lastAutoSwitchPath == item.path &&
        now.difference(_lastAutoSwitchAt!) < const Duration(milliseconds: 800)) {
      return false;
    }
    _lastAutoSwitchAt = now;
    _lastAutoSwitchPath = item.path;
    if ((settings?.onlineFailureBehavior ?? 'pause') != 'autoswitch' &&
        !force) {
      return false;
    }

    final infoJson = item.onlineInfoJson ?? item.onlineSongJson;
    if (infoJson == null || infoJson.isEmpty) return false;
    var info = <String, dynamic>{};
    try {
      info = jsonDecode(infoJson) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }

    final key = '${item.title}|${item.artist}';
    if (_switchCtxKey != key) {
      _switchCtxKey = key;
      _failedSources.clear();
    }
    if (item.title.trim().isEmpty) return false;
    AppLog.info('autoswitch', '起播失败自动换源: ${item.title}');

    if (await _switchViaSiblingPlatform(item)) return true;

    final curSource = (info['source'] as String?) ?? item.source;
    var curKey = (curSource == null || curSource.isEmpty) ? '' : curSource;
    if (curKey.isEmpty) {
      final mj = info['musicInfo'];
      var label = mj is Map<String, dynamic>
          ? (mj['platform'] ?? mj['source'])?.toString() ?? ''
          : '';
      if (label.isEmpty) {
        try {
          final sj = jsonDecode(item.onlineSongJson ?? '') as Map<String, dynamic>?;
          final sm = sj?['musicInfo'];
          if (sm is Map<String, dynamic>) {
            label = (sm['platform'] ?? sm['source'])?.toString() ?? '';
          }
          if (label.trim().isEmpty) {
            final pid = sj?['pluginId'] as String?;
            if (pid != null && pid.isNotEmpty) {
              final engine = await _ref.read(pluginEngineProvider.future);
              label = await _platformLabelFromPluginMeta(engine, pid);
              if (label.isNotEmpty) {
                AppLog.info('autoswitch',
                    'musicInfo 无平台标签，回退插件元数据: $label');
              }
            }
          }
        } catch (_) {}
      }
      curKey = lxSourceKeyForPlatform(label);
    }
    if (curKey.isEmpty) {
      AppLog.warn('autoswitch', '无法识别平台标签，放弃落雪换源: ${item.title}');
      return false;
    }
    _failedSources.add(curKey);

    final fb = settings?.onlineQualityFallbackBehavior ?? 'lower';
    final preferred = settings?.onlineDefaultQuality ?? '320k';
    final sourceLabels = {for (final s in kOnlineSources) s.id: s.label};

    while (true) {
      final String rawJson;
      try {
        rawJson = await findAlternativeLxSource(
          songName: item.title,
          songArtist: item.artist,
          songDuration: item.durationMs / 1000.0,
          failedSourcesJson: jsonEncode(_failedSources.toList()),
        );
      } catch (_) {
        break;
      }
      if (rawJson.isEmpty || rawJson == 'null') break;
      final Map<String, dynamic> raw;
      try {
        raw = jsonDecode(rawJson) as Map<String, dynamic>;
      } catch (_) {
        break;
      }
      final newItem = OnlineTrack.fromJson(raw).toQueueItem();
      final srcId = newItem.source;
      final infoJson = newItem.onlineInfoJson;
      if (srcId == null ||
          srcId.isEmpty ||
          _failedSources.contains(srcId) ||
          infoJson == null ||
          infoJson.isEmpty) {
        break;
      }
      final url = await _tryLxResolve(
        infoJson,
        _qualityCandidates(preferred, fb),
      );
      if (url == null) {
        AppLog.warn('autoswitch', '落雪换源候选解析失败: $srcId');
        _failedSources.add(srcId);
        continue;
      }
      final idx = state.queueIndex;
      final queue = [...state.queue];
      if (idx >= 0 && idx < queue.length) queue[idx] = newItem;
      state = state.copyWith(
        queue: queue,
        current: newItem,
        isPlaying: false,
        resolving: true,
        position: 0,
        duration: newItem.durationMs / 1000.0,
        error: null,
      );
      _syncToSystemMediaSession();
      try {
        state = state.copyWith(resolving: false);
        await _startOnlineUrl(url.url,
            headers: url.headers, item: newItem, ekey: url.ekey, cek: url.cek);
      } catch (_) {
        _failedSources.add(srcId);
        continue;
      }
      _skipDepth = 0;
      state = state.copyWith(resolving: false, error: null);
      _currentPlayCountRecorded = false;
      _accumulatedTime = 0;
      _recordRecentPlay(newItem);
      _recordHistory(newItem);
      _reportBehavior(newItem, 'play', 0);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
      AppLog.info('autoswitch', '落雪换源命中: $srcId');
      _showPlaybackToast(
          tr('已自动切换到 {source} 音源', {'source': sourceLabels[srcId] ?? srcId}));
      return true;
    }
    return false;
  }

  Future<bool> _switchViaSiblingPlatform(QueueItem item) async {
    ResolvedMediaUrl? hit;
    Map<String, dynamic>? healedJson;
    try {
      final json = item.onlineSongJson;
      if (json == null || json.isEmpty) return false;
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final pluginId = songJson['pluginId'] as String?;
      final format = songJson['format'] as String? ?? 'lx';
      final sourceKey = songJson['source'] as String? ?? '';
      final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
      if (pluginId == null || pluginId.isEmpty) return false;
      if (state.current?.path != item.path) return false;

      final engine = await _ref.read(pluginEngineProvider.future);
      final preferred =
          _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ??
              '320k';

      var labelOverride = _songPlatformLabel(format, sourceKey, musicInfo);
      if (labelOverride.trim().isEmpty) {
        labelOverride = await _platformLabelFromPluginMeta(engine, pluginId);
        if (labelOverride.isNotEmpty) {
          AppLog.info('autoswitch',
              'musicInfo 无平台标签，回退插件元数据: $labelOverride');
        }
      }
      final override = labelOverride.trim().isEmpty ? null : labelOverride;

      hit = await _resolveViaSiblingPlugin(
        failedId: pluginId,
        format: format,
        sourceKey: sourceKey,
        musicInfo: musicInfo,
        quality: preferred,
        itemPath: item.path,
        engine: engine,
        platformLabelOverride: override,
      );

      if (hit == null) {
        final sources = await engine.store.loadSources();
        final healed = await _crossFormatHeal(
            pluginId, format, sourceKey, musicInfo, sources, engine,
            platformLabelOverride: override);
        if (healed != null) {
          final (plugin, newJson) = healed;
          final newFormat = newJson['format'] as String? ?? format;
          final newSourceKey = newJson['source'] as String? ?? sourceKey;
          final newMusicInfo =
              newJson['musicInfo'] as Map<String, dynamic>? ?? musicInfo;
          if (isMfFormatValue(newFormat)) {
            hit = await engine.getMusicFreeUrl(
              plugin,
              newMusicInfo,
              preferred: preferred,
              fallback: 'pause',
            );
          } else {
            final r = await engine.getMusicUrl(
                plugin, newSourceKey, newMusicInfo, preferred);
            final url = r?['url'] as String?;
            hit = (r != null && _isPlayableUrl(url))
                ? ResolvedMediaUrl(
                    url: url!,
                    headers: r['headers'] is Map
                        ? (r['headers'] as Map).cast<String, String>()
                        : null,
                    quality: preferred,
                  )
                : null;
          }
          if (hit != null) healedJson = newJson;
        }
      }
      if (hit == null) return false;

      if (healedJson != null) {
        _applyCrossFormatHealToState(
          itemPath: item.path,
          pluginId: healedJson['pluginId'] as String? ?? pluginId,
          newOnlineSongJson: jsonEncode(healedJson),
          newSource: healedJson['source'] as String? ?? sourceKey,
          newOnlineInfoJson:
              jsonEncode(healedJson['musicInfo'] ?? musicInfo),
        );
      }

      state = state.copyWith(
        isPlaying: false,
        resolving: false,
        position: 0,
        error: null,
      );
      _skipDepth = 0;
      await _startOnlineUrl(hit.url,
          headers: hit.headers, item: item, ekey: hit.ekey, cek: hit.cek);
      state = state.copyWith(resolving: false, error: null);
      _currentPlayCountRecorded = false;
      _accumulatedTime = 0;
      _recordRecentPlay(item);
      _recordHistory(item);
      _reportBehavior(item, 'play', 0);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
      _showPlaybackToast(tr('播放失败，已自动切换音源重播'));
      return true;
    } catch (_) {
      return false;
    }
  }

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

  Future<ResolvedMediaUrl?> _resolvePluginUrl(
      Map<String, dynamic> songJson, String quality,
      {String itemPath = ''}) async {
    try {
      final pluginId = songJson['pluginId'] as String?;
      var sourceKey = songJson['source'] as String? ?? '';
      var musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
      var format = songJson['format'] as String? ?? 'lx';
      if (pluginId == null || pluginId.isEmpty) return null;

      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final staleUrl = musicInfo['url'];
      if (staleUrl is String && staleUrl.startsWith('http')) {
        musicInfo.remove('url');
      }
      var source = sources.where((s) => s.id == pluginId).toList();
      var labelOverride = _songPlatformLabel(format, sourceKey, musicInfo);
      if (labelOverride.trim().isEmpty) {
        labelOverride = await _platformLabelFromPluginMeta(engine, pluginId);
      }
      final override = labelOverride.trim().isEmpty ? null : labelOverride;
      if (source.isEmpty) {
        final healed = _findHealedPlugin(sources, format, sourceKey, musicInfo,
            platformLabelOverride: override);
        if (healed == null) {
          final healedCross = await _crossFormatHeal(
              pluginId, format, sourceKey, musicInfo, sources, engine,
              platformLabelOverride: override);
          if (healedCross == null) {
            return null;
          }
          source = [healedCross.$1];
          final newFormat = healedCross.$2['format'] as String? ?? format;
          final newSource = healedCross.$2['source'] as String? ?? sourceKey;
          final newMusicInfo = healedCross.$2['musicInfo'] as Map<String, dynamic>? ?? musicInfo;
          format = newFormat;
          sourceKey = newSource;
          musicInfo = newMusicInfo;
          final newOnlineSongJson = jsonEncode(healedCross.$2);
          final newOnlineInfoJson = jsonEncode(newMusicInfo);
          _applyCrossFormatHealToState(
            itemPath: itemPath,
            pluginId: healedCross.$1.id,
            newOnlineSongJson: newOnlineSongJson,
            newSource: newSource,
            newOnlineInfoJson: newOnlineInfoJson,
          );
        } else {
          source = [healed];
        }
      }

      ResolvedMediaUrl? resolved;
      if (isMfFormatValue(format)) {
        resolved = await engine
            .getMusicFreeUrl(
              source.first,
              musicInfo,
              preferred: quality,
              fallback: 'pause',
            )
            .timeout(const Duration(seconds: 8));
      } else {
        final result = await engine
            .getMusicUrl(source.first, sourceKey, musicInfo, quality)
            .timeout(const Duration(seconds: 8));
        final url = result?['url'] as String?;
        if (result != null && _isPlayableUrl(url)) {
          final h = result['headers'];
          final reportedRaw = result['type'];
          final reportedQuality = reportedRaw is String
              ? PluginEngine.normalizeQualityKey(reportedRaw)
              : null;
          resolved = ResolvedMediaUrl(
            url: url!,
            headers: h is Map ? h.cast<String, String>() : null,
            quality: reportedQuality ?? quality,
          );
        } else {
        }
      }
      if (resolved != null) return resolved;
      // 解析失败不上抛兄弟换源：本函数被音质探测回调共用，探测每档失败
      // 都会走到这里，若在此兜底换源会绕过「起播失败行为」设置门控与
      // _autoSwitchSource 的防抖（表现为未开启自动换源也频繁触发换源）。
      // 换源统一由起播失败路径 _autoSwitchSource 按 settings 门控执行。
      return null;
    } catch (e) {
      return null;
    }
  }

  String _songPlatformLabel(
    String format,
    String sourceKey,
    Map<String, dynamic> musicInfo,
  ) {
    if (format == 'lx') return sourceKey;
    final v = musicInfo['platform'] ?? musicInfo['source'] ?? sourceKey;
    return v?.toString() ?? '';
  }

  /// musicfree 插件的歌曲 musicInfo 常不带 platform/source 字段，
  /// 平台标签为空时从插件元数据兜底（exports 的 platform / pluginName / name）。
  Future<String> _platformLabelFromPluginMeta(
    PluginEngine engine,
    String pluginId,
  ) async {
    try {
      final sources = await engine.store.loadSources();
      final src = sources.where((s) => s.id == pluginId).toList();
      if (src.isEmpty) return '';
      final meta = await engine.ensureLoaded(src.first);
      for (final k in const ['platform', 'pluginName', 'name']) {
        final v = meta?[k]?.toString() ?? '';
        if (v.trim().isNotEmpty) return v.trim();
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  Future<ResolvedMediaUrl?> _resolveViaSiblingPlugin({
    required String failedId,
    required String format,
    required String sourceKey,
    required Map<String, dynamic> musicInfo,
    required String quality,
    required String itemPath,
    required PluginEngine engine,
    String? platformLabelOverride,
  }) async {
    try {
      final pluginFormat = PluginFormat.fromValue(format);
      var platformLabel = _songPlatformLabel(format, sourceKey, musicInfo);
      if (platformLabel.trim().isEmpty &&
          platformLabelOverride != null &&
          platformLabelOverride.trim().isNotEmpty) {
        platformLabel = platformLabelOverride;
      }
      final sources = await engine.store.loadSources();
      final candidates = listEnabledPluginsForPlatform(
        platformLabel: platformLabel,
        installedPlugins: sources,
        format: pluginFormat,
        excludeId: failedId,
      ).take(3).toList();
      AppLog.info('autoswitch',
          '兄弟插件换源 label=$platformLabel failedId=$failedId candidates=${candidates.length}');
      for (final plugin in candidates) {
        final ResolvedMediaUrl? hit;
        if (plugin.format.isMfCompatible) {
          hit = await engine
              .getMusicFreeUrl(
                plugin,
                musicInfo,
                preferred: quality,
                fallback: 'pause',
              )
              .timeout(const Duration(seconds: 8));
        } else {
          final lxKey = lxSourceKeyForPlatform(platformLabel);
          final lxSupported =
              plugin.sources.isEmpty || plugin.sources.contains(lxKey);
          if (lxKey.isEmpty || !lxSupported) {
            continue;
          }
          final result = await engine
              .getMusicUrl(plugin, lxKey, musicInfo, quality)
              .timeout(const Duration(seconds: 8));
          final url = result?['url'] as String?;
          hit = (result != null && _isPlayableUrl(url))
              ? ResolvedMediaUrl(
                  url: url!,
                  headers: result['headers'] is Map
                      ? (result['headers'] as Map).cast<String, String>()
                      : null,
                  quality: quality,
                )
              : null;
        }
        if (hit == null) {
          continue;
        }
        return hit;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  PluginSource? _findHealedPlugin(
    List<PluginSource> sources,
    String format,
    String sourceKey,
    Map<String, dynamic> musicInfo, {
    String? platformLabelOverride,
  }) {
    final pluginFormat = PluginFormat.fromValue(format);
    var platform = _songPlatformLabel(format, sourceKey, musicInfo);
    if (platform.trim().isEmpty &&
        platformLabelOverride != null &&
        platformLabelOverride.trim().isNotEmpty) {
      platform = platformLabelOverride;
    }
    if (platform.trim().isEmpty) return null;
    return findPluginForPlatform(
      platformLabel: platform,
      installedPlugins: sources,
      format: pluginFormat,
    );
  }

  Future<(PluginSource, Map<String, dynamic>)?> _crossFormatHeal(
    String pluginId,
    String format,
    String sourceKey,
    Map<String, dynamic> musicInfo,
    List<PluginSource> sources,
    PluginEngine engine, {
    String? platformLabelOverride,
  }) async {
    final pluginFormat = PluginFormat.fromValue(format);
    var platformLabel = _songPlatformLabel(format, sourceKey, musicInfo);
    if (platformLabel.trim().isEmpty &&
        platformLabelOverride != null &&
        platformLabelOverride.trim().isNotEmpty) {
      platformLabel = platformLabelOverride;
    }
    if (platformLabel.trim().isEmpty) return null;

    final title = (musicInfo['name'] ?? musicInfo['title'] ?? '').toString().trim();
    final artist = (musicInfo['singer'] ?? musicInfo['artist'] ?? '').toString().trim();
    if (title.isEmpty) return null;

    final cacheKey = '$pluginId|$title|$artist';
    final cached = _crossFormatHealCache[cacheKey];
    if (cached != null) {
      final cachedSource = sources.where((s) => s.id == cached['pluginId']).toList();
      if (cachedSource.isNotEmpty) return (cachedSource.first, cached);
      _crossFormatHealCache.remove(cacheKey);
    }

    final cross = findPluginForPlatform(
      platformLabel: platformLabel,
      installedPlugins: sources,
      format: pluginFormat,
      allowCrossFormat: true,
    );
    if (cross == null) return null;
    if (cross.format == pluginFormat) return null;

    final keyword = artist.isEmpty ? title : '$title $artist';
    try {
      final PluginSearchResult? match;
      if (cross.format.isMfCompatible) {
        final catalog = PluginCatalogService(engine, sources);
        final results = await catalog.searchMusic(cross, keyword, limit: 10);
        match = _pickBestSearchMatch(results, title, artist);
      } else {
        final lxKey = _lxSourceKeyForPlatform(platformLabel, cross);
        final results = await engine.searchInPlugin(cross, lxKey, keyword, limit: 10);
        match = _pickBestSearchMatch(results, title, artist);
      }
      if (match == null) return null;

      final newSongJson = cross.format.isMfCompatible
          ? {
              'pluginId': cross.id,
              'format': cross.format.value,
              'musicInfo': match.toJson(),
            }
          : {
              'pluginId': cross.id,
              'format': 'lx',
              'source': match.source,
              'musicInfo': match.toJson(),
            };
      _crossFormatHealCache[cacheKey] = newSongJson;
      if (_crossFormatHealCache.length > 64) {
        _crossFormatHealCache.remove(_crossFormatHealCache.keys.first);
      }
      return (cross, newSongJson);
    } catch (e) {
      return null;
    }
  }

  void _applyCrossFormatHealToState({
    required String itemPath,
    required String pluginId,
    required String newOnlineSongJson,
    required String newSource,
    required String newOnlineInfoJson,
  }) {
    final cur = state.current;
    if (cur != null && cur.path == itemPath) {
      final curOnline = cur.onlineSongJson;
      if (curOnline != null && curOnline.contains('"pluginId":"$pluginId"')) {
        return;
      }
    }
    final updated = cur?.path == itemPath
        ? cur!.copyWithOnlineSource(
            onlineSongJson: newOnlineSongJson,
            source: newSource,
            onlineInfoJson: newOnlineInfoJson,
          )
        : cur;
    final queue = state.queue.map((q) {
      if (q.path != itemPath) return q;
      return q.copyWithOnlineSource(
        onlineSongJson: newOnlineSongJson,
        source: newSource,
        onlineInfoJson: newOnlineInfoJson,
      );
    }).toList();
    state = state.copyWith(current: updated, queue: queue);
  }

  PluginSearchResult? _pickBestSearchMatch(
    List<PluginSearchResult> results,
    String title,
    String artist,
  ) {
    if (results.isEmpty) return null;
    for (final r in results) {
      if (_matchOnlineTitle(title, r.name)) return r;
    }
    return results.first;
  }

  String _lxSourceKeyForPlatform(String platformLabel, PluginSource plugin) {
    final lxKey = lxSourceKeyForPlatform(platformLabel);
    for (final s in plugin.sources) {
      if (s == lxKey) return s;
    }
    return lxKey.isNotEmpty ? lxKey : (plugin.sources.isNotEmpty ? plugin.sources.first : 'default');
  }

  void _reportBehavior(QueueItem item, String action, int listenDuration) {
    final hash = md5.convert(utf8.encode('${item.title}|${item.artist}|local')).toString();
    _ref.read(accountApiProvider).reportUserBehavior(
          songId: item.path,
          songName: item.title,
          singer: item.artist,
          songHash: hash,
          source: item.isOnline ? 'online' : 'local',
          action: action,
          listenDuration: listenDuration,
          playCount: 1,
        );
  }

  void _recordRecentPlay(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
        if (item.isOnline) {
          await _ref.read(onlineMetaStoreProvider).put(item);
        }
        _ref.invalidate(recentProvider);
      } catch (_) {
      }
    });
  }

  Future<void> removeFromQueue(int index) async {
    final queue = [...state.queue];
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == state.queueIndex;
    queue.removeAt(index);
    if (queue.isEmpty) {
      _playEpoch++;
      await _stopExclusive();
      await _player.stop();
      state = const PlaybackState();
      return;
    }
    var newIndex = state.queueIndex;
    if (index < state.queueIndex) {
      newIndex = state.queueIndex - 1;
    } else if (index == state.queueIndex) {
      newIndex = index.clamp(0, queue.length - 1);
    }
    if (wasCurrent) {
      await _playAt(newIndex);
    } else {
      state = state.copyWith(queue: queue, queueIndex: newIndex);
    }
  }

  Future<void> clearQueue() async {
    _playEpoch++;
    if (_activeProbeKey != null) {
      try {
        onlineQualityProbeRegistry.invalidate(_activeProbeKey!);
      } catch (_) {}
      _activeProbeKey = null;
    }
    _skipDepth = 0;
    _sessionQualityOverride = null;
    await _stopExclusive();
    try {
      await _player.stop();
    } catch (_) {}
    state = const PlaybackState();
    // 同步落盘空会话，防止下次启动恢复出已清空的队列
    await _persistSession();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.queue.length) return;
    if (newIndex < 0 || newIndex >= state.queue.length) return;
    final queue = [...state.queue];
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    var qi = state.queueIndex;
    if (oldIndex == qi) {
      qi = newIndex;
    } else if (oldIndex < qi && newIndex >= qi) {
      qi--;
    } else if (oldIndex > qi && newIndex <= qi) {
      qi++;
    }
    state = state.copyWith(queue: queue, queueIndex: qi);
  }

  Future<void> playQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _playAt(index);
  }

  Future<void> playNextShare(QueueItem item) async {
    final queue = [...state.queue];
    final qi = state.queueIndex;
    if (queue.isEmpty) {
      state = state.copyWith(
        queue: [item],
        queueIndex: 0,
        current: null,
        isPlaying: false,
      );
      return;
    }
    final insertAt = (qi + 1).clamp(0, queue.length);
    queue.insert(insertAt, item);
    state = state.copyWith(queue: queue, queueIndex: qi);
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

  Future<void> pauseFromSystem() async {
    if (!state.isPlaying) return;
    final st =
        StackTrace.current.toString().split('\n').take(3).join(' <- ');
    AppLog.warn('playgate', 'pauseFromSystem $st');
    await toggle();
  }

  DateTime _lastUserPauseAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get lastUserPauseAt => _lastUserPauseAt;

  Future<void> resumeAfterMvPause() async {
    AppLog.warn('playgate', 'resume after mv focus-fight pause');
    await _player.play();
  }

  bool mvSuppressFocusLoss = false;

  /// 音频焦点被其他应用打断：暂停当前出声主体。DSP/USB 独占管线必须走
  /// Pause 命令（_player 只控制 ExoPlayer，停不了 Rust 侧 AAudio 流）；
  /// 投放中输出主体不在本机，焦点变化不影响被投端，忽略。
  Future<void> _pauseForInterruption() async {
    if (_ref.read(dlnaCastProvider).isCasting) return;
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

  /// 临时打断结束后恢复播放（与 toggle 恢复分支同构，但不涉及冷启动续播）。
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

  Future<void> toggle() async {
    if (state.current == null) return;
    final st =
        StackTrace.current.toString().split('\n').take(3).join(' <- ');
    AppLog.info('playgate',
        'toggle cur=${state.isPlaying ? "play->pause" : "pause->play"} $st');
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
      // 暂停/恢复必须走 Pause/Resume（Rust 侧仅切换流状态，samples_played
      // 冻结不动，位置严格连续）。不可用 Seek(state.position) 实现——显示
      // 位置比实际解码位置滞后至多一个轮询周期，且 try_seek 失败时错误被
      // 吞、进度基准仍被无条件重设，恢复播放后音频位置与进度条脱节（乱飞）。
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
        // 在线歌冷启动恢复：直链需重新解析，统一走 _playAt 入口续播
        final idx = state.queueIndex;
        if (idx >= 0 && idx < state.queue.length) {
          try {
            await _playAt(idx, startAtSecs: pendingPos, skipOnFailure: false);
          } catch (_) {
            // 失败已在 _playAt 内置错误态（不换源不跳歌），这里只吞 rethrow
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
    // 诊断插桩：定位 DLNA 被投场景下「起播 ~200ms 内 DSP 死亡」是否有
    // 隐性 seek 参与（watch_link / MediaSession / DMR 均是候选来源）。
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

  Future<void> cyclePlayMode() async {
    final next = (state.playMode + 1) % 3;
    state = state.copyWith(playMode: next);
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    await _ref.read(settingsProvider.notifier).setPlayMode(next);
    _syncToSystemMediaSession();
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
    if (ended != null) _reportBehavior(ended, 'complete', 0);
    _flushPlayStats();
    if (state.playMode == 1) {
      await seek(0);
      await _player.play();
      _trackStartTime = DateTime.now();
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      await _player.pause();
      if (state.current != null) await seek(0);
      return;
    }
    await _playAt(next);
  }

  int _pickNextIndex() {
    final n = state.queue.length;
    if (n == 0) return -1;
    if (state.playMode == 2) {
      return _randomNextIndex();
    }
    if (state.queueIndex < 0) return 0;
    return (state.queueIndex + 1) % n;
  }

  int _randomNextIndex() {
    if (_shuffleFuture.isNotEmpty) {
      final path = _shuffleFuture.removeLast();
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0) return i;
    }
    if (state.current != null) {
      _shuffleHistory.add(state.current!.path);
      if (_shuffleHistory.length > 256) _shuffleHistory.removeAt(0);
    }
    return _randomDistinctIndex();
  }

  int _randomPrevIndex() {
    if (_shuffleHistory.isNotEmpty) {
      final path = _shuffleHistory.removeLast();
      if (state.current != null) _shuffleFuture.add(state.current!.path);
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0) return i;
    }
    return _randomDistinctIndex();
  }

  int _randomDistinctIndex() {
    final n = state.queue.length;
    if (n <= 1) return 0;
    final cur = state.current?.path;
    final candidates = <int>[];
    for (var i = 0; i < n; i++) {
      if (state.queue[i].path != cur) candidates.add(i);
    }
    if (candidates.isEmpty) return 0;
    return candidates[_rand.nextInt(candidates.length)];
  }

  Future<void> _persistSession() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final settings = _ref.read(settingsProvider).valueOrNull;
      final item = state.current;
      if (item == null || state.queue.isEmpty) {
        // 空队列（如清空播放队列后）也要落盘空会话，否则旧会话残留
        // 会在下次启动被 _restoreSession 原样恢复，表现为队列清不掉
        await savePlaybackSession(
          dbPath: dbPath,
          sessionJson: jsonEncode({
            'currentSongPath': '',
            'playQueuePaths': <String>[],
            'sourceSongPaths': <String>[],
            'playMode': 0,
            'volume': (settings?.volume ?? 1.0) * 100.0,
            'currentPositionSecs': 0.0,
            'isPlaying': false,
            'sessionQualityOverride': null,
            'queueSongMeta': <String, dynamic>{},
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        return;
      }

      final Map<String, dynamic> queueSongMeta = {};
      for (final q in state.queue) {
        queueSongMeta[q.path] = {
          'path': q.path,
          'title': q.title,
          'artist': q.artist,
          'album': q.album,
          'durationMs': q.durationMs,
          'coverUrl': q.coverUrl,
          'coverPath': q.coverPath,
          'source': q.source,
          'onlineSongJson': q.onlineSongJson,
          'onlineQuality': q.onlineQuality,
          'onlineInfoJson': q.onlineInfoJson,
        };
      }

      final sessionJson = jsonEncode({
        'currentSongPath': item.path,
        'playQueuePaths': state.queue.map((q) => q.path).toList(),
        'sourceSongPaths': state.queue.map((q) => q.path).toList(),
        'playMode': state.playMode,
        'volume': (settings?.volume ?? 1.0) * 100.0,
        'currentPositionSecs': state.position,
        'isPlaying': state.isPlaying,
        'sessionQualityOverride': null,
        'queueSongMeta': queueSongMeta,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await savePlaybackSession(dbPath: dbPath, sessionJson: sessionJson);
    } catch (e) {
      AppLogger.instance.log('session', '播放会话保存失败: $e');
    }
  }

  // ---------------- DLNA 投屏支持 ----------------

  Future<void> pauseLocalEngine() async {
    _flushPlayStats();
    try {
      await _stopExclusive();
    } catch (_) {}
    try {
      await _player.pause();
    } catch (_) {}
    state = state.copyWith(isPlaying: false);
    _syncToSystemMediaSession();
  }

  void syncCastPosition(double pos, double dur, bool playing) {
    if (state.current == null) return;
    state = state.copyWith(
      position: pos < 0 ? 0 : pos,
      duration: dur > 0.5 ? dur : null,
      isPlaying: playing,
    );
  }

  Future<void> playExternalUri({
    required String uri,
    required String title,
    String artist = '',
    String album = '',
    int durationMs = 0,
    String coverUrl = '',
  }) async {
    await _stopExclusive();
    _playEpoch++;
    _flushPlayStats();
    _currentPlayCountRecorded = false;
    _accumulatedTime = 0;
    _restoredOnlinePending = null;
    _restoredLocalPending = null;
    if (_activeProbeKey != null) {
      onlineQualityProbeRegistry.invalidate(_activeProbeKey!);
      _activeProbeKey = null;
    }
    final item = QueueItem(
      path: uri,
      title: title.isEmpty ? tr('DLNA 投放') : title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      coverUrl: coverUrl.isEmpty ? null : coverUrl,
    );
    state = state.copyWith(
      queue: [item],
      queueIndex: 0,
      current: item,
      isPlaying: false,
      position: 0,
      duration: durationMs / 1000.0,
      resolving: false,
      error: null,
    );
    _syncToSystemMediaSession();
    try {
      // 走在线管线而非 _startUrl：被投 URL 指向发送端 httpd（内网地址），
      // 直喂 DSP 会被 SSRF 校验拒绝；经本机回环代理后 DSP 拿到 127.0.0.1
      // 天然放行，同时获得流缓存/进度 seek 支持与正常的播放上报链路。
      await _startOnlineUrl(uri, item: item);
      state = state.copyWith(isPlaying: true);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
    } catch (e) {
      state = state.copyWith(
        isPlaying: false,
        error: tr('播放失败：{e}', {'e': e.toString()}),
      );
      _showPlaybackToast(tr('DLNA 投放播放失败'));
      _syncToSystemMediaSession();
    }
  }

  Future<CastMediaResolution?> resolveForCast(QueueItem item) async {
    if (item.isOnline) {
      final json = item.onlineSongJson;
      if (json != null && json.isNotEmpty) {
        final songJson = jsonDecode(json) as Map<String, dynamic>;
        final s0 = _ref.read(settingsProvider).valueOrNull;
        final fb0 = s0?.onlineQualityFallbackBehavior ?? 'lower';
        final preferred = _sessionQualityOverride ??
            s0?.onlineDefaultQuality ??
            item.onlineQuality ??
            '320k';
        final candidates = _qualityCandidates(preferred, fb0);
        final key = _songProbeKey(songJson, item);
        final probe = onlineQualityProbeRegistry.ensure(
            key, _buildResolveCallback(songJson, item));
        _activeProbeKey = key;
        final start = await probe
            .startBest(preferred, candidates)
            .timeout(const Duration(seconds: 45), onTimeout: () => null);
        if (start == null) return null;
        final clean = sanitizeMediaUrl(start.url);
        if (clean.isEmpty) return null;
        return CastMediaResolution(
          url: clean,
          headers: await withBilibiliStreamCookie(
                clean,
                normalizeMediaRequestHeaders(clean, start.headers),
                dataDir: _ref.read(appDataDirProvider.future),
              ) ??
              const {},
          isRemote: true,
        );
      }
      final url = await _resolveOnlineUrl(item);
      if (url == null) return null;
      final clean = sanitizeMediaUrl(url.url);
      if (clean.isEmpty) return null;
      return CastMediaResolution(
        url: clean,
        headers: await withBilibiliStreamCookie(
              clean,
              normalizeMediaRequestHeaders(clean, url.headers),
              dataDir: _ref.read(appDataDirProvider.future),
            ) ??
            const {},
        isRemote: true,
      );
    }
    if (_isRemotePath(item.path)) {
      final plan = await RemoteLibraryService(_ref).playbackSource(item.path);
      if (plan.isCached) {
        return CastMediaResolution(
            url: plan.cachedPath!, headers: const {}, isRemote: false);
      }
      if (plan.url.isEmpty) return null;
      return CastMediaResolution(
        url: plan.url,
        headers: plan.headers ?? const {},
        isRemote: true,
      );
    }
    var target = item.path;
    if (SafChannel.isSafPath(target)) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          target, p.join(tmp.path, 'saf_playback'));
    }
    if (!File(target).existsSync()) return null;
    return CastMediaResolution(url: target, headers: const {}, isRemote: false);
  }

  Future<void> _castFollowPlay(
    QueueItem item,
    int epoch, {
    double startAtSecs = 0,
  }) async {
    state = state.copyWith(resolving: item.isOnline);
    final media = await resolveForCast(item);
    if (epoch != _playEpoch) return;
    if (media == null) throw StateError(tr('无法获取播放链接'));
    try {
      await _player.stop();
    } catch (_) {}
    // castMedia 内建 SetUri→Play→Seek 链（startAtSecs 直达，设备不响应
    // seek 时静默降级从头播），与桌面 castFromPlayAudio 的 startOffsetMs
    // 语义对齐，无需调用方事后补偿 seek
    await _ref.read(dlnaCastProvider.notifier).castMedia(
          title: item.title,
          artist: item.artist,
          album: item.album,
          url: media.url,
          isRemote: media.isRemote,
          headers: media.headers,
          durationMs: item.durationMs,
          coverUrl: item.coverUrl,
          startAtSecs: startAtSecs,
        );
    if (epoch != _playEpoch) return;
    state = state.copyWith(isPlaying: true, resolving: false);
  }

  @override
  void dispose() {
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

class CastMediaResolution {
  final String url;
  final Map<String, String> headers;

  final bool isRemote;
  const CastMediaResolution({
    required this.url,
    required this.headers,
    required this.isRemote,
  });
}

final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ?? 1.0;
});

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>(
  (ref) => PlayerNotifier(ref),
);
