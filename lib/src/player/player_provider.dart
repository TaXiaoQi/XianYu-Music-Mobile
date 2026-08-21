import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/app_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../rust/api.dart';

/// 播放中的单曲信息（小而美：仅保留 UI 需要的最小字段）。
///
/// 同时承载本地与在线两类曲目：
/// - 本地：`path` 为文件路径，[isOnline] 为 false
/// - 在线：`path` 为 `lx://{source}/{songmid}` 形式的标识，
///   [onlineInfoJson] 保存解析直链所需的原始信息，[coverUrl] 为网络封面
class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;

  /// 在线曲目的封面 URL；本地曲目为 null。
  final String? coverUrl;

  /// 在线音源标识（kw/kg/tx/wy/mg）；本地曲目为 null。
  final String? source;

  /// 解析直链所需的 `LxUrlSongInfo` JSON；本地曲目为 null。
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

  /// 是否为在线曲目（需要解析直链后播放）。
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

  /// 在线曲目正在解析直链（UI 可展示加载态）。
  final bool resolving;

  /// 最近一次播放失败的提示；成功播放时清空。
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
    // 传入 null 需显式清空，故用哨兵区分「未传」与「置空」。
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

/// `copyWith` 中区分「参数未传」与「显式置为 null」的哨兵值。
const Object _noChange = Object();

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
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

  /// 恢复的在线曲目尚未加载直链：恢复时只展示信息，
  /// 用户点播放时再解析直链并跳回恢复位置。
  double? _restoredOnlinePending;

  /// 本首歌曲开始听歌的时间戳，用于计算有效听歌时长
  DateTime? _trackStartTime;

  // 随机模式历史/未来栈（与桌面端一致）。
  final List<String> _shuffleHistory = [];
  final List<String> _shuffleFuture = [];

  /// 应用切后台/被杀前立即落盘播放会话，避免丢失最后 5 秒内的状态
  /// （平时依赖 5 秒防抖保存，退出场景需要即时保存）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _persistSession();
    }
  }

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

  /// 启动时恢复上次关闭时的播放会话（SQLite）。
  Future<void> _restoreSession() async {
    try {
      String jsonStr = '';
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        jsonStr = await loadPlaybackSession(dbPath: dbPath);
      } catch (e) {
        AppLogger.instance.log('session', '读取播放会话失败: $e');
      }

      AppLogger.instance.log('session',
          '读取到会话数据长度=${jsonStr.length} 内容=${jsonStr.length > 300 ? jsonStr.substring(0, 300) : jsonStr}');
      if (jsonStr.isEmpty || jsonStr == 'null') {
        AppLogger.instance.log('session', '无持久化会话，跳过恢复');
        return;
      }

      final j = jsonDecode(jsonStr) as Map<String, dynamic>;
      final paths = ((j['play_queue_paths'] ?? j['playQueuePaths']) as List? ?? const [])
          .cast<String>();
      if (paths.isEmpty) {
        AppLogger.instance.log('session', '会话队列为空，跳过恢复');
        return;
      }

      final metaMap = (j['queue_song_meta'] ?? j['queueSongMeta']) as Map<String, dynamic>?;
      final items = <QueueItem>[];

      for (final p in paths) {
        Map<String, dynamic>? m;
        if (metaMap != null && metaMap.containsKey(p)) {
          m = metaMap[p] as Map<String, dynamic>?;
        }

        if (m != null) {
          items.add(QueueItem(
            path: m['path'] as String? ?? p,
            title: m['title'] as String? ?? _titleFromPath(p),
            artist: m['artist'] as String? ?? '',
            album: m['album'] as String? ?? '',
            durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
            coverUrl: m['coverUrl'] as String?,
            source: m['source'] as String?,
            onlineInfoJson: m['onlineInfoJson'] as String?,
          ));
        } else {
          items.add(QueueItem(
            path: p,
            title: _titleFromPath(p),
            artist: '',
            album: '',
          ));
        }
      }

      final currentPath = (j['current_song_path'] ?? j['currentSongPath']) as String?;
      final startIndex = currentPath == null ? 0 : paths.indexOf(currentPath);
      final idx = startIndex < 0 ? 0 : startIndex;
      final mode = (j['play_mode'] ?? j['playMode'] as num?)?.toInt() ?? 0;
      final pos = (j['current_position_secs'] ?? j['currentPositionSecs'] as num?)?.toDouble() ?? 0;

      final currentItem = items[idx];

      state = state.copyWith(
        queue: items,
        queueIndex: idx,
        current: currentItem,
        playMode: mode,
        position: pos,
        // 恢复时长先用元数据，本地曲加载后 durationStream 会刷新为精确值。
        duration: currentItem.durationMs > 0
            ? currentItem.durationMs / 1000.0
            : 0,
        isPlaying: false,
      );
      AppLogger.instance.log('session',
          '恢复成功: 队列${items.length}首 当前「${currentItem.title}」位置${pos.toStringAsFixed(1)}s 在线=${currentItem.isOnline}');

      // settings 尚未加载完（AsyncNotifier loading）时跳过：
      // setPlayMode 会以默认值整体覆盖保存，重置用户全部设置。
      final settingsReady = _ref.read(settingsProvider).hasValue;
      if (settingsReady) {
        await _ref.read(settingsProvider.notifier).setPlayMode(mode);
      }
      await _player.setVolume(_ref.read(volumeProvider));

      if (!currentItem.isOnline) {
        try {
          await _player.setFilePath(currentItem.path);
          await seek(pos);
        } catch (e) {
          AppLogger.instance.log('session', '本地曲目预加载失败: $e');
        }
      } else {
        // 在线曲目：恢复阶段仅展示信息（封面/标题/进度），
        // 点播放时再解析直链，避免启动即发起网络请求。
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
        await _persistSession();
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

    // 切歌时先结清上一首歌曲的听歌时长
    _flushPlayStats();

    _manualPause = manualPause;
    // 切歌后旧的「待恢复」状态作废。
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
    try {
      if (item.isOnline) {
        final url = await _resolveOnlineUrl(item);
        // 解析期间用户可能已切歌，丢弃过期结果。
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
      await _player.setVolume(_ref.read(volumeProvider));
      await _player.play();

      // 记录添加到播放历史 + 标记本次听歌开始时间
      _recordHistory(item);
      _trackStartTime = DateTime.now();
    } catch (e) {
      state = state.copyWith(
        isPlaying: false,
        resolving: false,
        error: item.isOnline ? '在线播放失败' : '文件无法播放',
      );
    }
    _persistSession();
  }

  /// 结清当前歌曲的有效听歌时长
  void _flushPlayStats() {
    final item = state.current;
    if (item != null && _trackStartTime != null) {
      final listenedSecs =
          DateTime.now().difference(_trackStartTime!).inMilliseconds / 1000.0;
      _recordPlayStats(item, listenedSecs);
      _trackStartTime = null;
    }
  }

  /// 记录添加到播放历史
  void _recordHistory(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
      } catch (_) {}
    });
  }

  /// 记录本次播放时长与播放次数
  void _recordPlayStats(QueueItem item, double listenedSecs) {
    if (listenedSecs < 3) return; // 播放小于 3 秒视作试听跳过，不计入有效听歌数据
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

  /// 解析在线曲目的播放直链，按设置的默认音质并在失败时降级。
  Future<String?> _resolveOnlineUrl(QueueItem item) async {
    final infoJson = item.onlineInfoJson;
    if (infoJson == null) return null;
    final preferred =
        _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    // 传入数据目录，让 Rust 侧优先用已导入的音源插件解析。
    final dataDir = await _ref.read(appDataDirProvider.future);
    // 首选音质失败时逐级降级，提升可播率。
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
      } catch (_) {
        // 尝试下一档音质
      }
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
      // 恢复的在线曲目尚未加载直链：首次播放时解析并跳回恢复位置。
      final pendingPos = _restoredOnlinePending;
      if (pendingPos != null) {
        _restoredOnlinePending = null;
        await _resumeRestoredOnline(pendingPos);
        _persistSession();
        return;
      }
      await _player.play();
    }
    _persistSession();
  }

  Future<void> seek(double secs) async {
    // 恢复的在线曲目未加载直链前，播放器无源不能 seek：
    // 记录目标位置，首次播放时跳到该处。
    if (_restoredOnlinePending != null) {
      _restoredOnlinePending = secs;
      state = state.copyWith(position: secs);
      return;
    }
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
    _flushPlayStats();
    if (state.playMode == 1) {
      // 单曲循环：重播当前曲。
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

      // Rust 侧 PlaybackSessionData 标注 #[serde(rename_all = "camelCase")]，
      // 字段名必须是 camelCase：此前误用 snake_case 导致 Rust 反序列化
      // 「missing field」失败，会话从未保存成功（播放记忆失效的根因）。
      final sessionJson = jsonEncode({
        'currentSongPath': item.path,
        'playQueuePaths': state.queue.map((q) => q.path).toList(),
        'sourceSongPaths': state.queue.map((q) => q.path).toList(),
        'playMode': state.playMode,
        'volume': (settings?.volume ?? 1.0) * 100.0, // Rust volume 范围 0-100
        'currentPositionSecs': state.position,
        'isPlaying': state.isPlaying,
        'sessionQualityOverride': null,
        'queueSongMeta': queueSongMeta,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await savePlaybackSession(dbPath: dbPath, sessionJson: sessionJson);
    } catch (e) {
      // 保存失败不再静默吞掉：这是播放记忆的唯一持久化通道，
      // 失败需要能从日志发现（诊断日志 + debugPrint）。
      AppLogger.instance.log('session', '播放会话保存失败: $e');
      debugPrint('播放会话保存失败: $e');
    }
  }

  /// 恢复的在线曲目点播放时：解析直链 → 加载 → 跳回恢复位置。
  Future<void> _resumeRestoredOnline(double pos) async {
    final item = state.current;
    if (item == null) return;
    state = state.copyWith(resolving: true, error: null);
    try {
      final url = await _resolveOnlineUrl(item);
      if (url == null) {
        state = state.copyWith(
          isPlaying: false,
          resolving: false,
          error: '无法获取播放链接',
        );
        return;
      }
      await _player.setUrl(url);
      await _player.setVolume(_ref.read(volumeProvider));
      state = state.copyWith(resolving: false);
      await seek(pos);
      await _player.play();
    } catch (e) {
      state = state.copyWith(
        isPlaying: false,
        resolving: false,
        error: '在线播放失败',
      );
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

/// 音量（与设置联动）。
final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ?? 1.0;
});

final playerProvider =
    StateNotifierProvider<PlayerNotifier, PlaybackState>((ref) {
  return PlayerNotifier(ref);
});