import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../rust/api.dart';

/// 播放中的单曲信息（小而美：仅保留 UI 需要的最小字段）。
class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
  });
}

class PlaybackState {
  final QueueItem? current;
  final List<QueueItem> queue;
  final int queueIndex;
  final bool isPlaying;
  final double position;
  final double duration;
  final int playMode; // 0 顺序(列表循环) 1 单曲循环 2 随机
  const PlaybackState({
    this.current,
    this.queue = const [],
    this.queueIndex = -1,
    this.isPlaying = false,
    this.position = 0,
    this.duration = 0,
    this.playMode = 0,
  });

  PlaybackState copyWith({
    QueueItem? current,
    List<QueueItem>? queue,
    int? queueIndex,
    bool? isPlaying,
    double? position,
    double? duration,
    int? playMode,
  }) {
    return PlaybackState(
      current: current ?? this.current,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playMode: playMode ?? this.playMode,
    );
  }
}

class PlayerNotifier extends StateNotifier<PlaybackState> {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
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

  // 随机模式历史/未来栈（与桌面端一致）。
  final List<String> _shuffleHistory = [];
  final List<String> _shuffleFuture = [];

  Future<void> _init() async {
    _posSub = _player.positionStream.listen((p) {
      state = state.copyWith(position: p.inMilliseconds / 1000.0);
      _persistPositionDebounced();
    });
    _durSub = _player.durationStream.listen((d) {
      state = state.copyWith(
          duration: (d ?? Duration.zero).inMilliseconds / 1000.0);
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      final playing = ps.playing;
      if (playing != state.isPlaying) {
        state = state.copyWith(isPlaying: playing);
        if (!playing && !_manualPause) {
          _onTrackEnd();
        }
      }
    });
    await _restoreSession();
  }

  /// 启动时从 SQLite 恢复上次播放会话。
  Future<void> _restoreSession() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final jsonStr = await loadPlaybackSession(dbPath: dbPath);
      final j = jsonDecode(jsonStr) as Map<String, dynamic>;
      final paths = (j['playQueuePaths'] as List? ?? const []).cast<String>();
      if (paths.isEmpty) return;
      final items = paths
          .map((p) => QueueItem(
                path: p,
                title: _titleFromPath(p),
                artist: '',
                album: '',
              ))
          .toList();
      final currentPath = j['currentSongPath'] as String?;
      final startIndex = currentPath == null
          ? 0
          : paths.indexOf(currentPath);
      final idx = startIndex < 0 ? 0 : startIndex;
      final mode = (j['playMode'] as num?)?.toInt() ?? 0;
      final pos = (j['currentPositionSecs'] as num?)?.toDouble() ?? 0;
      final wasPlaying = j['isPlaying'] as bool? ?? false;

      state = state.copyWith(
        queue: items,
        queueIndex: idx,
        current: items[idx],
        playMode: mode,
        position: pos,
        isPlaying: false,
      );
      await _ref.read(settingsProvider.notifier).setPlayMode(mode);
      try {
        await _player.setFilePath(items[idx].path);
        await seek(pos);
        if (wasPlaying) {
          _manualPause = false;
          await _player.play();
        }
      } catch (_) {
        // 文件不可用，仅恢复队列不播放。
      }
    } catch (_) {
      // 无有效会话，忽略。
    }
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 防抖持久化进度（每 5 秒一次），供重启恢复。
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
      } catch (_) {}
    });
  }

  /// 播放一组歌曲（替换队列）。
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
    _manualPause = manualPause;
    final item = state.queue[index];
    state = state.copyWith(
      queueIndex: index,
      current: item,
      isPlaying: false,
      position: 0,
      duration: item.durationMs / 1000.0,
    );
    try {
      await _player.setFilePath(item.path);
      await _player.setVolume(_ref.read(volumeProvider));
      await _player.play();
    } catch (_) {
      state = state.copyWith(isPlaying: false);
    }
    _persistSession();
  }

  Future<void> toggle() async {
    if (state.current == null) return;
    if (state.isPlaying) {
      _manualPause = true;
      await _player.pause();
    } else {
      _manualPause = false;
      await _player.play();
    }
  }

  Future<void> seek(double secs) async {
    await _player.seek(Duration(milliseconds: (secs * 1000).round()));
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
    if (state.playMode == 1) {
      // 单曲循环：重播当前曲。
      await seek(0);
      await _player.play();
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
    return (state.queueIndex + 1) % n; // 顺序：列表循环环绕
  }

  /// 随机模式下一首：优先 future 栈，否则随机不重复当前曲并记录历史。
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
    final dbPath = await _ref.read(dbPathProvider.future);
    final settings = _ref.read(settingsProvider).valueOrNull;
    final item = state.current;
    if (item == null) return;
    final sessionJson = jsonEncode({
      'currentSongPath': item.path,
      'playQueuePaths': state.queue.map((q) => q.path).toList(),
      'sourceSongPaths': const <String>[],
      'playMode': state.playMode,
      'volume': settings?.volume ?? 1.0,
      'currentPositionSecs': state.position,
      'isPlaying': state.isPlaying,
      'sessionQualityOverride': null,
      'queueSongMeta': const <String, dynamic>{},
    });
    await savePlaybackSession(dbPath: dbPath, sessionJson: sessionJson);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

/// 音量（与设置联动）。
final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ?? 1.0;
});

final playerProvider =
    StateNotifierProvider<PlayerNotifier, PlaybackState>((ref) {
  return PlayerNotifier(ref);
});