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
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_provider.dart';
import '../recent/recent_provider.dart';
import '../remote/remote_library_service.dart';
import '../rust/api.dart';
import '../widgets/app_toast.dart';
import '../navigation/routes.dart';
import 'media_url.dart';
import 'cast_provider.dart';
import 'online_quality_probe.dart';
import '../i18n/i18n.dart';

/// 全局系统控制中心 AudioHandler 句柄
XianYuAudioHandler? audioHandler;

/// 直链体积缓存（url → 字节）：音质/下载弹窗重复打开不重复探测。
/// 直链带过期参数会变化，超上限直接清空重建，避免无界增长。
final Map<String, int> _qualitySizeByUrl = {};

/// 已预热过体积的歌曲探测 key：避免切歌后台预热对同一首歌重复起跑全档解析。
/// 有上限，防止长期运行无限增长。
final Set<String> _prewarmKeys = {};

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
    _lastSyncItem = item;
    _lastSyncDuration = durationSecs;
    mediaItem.add(_buildMediaItem(item, durationSecs, _artUriFor(item)));
    // 在线封面异步落盘，成功后补推一次本地 file:// 封面（见 _materializeOnlineArt）。
    unawaited(_materializeOnlineArt(item));
  }

  /// 最近一次广播的歌曲与时长（封面落盘完成后补推用）。
  QueueItem? _lastSyncItem;
  double _lastSyncDuration = 0;

  /// 在线封面落盘缓存（url → 本地文件路径）。
  final Map<String, String> _artFileCache = {};
  /// 正在落盘的 url，防并发重复写。
  final Set<String> _artMaterializing = {};

  /// 计算系统卡片封面 URI。
  ///
  /// 鸿蒙 4.2 及更早版本的「媒体播控中心」运行在安卓兼容层，不会联网加载
  /// https 远程封面 URI（华为系统服务不做网络请求），加载失败会导致播控
  /// 卡片无封面甚至表现异常；故已落盘的在线封面一律用本地 file:// URI，
  /// 未落盘前先用 https 兜底，落盘完成后补推本地封面。
  Uri? _artUriFor(QueueItem item) {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      final cached = _artFileCache[url];
      if (cached != null) return Uri.file(cached);
      return Uri.tryParse(url);
    }
    final local = item.coverPath;
    if (local != null && local.isNotEmpty) return Uri.file(local);
    return null;
  }

  as_pkg.MediaItem _buildMediaItem(
      QueueItem item, double durationSecs, Uri? artUri) {
    return as_pkg.MediaItem(
      id: item.path,
      album: item.album.isEmpty ? tr('弦予音乐') : item.album,
      title: item.title,
      artist: item.artist.isEmpty ? tr('未知歌手') : item.artist,
      // 时长无效（在线歌起播瞬间尚未探测到时长）时不下发 0：
      // METADATA_KEY_DURATION=0 在鸿蒙播控中心会被判定无效元数据，卡片不显示。
      duration:
          durationSecs > 0 ? Duration(milliseconds: (durationSecs * 1000).round()) : null,
      artUri: artUri,
    );
  }

  /// 在线封面经 CoverProxy 取回字节后写入临时目录，artUri 换成本地文件。
  /// 只在 Android 生效（iOS 控制中心可加载网络图，桌面端无此桥接）。
  Future<void> _materializeOnlineArt(QueueItem item) async {
    if (!Platform.isAndroid) return;
    final url = item.coverUrl;
    if (url == null || url.isEmpty) return;
    if (_artFileCache.containsKey(url)) return;
    if (!_artMaterializing.add(url)) return;
    try {
      final bytes = await CoverProxy.fetch(url);
      if (bytes == null || bytes.isEmpty) return;
      final dir = await getTemporaryDirectory();
      final key = md5.convert(utf8.encode(url)).toString();
      final file = File('${dir.path}/media_art_$key.jpg');
      await file.writeAsBytes(bytes, flush: true);
      _artFileCache[url] = file.path;
      // 仍是当前这首歌时补推一次，让播控卡片尽快换成本地封面。
      if (_lastSyncItem?.path == item.path) {
        mediaItem.add(
          _buildMediaItem(item, _lastSyncDuration, Uri.file(file.path)),
        );
      }
    } catch (_) {
      // 落盘失败静默：保留 https artUri 兜底。
    } finally {
      _artMaterializing.remove(url);
    }
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
            // 0.18.x 的 androidIcon 必须带 "drawable/" 前缀：
            // Android 端 getResourceId 按 "/" split 后取 parts[1]，
            // 缺前缀会抛 ArrayIndexOutOfBoundsException 导致整个媒体卡片不显示。
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
        1 => tr('单曲循环'),
        2 => tr('随机播放'),
        _ => tr('列表循环'),
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
  /// 共享 DSP 管线（AAudio shared + 系统混音器）播放中：普通模式效果链走 Rust。
  final bool dspActive;
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
  StreamSubscription<dynamic>? _errSub;
  Timer? _listenTimer;
  /// 播放错误处理互斥：错误风暴（换源探测失败链）时只处理一次。
  bool _playbackErrorHandling = false;
  // 自然播完衔接互斥：completed 事件在解析直链的长窗口内可能重复到达，
  // 无防护会并发两次 _playAt 导致跳两首/状态互相覆盖。
  bool _onTrackEndBusy = false;
  Timer? _exclusiveTimer;
  Timer? _sfxSyncTimer;
  /// 共享 DSP 管线本会话是否可用（AAudio 初始化失败后置 false，全部回退 ExoPlayer）。
  bool _dspAvailable = true;
  /// 管线中途退出（解码失败等）后的下一次起播跳过管线，防「退出→重播→退出」环。
  bool _dspSkipNextStart = false;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  // 在线歌曲连续失败跳过计数（防环）。
  int _skipDepth = 0;
  // [播放结束双通道兜底] 对齐桌面端：rAF 进度超限（evaluateStallAutoNext 同源）。
  // 每 500ms 检查一次进度，completed 事件丢失或播放器静默死亡时仍能自动衔接。
  Timer? _stallTimer;
  double _stallLastPos = -1;
  int _stallTicks = 0;
  // 失败在线音源记录（key → 失败时间，10 分钟过期）：同源队列歌曲批量快速跳过，
  // 对齐桌面端 knownFailedPluginPrefixes + recentOnlineFailurePaths。
  final Map<String, DateTime> _failedOnlineSources = {};

  /// 起播流水线代际号：清空队列/队列删空等「重置」操作递增，_playAt 在每个
  /// await 边界后校验，不一致即放弃后续起播——否则清空队列时在途的
  /// `_playAt`（在线解析/换管线/加载源）会把 current 写回 state 并重新
  /// `_player.play()`，表现为「清了还在响、队列复活、播放页不退出」。
  int _playEpoch = 0;
  // 自动换源上下文：同一首歌的失败音源集；歌曲切换时被 _switchCtxKey 重建。
  final Set<String> _failedSources = {};
  String? _switchCtxKey;
  // 分享链接深链触发的播放：失败行为按「分享链接播放失败行为」设置决定（replace 才允许插件换源重播）。
  bool _shareLinkPlayback = false;
  /// 会话级临时音质覆盖（音质菜单显式选择时写入，对齐桌面端 sessionQualityOverride）。
  /// 播放时优先级：_sessionQualityOverride > 设置的 onlineDefaultQuality > 歌曲自带档位。
  /// 新播放会话（playQueue/清空队列）时清空，手动切歌保留。
  String? _sessionQualityOverride;

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
  /// 已发起封面预加载的歌曲 path（避免同歌重复预热；满额清首保活）。
  final Set<String> _preloadedCovers = {};
  /// 进程内是否已请求过通知权限（Android 13+ 媒体通知必需）。
  bool _notifPermissionAsked = false;

  final List<String> _shuffleHistory = [];
  final List<String> _shuffleFuture = [];
  /// 上一首已预缓存的远程歌曲路径（去重，防止每个进度 tick 重复触发）。
  String? _lastPrecachedRemotePath;

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
      _maybePrecacheNextRemote(pos);
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
    // 播放中途错误（直链中途失效/网络断/解码失败）：just_audio 通过
    // playbackEventStream 的 onError 上报。此前无人监听 → 播放器已死但
    // UI 仍停在 isPlaying=true。统一路由：在线歌先尝试换源，失败透出错误。
    _errSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _onPlaybackError(e);
      },
    );
    // 播放中每 15 秒把当前会话的听歌时长增量刷写进数据库（首页统计/排行榜共用），
    // 避免长时间连续播放时统计迟迟不落库。
    _listenTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (state.isPlaying) {
        _flushPlayStats();
      }
    });
    // [播放结束双通道兜底] 每 500ms 检查进度超限/停滞（对齐桌面端
    // rAF 到点检测 + evaluateStallAutoNext 停滞判定），防止 completed
    // 事件丢失或播放器静默死亡时卡在最后一秒不切歌。
    _stallTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _checkStalledProgress();
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
    // 音量即时同步到 DSP 管线（独占/共享）。
    _ref.listen(volumeProvider, (_, v) {
      if (state.usbExclusive || state.dspActive) {
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
    // 输出设备切换时，正在使用独占/共享 DSP 管线的本地曲目在当前位置
    // 无缝重建管线，让新设备立即生效（对齐桌面端切换输出设备行为）。
    _ref.listen(
      settingsProvider.select((s) => s.valueOrNull?.usbExclusiveDeviceId ?? -1),
      (prev, next) {
        if (prev != next) _onOutputDeviceChanged();
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
      // 关闭独占：优先无缝切到共享 DSP 管线（效果链继续生效），失败回退 ExoPlayer。
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
      } catch (_) {}
    }
  }

  /// 输出设备变更：独占/共享 DSP 管线正在使用时，在当前位置无缝重建管线，
  /// 让新设备立即生效；仅 ExoPlayer 在播时不打断（设备选择在下次起播生效）。
  /// 新设备上管线启动失败时回退 ExoPlayer 续播，避免静音。
  Future<void> _onOutputDeviceChanged() async {
    if (!state.usbExclusive && !state.dspActive) return;
    final item = state.current;
    if (item == null || item.isOnline || _isRemotePath(item.path)) return;
    final pos = state.position;
    final playing = state.isPlaying;
    // SAF content:// 先物化为本地真实文件，独占/共享管线无法消费树文档 URI。
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
    // 新设备/新管线上启动失败：回退 ExoPlayer 从当前位置续播。
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

  /// 启动共享 DSP 管线播放（AAudio shared + 系统混音器）。
  /// 全效果链（EQ/混响/空间音效/变速变调/响度平衡）在 Rust 侧生效。
  /// 失败返回 false，调用方回退 ExoPlayer。
  Future<bool> _tryStartDspPipeline(
    String path, {
    required double startAtSecs,
    required bool isPlaying,
  }) async {
    if (!_dspAvailable) return false;
    // 管线中断后的首次重播跳过 DSP（防退出环），正常切歌后自动恢复尝试。
    if (_dspSkipNextStart) {
      _dspSkipNextStart = false;
      return false;
    }
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      final settings = _ref.read(settingsProvider).valueOrNull;
      await startUsbExclusivePlayback(
        path: path,
        // 共享 DSP 管线同样输出到「输出设备」所选设备（-1 = 系统默认，
        // 对齐桌面端共享模式可选输出设备）。
        deviceId: settings?.usbExclusiveDeviceId ?? -1,
        volume: _ref.read(volumeProvider),
        startTimeSecs: startAtSecs,
        isPlaying: isPlaying,
        volumeBalanceGain: _effectiveBalanceGain(),
        equalizerSettingsJson: jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: jsonEncode(sfx.toRustJson()),
        bitPerfect: false,
        dsdNativePassthrough: false,
        sharedMode: true,
      );
      state = state.copyWith(usbExclusive: false, dspActive: true, isPlaying: isPlaying);
      _startExclusivePolling();
      _syncToSystemMediaSession();
      return true;
    } catch (e) {
      state = state.copyWith(dspActive: false);
      // AAudio 库加载失败（API < 26 等）属于会话级不可用，避免每首歌都空等 3s 超时。
      final msg = e.toString();
      if (msg.contains('AAudio') || msg.contains('aaudio')) {
        _dspAvailable = false;
      }
      AppLogger.instance.log('dsp', '共享 DSP 管线启动失败，回退 ExoPlayer: $e');
      return false;
    }
  }

  /// 停止独占/共享 DSP 管线并释放设备。
  Future<void> _stopExclusive() async {
    _stopExclusivePolling();
    try {
      await stopUsbExclusivePlayback();
    } catch (_) {}
    if (state.usbExclusive || state.dspActive) {
      state = state.copyWith(usbExclusive: false, dspActive: false);
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
    if (!state.usbExclusive && !state.dspActive) return;
    try {
      final pos = await getUsbExclusivePositionSecs();
      state = state.copyWith(position: pos);
      _syncToSystemMediaSession();
      _persistPositionDebounced();
      _maybePrecacheNextRemote(pos);
      final infoStr = await getUsbExclusiveDeviceInfo();
      final info = jsonDecode(infoStr) as Map<String, dynamic>;
      // DSP 管线的解码器总时长比元数据更准，覆盖 ExoPlayer 阶段的缓存值。
      final engineDur = (info['durationSecs'] as num?)?.toDouble() ?? 0.0;
      if (engineDur > 0) {
        state = state.copyWith(duration: engineDur);
      }
      final dur = state.duration;
      // 管线工作线程退出检测：设备断开/解码失败/自然放完。
      // 用进度区分「自然放完」与「中断」——近末尾按自然结束衔接下一曲，
      // 进度远离末尾才是中断，回退普通播放续播当前曲。
      if (info['active'] != true) {
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

  /// 管线中断（设备断开/解码失败）：释放管线并在普通播放继续当前曲目。
  Future<void> _onExclusiveDisconnect() async {
    final cur = state.current;
    _flushPlayStats();
    if (cur != null) _reportBehavior(cur, 'usb_disconnect', 0);
    await _stopExclusive();
    // 下一轮起播跳过管线，防「退出→重播→退出」环；正常切歌后自动恢复尝试。
    _dspSkipNextStart = true;
    if (cur == null) return;
    await _playAt(state.queueIndex);
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

  /// EQ/音效设置变化时同步到 DSP 管线（独占/共享，50ms 防抖）。
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

  /// 将音效的倍速/变调应用到 just_audio。
  /// DSP 管线（独占/共享）播放时由 Rust 侧处理变速变调，跳过。
  Future<void> _applyEffectSpeedPitch(SoundEffectSettings s) async {
    if (state.usbExclusive || state.dspActive) return;
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

  /// 预加载播放队列封面（后台异步，不阻塞起播）。
  ///
  /// 目标：切歌/切歌封面动画时，下一首封面多数已解码/落盘，避免新封面从占位
  /// 渐显的等待。只预热当前之后若干首 + 随机模式下若干随机候选：
  ///   - 在线封面：防盗链域名（bili/网易/腾讯/酷我 CDN 等）经 [CoverProxy.fetch]
  ///     预先拉取到内存缓存（CoverImage._maybeProxy 可直接命中渲染）；
  ///   - 本地封面：经 [getSongCoverThumbnail] 预热缩略图到磁盘缓存（diff.rs 按
  ///     mtime+size 短路的既成缓存，后续 CoverImage 再次提取立刻返回）。
  /// 同歌只预热一次（_preloadedCovers 去重，满额清首保活）。
  void _preloadQueueCovers() {
    final targets = <QueueItem>{};
    for (var k = 1; k <= 6 && state.queueIndex + k < state.queue.length; k++) {
      targets.add(state.queue[state.queueIndex + k]);
    }
    // 随机模式：额外预取若干随机候选，增大切歌即命中的概率。
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
      // 预载失败静默：封面另有占位兜底，不影响起播。
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
            var path = currentItem.path;
            // 会话恢复的转码类格式（APE/WV/AIFF/QMC）：先转码/解密再预载。
            if (_isTranscodePath(path)) {
              try {
                path =
                    (await RemoteLibraryService(_ref).transcodeToWav(path)).path;
                await _updateRgGain(path);
              } catch (e) {
                AppLogger.instance.log('session', '转码预载失败: $e');
              }
            }
            // 共享 DSP 管线暂停态预载（对齐独占恢复），失败回退 ExoPlayer 预载。
            restored = await _tryStartDspPipeline(path,
                startAtSecs: pos, isPlaying: false);
            if (!restored) {
              try {
                await _player.setFilePath(path);
                await seek(pos);
              } catch (e) {
                AppLogger.instance.log('session', '本地曲目预加载失败: $e');
              }
              await _player.setVolume(_effectiveVolume());
            }
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
      // 手势调用点不 await 异步错误，此处兜底捕获避免整链静默中断。
      AppLog.error('play', 'playQueue 异常: $e\n$st');
      state = state.copyWith(isPlaying: false, resolving: false);
    }
  }

  Future<void> _playAt(int index, {double startAtSecs = 0}) async {
    if (index < 0 || index >= state.queue.length) return;
    // 自增代际号：任何新的起播（自然衔接/手动切歌/失败跳曲递归）都会令
    // 更早的在途起播在下一个 await 边界放弃，防止并发起播互相踩踏
    //（快速连点下一首、播完自动衔接与手动切换竞争等场景）。
    _playEpoch++;
    final epoch = _playEpoch;

    AppLog.info('play', '_playAt index=$index path=${state.queue[index].path}');
    // 首次播放时申请通知权限（Android 13+ 未授权则媒体通知被系统静默拦截）。
    unawaited(_ensureNotificationPermission());
    _flushPlayStats();
    // 新曲目首播计数重置：后续增量刷写只加时长、不再累加播放次数。
    _currentPlayCountRecorded = false;
    _accumulatedTime = 0;

    _restoredOnlinePending = null;
    _restoredLocalPending = null;
    final item = state.queue[index];
    // [失败音源快速跳过] 该曲所属音源短时间内已因播放失败被批量标记（对齐
    // 桌面端 knownFailedPluginPrefixes）：不再走完整的解析/换源流程，直接跳到
    // 队列下一首，避免整个同源队列逐首承受 12s+ 的解析超时。
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
      // 队列里已无可播放歌曲：立即停止并提示，不卡加载态也不反复跳歌。
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
      return;
    }
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
        // [DLNA 投屏] 投屏中：解析当前曲并投到电视，本地引擎保持静默，
        // 队列/历史/统计等尾部逻辑与普通播放共用。
        if (_ref.read(dlnaCastProvider).isCasting) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          await _castFollowPlay(item, epoch);
          if (epoch != _playEpoch) return;
        } else if (item.isOnline) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          // 切歌即停上一首：在线解析（插件直链/探测，最长 12s+）期间
          // 不得让上一首继续出声，否则新歌封面/歌名已就位而旧歌还在响。
          try {
            await _player.stop();
          } catch (_) {}
          if (epoch != _playEpoch) return;
          await _playOnline(item);
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
        // QMC/AIFF 在独占管线（Rust symphonia + QMC 解密）内有原生支持，
        // 仍可 Bit-perfect 独占；APE/WV 无独占解码器，始终走转码缓存。
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
          // 普通模式默认走共享 DSP 管线（AAudio shared + 系统混音器），
          // 全效果链（EQ/混响/空间音效/变速变调/响度平衡）在 Rust 侧生效；
          // 失败（API<26/流创建失败等）自动回退 ExoPlayer。
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
      _reportBehavior(item, 'play', 0);
      _recordRecentPlay(item);
      _recordHistory(item);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
      // 本地歌曲通知栏封面兜底（异步，不阻塞起播）。
      unawaited(_resolveNotificationCover(item));
      // 预热队列后续歌曲封面，使切歌/封面动画时下一首封面多数已就绪。
      unawaited(Future(() => _preloadQueueCovers()));
    } catch (e) {
      // 队列已被清空/删空：放弃失败处理（换源/跳过/错误透出），不再改写 state。
      if (epoch != _playEpoch) {
        _shareLinkPlayback = false;
        return;
      }
      state = state.copyWith(isPlaying: false, resolving: false);
      // 新歌加载失败：先停掉正在响的上一首，避免「点了新歌没反应但旧歌还在响」。
      // 换源/跳过分支随后会自行重新起播，此处停止对它们无影响。
      try {
        await _stopExclusive();
      } catch (_) {}
      try {
        await _player.stop();
      } catch (_) {}
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
          // 批量标记该曲音源为失败：后续同源队列歌曲走 _playAt 顶部的快速跳过，
          // 不再逐首承受解析超时（对齐桌面端 knownFailedPluginPrefixes）。
          _markOnlineSourceFailed(item);
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
        final msg = e is PluginEngineException
            ? e.message
            : tr('播放失败：{e}', {'e': e.toString()});
        state = state.copyWith(error: msg);
        _showPlaybackToast(tr('在线播放失败：{e}', {'e': e.toString()}));
      } else {
        // 本地歌曲失败同样透出：静默失败会让用户以为「点击没反应」。
        AppLog.error('play', '本地播放失败 path=${item.path} error=$e');
        state = state.copyWith(
            error: e is PluginEngineException
                ? e.message
                : tr('本地播放失败：{e}', {'e': e.toString()}));
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
    AppLog.info('play', '[playOnline] ${item.title} path=${item.path} '
        'onlineSongJson=${json?.isNotEmpty ?? false}');
    if (json != null && json.isNotEmpty) {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final s0 = _ref.read(settingsProvider).valueOrNull;
      final fb0 = s0?.onlineQualityFallbackBehavior ?? 'lower';
      // 会话覆盖 > 设置的在线默认音质 > 歌曲自带档位（对齐桌面端
      // sessionQualityOverride > audio.onlineDefaultQuality；设置优先于歌曲预设）。
      final preferred = _sessionQualityOverride ??
          s0?.onlineDefaultQuality ??
          item.onlineQuality ??
          '320k';
      final candidates = _qualityCandidates(preferred, fb0);
      AppLog.info('play', '[playOnline] pluginId=${songJson['pluginId']} '
          'source=${songJson['source']} format=${songJson['format']} '
          'preferred=$preferred candidates=$candidates');

      // 共享探测：同歌一轮，起播优先、档位菜单/下载复用。
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.ensure(
          key, _buildResolveCallback(songJson, item));
      _activeProbeKey = key;

      // 探测整体限时：多档串行超时（每档 8-30s）会拖垮加载态，超时即放弃。
      final start = await probe
          .startBest(preferred, candidates)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      AppLog.info('play',
          '[playOnline] probe startBest result=${start == null ? 'NULL' : 'url=${start.url} q=${start.quality}'} '
          'available=${probe.availableQualities} probing=${probe.probing}');
      if (start != null) {
        // 直链已就绪，立即结束加载态；流的加载/缓冲由播放器内部处理。
        state = state.copyWith(resolving: false);
        await _startOnlineUrl(start.url, headers: start.headers, item: item);
        state = state.copyWith(currentQuality: start.quality);
        _refreshQualityMenuState(probe);
        unawaited(_prewarmOnlineSizes(item));
        return;
      }
      throw StateError(tr('直链解析失败'));
    }
    // onlineInfoJson：走 lxResolveUrl（在线搜索音源）。
    final url = await _resolveOnlineUrl(item);
    if (url == null) throw StateError(tr('无法获取播放链接'));
    state = state.copyWith(
      resolving: false,
      currentQuality: url.quality,
    );
    await _startOnlineUrl(url.url, headers: url.headers, item: item);
    unawaited(_prewarmOnlineSizes(item));
  }

  /// 切歌/起播后台预热（对齐桌面 ensureFooterQualityInfo）：
  /// 播放开始时在后台补齐当前在线歌各档位直链，并并行探测文件体积写入
  /// 全局按直链缓存，使稍后打开音质/下载弹窗时体积多数已在手，减少冷探测
  /// 延迟。不触碰菜单 UI 状态；失败时移除待办 key 以便后续重试。同一首歌只
  /// 预热一次（见 _prewarmKeys），避免重复起跑全档解析。
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
      final probe = onlineQualityProbeRegistry.peek(key);
      if (probe == null) {
        _prewarmKeys.remove(key);
        return;
      }
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      // 1) 声明档就后台解析（填充 probe.resolved 供 qualitySizes 读取）；
      //    无声明时探常用无损档 + 320k/128k 兜底档。
      final declared = await _declaredQualities(songJson);
      final targets = declared.isNotEmpty
          ? kQualityLadder.reversed.where(declared.contains).toList()
          : kQualityLadder.reversed
              .where((q) => isLosslessQuality(q) || q == '320k' || q == '128k')
              .toList();
      await Future.wait(targets.map(probe.probe).toList())
          .timeout(const Duration(seconds: 30));
      // 2) 读已解析直链并并行探体积，写入全局 _qualitySizeByUrl（按直链去重）。
      await qualitySizes();
    } catch (_) {
      // 预热失败不阻塞播放，移除 key 允许后续重试。
      _prewarmKeys.remove(key);
    }
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
    AppLog.debug('quality', '[quality] _declaredQualities pid=$pid result=$result');
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
      if (resolved == 'null' || resolved.isEmpty) {
        AppLog.warn('lx', '[lxResolve] 公共API $quality 无结果: $resolved');
        return null;
      }
      final url =
          (jsonDecode(resolved) as Map<String, dynamic>)['url'] as String?;
      if (!_isPlayableUrl(url)) {
        AppLog.warn('lx', '[lxResolve] 公共API $quality 非法直链: $url');
        return null;
      }
      AppLog.info('lx', '[lxResolve] 公共API $quality 命中');
      return ResolvedMediaUrl(url: url!);
    } catch (e) {
      AppLog.error('lx', '[lxResolve] 公共API $quality 异常: $e');
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
      _sessionQualityOverride = res.quality;
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

  /// 当前歌曲各已解析档位的实测体积：实际音质 → 体积信息。
  ///
  /// 对齐桌面端弹窗的「扩展名 · 体积」：复用共享探针已解析出的直链，
  /// 逐条做 Range 体积探测（Rust `probe_url_size`）；结果按直链缓存，
  /// 弹窗重复打开不重复请求。仅含已解析完成的档位，探测中的档位不出现在
  /// 返回值里，由 UI 以「未知体积」兜底。
  Future<Map<String, QualitySizeInfo>> qualitySizes() async {
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    if (item == null || json == null || json.isEmpty) return const {};
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.peek(key);
      if (probe == null) return const {};
      final entries = probe.resolved;
      if (entries.isEmpty) return const {};
      final out = <String, QualitySizeInfo>{};
      await Future.wait(entries.map((r) async {
        final cached = _qualitySizeByUrl[r.url];
        if (cached != null) {
          out[r.quality] = QualitySizeInfo(url: r.url, bytes: cached);
          return;
        }
        try {
          final raw = await probeUrlSize(url: r.url);
          final info = jsonDecode(raw);
          final size = info is Map<String, dynamic> ? info['size'] : null;
          if (size is num && size > 0) {
            if (_qualitySizeByUrl.length > 200) _qualitySizeByUrl.clear();
            _qualitySizeByUrl[r.url] = size.toInt();
            out[r.quality] = QualitySizeInfo(url: r.url, bytes: size.toInt());
          }
        } catch (_) {
          // 单条直链体积探测失败不影响其他档位（服务器不支持 Range 等）。
        }
      }));
      _dedupeSameSize(out);
      return out;
    } catch (e) {
      AppLog.debug('quality', '[quality] 体积探测失败: $e');
      return const {};
    }
  }

  /// 同体积去重：不同直链返回完全相同字节数时几乎必为同一音频文件
  /// （音源插件多档位回吐同一文件、仅 URL 签名参数不同的变体），
  /// 保留最低档标签，去掉更高档的「假体积」，避免菜单显示
  /// 「flac · 4.1MB」这类与实际文件不符的条目。
  void _dedupeSameSize(Map<String, QualitySizeInfo> out) {
    if (out.length < 2) return;
    final keys = out.keys.toList()
      ..sort((a, b) {
        final ra = kQualityLadder.indexOf(a);
        final rb = kQualityLadder.indexOf(b);
        return (ra < 0 ? 1 << 30 : ra).compareTo(rb < 0 ? 1 << 30 : rb);
      });
    final seenBytes = <int, String>{};
    for (final q in keys) {
      final bytes = out[q]!.bytes;
      final existing = seenBytes[bytes];
      if (existing == null) {
        seenBytes[bytes] = q;
      } else {
        // 同字节数：q 档位更高（升序遍历后到者），视为与已保留档同文件。
        out.remove(q);
      }
    }
  }

  Future<List<String>> _probeQualityOptions(
      {required bool forDownload}) async {
    final item = state.current;
    // 插件歌走 onlineSongJson，落雪在线搜索歌走 onlineInfoJson，二者都要支持。
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

      // 探测目标：优先用源声明的音质（对齐桌面 probeDownloadableQualities，
      // 插件只声明支持哪些档，探测声明之外无意义）；无声明时回退
      // 无损 + 320k（常用档）+ 128k 兜底档。
      final declared = await _declaredQualities(songJson);
      if (declared.isNotEmpty) {
        // 对齐桌面 getOnlineAvailableQualities：菜单直接展示源声明音质，
        // 探测仅作后台校验/降级修正，不再阻塞菜单展示（避免探测慢/挂起导致空态）。
        final base = kQualityLadder.reversed.where(declared.contains).toList();
        AppLog.debug('quality', '[quality] declared non-empty base=$base');
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
      AppLog.debug('quality', '[quality] declared empty, probing targets=$targets');
      await Future.wait(targets.map(probe.probe).toList());

      final opts = <String>{...probe.availableQualities};
      if (state.currentQuality != null) opts.add(state.currentQuality!);
      final ordered =
          kQualityLadder.reversed.where(opts.contains).toList();
      AppLog.info('quality', '[quality] probe done opts=$ordered');
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

  /// 后台探测可用档位：成功档位并入 [base]，供切换/下载复用。
  /// 探测失败/超时不影响已展示的声明音质。
  Future<void> _probeInBackground(
    SongQualityProbe probe,
    List<String> targets,
    List<String> base,
  ) async {
    try {
      // Baka 插件「信任模式」快径（对齐桌面 probeDownloadableQualities）：声明档位
      // 值得信任时只实测最高档一次——若最高档在实际档与请求档一致（未降级），声明档
      // 即全部视为可用，不再逐档串行发 track_v2 网络请求。既大幅缩短起播/菜单耗时，
      // 又保住完整 12 档菜单，避免逐档探测慢导致菜单残缺。最高档被降级时回退逐档。
      if (await _tryBakaTrustProbe(probe, targets, base)) {
        state = state.copyWith(
          availableQualities: probe.availableQualities,
          qualityMenuProbing: false,
        );
        return;
      }

      // 区分在线源类型：Baka 插件 reported 原生键可信，逐档实测塌缩到真实档；
      // LX 在线（无 pluginId）reported 键同样可信，维持逐档实测；MF 插件走分组。
      if (await _currentIsPluginSong()) {
        // MF 插件：reported 是四级键语义（super 档同时服务全部无损档），逐档实测
        // 会因 reported 档低于请求档把声明档整体塌缩成实际档（如 hires→flac），
        // 造成「音质探测不全」。对齐桌面 runPluginGetMusicInfo 的 tryPairs 代表档
        // 语义 + 「声明档为 UI 展示与回退上界」：按四级键分组，每组只实测代表档
        // （组内最高档）一次，组任一成功 → 组内全部声明档保留，组失败 → 整组移除。
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
              // 组成功：整组声明档信任为可用（写回探针保持各消费方一致）。
              probe.trustDeclared(grp);
            }
          } catch (_) {
            // 组失败：整组声明档不信任，菜单自动去除该组。
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
      state = state.copyWith(
        availableQualities: ordered,
        qualityMenuProbing: false,
      );
    } catch (_) {
      state = state.copyWith(qualityMenuProbing: false);
    }
  }

  /// 当前歌曲是否 MusicFree 插件在线曲（区别于 LX 在线与本地）。
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

  /// Baka 信任模式探测：只实测声明中的最高档，未降级即信任全部声明档位。
  /// 非 Baka 插件 / 无声明 / 最高档失败或被降级时返回 false，交由逐档探测。
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

    // 只探测声明中的最高档（对齐桌面取声明档位上限作快径）。
    final top = targets.reduce((a, b) =>
        kQualityLadder.indexOf(a) > kQualityLadder.indexOf(b) ? a : b);
    final res = await probe.probe(top).timeout(const Duration(seconds: 10));
    if (res == null || res.url.isEmpty) return false;
    if (res.quality != top) {
      // 最高档被降级（如咪咕把 hires/atmos 全降为 flac24bit）：不信任声明，
      // 回退逐档让各档塌缩到真实档位，避免菜单虚高档位。
      AppLog.info('quality', '[quality] Baka 最高档 $top 实际返回 ${res.quality}，回退逐档实测');
      return false;
    }
    // 未降级：信任声明档位，直接以声明列表作为可用档位（完整 12 档保留）。
    // 写回探针而非 state，使 _refreshQualityMenuState/切换等后续读取一致，避免被覆盖。
    probe.trustDeclared(base);
    final ordered = probe.availableQualities;
    AppLog.info('quality', '[quality] Baka 信任模式命中，声明档全量可用 $ordered');
    return true;
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

  /// ExoPlayer 不支持的格式：APE/WV/AIFF 需转码为 WAV 缓存，
  /// QMC 加密（mflac/mgg/qmc* 等）需解密为内部格式，播放前先走转码缓存。
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

  /// 独占管线（Rust AAudio + symphonia / QMC 解密）原生支持的格式：
  /// DSD / AIFF / QMC 加密文件可直接独占直出；APE/WV 不在其中。
  static bool _isNativeExclusiveFormat(String path) {
    final lower = path.toLowerCase();
    if (_isDsdPath(lower)) return true;
    if (lower.endsWith('.aif') || lower.endsWith('.aiff')) return true;
    return const [
      '.mgg', '.mgg0', '.mggl', '.mflac', '.mflac0',
      '.qmc0', '.qmc2', '.qmc3', '.qmcflac', '.qmcogg',
    ].any(lower.endsWith);
  }

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

  /// WebDAV 远程歌曲：缓存命中则本地播放，否则带 Basic Auth 流式播放。
  /// 远程 DSD 强制走 USB 独占 DoP 管线；APE/WV 先转码为 WAV 缓存。
  Future<void> _playRemote(QueueItem item) async {
    final service = RemoteLibraryService(_ref);

    // 远程 DSD：ExoPlayer 无 DSD 解码，与本地 DSD 一致走 USB 独占 DoP 直出。
    // 先整文件下载进远程缓存，再把缓存路径交给独占管线。
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

    // APE/WV：转码为 WAV 后按本地文件播放（远程源自动先下载进缓存）。
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

  /// WebDAV 下一首预缓存（对齐桌面端）：当前远程歌曲进度过 60% 时，
  /// 预下载队列下一首的远程文件。顺序/列表循环取 index+1；随机模式仅在
  /// 已压入 _shuffleFuture 时可预知；单曲循环无下一首。
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
    if (clean.isEmpty) throw StateError(tr('无效的播放链接'));
    // 合并插件 headers 与按域名补齐的防盗链头（Referer/Origin/Accept）。
    final h = normalizeMediaRequestHeaders(clean, headers);
    await _player.setUrl(clean, headers: h);
    await _player.setVolume(_ref.read(volumeProvider));
    await _player.play();
  }

  /// 在线直链专用起播：加载完成后校验实际时长与搜索元数据声明时长。
  ///
  /// 部分失效直链会返回 200 但内容为空/极短（防盗链页、CDN 下架后的兜底音频），
  /// ExoPlayer 能正常加载甚至"播完"，但全程无声——用户看到的是"进度条在走
  /// 却没声音"。与声明时长严重不符（实际 <5s 且声明 ≥30s）时抛错，走统一的
  /// 换源/跳过/报错失败路径，而不是静默播一段空音频。
  Future<void> _startOnlineUrl(
    String url, {
    Map<String, String>? headers,
    required QueueItem item,
  }) async {
    final clean = sanitizeMediaUrl(url);
    if (clean.isEmpty) throw StateError(tr('无效的播放链接'));
    final h = normalizeMediaRequestHeaders(clean, headers);
    await _player.setUrl(clean, headers: h);
    final declaredMs = item.durationMs;
    final actualMs = _player.duration?.inMilliseconds ?? 0;
    if (declaredMs >= 30000 && actualMs > 0 && actualMs < 5000) {
      AppLog.warn('play', '[startOnlineUrl] 直链实际时长异常 '
          'declared=${declaredMs}ms actual=${actualMs}ms url=$clean');
      throw StateError(tr('直链已失效（返回内容与歌曲不符）'));
    }
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
        // 首页「统计」卡片与「常听排行」读取的都是数据库，落库后需使其重新求值，
        // 否则播放再久，界面上的统计数据都停留在首次加载的值。
        _ref.invalidate(listenStatsProvider);
        _ref.invalidate(mostPlayedProvider);
      } catch (e) {
        debugPrint('[stats] record_play 失败: $e');
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
        await _startOnlineUrl(url.url, headers: url.headers, item: newItem);
      } catch (_) {
        _failedSources.add(src.id);
        continue;
      }
      _skipDepth = 0;
      state = state.copyWith(resolving: false, error: null);
      // 换源成功等同于一次全新起播：重置首播计数并记录最近播放/历史，
      // 否则换源曲目不进最近播放、播放次数也会漏记。
      _currentPlayCountRecorded = false;
      _accumulatedTime = 0;
      _recordRecentPlay(newItem);
      _recordHistory(newItem);
      _reportBehavior(newItem, 'play', 0);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
      _showPlaybackToast(tr('已自动切换到 {source} 音源', {'source': src.label}));
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
      if (source.isEmpty) {
        debugPrint('[playPlugin] store 中无插件 $pluginId（source=$sourceKey）');
        return null;
      }

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
      if (result == null) {
        debugPrint('[playPlugin] ${source.first.name} '
            'musicUrl($sourceKey/$quality) 返回空');
        return null;
      }
      final url = result['url'] as String?;
      if (!_isPlayableUrl(url)) {
        debugPrint('[playPlugin] ${source.first.name} '
            'musicUrl($sourceKey/$quality) 非法直链: $url');
        return null;
      }
      final h = result['headers'];
      // 采用插件实际返回的 type（可能被静默降级）作为报告音质，对齐桌面端
      // `reportedQuality = musicInfo?.actualQuality ?? q`：请求 flac 但插件仅
      // 解锁到 320k 时，用它避免 UI 虚高显示无损（音质与体积对不上的「假音质」）。
      final reportedRaw = result['type'];
      final reportedQuality = reportedRaw is String
          ? PluginEngine.normalizeQualityKey(reportedRaw)
          : null;
      debugPrint('[playPlugin] ${source.first.name} '
          'musicUrl($sourceKey/$quality) 命中 type=${result['type']} '
          'reported=${reportedQuality ?? quality}');
      return ResolvedMediaUrl(
        url: url!,
        headers: h is Map ? h.cast<String, String>() : null,
        quality: reportedQuality ?? quality,
      );
    } catch (e) {
      debugPrint('[playPlugin] 解析异常($quality): $e');
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
        // 在线歌曲（lx://、plugin://）不在本地曲库中，历史只存路径无法反查。
        // 对齐桌面端：把完整元数据写入持久化池，最近播放列表据此还原展示。
        if (item.isOnline) {
          await _ref.read(onlineMetaStoreProvider).put(item);
        }
        // 使最近播放角标/列表实时刷新：invalidate 在下次 watch 时让 provider
        // 重建并从 DB 重读（对齐首页统计的实时刷新模式），否则要等重启后
        // RecentManager 构造时 refresh 才会更新。
        _ref.invalidate(recentProvider);
      } catch (e) {
        debugPrint('[stats] 最近播放写入失败: $e');
      }
    });
  }

  /// 从队列移除指定歌曲（当前播放曲移除后自动切下一首）。
  Future<void> removeFromQueue(int index) async {
    final queue = [...state.queue];
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == state.queueIndex;
    queue.removeAt(index);
    if (queue.isEmpty) {
      // 队列删空等同重置：递增代际号让在途起播放弃，防止复活。
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

  /// 清空播放队列并停止播放（对齐桌面端 clearQueue）。
  ///
  /// 停掉独占/普通两条播放管线、失效共享探针、清空当前曲——
  /// 播放详情页/迷你条随 current 为空自动收起，用于从「无法加载的坏歌」中脱身。
  Future<void> clearQueue() async {
    // 先递增代际号：让所有在途起播流水线在下一个 await 边界放弃。
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
    // [DLNA 投屏] 投屏中：播放/暂停遥控电视而非本地引擎。
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
    // DSP 管线（独占/共享）：seek(pos, isPlaying) 即暂停/恢复。
    if (state.usbExclusive || state.dspActive) {
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
    // [DLNA 投屏] 投屏中：进度条拖动遥控电视端 seek。
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
    // 控制中心右侧「播放顺序」图标需要随模式刷新。
    _syncToSystemMediaSession();
  }

  /// 播放错误提示（对齐桌面 showToast）。
  ///
  /// 播放链路常跨 async 间隙运行，无稳定页面 context，因此用 root Overlay 展示
  ///（appNavigatorKey.currentState.overlay），后台播放/切歌期间同样生效。
  void _showPlaybackToast(String message) {
    final overlay = appNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    showXianYuToastByOverlay(overlay, message);
  }

  /// 播放器中途错误（playbackEventStream onError）统一处理。
  ///
  /// 换源/切歌期间主动 stop/setUrl 一般不产生错误事件；真实错误（直链中途
  /// 失效、网络断、解码失败）到达时：先把 isPlaying 拉回真实值，在线歌尝试
  /// 自动换源（_autoSwitchSource 自带按 title|artist 隔离的失败源防环），
  /// 换源失败透出错误。切歌后到达的旧源错误直接丢弃。
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
        final switched = await _autoSwitchSource(item);
        if (switched) return;
        // 换源不可用/失败：透出错误并保持暂停，交由用户决定（重试/跳过）。
        if (state.current?.path != item.path) return;
        state = state.copyWith(
          error: tr('播放失败：{e}', {'e': e.toString()}),
          isPlaying: false,
        );
        _showPlaybackToast(tr('在线播放失败，已自动换源无果，请重试或更换音源'));
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

  /// 在线流异常完成（实际时长远短于声明时长）的失败路由：
  /// 换源 → 按在线失败行为跳过 → 停止并透出错误。对齐 _playAt 的 catch 分支。
  Future<void> _handleBrokenOnlineStream(QueueItem item) async {
    if (_playbackErrorHandling) return;
    _playbackErrorHandling = true;
    try {
      state = state.copyWith(isPlaying: false, resolving: true);
      final switched = await _autoSwitchSource(item);
      if (switched) return;
      if (state.current?.path != item.path) return;
      final behavior = _ref
              .read(settingsProvider)
              .valueOrNull
              ?.onlineFailureBehavior ??
          'skip';
      if (behavior == 'skip') {
        // 批量标记该曲音源为失败（对齐桌面端 knownFailedPluginPrefixes）。
        _markOnlineSourceFailed(item);
        _skipDepth++;
        final next = _pickNextIndex();
        if (next >= 0 && next != state.queueIndex) {
          await _playAt(next);
          return;
        }
      }
      state = state.copyWith(
        error: tr('在线音源已失效，未能自动换源'),
        isPlaying: false,
        resolving: false,
      );
      _showPlaybackToast(tr('在线音源已失效，未能自动换源'));
      _syncToSystemMediaSession();
    } finally {
      _playbackErrorHandling = false;
    }
  }

  /// 进度停滞/超限兜底检测（对齐桌面端 playbackTiming.evaluateStallAutoNext）：
  /// - 进度超限：position 已到 duration 末端 0.3s 内仍未收到 completed → 自动衔接；
  /// - 进度停滞：position 连续多轮（本地≈2s/在线≈6s，在线放宽以容忍缓冲）
  ///   不前进，且已接近末尾（差 ≤3s）或时长未知 → 判定自然播完，自动衔接。
  /// 独占/DSP 管线有自己的 250ms 轮询结束检测（_pollExclusive），此处跳过。
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
    // 进度推进/回退 ≥0.05s（或刚起播）视为正常，清零停滞计数。
    if (pos <= 0 || _stallLastPos < 0 || (pos - _stallLastPos).abs() >= 0.05) {
      _stallLastPos = pos;
      _stallTicks = 0;
    } else {
      _stallTicks++;
    }
    final dur = state.duration;
    // 进度超限兜底：到点未收到 completed（结束事件丢失/播放器静默死亡）。
    if (dur > 0 && pos >= dur - 0.3) {
      _resetStallTracking();
      AppLog.warn('play',
          '[stall] 进度到达末尾未收到 completed，兜底切歌 pos=$pos dur=$dur');
      unawaited(_onTrackEnd());
      return;
    }
    // 停滞兜底：中段缓冲因「远离末尾」不触发，只有近末尾/未知时长才判定结束。
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

  /// 在线歌曲的音源批量标记 key：插件歌取 pluginId（对齐桌面 `plugin://<id>/` 前缀），
  /// 落雪音源歌取 source（kw/kg/tx/wy…）。无法识别返回 null（不参与批量标记）。
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
    // [在线流异常完成] 失效直链可能返回极短/空音频：ExoPlayer 正常走到
    // completed，但实际时长与搜索元数据声明时长严重不符（几秒"播完"一首
    // 几分钟的歌、全程无声）。这不算自然播完——否则会立刻跳到队列下一首，
    // 混排队列里表现就是"拉一下时间轴跳去播放本地音乐"。按起播失败处理：
    // 先尝试换源，再按在线失败行为（跳过/停止）兜底。
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
            error: tr('无法获取播放链接'),
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
        error: tr('在线播放失败'),
      );
      _syncToSystemMediaSession();
    }
  }

  // ---------------- DLNA 投屏支持 ----------------

  /// DLNA 连接/投屏开始时静默本地引擎（不经 cast 门控，直接暂停本地播放器）。
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

  /// DLNA 投屏进度回填（castProvider 1s 轮询驱动）：本地引擎静默期间
  /// 播放页/播放条进度以电视实测为准。
  void syncCastPosition(double pos, double dur, bool playing) {
    if (state.current == null) return;
    state = state.copyWith(
      position: pos < 0 ? 0 : pos,
      // 电视端实测时长回填（部分在线歌 duration 声明缺失/为 0）。
      duration: dur > 0.5 ? dur : null,
      isPlaying: playing,
    );
  }

  /// DMR 接收：他端投放的 http(s) 直链本地起播。
  ///
  /// 建临时 QueueItem 展示（不记历史/不计统计），走插件同款
  /// `_startUrl` 直链流式缓存分支（天然兼容防盗链头补齐）。
  Future<void> playExternalUri({
    required String uri,
    required String title,
    String artist = '',
    String album = '',
    int durationMs = 0,
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
      await _startUrl(uri);
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

  /// DLNA 投屏媒体解析：在线→直链+防盗链头；远程→缓存/直链；本地→SAF 物化。
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
            .timeout(const Duration(seconds: 12), onTimeout: () => null);
        if (start == null) return null;
        final clean = sanitizeMediaUrl(start.url);
        if (clean.isEmpty) return null;
        return CastMediaResolution(
          url: clean,
          headers:
              normalizeMediaRequestHeaders(clean, start.headers) ?? const {},
          isRemote: true,
        );
      }
      final url = await _resolveOnlineUrl(item);
      if (url == null) return null;
      final clean = sanitizeMediaUrl(url.url);
      if (clean.isEmpty) return null;
      return CastMediaResolution(
        url: clean,
        headers:
            normalizeMediaRequestHeaders(clean, url.headers) ?? const {},
        isRemote: true,
      );
    }
    if (_isRemotePath(item.path)) {
      // 远程库：优先已缓存文件（投本地 token）；未缓存投远程直链（带认证头）。
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
    // 本地文件：SAF content:// 先物化为真实路径（与普通播放同源）。
    var target = item.path;
    if (SafChannel.isSafPath(target)) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          target, p.join(tmp.path, 'saf_playback'));
    }
    if (!File(target).existsSync()) return null;
    return CastMediaResolution(url: target, headers: const {}, isRemote: false);
  }

  /// 投屏中起播（_playAt cast 分支）：解析→投递→置播放态。
  Future<void> _castFollowPlay(QueueItem item, int epoch) async {
    state = state.copyWith(resolving: item.isOnline);
    final media = await resolveForCast(item);
    if (epoch != _playEpoch) return;
    if (media == null) throw StateError(tr('无法获取播放链接'));
    try {
      await _player.stop();
    } catch (_) {}
    await _ref.read(dlnaCastProvider.notifier).castMedia(
          title: item.title,
          artist: item.artist,
          album: item.album,
          url: media.url,
          isRemote: media.isRemote,
          headers: media.headers,
          durationMs: item.durationMs,
          coverUrl: item.coverUrl,
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
    try {
      stopUsbExclusivePlayback();
    } catch (_) {}
    _player.dispose();
    super.dispose();
  }
}

/// DLNA 投屏媒体解析结果：远程直链（含防盗链头）或本地文件路径。
class CastMediaResolution {
  final String url;
  final Map<String, String> headers;

  /// true = 远程直链（走 token 代理）；false = 本地文件路径。
  final bool isRemote;
  const CastMediaResolution({
    required this.url,
    required this.headers,
    required this.isRemote,
  });
}

/// 音量（与设置联动）。
final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ?? 1.0;
});

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>(
  (ref) => PlayerNotifier(ref),
);
