import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as as_pkg;
import 'package:crypto/crypto.dart';
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
import '../playlist/playlist_provider.dart';
import '../recent/recent_provider.dart';
import '../remote/remote_library_service.dart';
import '../rust/api.dart';
import '../widgets/app_toast.dart';
import '../widgets/cover_image.dart';
import '../navigation/routes.dart';
import 'mv_auto_sync.dart';
import 'audio_head_cache.dart';
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
    _init();
  }

  final Ref _ref;
  final AudioPlayer _player = _GatedAudioPlayer();
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
  bool _dspAvailable = true;
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

  Future<void> _init() async {
    _posSub = _player.positionStream.listen((p) {
      final pos = p.inMilliseconds / 1000.0;
      state = state.copyWith(position: pos);
      _persistPositionDebounced();
      _maybePrecacheNextRemote(pos);
    });
    _durSub = _player.durationStream.listen((d) {
      final dur = (d ?? Duration.zero).inMilliseconds / 1000.0;
      state = state.copyWith(duration: dur);
      _syncToSystemMediaSession();
    });
    AudioSession.instance.then((session) {
      _interruptionSub = session.interruptionEventStream.listen((event) async {
        if (!event.begin) {
          if (_interruptedByInterruption) {
            _interruptedByInterruption = false;
            await _player.play();
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
          await _player.pause();
        }
      });
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      final playing = ps.playing;
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
          setUsbExclusiveVolume(volume: v);
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
        volume: _ref.read(volumeProvider),
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
  }) async {
    if (!_dspAvailable) return false;
    if (_dspSkipNextStart) {
      _dspSkipNextStart = false;
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
      AppLogger.instance.log('dsp', '共享 DSP 管线已接管播放: $deviceName');
      return true;
    } catch (e) {
      state = state.copyWith(dspActive: false);
      final msg = e.toString();
      if (msg.contains('libaaudio')) {
        _dspAvailable = false;
      }
      AppLogger.instance.log('dsp', '共享 DSP 管线启动失败，回退 ExoPlayer: $e');
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
      audioHandler?.syncPlaybackState(
        isPlaying: state.isPlaying,
        positionSecs: state.position,
        durationSecs: state.duration,
        isFavorite: _ref.read(favoritesProvider).contains(cur.path),
        playMode: state.playMode,
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
        } else if (SafChannel.isSafPath(currentItem.path)) {
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
            if (_isTranscodePath(path)) {
              try {
                path =
                    (await RemoteLibraryService(_ref).transcodeToWav(path)).path;
                await _updateRgGain(path);
              } catch (e) {
                AppLogger.instance.log('session', '转码预载失败: $e');
              }
            }
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
      AppLog.info('session',
          'restored queue=${queue.length} cur="${currentItem.title}" '
          'pos=${pos.toStringAsFixed(1)} online=${currentItem.isOnline}');
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
        AppLog.debug('session',
            'position saved cur=${current.title} pos=${pos.toStringAsFixed(1)} '
            'playing=$isPlaying online=${current.isOnline}');
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

  Future<void> _playAt(int index, {double startAtSecs = 0}) async {
    if (index < 0 || index >= state.queue.length) return;
    _playEpoch++;
    final epoch = _playEpoch;

    AppLog.info('play', '_playAt index=$index path=${state.queue[index].path}');
    unawaited(_ensureNotificationPermission());
    _flushPlayStats();
    _currentPlayCountRecorded = false;
    _accumulatedTime = 0;

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
    _precacheNextCover();
    try {
        if (_ref.read(dlnaCastProvider).isCasting) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
          await _castFollowPlay(item, epoch);
          if (epoch != _playEpoch) return;
        } else if (item.isOnline) {
          await _stopExclusive();
          if (epoch != _playEpoch) return;
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
        var target = item.path;
        if (SafChannel.isSafPath(target)) {
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
      _reportBehavior(item, 'play', 0);
      _recordRecentPlay(item);
      _recordHistory(item);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
      unawaited(Future(() => _preloadQueueCovers()));
    } catch (e) {
      if (epoch != _playEpoch) {
        _shareLinkPlayback = false;
        return;
      }
      state = state.copyWith(isPlaying: false, resolving: false);
      try {
        await _stopExclusive();
      } catch (_) {}
      try {
        await _player.stop();
      } catch (_) {}
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

  Future<void> _playOnline(QueueItem item) async {
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
        await _startOnlineUrl(start.url,
            headers: start.headers, item: item, ekey: start.ekey);
        state = state.copyWith(currentQuality: start.quality);
        _refreshQualityMenuState(probe);
        unawaited(_prewarmOnlineSizes(item));
        return;
      }
      throw StateError(tr('直链解析失败'));
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
            headers: url.headers, ekey: url.ekey);
      } catch (_) {
      }
    }
    state = state.copyWith(
      resolving: false,
      currentQuality: url.quality,
    );
    await _startOnlineUrl(url.url,
        headers: url.headers, item: item, ekey: url.ekey);
    unawaited(_prewarmOnlineSizes(item));
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

  double _effectiveVolume() =>
      (_ref.read(volumeProvider) * _effectiveBalanceGain()).clamp(0.0, 4.0);

  double _effectiveBalanceGain() {
    final s = _ref.read(settingsProvider).valueOrNull;
    return (s?.volumeBalanceEnabled ?? false) ? _rgGain : 1.0;
  }

  Future<Duration?> _setLocalSource(String path) async {
    var target = path;
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

  Future<void> _startUrl(String url, {Map<String, String>? headers}) async {
    final clean = sanitizeMediaUrl(url);
    if (clean.isEmpty) throw StateError(tr('无效的播放链接'));
    final h = normalizeMediaRequestHeaders(clean, headers);
    await AudioProxyServer.instance.ensureStarted();
    AudioHeadCache.instance.registerHeaders(clean, h);
    final playUrl = AudioProxyServer.instance.playUrlFor(clean);
    await _player.setUrl(playUrl, headers: h);
    await _player.setVolume(_ref.read(volumeProvider));
    await _player.play();
  }

  Future<void> _startOnlineUrl(
    String url, {
    Map<String, String>? headers,
    required QueueItem item,
    String? ekey,
  }) async {
    final clean = sanitizeMediaUrl(url);
    if (clean.isEmpty) throw StateError(tr('无效的播放链接'));
    final h = await withBilibiliStreamCookie(
      clean,
      normalizeMediaRequestHeaders(clean, headers),
      dataDir: _ref.read(appDataDirProvider.future),
    );
    if (ekey != null && ekey.isNotEmpty) {
      await _startEncryptedFile(clean, h, item, ekey);
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
      final ok = await _tryStartDspPipeline(proxyUrl,
          startAtSecs: 0, isPlaying: true);
      if (ok) {
        _triggerOnlinePrecache(item);
        return;
      }
    }
    final playUrl = AudioProxyServer.instance.playUrlFor(clean);
    await _player.setUrl(playUrl, headers: h);
    final declaredMs = item.durationMs;
    final actualMs = _player.duration?.inMilliseconds ?? 0;
    if (declaredMs >= 30000 && actualMs > 0 && actualMs < 5000) {
      AppLog.warn('play', '[startOnlineUrl] 直链实际时长异常 '
          'declared=${declaredMs}ms actual=${actualMs}ms url=$clean');
      throw StateError(tr('直链已失效（返回内容与歌曲不符）'));
    }
    await _player.setVolume(_ref.read(volumeProvider));
    await _player.play();
    _triggerOnlinePrecache(item);
  }

  Future<void> _startEncryptedFile(
    String url,
    Map<String, String>? headers,
    QueueItem item,
    String ekey,
  ) async {
    try {
      await _player.stop();
    } catch (_) {}
    final plainPath = await _decryptUrlToTemp(url, headers, ekey);
    await _player.setFilePath(plainPath);
    await _player.setVolume(_ref.read(volumeProvider));
    await _player.play();
    _triggerOnlinePrecache(item);
  }

  static const int _decryptCacheMax = 48;
  final Map<String, String> _decryptPathCache = {};

  Future<String> _decryptUrlToTemp(
    String url,
    Map<String, String>? headers,
    String ekey,
  ) async {
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
      ekey: ekey,
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
    if ((settings?.onlineFailureBehavior ?? 'stop') != 'autoswitch' &&
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
        } catch (_) {}
      }
      curKey = lxSourceKeyForPlatform(label);
    }
    if (curKey.isEmpty) return false;
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
            headers: url.headers, item: newItem, ekey: url.ekey);
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

      hit = await _resolveViaSiblingPlugin(
        failedId: pluginId,
        format: format,
        sourceKey: sourceKey,
        musicInfo: musicInfo,
        quality: preferred,
        itemPath: item.path,
        engine: engine,
      );

      if (hit == null) {
        final sources = await engine.store.loadSources();
        final healed = await _crossFormatHeal(
            pluginId, format, sourceKey, musicInfo, sources, engine);
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
          headers: hit.headers, item: item, ekey: hit.ekey);
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
      if (source.isEmpty) {
        final healed =
            _findHealedPlugin(sources, format, sourceKey, musicInfo);
        if (healed == null) {
          final healedCross =
              await _crossFormatHeal(pluginId, format, sourceKey, musicInfo, sources, engine);
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
          if (itemPath.isNotEmpty) {
            unawaited(_ref
                .read(playlistManagerProvider.notifier)
                .healSongPluginFull(
                  itemPath,
                  pluginId: healedCross.$1.id,
                  source: newSource,
                  format: newFormat,
                  musicInfo: newMusicInfo,
                ));
          }
        } else {
          source = [healed];
          if (itemPath.isNotEmpty) {
            unawaited(_ref
                .read(playlistManagerProvider.notifier)
                .healSongPlugin(itemPath, healed.id));
          }
        }
      }

      ResolvedMediaUrl? resolved;
      if (isMfFormatValue(format)) {
        resolved = await engine.getMusicFreeUrl(
          source.first,
          musicInfo,
          preferred: quality,
          fallback: 'pause',
        );
      } else {
        final result = await engine.getMusicUrl(
            source.first, sourceKey, musicInfo, quality);
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
      return await _resolveViaSiblingPlugin(
        failedId: source.first.id,
        format: format,
        sourceKey: sourceKey,
        musicInfo: musicInfo,
        quality: quality,
        itemPath: itemPath,
        engine: engine,
      );
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

  Future<ResolvedMediaUrl?> _resolveViaSiblingPlugin({
    required String failedId,
    required String format,
    required String sourceKey,
    required Map<String, dynamic> musicInfo,
    required String quality,
    required String itemPath,
    required PluginEngine engine,
  }) async {
    try {
      final pluginFormat = PluginFormat.fromValue(format);
      final platformLabel =
          _songPlatformLabel(format, sourceKey, musicInfo);
      final sources = await engine.store.loadSources();
      final candidates = listEnabledPluginsForPlatform(
        platformLabel: platformLabel,
        installedPlugins: sources,
        format: pluginFormat,
        excludeId: failedId,
      ).take(3);
      for (final plugin in candidates) {
        final ResolvedMediaUrl? hit;
        if (plugin.format.isMfCompatible) {
          hit = await engine.getMusicFreeUrl(
            plugin,
            musicInfo,
            preferred: quality,
            fallback: 'pause',
          );
        } else {
          final lxKey = lxSourceKeyForPlatform(platformLabel);
          final lxSupported =
              plugin.sources.isEmpty || plugin.sources.contains(lxKey);
          if (lxKey.isEmpty || !lxSupported) {
            continue;
          }
          final result =
              await engine.getMusicUrl(plugin, lxKey, musicInfo, quality);
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
        if (itemPath.isNotEmpty) {
          unawaited(_ref
              .read(playlistManagerProvider.notifier)
              .healSongPlugin(itemPath, plugin.id));
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
    Map<String, dynamic> musicInfo,
  ) {
    final pluginFormat = PluginFormat.fromValue(format);
    final platform = _songPlatformLabel(format, sourceKey, musicInfo);
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
    PluginEngine engine,
  ) async {
    final pluginFormat = PluginFormat.fromValue(format);
    final platformLabel = _songPlatformLabel(format, sourceKey, musicInfo);
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
      _lastUserPauseAt = DateTime.now();
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
