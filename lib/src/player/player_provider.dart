import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as as_pkg;
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../auth/account_api.dart';
import '../core/app_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../effects/sound_effect_provider.dart';
import '../favorites/favorites_provider.dart';
import '../home/home_providers.dart';
import '../library/saf_channel.dart';
import '../online/online_search_provider.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_provider.dart';
import '../recent/recent_provider.dart';
import '../remote/remote_library_service.dart';
import '../rust/api.dart';
import 'media_url.dart';
import 'online_quality_probe.dart';

/// 全局系统控制中心 AudioHandler 句柄
XianYuAudioHandler? audioHandler;

/// 最近创建的播放控制器（playerProvider 为全局单例）。
///
/// AudioService.init 是后台异步初始化，PlayerNotifier 构造时 audioHandler
/// 可能仍为 null 导致 bindNotifier 落空（控制中心按键全部失效）；
/// 此处留存全局引用，init 完成后在 main 中补绑。
PlayerNotifier? activePlayerNotifier;

/// 系统控制中心（MediaSession / Notification）与 Flutter 播放状态的双向桥梁
class XianYuAudioHandler extends as_pkg.BaseAudioHandler with as_pkg.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  /// 广播更新当前系统的 MediaItem（系统控制中心卡片：标题/歌手/专辑/封面/时长）
  void syncMediaItem(QueueItem item, double durationSecs) {
    // 封面：在线歌曲用网络 URL；本地歌曲用缩略图文件路径（file:// URI）。
    Uri? artUri;
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      artUri = Uri.tryParse(url);
    } else {
      final local = item.coverPath;
      if (local != null && local.isNotEmpty) {
        artUri = Uri.file(local);
      }
    }
    mediaItem.add(
      as_pkg.MediaItem(
        id: item.path,
        album: item.album.isEmpty ? '弦予音乐' : item.album,
        title: item.title,
        artist: item.artist.isEmpty ? '未知歌手' : item.artist,
        duration: Duration(milliseconds: (durationSecs * 1000).round()),
        artUri: artUri,
      ),
    );
  }

  /// 广播更新系统的 PlaybackState（播放状态/进度/控制动作/循环模式）
  void syncPlaybackState({
    required bool isPlaying,
    required double positionSecs,
    required double durationSecs,
    required bool isFavorite,
    required int playMode,
  }) {
    playbackState.add(
      as_pkg.PlaybackState(
        controls: [
          as_pkg.MediaControl.skipToPrevious,
          if (isPlaying) as_pkg.MediaControl.pause else as_pkg.MediaControl.play,
          as_pkg.MediaControl.skipToNext,
          as_pkg.MediaControl(
            androidIcon: _playModeIcon(playMode),
            label: _playModeLabel(playMode),
            action: as_pkg.MediaAction.custom,
            customAction: const as_pkg.CustomMediaAction(name: 'cyclePlayMode'),
          ),
          as_pkg.MediaControl(
            // 0.18.x 的 androidIcon 必须带 "drawable/" 前缀：
            // Android 端 getResourceId 按 "/" split 后取 parts[1]，
            // 缺前缀会抛 ArrayIndexOutOfBoundsException 导致整个媒体卡片不显示。
            androidIcon: isFavorite
                ? 'drawable/ic_notif_favorite_filled'
                : 'drawable/ic_notif_favorite',
            label: isFavorite ? '取消收藏' : '收藏',
            action: as_pkg.MediaAction.custom,
            customAction: const as_pkg.CustomMediaAction(name: 'toggleFavorite'),
          ),
        ],
        systemActions: const {
          as_pkg.MediaAction.seek,
          as_pkg.MediaAction.seekForward,
          as_pkg.MediaAction.seekBackward,
        },
        // 紧凑视图（锁屏/折叠态）仍只显示 上一首/播放/下一首。
        // 注意：华为 EMUI 上 setShowActionsInCompactView 引用非 0 起始索引
        // 会抛 IndexOutOfBoundsException: Index: 3, Size: 3，故把三个基础
        // 控制排到 [0,1,2] 并让紧凑视图引用 0 起始索引。
        androidCompactActionIndices: const [0, 1, 2],
        processingState: as_pkg.AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: Duration(milliseconds: (positionSecs * 1000).round()),
        bufferedPosition: Duration(milliseconds: (positionSecs * 1000).round()),
        speed: 1.0,
      ),
    );
  }

  /// 播放顺序(0 列表循环 / 1 单曲循环 / 2 随机)对应的控制中心图标。
  /// 注意 androidIcon 必须带 "drawable/" 前缀（见上）。
  String _playModeIcon(int mode) => switch (mode) {
        1 => 'drawable/ic_notif_mode_repeat_one',
        2 => 'drawable/ic_notif_mode_shuffle',
        _ => 'drawable/ic_notif_mode_repeat',
      };

  /// 播放顺序对应的控制中心无障碍标签。
  String _playModeLabel(int mode) => switch (mode) {
        1 => '单曲循环',
        2 => '随机播放',
        _ => '列表循环',
      };

  /// 控制中心自定义按键（收藏 / 播放顺序）。
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

  /// 用户划掉通知/停止服务：只暂停，不得在暂停态误触发播放。
  @override
  Future<void> stop() => _notifier?.pauseFromSystem() ?? Future.value();
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
  /// 本地歌曲封面缩略图文件路径（通知栏/锁屏封面，file:// URI 用）。
  final String? coverPath;
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
    this.coverPath,
    this.source,
    this.onlineInfoJson,
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
      );

  /// 复制并更新在线音质（音质切换后写回队列项，切歌/重播沿用该档）。
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
      );
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
  /// 当前在线歌曲实际播放音质（降级校验后）。
  final String? currentQuality;
  /// 当前在线歌曲已探测到的真实可用档位（高 → 低，不含虚高档）。
  final List<String> availableQualities;
  /// 当前在线歌曲是否仍在后台探测可用档位（音质菜单可显示加载态）。
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
      currentQuality: currentQuality ?? this.currentQuality,
      availableQualities: availableQualities ?? this.availableQualities,
      qualityMenuProbing:
          qualityMenuProbing ?? this.qualityMenuProbing,
    );
  }
}

const Object _noChange = Object();

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
    // AudioService.init 后台异步完成：先全局注册，init 完成后由 main 补绑。
    activePlayerNotifier = this;
    audioHandler?.bindNotifier(this);
    _init();
  }

  final Ref _ref;
  final AudioPlayer _player = AudioPlayer();
  /// 当前在线歌曲的共享探针 key，切歌时用于失效上一首的探测。
  String? _activeProbeKey;
  final Random _rand = Random();
  StreamSubscription<Duration?>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<dynamic>? _stateSub;
  StreamSubscription<ProcessingState>? _procSub;
  Timer? _listenTimer;
  Timer? _exclusiveTimer;
  Timer? _sfxSyncTimer;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  // 在线歌曲连续失败跳过计数（防环）。
  int _skipDepth = 0;
  // 自动换源上下文：同一首歌的失败音源集；歌曲切换时被 _switchCtxKey 重建。
  final Set<String> _failedSources = {};
  String? _switchCtxKey;
  // 分享链接深链触发的播放：失败行为按「分享链接播放失败行为」设置决定（replace 才允许插件换源重播）。
  bool _shareLinkPlayback = false;

  double? _restoredOnlinePending;
  // SAF 本地歌曲恢复会话时的待恢复进度：点击播放时再物化文件并从该位置续播。
  double? _restoredLocalPending;
  DateTime? _trackStartTime;
  /// 本次播放会话尚未写入数据库的累计听歌声长（秒），对标桌面端 flushPlaySession。
  double _accumulatedTime = 0;
  /// 当前这一首歌的首播是否已计入播放次数（后续增量刷写只加时长不加次数）。
  bool _currentPlayCountRecorded = false;
  /// 通知栏封面路径缓存（歌曲 path → 缩略图路径；空串 = 无封面）。
  final Map<String, String> _notifCoverCache = {};
  /// 进程内是否已请求过通知权限（Android 13+ 媒体通知必需）。
  bool _notifPermissionAsked = false;

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
      }
    });
    // 自然播完的权威信号：just_audio 在源播完时把 processingState 置为
    // completed（playing 字段不保证翻转），据此自动衔接到队列下一首。
    // 手动暂停是 paused 而非 completed，不会误触发，故无需 _manualPause 门控。
    _procSub = _player.processingStateStream.listen((ps) {
      if (ps == ProcessingState.completed) {
        _onTrackEnd();
      }
    });
    // 播放中每 15 秒把当前会话的听歌时长增量刷写进数据库（首页统计/排行榜共用），
    // 避免长时间连续播放时统计迟迟不落库。
    _listenTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (state.isPlaying) {
        _flushPlayStats();
      }
    });
    // 音效变速变调即时生效（just_audio 原生支持 speed/pitch）。
    _ref.listen(soundEffectProvider.select((s) => s.settings), (_, s) {
      _applyEffectSpeedPitch(s);
      _syncExclusiveEffects(s);
    });
    // 收藏在应用内变化时刷新通知栏「收藏」图标。
    _ref.listen(favoritesProvider, (_, _) {
      _syncToSystemMediaSession();
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
    // SAF content:// 先物化为本地真实文件，独占管线无法消费树文档 URI。
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
  }

  /// 启动 USB 独占播放（AAudio exclusive + Rust DSP 管线）。失败返回 false。
  Future<bool> _tryStartExclusive(
    String path, {
    required double startAtSecs,
    required bool isPlaying,
  }) async {
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      final settings = _ref.read(settingsProvider).valueOrNull;
      final bitPerfect = settings?.bitPerfectOutput ?? false;
      final dsd = settings?.dsdNativePassthrough ?? false;
      await startUsbExclusivePlayback(
        path: path,
        deviceId: settings?.usbExclusiveDeviceId ?? -1,
        volume: _ref.read(volumeProvider),
        startTimeSecs: startAtSecs,
        isPlaying: isPlaying,
        volumeBalanceGain: bitPerfect ? 1.0 : _effectiveBalanceGain(),
        // Bit-perfect 直出时 EQ/音效被旁通，避免传空让 DAC 保持原生。
        equalizerSettingsJson: bitPerfect ? '' : jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: bitPerfect ? '' : jsonEncode(sfx.toRustJson()),
        bitPerfect: bitPerfect,
        dsdNativePassthrough: dsd,
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
      // 本地歌曲未携带封面字段时，用已解析的通知栏封面缓存兜底。
      var item = cur;
      if (!cur.isOnline &&
          (cur.coverUrl == null || cur.coverUrl!.isEmpty) &&
          (cur.coverPath == null || cur.coverPath!.isEmpty)) {
        final cached = _notifCoverCache[cur.path];
        if (cached != null && cached.isNotEmpty) {
          item = cur.copyWith(coverPath: cached);
        }
      }
      audioHandler?.syncMediaItem(item, state.duration);
      audioHandler?.syncPlaybackState(
        isPlaying: state.isPlaying,
        positionSecs: state.position,
        durationSecs: state.duration,
        isFavorite: _ref.read(favoritesProvider).contains(cur.path),
        playMode: state.playMode,
      );
    }
  }

  /// 通知栏/锁屏封面兜底：本地歌曲播放时查曲库缩略图（含 SAF 自愈），
  /// 结果缓存（空串 = 无封面，同样缓存防重复查询）。
  Future<void> _resolveNotificationCover(QueueItem item) async {
    if (item.isOnline) return;
    if (item.coverUrl?.isNotEmpty == true) return;
    if (item.coverPath?.isNotEmpty == true) return;
    if (_notifCoverCache.containsKey(item.path)) return;
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
        // SAF 歌曲缓存未命中时经 fd 自愈提取一次（顺带回写数据库）。
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
      }
    } catch (_) {}
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
            coverPath: meta['coverPath'] as String?,
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
      // 会话恢复时本地曲目封面同样走懒提取补封面（否则重启后媒体会话无封面）。
      unawaited(_resolveNotificationCover(currentItem));

      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await _player.setVolume(vol);

      if (!currentItem.isOnline) {
        if (_isRemotePath(currentItem.path)) {
          final cached = await _preloadRemote(currentItem);
          await _updateRgGain(cached);
          await seek(pos);
          await _player.setVolume(_effectiveVolume());
        } else if (SafChannel.isSafPath(currentItem.path)) {
          // SAF 歌曲不做启动预载（大文件复制会拖慢启动，且 setFilePath 无法
          // 消费 content://）；记录待恢复进度，点击播放时再物化并续播。
          _restoredLocalPending = pos;
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

  /// 进程内只请求一次通知权限（用户拒绝后下次冷启动播放时再问，标准做法）。
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
    debugPrint('[play] playQueue ${items.length} 首 startIndex=$startIndex');
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
      // 手势调用点不 await 异步错误，此处兜底捕获避免整链静默中断。
      debugPrint('[play] playQueue 异常: $e\n$st');
      state = state.copyWith(isPlaying: false, resolving: false);
    }
  }

  Future<void> _playAt(int index, {double startAtSecs = 0}) async {
    if (index < 0 || index >= state.queue.length) return;

    debugPrint('[play] _playAt index=$index path=${state.queue[index].path}');
    // 首次播放时申请通知权限（Android 13+ 未授权则媒体通知被系统静默拦截）。
    unawaited(_ensureNotificationPermission());
    _flushPlayStats();
    // 新曲目首播计数重置：后续增量刷写只加时长、不再累加播放次数。
    _currentPlayCountRecorded = false;
    _accumulatedTime = 0;

    _restoredOnlinePending = null;
    _restoredLocalPending = null;
    final item = state.queue[index];
    // 切到不同歌曲时失效上一首的共享探针，避免残留探测与串歌缓存。
    final prev = state.current;
    if (_activeProbeKey != null && (prev == null || prev.path != item.path)) {
      onlineQualityProbeRegistry.invalidate(_activeProbeKey!);
      _activeProbeKey = null;
    }
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
        // SAF content:// 路径先物化为本地真实文件，独占/音量平衡/普通播放统一
        // 使用真实路径（Rust/ExoPlayer 均无法直接消费树文档 URI）。
        var target = item.path;
        if (SafChannel.isSafPath(target)) {
          final tmp = await getTemporaryDirectory();
          target = await SafChannel.ensureLocalPlaybackCopy(
              target, p.join(tmp.path, 'saf_playback'));
        }
        await _updateRgGain(target);
        final s = _ref.read(settingsProvider).valueOrNull;
        final isDsd = _isDsdPath(target);
        final useExclusive =
            (s?.usbExclusiveOutput ?? false) ||
                (isDsd && (s?.dsdNativePassthrough ?? false));
        var started = false;
        if (useExclusive) {
          await _stopExclusive();
          started = await _tryStartExclusive(target,
              startAtSecs: startAtSecs, isPlaying: true);
        }
        if (!started) {
          await _stopExclusive();
          try {
            await _player.stop();
          } catch (_) {}
          await _setLocalSource(target);
          if (startAtSecs > 0) {
            try {
              await seek(startAtSecs);
            } catch (_) {}
          }
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
      // 本地歌曲通知栏封面兜底（异步，不阻塞起播）。
      unawaited(_resolveNotificationCover(item));
    } catch (e) {
      state = state.copyWith(isPlaying: false, resolving: false);
      // 在线歌曲：先尝试自动切换其他音源，避免直接跳过/停止。
      // 分享链接触发的播放按「分享链接播放失败行为」设置：pause 不换源（直接透出错误暂停），
      // replace 才允许走插件索引换源重播。
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
      // 在线歌曲失败处理（防环：跳过数不超过队列长度）。
      if (item.isOnline && _skipDepth < state.queue.length) {
        final behavior = _ref
                .read(settingsProvider)
                .valueOrNull
                ?.onlineFailureBehavior ??
            'skip';
        if (behavior == 'skip') {
          _skipDepth++;
          final next = _pickNextIndex();
          if (next >= 0 && next != index) {
            await _playAt(next);
            return;
          }
        }
      }
      // 无下一首可跳（或 stop 行为）时透出错误信息。
      if (item.isOnline) {
        state = state.copyWith(
            error: e is PluginEngineException
                ? e.message
                : '播放失败：${e.toString()}');
      } else {
        // 本地歌曲失败同样透出：静默失败会让用户以为「点击没反应」。
        debugPrint('[play] 本地播放失败 path=${item.path} error=$e');
        state = state.copyWith(
            error: e is PluginEngineException
                ? e.message
                : '本地播放失败：${e.toString()}');
      }
      _syncToSystemMediaSession();
    }
    // 一次起播尝试结束即清掉分享链路标记，避免泄漏影响后续非分享链接播放。
    _shareLinkPlayback = false;
    if (!item.isOnline) _persistSession();
  }

  /// 在线歌曲：解析直链后播放。失败抛异常由调用方处理。
  Future<void> _playOnline(QueueItem item) async {
    final json = item.onlineSongJson;
    if (json != null && json.isNotEmpty) {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final s0 = _ref.read(settingsProvider).valueOrNull;
      final fb0 = s0?.onlineQualityFallbackBehavior ?? 'lower';
      final preferred = item.onlineQuality ??
          s0?.onlineDefaultQuality ??
          '320k';
      final candidates = _qualityCandidates(preferred, fb0);

      // 共享探测：同歌一轮，起播优先、档位菜单/下载复用。
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.ensure(
          key, _buildResolveCallback(songJson, item));
      _activeProbeKey = key;

      // 探测整体限时：多档串行超时（每档 8-30s）会拖垮加载态，超时即放弃。
      final start = await probe
          .startBest(preferred, candidates)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      if (start != null) {
        // 直链已就绪，立即结束加载态；流的加载/缓冲由播放器内部处理。
        state = state.copyWith(resolving: false);
        await _startUrl(start.url, headers: start.headers);
        state = state.copyWith(currentQuality: start.quality);
        _refreshQualityMenuState(probe);
        return;
      }
      throw StateError('直链解析失败');
    }
    // onlineInfoJson：走 lxResolveUrl（在线搜索音源）。
    final url = await _resolveOnlineUrl(item);
    if (url == null) throw StateError('无法获取播放链接');
    state = state.copyWith(
      resolving: false,
      currentQuality: url.quality,
    );
    await _startUrl(url.url, headers: url.headers);
  }

  /// 歌曲级探测 key：隔离不同歌曲且共享同一首歌的多路调用。
  String _songProbeKey(Map<String, dynamic> songJson, QueueItem item) {
    final pid = songJson['pluginId'];
    final src = songJson['source'];
    final mid = songJson['songmid'] ?? songJson['id'];
    if (pid != null) {
      return 'plugin:$pid:${mid ?? songJson['title'] ?? item.title}';
    }
    return 'lx:$src:${mid ?? item.title}';
  }

  /// 获取当前歌曲的声明音质（对齐桌面 getOnlineAvailableQualities）：
  /// - 插件歌：优先读 musicInfo._types（LX 插件搜索结果带真实音质档），
  ///   其次读插件元数据 supportedQualities（MusicFree 新式插件声明），
  ///   都没有时按桌面 pluginGetSupportedQualities 兜底为 128k/320k/flac。
  /// - 落雪在线搜索歌：读顶层 _types。
  /// 无声明返回空列表。
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
          debugPrint('[quality] declared pid=$pid meta=${meta == null ? 'null' : 'ok'} '
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
        // 对齐桌面 pluginGetSupportedQualities 兜底：原版 MusicFree 插件
        // 只暴露 standard/high/lossless 三档，映射为代表音质。
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
    debugPrint('[quality] _declaredQualities pid=$pid result=$result');
    return result;
  }

  /// 构造单档解析回调：插件音源逐档优先，同档插件失败立即用 LX 兜底；
  /// 纯 LX 音源直接走 LX 单档解析。
  Future<ResolvedMediaUrl?> Function(String) _buildResolveCallback(
      Map<String, dynamic> songJson, QueueItem item) {
    final hasPlugin = songJson.containsKey('pluginId');
    return (String q) async {
      if (hasPlugin) {
        final u = await _resolvePluginUrl(songJson, q);
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

  /// 单档 LX 直链解析（已导入插件优先 → 公共 API）。单档限时 8s。
  Future<ResolvedMediaUrl?> _lxResolveQuality(
      String songInfoJson, String quality) async {
    try {
      final dataDir = await _ref.read(appDataDirProvider.future);
      final resolved = await lxResolveUrl(
        songInfoJson: songInfoJson,
        quality: quality,
        dataDir: dataDir,
      ).timeout(const Duration(seconds: 8));
      if (resolved == 'null' || resolved.isEmpty) return null;
      final url =
          (jsonDecode(resolved) as Map<String, dynamic>)['url'] as String?;
      return _isPlayableUrl(url) ? ResolvedMediaUrl(url: url!) : null;
    } catch (_) {
      return null;
    }
  }

  /// 把探针的最新可用档位同步到 UI 状态（音质按钮/菜单）。
  void _refreshQualityMenuState(SongQualityProbe probe) {
    state = state.copyWith(
      availableQualities: probe.availableQualities,
      qualityMenuProbing: probe.probing,
    );
  }

  /// 切换当前在线歌曲播放音质：复用共享探针，命中即重播。
  Future<bool> switchQuality(String quality) async {
    final item = state.current;
    if (item == null || !item.isOnline) return false;
    // 插件歌走 onlineSongJson，落雪在线搜索歌走 onlineInfoJson，二者都要支持。
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json == null || json.isEmpty) return false;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry
          .ensure(key, _buildResolveCallback(songJson, item));
      _activeProbeKey = key;
      state = state.copyWith(resolving: true);
      final res = await probe.probe(quality);
      if (res == null || res.url.isEmpty) {
        state = state.copyWith(resolving: false);
        return false;
      }
      await _startUrl(res.url, headers: res.headers);
      // 把所选音质写回队列项，切歌/重播沿用该档（对齐桌面端会话级覆盖）。
      final updated = item.copyWithQuality(res.quality);
      state = state.copyWith(
        current: updated,
        queue: state.queue
            .map((e) => e.path == item.path ? updated : e)
            .toList(),
        resolving: false,
        currentQuality: res.quality,
        availableQualities: probe.availableQualities,
        qualityMenuProbing: probe.probing,
      );
      return true;
    } catch (_) {
      state = state.copyWith(resolving: false);
      return false;
    }
  }

  /// 获取当前在线歌曲的真实可用档位（触发无损档全量探测，供音质菜单展示）。
  ///
  /// 复用共享探针做受控并发探测与降级校验，返回按高 → 低排序的可用档。
  Future<List<String>> qualityOptions() =>
      _probeQualityOptions(forDownload: false);

  /// 获取当前在线歌曲的可下载档位（触发无损档 + 320k 全量探测，供下载弹窗展示）。
  ///
  /// 与 [qualityOptions] 共用同一轮共享探针（探测传递），额外包含 320k
  /// 这一常用下载档，返回按高 → 低排序的可用档。
  Future<List<String>> downloadQualityOptions() =>
      _probeQualityOptions(forDownload: true);

  Future<List<String>> _probeQualityOptions(
      {required bool forDownload}) async {
    final item = state.current;
    // 插件歌走 onlineSongJson，落雪在线搜索歌走 onlineInfoJson，二者都要支持。
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    debugPrint('[quality] _probeQualityOptions item=${item?.title} '
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

      // 探测目标：优先用源声明的音质（对齐桌面 probeDownloadableQualities，
      // 插件只声明支持哪些档，探测声明之外无意义）；无声明时回退
      // 无损 + 320k（常用档）+ 128k 兜底档。
      final declared = await _declaredQualities(songJson);
      if (declared.isNotEmpty) {
        // 对齐桌面 getOnlineAvailableQualities：菜单直接展示源声明音质，
        // 探测仅作后台校验/降级修正，不再阻塞菜单展示（避免探测慢/挂起导致空态）。
        final base = kQualityLadder.reversed.where(declared.contains).toList();
        debugPrint('[quality] declared non-empty base=$base');
        state = state.copyWith(
          availableQualities: base,
          qualityMenuProbing: true,
        );
        unawaited(_probeInBackground(probe, declared, base));
        return base;
      }

      // 无声明（如落雪在线搜索无 _types）：探测常用档位后展示。
      final targets = kQualityLadder.reversed
          .where((q) => isLosslessQuality(q) || q == '320k' || q == '128k')
          .toList();
      debugPrint('[quality] declared empty, probing targets=$targets');
      await Future.wait(targets.map(probe.probe).toList());

      final opts = <String>{...probe.availableQualities};
      if (state.currentQuality != null) opts.add(state.currentQuality!);
      final ordered =
          kQualityLadder.reversed.where(opts.contains).toList();
      debugPrint('[quality] probe done opts=$ordered');
      state = state.copyWith(
        availableQualities: ordered,
        qualityMenuProbing: false,
      );
      return ordered;
    } catch (e) {
      debugPrint('[quality] _probeQualityOptions error: $e');
      state = state.copyWith(qualityMenuProbing: false);
      return state.availableQualities;
    }
  }

  /// 后台探测可用档位：成功档位并入 [base]，供切换/下载复用。
  /// 探测失败/超时不影响已展示的声明音质。
  Future<void> _probeInBackground(
    SongQualityProbe probe,
    List<String> targets,
    List<String> base,
  ) async {
    try {
      await Future.wait(targets.map(probe.probe).toList())
          .timeout(const Duration(seconds: 30));
      final opts = <String>{...probe.availableQualities};
      if (state.currentQuality != null) opts.add(state.currentQuality!);
      if (opts.isEmpty) opts.addAll(base);
      final ordered =
          kQualityLadder.reversed.where(opts.contains).toList();
      state = state.copyWith(
        availableQualities: ordered,
        qualityMenuProbing: false,
      );
    } catch (_) {
      state = state.copyWith(qualityMenuProbing: false);
    }
  }

  /// 音质阶梯（低 → 高），与设置页可选档位一致（对齐桌面端 rank 排序）。
  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  /// 音质候选链（对齐桌面端 resolveOnlinePlayQuality）。
  /// - [preferred] 首选音质，[fallback] 回退行为：pause 严格不回退（仅首选）/ lower 向下降级 / higher 向上升级。
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
    // pause：严格只试首选一次，失败交给起播失败行为处理。
    if (fallback == 'pause') return result.isNotEmpty ? result : [preferred];
    if (result.isEmpty && avail.isNotEmpty) result.add(avail.first);
    return result;
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
  /// 加载本地曲目音源：SAF 的 `content://` 页先物化为本地真实文件再交给
  /// just_audio 播放（content 树文档 URI 播放不可靠），普通路径直接走文件。
  Future<Duration?> _setLocalSource(String path) async {
    var target = path;
    if (path.startsWith('content://')) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          path, p.join(tmp.path, 'saf_playback'));
    }
    if (target.startsWith('content://')) {
      // 物化失败时回退直接以 content URI 交给 just_audio。
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

  Future<void> _startUrl(String url, {Map<String, String>? headers}) async {
    final clean = sanitizeMediaUrl(url);
    if (clean.isEmpty) throw StateError('无效的播放链接');
    // 合并插件 headers 与按域名补齐的防盗链头（Referer/Origin/Accept）。
    final h = normalizeMediaRequestHeaders(clean, headers);
    await _player.setUrl(clean, headers: h);
    await _player.setVolume(_ref.read(volumeProvider));
    await _player.play();
  }

  /// 按候选音质依次调用 lxResolveUrl（已导入插件 → 公共 API），
  /// 返回首个合法 http(s) 直链。整体限时 12s，避免多档串行超时拖垮加载态。
  Future<ResolvedMediaUrl?> _tryLxResolve(
      String songInfoJson, List<String> candidates) async {
    final dataDir = await _ref.read(appDataDirProvider.future);
    try {
      return await _tryLxResolveInner(songInfoJson, candidates, dataDir)
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return null;
    }
  }

  Future<ResolvedMediaUrl?> _tryLxResolveInner(
      String songInfoJson, List<String> candidates, String dataDir) async {
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
        if (_isPlayableUrl(url)) {
          return ResolvedMediaUrl(url: url!, quality: quality);
        }
      } catch (_) {}
    }
    return null;
  }

  /// 累计并落库本次会话的听歌时长（对标桌面端 flushPlaySession）。
  ///
  /// `_accumulatedTime` 累计上一段已停止播放的时间；`_trackStartTime` 追踪当前
  /// 连续播放段的起点。达到阈值才写入数据库，避免频繁落库；同一首歌只有首帧
  /// 计入播放次数，后续增量只加时长（countAsPlay=false）。
  void _flushPlayStats() {
    final item = state.current;
    if (item == null) return;
    // 只要 _trackStartTime 非空即代表存在待结算的连续播放段（含刚自然播完/刚暂停
    // 的时刻，此时 isPlaying 已被置 false），一律按 now - 起点 结算，避免丢失尾段时长。
    double currentSession = 0;
    if (_trackStartTime != null) {
      currentSession =
          DateTime.now().difference(_trackStartTime!).inMilliseconds / 1000.0;
    }
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
    // 置位新起点：若仍在播放，从此刻继续累计；否则等待下次 resume 重建起点。
    _trackStartTime = state.isPlaying ? DateTime.now() : null;
  }

  void _recordHistory(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
      } catch (_) {}
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
        // 首页「统计」卡片与「常听排行」读取的都是数据库，落库后需使其重新求值，
        // 否则播放再久，界面上的统计数据都停留在首次加载的值。
        _ref.invalidate(listenStatsProvider);
        _ref.invalidate(mostPlayedProvider);
      } catch (_) {}
    });
  }

  Future<ResolvedMediaUrl?> _resolveOnlineUrl(QueueItem item) async {
    final infoJson = item.onlineInfoJson;
    if (infoJson == null) return null;
    final s = _ref.read(settingsProvider).valueOrNull;
    final preferred = s?.onlineDefaultQuality ?? '320k';
    final fb = s?.onlineQualityFallbackBehavior ?? 'lower';
    return _tryLxResolve(infoJson, _qualityCandidates(preferred, fb));
  }

  /// 在线歌曲起播失败时自动切换到其他落雪音源（同一首歌、另一平台）。
  /// 通过公共音源搜索同名曲目并解析直链播放；返回 true 表示已换源成功。
  Future<bool> _autoSwitchSource(QueueItem item, {bool force = false}) async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    // 分享链接「替换播放」走插件索引换源时允许绕过通用开关（force=true）。
    if (!(settings?.autoSwitchSourceOnFailure ?? false) && !force) return false;

    final infoJson = item.onlineInfoJson ?? item.onlineSongJson;
    if (infoJson == null || infoJson.isEmpty) return false;
    var info = <String, dynamic>{};
    try {
      info = jsonDecode(infoJson) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    final curSource = (info['source'] as String?) ?? item.source;
    if (curSource == null || curSource.isEmpty) return false;

    // 换源上下文按歌曲（标题+歌手）隔离，避免残留到下一首。
    final key = '${item.title}|${item.artist}';
    if (_switchCtxKey != key) {
      _switchCtxKey = key;
      _failedSources.clear();
    }
    _failedSources.add(curSource);
    if (item.title.trim().isEmpty) return false;

    final fb = settings?.onlineQualityFallbackBehavior ?? 'lower';
    final preferred = settings?.onlineDefaultQuality ?? '320k';

    for (final src in kOnlineSources) {
      if (_failedSources.contains(src.id)) continue;
      final raw = await _searchAlternative(item, src.id);
      if (raw == null) {
        _failedSources.add(src.id);
        continue;
      }
      final newItem = OnlineTrack.fromJson(raw).toQueueItem();
      final url = await _tryLxResolve(
        jsonEncode(raw),
        _qualityCandidates(preferred, fb),
      );
      if (url == null) {
        _failedSources.add(src.id);
        continue;
      }
      // 更新当前队列项为该音源，再播放。
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
        // 直链已就绪，立即结束加载态；流的加载/缓冲由播放器内部处理。
        state = state.copyWith(resolving: false);
        await _startUrl(url.url, headers: url.headers);
      } catch (_) {
        _failedSources.add(src.id);
        continue;
      }
      _skipDepth = 0;
      state = state.copyWith(resolving: false, error: null);
      _reportBehavior(newItem, 'play', 0);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
      return true;
    }
    return false;
  }

  /// 在指定音源搜索与当前歌曲同名的曲目，返回第一个匹配的原始搜索项；无匹配返回 null。
  Future<Map<String, dynamic>?> _searchAlternative(
    QueueItem item,
    String source,
  ) async {
    try {
      final q = item.artist.trim().isEmpty
          ? item.title.trim()
          : '${item.title.trim()} ${item.artist.trim()}';
      final res = await lxSearch(source: source, keyword: q, limit: 10);
      final list = (jsonDecode(res) as List).cast<Map<String, dynamic>>();
      for (final raw in list) {
        if (_matchOnlineTitle(item.title, OnlineTrack.fromJson(raw).title)) {
          return raw;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 标题归一化匹配（去空格/标点/大小写后比较；长度≥3 允许互相包含）。
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

  /// 通过插件引擎解析播放直链。
  Future<ResolvedMediaUrl?> _resolvePluginUrl(
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
        // MusicFree 插件：调用 getMediaSource(musicItem, quality)，内部做音质降级映射。
        return await engine.getMusicFreeUrl(
          source.first,
          musicInfo,
          preferred: quality,
        );
      }

      final result =
          await engine.getMusicUrl(source.first, sourceKey, musicInfo, quality);
      if (result == null) return null;
      final url = result['url'] as String?;
      if (!_isPlayableUrl(url)) return null;
      final h = result['headers'];
      return ResolvedMediaUrl(
        url: url!,
        headers: h is Map ? h.cast<String, String>() : null,
      );
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
        // 刷新最近播放列表，使新播放立即可见（对齐 sync 导入后的 refresh）。
        try {
          await _ref.read(recentProvider.notifier).refresh();
        } catch (_) {}
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
      await _playAt(newIndex);
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
    await _playAt(index);
  }

  /// 将 [item] 插入到当前曲目的下一首播放（不中断当前播放、不自动起播）。
  /// 队列为空时作为待播队列唯一一首置入（仍不起播），供后续手动播放。
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
    // 插入在当前曲目之后，queueIndex 无需变化。
    state = state.copyWith(queue: queue, queueIndex: qi);
  }

  /// 系统控制中心「收藏」键：切换当前歌曲收藏并刷新通知栏图标。
  Future<void> toggleFavoriteFromSystem() async {
    final item = state.current;
    if (item == null) return;
    await _ref.read(favoritesProvider.notifier).toggle(item);
    _syncToSystemMediaSession();
  }

  /// 系统控制中心「播放」键：仅暂停中生效（复用 toggle 的全部分支逻辑）。
  Future<void> resumeFromSystem() async {
    if (state.isPlaying) return;
    await toggle();
  }

  /// 系统控制中心「暂停 / 停止」键：仅播放中生效。
  Future<void> pauseFromSystem() async {
    if (!state.isPlaying) return;
    await toggle();
  }

  Future<void> toggle() async {
    if (state.current == null) return;
    // USB 独占管线：seek(pos, isPlaying) 即暂停/恢复。
    if (state.usbExclusive) {
      if (state.isPlaying) {
        _flushPlayStats();
        await seekUsbExclusive(timeSecs: state.position, isPlaying: false);
        state = state.copyWith(isPlaying: false);
      } else {
        _trackStartTime = DateTime.now();
        await seekUsbExclusive(timeSecs: state.position, isPlaying: true);
        state = state.copyWith(isPlaying: true);
      }
      _syncToSystemMediaSession();
      _persistSession();
      return;
    }
    if (state.isPlaying) {
      _flushPlayStats();
      await _player.pause();
    } else {
      _trackStartTime = DateTime.now();
      final pendingPos = _restoredOnlinePending;
      if (pendingPos != null) {
        _restoredOnlinePending = null;
        await _resumeRestoredOnline(pendingPos);
        _persistSession();
        return;
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
    // 控制中心右侧「播放顺序」图标需要随模式刷新。
    _syncToSystemMediaSession();
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
        await _player.setUrl(url.url, headers: url.headers);
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
    _procSub?.cancel();
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
