import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as as_pkg;
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../auth/account_api.dart';
import '../core/app_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../effects/sound_effect_provider.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_provider.dart';
import '../remote/remote_library_service.dart';
import '../rust/api.dart';
import '../stats/listen_stats.dart';

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
  /// 在线歌曲信息 JSON（lxResolveUrl 直链解析用）；本地歌曲为空。
  final String? onlineSongJson;
  /// 在线歌曲音质（如 320k / flac）。
  final String? onlineQuality;
  /// 在线歌曲封面 URL（在线歌曲优先展示，本地歌曲为空）。
  final String? coverUrl;
  /// 在线歌曲音源 key（如 kw/kg/tx/wy），用于歌词抓取。
  final String? source;
  /// 在线歌曲信息 JSON（歌词抓取用，LyricSongInfo 格式）。
  final String? onlineInfoJson;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.onlineSongJson,
    this.onlineQuality,
    this.coverUrl,
    this.source,
    this.onlineInfoJson,
  });

  bool get isOnline =>
      path.startsWith('lx://') ||
      path.startsWith('plugin://') ||
      onlineInfoJson != null;
}

class PlaybackState {
  final QueueItem? current;
  final List<QueueItem> queue;
  final int queueIndex;
  final bool isPlaying;
  final double position;
  final double duration;
  final int playMode; // 0 顺序(列表循环) 1 单曲循环 2 随机
  /// 在线歌曲直链解析中（UI 播放键显示加载态）。
  final bool resolving;
  /// 当前播放错误信息（在线歌曲解析/播放失败时展示）。
  final String? error;
  /// USB 独占输出（AAudio exclusive）播放中：EQ/音效 DSP 走 Rust 管线。
  final bool usbExclusive;
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
  Timer? _listenTimer;
  Timer? _exclusiveTimer;
  Timer? _sfxSyncTimer;
  bool _manualPause = false;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  // 在线歌曲连续失败跳过计数（防环）。
  int _skipDepth = 0;

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
    // 播放中每秒累计一次听歌时长，供排行榜上报。
    _listenTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.isPlaying) {
        _ref.read(listenStatsProvider).addDuration(1);
      }
    });
    // 音效变速变调即时生效（just_audio 原生支持 speed/pitch）。
    _ref.listen(soundEffectProvider.select((s) => s.settings), (_, s) {
      _applyEffectSpeedPitch(s);
      _syncExclusiveEffects(s);
    });
    // 音量即时同步到独占管线。
    _ref.listen(volumeProvider, (_, v) {
      if (state.usbExclusive) {
        try {
          setUsbExclusiveVolume(volume: v);
        } catch (_) {}
      }
    });
    // 独占输出开关切换时，正在播放的本地曲目无缝切换管线。
    _ref.listen(
      settingsProvider.select((s) => s.valueOrNull?.usbExclusiveOutput ?? false),
      (prev, next) {
        if (prev != next) _onExclusiveSettingChanged(next);
      },
    );
    // 音量平衡（ReplayGain）设置变化：重算当前曲目增益并即时应用。
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

  /// 独占输出开关切换：当前本地曲目从当前位置无缝换管线。
  Future<void> _onExclusiveSettingChanged(bool enabled) async {
    final item = state.current;
    if (item == null || item.isOnline || _isRemotePath(item.path)) return;
    final pos = state.position;
    final playing = state.isPlaying;
    if (enabled) {
      if (state.usbExclusive) return;
      final ok =
          await _tryStartExclusive(item.path, startAtSecs: pos, isPlaying: playing);
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
      try {
        await _updateRgGain(item.path);
        await _player.setFilePath(item.path);
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
  }

  /// 启动 USB 独占播放（AAudio exclusive + Rust DSP 管线）。失败返回 false。
  Future<bool> _tryStartExclusive(
    String path, {
    required double startAtSecs,
    required bool isPlaying,
  }) async {
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      await startUsbExclusivePlayback(
        path: path,
        deviceId: -1,
        volume: _ref.read(volumeProvider),
        startTimeSecs: startAtSecs,
        isPlaying: isPlaying,
        volumeBalanceGain: _effectiveBalanceGain(),
        equalizerSettingsJson: jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: jsonEncode(sfx.toRustJson()),
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

  /// 停止独占播放并释放设备。
  Future<void> _stopExclusive() async {
    _stopExclusivePolling();
    try {
      await stopUsbExclusivePlayback();
    } catch (_) {}
    if (state.usbExclusive) {
      state = state.copyWith(usbExclusive: false);
    }
  }

  /// 独占播放轮询：同步进度、检测自然播完。
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
    if (!state.usbExclusive) return;
    try {
      final pos = await getUsbExclusivePositionSecs();
      state = state.copyWith(position: pos);
      _syncToSystemMediaSession();
      _persistPositionDebounced();
      final dur = state.duration;
      if (dur > 0 && pos >= dur - 0.3) {
        await _onExclusiveTrackEnd();
      }
    } catch (_) {}
  }

  /// 独占播放自然结束：释放设备后按播放模式衔接。
  Future<void> _onExclusiveTrackEnd() async {
    final ended = state.current;
    if (ended != null) _reportBehavior(ended, 'complete', 0);
    _flushPlayStats();
    await _stopExclusive();
    if (state.playMode == 1) {
      await _playAt(state.queueIndex, manualPause: false);
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      state = state.copyWith(isPlaying: false, position: 0);
      _syncToSystemMediaSession();
      return;
    }
    await _playAt(next, manualPause: false);
  }

  /// EQ/音效设置变化时同步到独占管线（50ms 防抖）。
  void _syncExclusiveEffects(SoundEffectSettings s) {
    if (!state.usbExclusive) return;
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
            onlineSongJson: meta['onlineSongJson'] as String?,
            onlineQuality: meta['onlineQuality'] as String?,
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
        if (_isRemotePath(currentItem.path)) {
          final cached = await _preloadRemote(currentItem);
          await _updateRgGain(cached);
          await seek(pos);
          await _player.setVolume(_effectiveVolume());
        } else {
          await _updateRgGain(currentItem.path);
          final useExclusive =
              _ref.read(settingsProvider).valueOrNull?.usbExclusiveOutput ?? false;
          var restored = false;
          if (useExclusive) {
            restored = await _tryStartExclusive(currentItem.path,
                startAtSecs: pos, isPlaying: false);
          }
          if (!restored) {
            try {
              await _player.setFilePath(currentItem.path);
              await seek(pos);
            } catch (e) {
              AppLogger.instance.log('session', '本地曲目预加载失败: $e');
            }
            await _player.setVolume(_effectiveVolume());
          }
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
      resolving: item.isOnline,
      error: null,
    );
    _syncToSystemMediaSession();
    try {
      if (item.isOnline) {
        await _stopExclusive();
        await _playOnline(item);
      } else if (_isRemotePath(item.path)) {
        await _stopExclusive();
        _rgGain = 1.0;
        await _playRemote(item);
      } else {
        await _updateRgGain(item.path);
        final s = _ref.read(settingsProvider).valueOrNull;
        final isDsd = _isDsdPath(item.path);
        final useExclusive =
            (s?.usbExclusiveOutput ?? false) ||
                (isDsd && (s?.dsdNativePassthrough ?? false));
        var started = false;
        if (useExclusive) {
          await _stopExclusive();
          started = await _tryStartExclusive(item.path,
              startAtSecs: 0, isPlaying: true);
        }
        if (!started) {
          await _stopExclusive();
          try {
            await _player.stop();
          } catch (_) {}
          await _player.setFilePath(item.path);
          await _player.setVolume(_effectiveVolume());
          await _player.play();
        }
      }
      _skipDepth = 0;
      state = state.copyWith(resolving: false, error: null);
      _reportBehavior(item, 'play', 0);
      _recordRecentPlay(item);
      _recordHistory(item);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
    } catch (e) {
      state = state.copyWith(isPlaying: false, resolving: false);
      // 在线歌曲失败自动跳下一首（防环：跳过数不超过队列长度）。
      if (item.isOnline && _skipDepth < state.queue.length) {
        _skipDepth++;
        final next = _pickNextIndex();
        if (next >= 0 && next != index) {
          await _playAt(next, manualPause: true);
          return;
        }
      }
      // 无下一首可跳时透出错误信息。
      if (item.isOnline) {
        state = state.copyWith(
            error: e is PluginEngineException
                ? e.message
                : '播放失败：${e.toString()}');
      }
      _syncToSystemMediaSession();
    }
    if (!item.isOnline) _persistSession();
  }

  /// 在线歌曲：解析直链后播放。失败抛异常由调用方处理。
  Future<void> _playOnline(QueueItem item) async {
    final json = item.onlineSongJson;
    if (json != null && json.isNotEmpty) {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final candidates = _qualityCandidates(item.onlineQuality ??
          _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ??
          '320k');

      // 插件音源：引擎逐档解析；全档失败时带上 LX 源信息走 lx 解析兜底。
      if (songJson.containsKey('pluginId')) {
        for (final quality in candidates) {
          final url = await _resolvePluginUrl(songJson, quality);
          if (_isPlayableUrl(url)) {
            await _startUrl(url!);
            return;
          }
        }
        final musicInfo =
            songJson['musicInfo'] as Map<String, dynamic>? ?? {};
        final fallbackInfo = <String, dynamic>{
          if ((songJson['source'] as String?)?.isNotEmpty ?? false)
            'source': songJson['source'],
          ...musicInfo,
        };
        final fallback = await _tryLxResolve(
            jsonEncode(fallbackInfo), candidates);
        if (fallback != null) {
          await _startUrl(fallback);
          return;
        }
        throw StateError('插件直链解析失败');
      }

      // LX 在线歌曲：lx 解析（已导入插件优先 → 公共 API），多音质降级。
      final url = await _tryLxResolve(json, candidates);
      if (url == null) throw StateError('直链解析失败');
      await _startUrl(url);
      return;
    }
    // onlineInfoJson：走 lxResolveUrl（在线搜索音源）。
    final url = await _resolveOnlineUrl(item);
    if (url == null) throw StateError('无法获取播放链接');
    await _startUrl(url);
  }

  /// 音质阶梯（低 → 高），与设置页可选档位一致（对齐桌面端 rank 排序）。
  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  /// 音质候选链：首选优先，其后向下降级（对齐桌面端 resolveOnlinePlayQuality
  /// 的 'lower' 行为）。首选不在阶梯内时先试首选再全阶梯降级。
  static List<String> _qualityCandidates(String preferred) {
    final desc = _qualityLadder.reversed.toList();
    final i = desc.indexOf(preferred);
    return i < 0 ? [preferred, ...desc] : desc.sublist(i);
  }

  static bool _isPlayableUrl(String? url) =>
      url != null && RegExp(r'^https?://').hasMatch(url);

  static bool _isRemotePath(String path) => path.startsWith('remote://');

  /// 是否为 DSD 容器文件（dsf/dff/dsd），走原生 DoP 直出。
  static bool _isDsdPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.dsf') ||
        lower.endsWith('.dff') ||
        lower.endsWith('.dsd');
  }

  // ==================== 音量平衡（ReplayGain 响度均衡） ====================

  /// 当前曲目 ReplayGain 线性增益（1.0 = 不调整）。切歌/设置变化时重算。
  double _rgGain = 1.0;

  /// 普通管线（just_audio）实际音量 = 用户音量 × ReplayGain 增益。
  double _effectiveVolume() =>
      (_ref.read(volumeProvider) * _effectiveBalanceGain()).clamp(0.0, 4.0);

  /// 当前应生效的音量平衡增益（设置关闭或在线歌曲为 1.0）。
  double _effectiveBalanceGain() {
    final s = _ref.read(settingsProvider).valueOrNull;
    return (s?.volumeBalanceEnabled ?? false) ? _rgGain : 1.0;
  }

  /// 计算并更新当前曲目的 ReplayGain 增益。
  /// 本地文件 / 远程缓存文件读标签；无标签或读取失败重置 1.0。
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

  /// 音量平衡设置变化：重算当前曲目增益并按当前管线即时应用
  /// （独占管线平滑渐变不中断；普通管线直接调整音量）。
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
    if (state.usbExclusive) {
      try {
        await setUsbExclusiveVolumeBalanceGain(gain: _effectiveBalanceGain());
      } catch (_) {}
    } else if (!item.isOnline) {
      try {
        await _player.setVolume(_effectiveVolume());
      } catch (_) {}
    }
  }

  /// WebDAV 远程歌曲：缓存命中则本地播放，否则带 Basic Auth 流式播放。
  Future<void> _playRemote(QueueItem item) async {
    final service = RemoteLibraryService(_ref);
    final plan = await service.playbackSource(item.path);
    try {
      await _player.stop();
    } catch (_) {}
    if (plan.isCached) {
      await _player.setFilePath(plan.cachedPath!);
      await _updateRgGain(plan.cachedPath);
    } else {
      if (!RegExp(r'^https?://').hasMatch(plan.url)) {
        throw StateError('远程源配置缺失或已失效');
      }
      await _player.setUrl(plan.url, headers: plan.headers);
      _rgGain = 1.0;
    }
    await _player.setVolume(_effectiveVolume());
    await _player.play();
  }

  /// 会话恢复时预载远程歌曲，返回缓存文件路径（未缓存返回 null）。
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

  Future<void> _startUrl(String url) async {
    await _player.setUrl(url);
    await _player.setVolume(_ref.read(volumeProvider));
    await _player.play();
  }

  /// 按候选音质依次调用 lxResolveUrl（已导入插件 → 公共 API），
  /// 返回首个合法 http(s) 直链。
  Future<String?> _tryLxResolve(
      String songInfoJson, List<String> candidates) async {
    final dataDir = await _ref.read(appDataDirProvider.future);
    for (final quality in candidates) {
      try {
        final resolved = await lxResolveUrl(
          songInfoJson: songInfoJson,
          quality: quality,
          dataDir: dataDir,
        );
        if (resolved == 'null' || resolved.isEmpty) continue;
        final url =
            (jsonDecode(resolved) as Map<String, dynamic>)['url'] as String?;
        if (_isPlayableUrl(url)) return url;
      } catch (_) {}
    }
    return null;
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
    return _tryLxResolve(infoJson, _qualityCandidates(preferred));
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
    // USB 独占管线：seek(pos, isPlaying) 即暂停/恢复。
    if (state.usbExclusive) {
      if (state.isPlaying) {
        _manualPause = true;
        _flushPlayStats();
        await seekUsbExclusive(timeSecs: state.position, isPlaying: false);
        state = state.copyWith(isPlaying: false);
      } else {
        _manualPause = false;
        _trackStartTime = DateTime.now();
        await seekUsbExclusive(timeSecs: state.position, isPlaying: true);
        state = state.copyWith(isPlaying: true);
      }
      _syncToSystemMediaSession();
      _persistSession();
      return;
    }
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
    if (state.usbExclusive) {
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
      debugPrint('播放会话保存失败: $e');
    }
  }

  Future<void> _resumeRestoredOnline(double pos) async {
    final item = state.current;
    if (item == null) return;
    await _stopExclusive();
    state = state.copyWith(resolving: true, error: null);
    _syncToSystemMediaSession();
    try {
      if (item.onlineSongJson != null && item.onlineSongJson!.isNotEmpty) {
        await _playOnline(item);
      } else {
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
      }
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
    _listenTimer?.cancel();
    _exclusiveTimer?.cancel();
    _sfxSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    try {
      stopUsbExclusivePlayback();
    } catch (_) {}
    _player.dispose();
    super.dispose();
  }
}

/// 音量（与设置联动）。
final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ?? 1.0;
});

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>(
  (ref) => PlayerNotifier(ref),
);
