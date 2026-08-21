import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as as_pkg;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/app_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../rust/api.dart';

/// 全局系统控制中心 AudioHandler 句柄
XianYuAudioHandler? audioHandler;

/// 系统控制中心（MediaSession / Notification）与 Flutter 播放状态的双向桥梁
class XianYuAudioHandler extends as_pkg.BaseAudioHandler with as_pkg.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  /// 广播更新当前系统的 MediaItem（系统控制中心卡片：标题/歌手/专辑/封面/时长）
  void syncMediaItem(QueueItem item, double durationSecs) {
    mediaItem.add(
      as_pkg.MediaItem(
        id: item.path,
        album: item.album.isEmpty ? '弦予音乐' : item.album,
        title: item.title,
        artist: item.artist.isEmpty ? '未知歌手' : item.artist,
        duration: Duration(milliseconds: (durationSecs * 1000).round()),
        artUri: (item.coverUrl != null && item.coverUrl!.isNotEmpty)
            ? Uri.tryParse(item.coverUrl!)
            : null,
      ),
    );
  }

  /// 广播更新系统的 PlaybackState（播放状态/进度/控制动作/循环模式）
  void syncPlaybackState({
    required bool isPlaying,
    required double positionSecs,
    required double durationSecs,
  }) {
    playbackState.add(
      as_pkg.PlaybackState(
        controls: [
          as_pkg.MediaControl.skipToPrevious,
          if (isPlaying) as_pkg.MediaControl.pause else as_pkg.MediaControl.play,
          as_pkg.MediaControl.skipToNext,
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
      ),
    );
  }

  @override
  Future<void> play() async {
    await _notifier?.toggle();
  }

  @override
  Future<void> pause() async {
    await _notifier?.toggle();
  }

  @override
  Future<void> skipToNext() async {
    await _notifier?.next();
  }

  @override
  Future<void> skipToPrevious() async {
    await _notifier?.previous();
  }

  @override
  Future<void> seek(Duration position) async {
    await _notifier?.seek(position.inMilliseconds / 1000.0);
  }

  @override
  Future<void> stop() async {
    await _notifier?.toggle();
  }
}

/// 播放中的单曲信息（小而美：仅保留 UI 需要的最小字段）。
class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String? coverUrl;
  final String? source;
  final String? onlineInfoJson;

  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.coverUrl,
    this.source,
    this.onlineInfoJson,
  });

  bool get isOnline => onlineInfoJson != null;
}

class PlaybackState {
  final QueueItem? current;
  final List<QueueItem> queue;
  final int queueIndex;
  final bool isPlaying;
  final double position;
  final double duration;
  final int playMode; // 0 顺序(列表循环) 1 单曲循环 2 随机
  final bool resolving;
  final String? error;

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
    );
  }
}

const Object _noChange = Object();

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
    audioHandler?.bindNotifier(this);
    _init();
  }

  final Ref _ref;
  final AudioPlayer _player = AudioPlayer();
  final Random _rand = Random();
  StreamSubscription<Duration?>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<dynamic>? _stateSub;
  bool _manualPause = false;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);

  double? _restoredOnlinePending;
  DateTime? _trackStartTime;

  final List<String> _shuffleHistory = [];
  final List<String> _shuffleFuture = [];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _persistSession();
    }
  }

  Future<void> _init() async {
    _posSub = _player.positionStream.listen((p) {
      final pos = p.inMilliseconds / 1000.0;
      state = state.copyWith(position: pos);
      _syncToSystemMediaSession();
      _persistPositionDebounced();
    });
    _durSub = _player.durationStream.listen((d) {
      final dur = (d ?? Duration.zero).inMilliseconds / 1000.0;
      state = state.copyWith(duration: dur);
      _syncToSystemMediaSession();
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      final playing = ps.playing;
      if (playing != state.isPlaying) {
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
        if (!playing && !_manualPause) {
          _onTrackEnd();
        }
      }
    });
    await _restoreSession();
  }

  /// 同步更新 Android/iOS 系统控制中心与通知栏
  void _syncToSystemMediaSession() {
    final cur = state.current;
    if (cur != null) {
      audioHandler?.syncMediaItem(cur, state.duration);
      audioHandler?.syncPlaybackState(
        isPlaying: state.isPlaying,
        positionSecs: state.position,
        durationSecs: state.duration,
      );
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

      if (jsonStr.isEmpty || jsonStr == 'null') return;

      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final String curPath = data['currentSongPath'] as String? ?? '';
      final List rawQueue = data['playQueuePaths'] as List? ?? [];
      final Map rawMeta = data['queueSongMeta'] as Map? ?? {};
      final int mode = (data['playMode'] as num?)?.toInt() ?? 0;
      final double pos = (data['currentPositionSecs'] as num?)?.toDouble() ?? 0;

      if (rawQueue.isEmpty || curPath.isEmpty) return;

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
            source: meta['source'] as String?,
            onlineInfoJson: meta['onlineInfoJson'] as String?,
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
        playMode: mode,
      );

      _syncToSystemMediaSession();

      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await _player.setVolume(vol);

      if (!currentItem.isOnline) {
        try {
          await _player.setFilePath(currentItem.path);
          await seek(pos);
        } catch (e) {
          AppLogger.instance.log('session', '本地曲目预加载失败: $e');
        }
      } else {
        _restoredOnlinePending = pos;
      }
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
    if (state.current == null) return;
    final now = DateTime.now();
    if (now.difference(_lastPosPersist).inSeconds < 5) return;
    _lastPosPersist = now;
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await updatePlaybackPosition(
          dbPath: dbPath,
          positionSecs: state.position,
          isPlaying: state.isPlaying,
        );
        await _persistSession();
      } catch (_) {}
    });
  }

  Future<void> playQueue(List<QueueItem> items, {int startIndex = 0}) async {
    if (items.isEmpty) return;
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    state = state.copyWith(
      queue: items,
      queueIndex: startIndex,
      current: items[startIndex],
    );
    await _playAt(startIndex, manualPause: true);
  }

  Future<void> _playAt(int index, {required bool manualPause}) async {
    if (index < 0 || index >= state.queue.length) return;

    _flushPlayStats();

    _manualPause = manualPause;
    _restoredOnlinePending = null;
    final item = state.queue[index];
    state = state.copyWith(
      queueIndex: index,
      current: item,
      isPlaying: false,
      position: 0,
      duration: item.durationMs / 1000.0,
      error: null,
      resolving: item.isOnline,
    );
    _syncToSystemMediaSession();
    try {
      if (item.isOnline) {
        final url = await _resolveOnlineUrl(item);
        if (state.queueIndex != index) return;
        if (url == null) {
          state = state.copyWith(
            isPlaying: false,
            resolving: false,
            error: '无法获取播放链接',
          );
          return;
        }
        await _player.setUrl(url);
      } else {
        await _player.setFilePath(item.path);
      }
      state = state.copyWith(resolving: false);
      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await _player.setVolume(vol);
      await _player.play();
      _syncToSystemMediaSession();

      _recordHistory(item);
      _trackStartTime = DateTime.now();
    } catch (e) {
      state = state.copyWith(
        isPlaying: false,
        resolving: false,
        error: item.isOnline ? '在线播放失败' : '文件无法播放',
      );
      _syncToSystemMediaSession();
    }
    _persistSession();
  }

  void _flushPlayStats() {
    final item = state.current;
    if (item != null && _trackStartTime != null) {
      final listenedSecs =
          DateTime.now().difference(_trackStartTime!).inMilliseconds / 1000.0;
      _recordPlayStats(item, listenedSecs);
      _trackStartTime = null;
    }
  }

  void _recordHistory(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
      } catch (_) {}
    });
  }

  void _recordPlayStats(QueueItem item, double listenedSecs) {
    if (listenedSecs < 3) return;
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
        });
        await statsRecordPlay(dbPath: dbPath, payloadJson: payloadJson);
      } catch (_) {}
    });
  }

  Future<String?> _resolveOnlineUrl(QueueItem item) async {
    final infoJson = item.onlineInfoJson;
    if (infoJson == null) return null;
    final preferred =
        _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    final dataDir = await _ref.read(appDataDirProvider.future);
    final candidates = <String>[
      preferred,
      if (preferred != '320k') '320k',
      if (preferred != '128k') '128k',
    ];
    for (final quality in candidates) {
      try {
        final json = await lxResolveUrl(
          songInfoJson: infoJson,
          quality: quality,
          dataDir: dataDir,
        );
        if (json == 'null') continue;
        final url = (jsonDecode(json) as Map<String, dynamic>)['url'] as String?;
        if (url != null && url.isNotEmpty) return url;
      } catch (_) {}
    }
    return null;
  }

  Future<void> toggle() async {
    if (state.current == null) return;
    if (state.isPlaying) {
      _manualPause = true;
      _flushPlayStats();
      await _player.pause();
    } else {
      _manualPause = false;
      _trackStartTime = DateTime.now();
      final pendingPos = _restoredOnlinePending;
      if (pendingPos != null) {
        _restoredOnlinePending = null;
        await _resumeRestoredOnline(pendingPos);
        _persistSession();
        return;
      }
      await _player.play();
    }
    _syncToSystemMediaSession();
    _persistSession();
  }

  Future<void> seek(double secs) async {
    if (_restoredOnlinePending != null) {
      _restoredOnlinePending = secs;
      state = state.copyWith(position: secs);
      _syncToSystemMediaSession();
      return;
    }
    await _player.seek(Duration(milliseconds: (secs * 1000).round()));
    _syncToSystemMediaSession();
  }

  Future<void> next() async {
    final i = _pickNextIndex();
    if (i >= 0) await _playAt(i, manualPause: true);
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
      if (i >= 0) await _playAt(i, manualPause: true);
      return;
    }
    final i = state.queueIndex <= 0 ? n - 1 : state.queueIndex - 1;
    await _playAt(i, manualPause: true);
  }

  Future<void> cyclePlayMode() async {
    final next = (state.playMode + 1) % 3;
    state = state.copyWith(playMode: next);
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    await _ref.read(settingsProvider.notifier).setPlayMode(next);
  }

  Future<void> _onTrackEnd() async {
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
    await _playAt(next, manualPause: false);
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
      if (item == null || state.queue.isEmpty) return;

      final Map<String, dynamic> queueSongMeta = {};
      for (final q in state.queue) {
        queueSongMeta[q.path] = {
          'path': q.path,
          'title': q.title,
          'artist': q.artist,
          'album': q.album,
          'durationMs': q.durationMs,
          'coverUrl': q.coverUrl,
          'source': q.source,
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
      debugPrint('播放会话保存失败: $e');
    }
  }

  Future<void> _resumeRestoredOnline(double pos) async {
    final item = state.current;
    if (item == null) return;
    state = state.copyWith(resolving: true, error: null);
    _syncToSystemMediaSession();
    try {
      final url = await _resolveOnlineUrl(item);
      if (url == null) {
        state = state.copyWith(
          isPlaying: false,
          resolving: false,
          error: '无法获取播放链接',
        );
        _syncToSystemMediaSession();
        return;
      }
      await _player.setUrl(url);
      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await _player.setVolume(vol);
      state = state.copyWith(resolving: false);
      await seek(pos);
      await _player.play();
      _syncToSystemMediaSession();
    } catch (e) {
      state = state.copyWith(
        isPlaying: false,
        resolving: false,
        error: '在线播放失败',
      );
      _syncToSystemMediaSession();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>(
  (ref) => PlayerNotifier(ref),
);
