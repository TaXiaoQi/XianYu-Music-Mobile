import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../auth/account_api.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../effects/sound_effect_provider.dart';
import '../plugin/plugin_provider.dart';
import '../rust/api.dart';
import '../stats/listen_stats.dart';

/// 播放中的单曲信息（小而美：仅保留 UI 需要的最小字段）。
class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  /// 在线歌曲信息 JSON（lxResolveUrl 直链解析用）；本地歌曲为空。
  final String? onlineSongJson;
  /// 在线歌曲音质（如 320k / flac）。
  final String? onlineQuality;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.onlineSongJson,
    this.onlineQuality,
  });

  bool get isOnline =>
      path.startsWith('lx://') || path.startsWith('plugin://');
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
  Timer? _listenTimer;
  bool _manualPause = false;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  // 在线歌曲连续失败跳过计数（防环）。
  int _skipDepth = 0;

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
    // 播放中每秒累计一次听歌时长，供排行榜上报。
    _listenTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.isPlaying) {
        _ref.read(listenStatsProvider).addDuration(1);
      }
    });
    // 音效变速变调即时生效（just_audio 原生支持 speed/pitch）。
    _ref.listen(soundEffectProvider.select((s) => s.settings), (_, s) {
      _applyEffectSpeedPitch(s);
    });
    await _restoreSession();
  }

  /// 将音效的倍速/变调应用到 just_audio。
  Future<void> _applyEffectSpeedPitch(SoundEffectSettings s) async {
    try {
      final rate = s.playbackRate.clamp(50.0, 200.0) / 100.0;
      await _player.setSpeed(rate);
      if (s.preservesPitch) {
        // 保持音调：仅变速，音调不变。
        await _player.setPitch(1.0);
      } else {
        final pitch = s.pitchShift.clamp(50.0, 200.0) / 100.0;
        await _player.setPitch(pitch);
      }
    } catch (_) {
      // 平台不支持 setPitch 时静默忽略。
    }
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

  /// 防抖持久化进度（每 5 秒一次），供重启恢复。在线会话不持久化。
  void _persistPositionDebounced() {
    final current = state.current;
    if (current == null || current.isOnline) return;
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
      if (item.isOnline) {
        await _playOnline(item);
      } else {
        await _player.setFilePath(item.path);
        await _player.setVolume(_ref.read(volumeProvider));
        await _player.play();
      }
      _skipDepth = 0;
      _reportBehavior(item, 'play', 0);
      _recordRecentPlay(item);
    } catch (_) {
      state = state.copyWith(isPlaying: false);
      // 在线歌曲失败自动跳下一首（防环：跳过数不超过队列长度）。
      if (item.isOnline && _skipDepth < state.queue.length) {
        _skipDepth++;
        final next = _pickNextIndex();
        if (next >= 0 && next != index) {
          await _playAt(next, manualPause: true);
          return;
        }
      }
    }
    if (!item.isOnline) _persistSession();
  }

  /// 在线歌曲：解析直链后播放。失败抛异常由调用方处理。
  Future<void> _playOnline(QueueItem item) async {
    final json = item.onlineSongJson;
    if (json == null || json.isEmpty) {
      throw StateError('在线歌曲信息缺失');
    }
    final songJson = jsonDecode(json) as Map<String, dynamic>;
    // 插件音源：走插件引擎解析直链
    if (songJson.containsKey('pluginId')) {
      final url = await _resolvePluginUrl(songJson, item.onlineQuality ?? '320k');
      if (url == null || url.isEmpty) {
        throw StateError('插件直链解析失败');
      }
      await _player.setUrl(url);
      await _player.setVolume(_ref.read(volumeProvider));
      await _player.play();
      return;
    }
    final resolved = await lxResolveUrl(
      songInfoJson: json,
      quality: item.onlineQuality ?? '320k',
    );
    if (resolved == 'null' || resolved.isEmpty) {
      throw StateError('直链解析失败');
    }
    final url = jsonDecode(resolved)['url'] as String?;
    if (url == null || url.isEmpty) {
      throw StateError('直链为空');
    }
    await _player.setUrl(url);
    await _player.setVolume(_ref.read(volumeProvider));
    await _player.play();
  }

  /// 通过插件引擎解析播放直链。
  Future<String?> _resolvePluginUrl(
      Map<String, dynamic> songJson, String quality) async {
    try {
      final pluginId = songJson['pluginId'] as String?;
      final sourceKey = songJson['source'] as String? ?? '';
      final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
      final format = songJson['format'] as String? ?? 'lx';
      if (pluginId == null || pluginId.isEmpty) return null;

      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final source = sources.where((s) => s.id == pluginId).toList();
      if (source.isEmpty) return null;

      if (format == 'musicfree') {
        // MusicFree 插件：调用 getMusicUrl(musicItem, quality)
        final response = await engine.call(
          source.first.id,
          'getMusicUrl',
          [musicInfo, quality],
        );
        if (response is String && response.isNotEmpty) return response;
        if (response is Map) {
          final url = (response['url'] ?? response['link']) as String?;
          if (url != null && url.isNotEmpty) return url;
        }
        return null;
      }

      final result =
          await engine.getMusicUrl(source.first, sourceKey, musicInfo, quality);
      return result?['url'];
    } catch (_) {
      return null;
    }
  }

  /// 播放行为上报（fire-and-forget，失败静默）。
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

  /// 记录最近播放（写入 SQLite 播放历史，fire-and-forget）。
  void _recordRecentPlay(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
      } catch (_) {}
    });
  }

  /// 从队列移除指定歌曲（当前播放曲移除后自动切下一首）。
  Future<void> removeFromQueue(int index) async {
    final queue = [...state.queue];
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == state.queueIndex;
    queue.removeAt(index);
    if (queue.isEmpty) {
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
      await _playAt(newIndex, manualPause: true);
    } else {
      state = state.copyWith(queue: queue, queueIndex: newIndex);
    }
  }

  /// 将队列中 [oldIndex] 的歌曲移动到 [newIndex]。
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

  /// 播放队列中指定歌曲。
  Future<void> playQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _playAt(index, manualPause: true);
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
    final ended = state.current;
    if (ended != null) _reportBehavior(ended, 'complete', 0);
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
    final item = state.current;
    if (item == null || item.isOnline) return;
    final dbPath = await _ref.read(dbPathProvider.future);
    final settings = _ref.read(settingsProvider).valueOrNull;
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
    _listenTimer?.cancel();
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