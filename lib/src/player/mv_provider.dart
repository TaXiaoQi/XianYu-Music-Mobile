library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/application_logger.dart';
import '../core/settings.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import 'audio_proxy_server.dart';
import 'mv_auto_sync.dart';
import 'mv_host_fallback.dart';
import 'mv_source.dart';
import 'player_provider.dart';

String normalizeMvQuality(String q) {
  final t = q.trim();
  if (t.isEmpty) return '';
  if (t.toLowerCase() == '4k') return '4K';
  return t.toUpperCase();
}

const _kMvIdKeys = [
  'mv',
  'mvHash',
  'mvdata',
  'mvVid',
  'mvId',
  'vid',
  'vid_hash',
  'vhash',
  'bvid',
  'aid',
  'cid',
  'id',
  'songmid',
  'mvid',
  'mid',
  'hash',
];

final Map<String, bool> _mvProbeResult = {};

String _mvProbeKey(QueueItem c) {
  try {
    final raw = jsonDecode(c.onlineSongJson ?? '');
    if (raw is! Map) return '';
    final pluginId = raw['pluginId']?.toString() ?? '';
    final songId = _songIdentity(c);
    if (pluginId.isEmpty || songId.isEmpty) return '';
    return '$pluginId|$songId';
  } catch (_) {
    return '';
  }
}

bool _hasMvIdentityHint(QueueItem c) {
  try {
    final song = mvSongOf(c);
    for (final key in _kMvIdKeys) {
      final v = song[key];
      if (v == null) continue;
      final s = v is String ? v.trim() : v.toString();
      if (s.isNotEmpty &&
          s != '0' &&
          s.toLowerCase() != 'false' &&
          s.toLowerCase() != 'null') {
        return true;
      }
    }
  } catch (_) {
    /* 解析失败按默认值处理 */
  }
  return false;
}

bool mvSupports(QueueItem? c) {
  if (c == null) return false;
  final key = _mvProbeKey(c);
  if (key.isNotEmpty && _mvProbeResult.containsKey(key)) {
    return _mvProbeResult[key]!;
  }
  return _hasMvIdentityHint(c);
}

Map<String, dynamic> mvSongOf(QueueItem c) {
  final js = c.onlineSongJson;
  if (js != null && js.isNotEmpty) {
    try {
      final raw = jsonDecode(js) as Map<String, dynamic>;
      if ((raw['format'] == 'musicfree' || raw['format'] == 'anime') &&
          raw['musicInfo'] is Map) {
        final song = Map<String, dynamic>.from(raw['musicInfo'] as Map);
        final rawMap = song['rawData'];
        if (rawMap is Map) {
          for (final k in const ['mv', 'mvVid', 'mvId', 'vid']) {
            if (rawMap[k] != null && song[k] == null) song[k] = rawMap[k];
          }
        }
        if (raw['pluginId'] != null) {
          song['pluginId'] = raw['pluginId'];
        }
        final plugin = raw['plugin'];
        if (plugin != null) {
          song['plugin'] = plugin;
        }
        return song;
      }
      return raw;
    } catch (_) {
      /* 解析失败按默认值处理 */
    }
  }
  return {
    'source': c.source,
    'path': c.path,
    'title': c.title,
    'artist': c.artist,
  };
}

class MvState {
  final bool requested;

  final bool ready;

  final bool loading;

  final MvSource? source;

  final VideoPlayerController? controller;

  final String phase;

  final int bufferedSec;

  final bool audioTakenOver;

  const MvState({
    this.requested = false,
    this.ready = false,
    this.loading = false,
    this.source,
    this.controller,
    this.phase = '',
    this.bufferedSec = 0,
    this.audioTakenOver = false,
  });

  bool get active => requested;

  MvState copyWith({String? phase, int? bufferedSec, bool? audioTakenOver}) =>
      MvState(
        requested: requested,
        ready: ready,
        loading: loading,
        source: source,
        controller: controller,
        phase: phase ?? this.phase,
        bufferedSec: bufferedSec ?? this.bufferedSec,
        audioTakenOver: audioTakenOver ?? this.audioTakenOver,
      );

  MvState refresh() => MvState(
    requested: requested,
    ready: ready,
    loading: loading,
    source: source,
    controller: controller,
    phase: phase,
    bufferedSec: bufferedSec,
    audioTakenOver: audioTakenOver,
  );
}

String _songIdentity(QueueItem? c) {
  if (c == null) return '';
  final song = mvSongOf(c);
  final buf = <String>[];
  for (final k in _kMvIdKeys) {
    final v = song[k];
    if (_isValidIdValue(v)) {
      buf.add('$k=$v');
      break;
    }
  }
  buf.add('${c.title}|${c.artist}');
  return buf.join('&');
}

bool _isValidIdValue(Object? v) {
  if (v == null) return false;
  final s = v.toString().trim();
  return s.isNotEmpty &&
      s != '0' &&
      s != 'false' &&
      s != 'null' &&
      s != '{}' &&
      s != '[]';
}

bool _sameSong(QueueItem? a, QueueItem? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return _songIdentity(a) == _songIdentity(b);
}

class MvNotifier extends StateNotifier<MvState> {
  MvNotifier(this._ref) : super(const MvState()) {
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _syncTimeline(),
    );
    _ref.listen<QueueItem?>(playerProvider.select((s) => s.current), (
      prev,
      next,
    ) {
      if (prev == next) return;
      syncSong(next);
    });
    _ref.listen<bool>(playerProvider.select((s) => s.isPlaying), (
      prev,
      playing,
    ) {
      if (playing) return;
      if (!state.requested || !state.ready) return;
      final pn = _ref.read(playerProvider.notifier);
      if (DateTime.now().difference(pn.lastUserPauseAt).inMilliseconds < 1500) {
        return;
      }
      final now = DateTime.now();
      if (now.difference(_guardWindowStart) > const Duration(minutes: 1)) {
        _guardWindowStart = now;
        _guardCount = 0;
      }
      _guardCount++;
      if (_guardCount > 8) {
        AppLog.warn('mv', 'focus-fight guard give up (8/min)');
        return;
      }
      AppLog.warn(
        'mv',
        'non-user pause while mv active, auto resume #$_guardCount',
      );
      Future.delayed(const Duration(milliseconds: 450), () async {
        if (!mounted || !state.requested || !state.ready) return;
        final s = _ref.read(playerProvider);
        if (s.isPlaying || s.current == null) return;
        await _ref.read(playerProvider.notifier).resumeAfterMvPause();
      });
    });
    _ref.listen<double>(volumeProvider, (_, v) {
      final c = state.controller;
      if (_audioTakenOver && c != null && c.value.isInitialized) {
        unawaited(c.setVolume(v.clamp(0.0, 1.0)));
      }
    });
  }

  bool _audioTakenOver = false;

  bool _mvResolveAmbiguous = false;

  // —— MV 解析降噪（仅影响日志与重复探测，不改变解析结果）——
  /// 本源插件已明确答复"无 MV"的歌曲：会话内不再重复走三档梯次
  final Set<String> _mvNoResultCache = {};

  /// 本源插件确定性答复过"无 MV"（方法存在且返回空），才允许写缓存
  bool _mvResolvedDefinitive = false;

  /// 已告警过一次"全链路无 MV"的插件，后续同类告警降为 debug
  final Set<String> _mvFailWarned = {};

  int _guardCount = 0;
  DateTime _guardWindowStart = DateTime.fromMillisecondsSinceEpoch(0);

  final Ref _ref;
  Timer? _syncTimer;

  int _requestVersion = 0;

  QueueItem? _song;

  int _syncOffsetMs = 0;

  Future<String?> toggle(QueueItem c) async {
    if (state.requested) {
      await stop();
      return null;
    }
    _ref.read(playerProvider.notifier).mvSuppressFocusLoss = true;
    _song = c;
    return _start(c);
  }

  void syncSong(QueueItem? c) {
    if (_sameSong(_song, c)) return;
    _song = c;
    _stallTicks = 0;
    _lastVposMs = -1;
    _lastApMs = -1;
    _restartCount = 0;
    if (c != null) unawaited(probeMvFor(c));
    if (!state.requested) {
      if (state.source != null) {
        state = const MvState();
      }
      return;
    }
    if (c == null || !mvSupports(c)) {
      _hardStop();
      return;
    }
    unawaited(_start(c));
  }

  Future<void> stop() async {
    _ref.read(playerProvider.notifier).mvSuppressFocusLoss = false;
    await _hardStop();
  }

  Future<String?> setQuality(String quality) async {
    final song = _song;
    if (song == null || !state.requested) return 'MV 未开启';
    return _start(song, quality: quality);
  }

  String _defaultQuality() {
    final q = _ref.read(settingsProvider).valueOrNull?.onlineDefaultMvQuality;
    return normalizeMvQuality(q ?? '720P');
  }

  Future<void> probeMvFor(QueueItem c) async {
    final key = _mvProbeKey(c);
    if (key.isEmpty || _mvProbeResult.containsKey(key)) return;
    bool? has;
    try {
      final src = await _resolve(mvSongOf(c), _defaultQuality());
      has = _mvResolveAmbiguous ? null : (src != null && src.url.isNotEmpty);
    } catch (_) {
      has = null;
    }
    if (has != null) _mvProbeResult[key] = has;
    if (!mounted) return;
    if (has == null || has == _hasMvIdentityHint(c)) return;
    state = state.refresh();
  }

  Future<void> probeQueueMvs(List<QueueItem> items) async {
    var first = true;
    for (final it in items) {
      final key = _mvProbeKey(it);
      if (key.isEmpty || _mvProbeResult.containsKey(key)) continue;
      if (!first) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (!mounted) return;
      }
      first = false;
      await probeMvFor(it);
      if (!mounted) return;
    }
  }

  Future<String?> _start(QueueItem c, {String? quality}) async {
    final song = mvSongOf(c);
    final ver = ++_requestVersion;
    final target = (quality != null && quality.isNotEmpty)
        ? normalizeMvQuality(quality)
        : _defaultQuality();
    final identity = _songIdentity(c);
    _syncOffsetMs = mvCachedSyncOffset(identity) ?? 0;

    // 无缝画质切换（PiliNara 同款体验，video_player 无「同实例换源」，
    // 用双实例过渡实现）：旧画面继续显示播放，新实例后台就绪并 seek 到
    // 旧画面当前位置后原子替换。任何失败都保留旧画面只报错
    final switching =
        quality != null &&
        state.ready &&
        state.controller != null &&
        state.source != null;
    if (!switching && _audioTakenOver) await _releaseAudio();
    if (!switching) {
      state = MvState(
        requested: true,
        loading: true,
        phase: 'resolve',
        source: null,
      );
    }

    final src = await _resolve(song, target);
    if (ver != _requestVersion) return null;
    if (src == null || src.url.isEmpty) {
      if (!_mvResolveAmbiguous) {
        final key = _mvProbeKey(c);
        if (key.isNotEmpty) _mvProbeResult[key] = false;
      }
      if (!switching) state = const MvState();
      return '此歌曲无 MV 或插件未提供 MV 解析';
    }

    if (!switching) state = state.copyWith(phase: 'init', bufferedSec: 0);
    final controller = await _initControllerWithFallback(src);
    if (controller == null) {
      if (ver != _requestVersion || !mounted) return null;
      if (!switching) state = const MvState();
      AppLog.warn('mv', 'init failed for all candidates: ${src.url}');
      return _lastInitError == null
          ? 'MV 加载失败'
          : 'MV 加载失败：${_shortMvError(_lastInitError!)}';
    }
    if (ver != _requestVersion || !mounted) {
      await controller.dispose();
      return null;
    }

    await controller.setLooping(true);
    if (switching) {
      // 位置恢复：对齐旧画面当前位置（同一 MV 内容换档，画面不跳）
      final oldPos = state.controller?.value.position.inMilliseconds ?? 0;
      final vd = controller.value.duration.inMilliseconds;
      if (vd > 0) {
        var posMs = oldPos % vd;
        if (posMs < 0) posMs += vd;
        await controller.seekTo(Duration(milliseconds: posMs));
      }
    } else {
      await controller.setVolume(0);
      final ad = _ref.read(playerProvider);
      final vd0 = controller.value.duration;
      if (ad.current != null && vd0 > Duration.zero) {
        final vd0Ms = vd0.inMilliseconds;
        var posMs = ((ad.position * 1000).round() + _syncOffsetMs) % vd0Ms;
        if (posMs < 0) posMs += vd0Ms;
        await controller.seekTo(Duration(milliseconds: posMs));
      }
    }
    if (ver != _requestVersion || !mounted) {
      await controller.dispose();
      return null;
    }

    final wasTakenOver = switching && state.audioTakenOver;
    final old = state.controller;
    state = MvState(
      requested: true,
      ready: true,
      source: src,
      controller: controller,
      audioTakenOver: wasTakenOver,
    );
    await old?.dispose();
    unawaited(controller.play());
    // 切换时接管态延续：歌曲本就被暂停压制，新源直接出声，不再重走接管
    if (wasTakenOver) {
      await controller.setVolume(1);
    }
    final vs = controller.value.size;
    AppLog.debug(
      'mv',
      'init ok dim=${vs.width.toInt()}x${vs.height.toInt()} '
          'dur=${controller.value.duration} q=$target url=${src.url}',
    );
    // 桌面端同款模型：起播位置按偏移环形映射（未分析时 offset=0，与歌曲
    // 同刻度），音画天然同步。autoSync 命中后仅做一次重对齐 seek，
    // 无持续同步机器。合流 MP4 自带音轨→接管淡出歌曲；DASH 视频流等
    // 无声源不接管，歌曲继续出声，画面纯跟时间轴。
    // 画质切换时接管态已延续（wasTakenOver），不再重走接管淡入
    if (src.hasAudioTrack && !switching) {
      await _takeOverAudio();
    }
    unawaited(_runTakeover(c, identity, ver));
    return null;
  }

  Future<void> _runTakeover(QueueItem c, String identity, int ver) async {
    final cacheDir = await mvSyncCacheDir();
    if (cacheDir == null) {
      AppLog.warn('mv', '[takeover] skip: sync cache dir unavailable');
      return;
    }
    final song = mvSongOf(c);
    final anchor = _ref.read(playerProvider);
    final result = await analyzeMvLocalForSong(
      identity: identity,
      resolveSource: (q) => _resolveQuality(song, q),
      qualities: const ['360P', '480P', '720P'],
      cacheDir: cacheDir,
      songPosSec: anchor.position,
      songDurationSec: anchor.duration,
      songPath: LastAudioSource.filePath ?? (c.isOnline ? null : c.path),
      songUrl: LastAudioSource.url,
      songHeaders: LastAudioSource.headers,
    );
    if (result == null) return;
    if (!mounted || ver != _requestVersion) return;
    if (_song == null || _songIdentity(_song!) != identity) return;
    if (!state.requested || !state.ready) return;
    final ctrl = state.controller;
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        ctrl.value.duration <= Duration.zero) {
      return;
    }
    _syncOffsetMs = result.offsetMs;
    final now = _ref.read(playerProvider);
    if (now.current != null) {
      final target = _ringTarget(now.position * 1000, ctrl.value.duration);
      _lastSeekAt = DateTime.now();
      _stallTicks = 0;
      _lastVposMs = -1;
      try {
        await ctrl.seekTo(target);
      } catch (e) {
        AppLog.warn('mv', 'realign seek failed: $e');
      }
    }
  }

  Future<void> _takeOverAudio() async {
    if (_audioTakenOver) return;
    // 合流 MP4 自带音轨：视频控制器即音源，直接拉其音量
    final target = state.controller;
    if (target == null || !target.value.isInitialized) return;
    _audioTakenOver = true;
    if (mounted) state = state.copyWith(audioTakenOver: true);
    final pn = _ref.read(playerProvider.notifier);
    await pn.setMvAudioOverride(true);
    final vol = _ref.read(volumeProvider).clamp(0.0, 1.0);
    const steps = 14;
    for (var i = 1; i <= steps; i++) {
      final k = (i / steps) * math.pi / 2;
      try {
        await pn.setMvSongGain(math.cos(k));
        await target.setVolume(vol * math.sin(k));
      } catch (_) {
        return;
      }
      if (i < steps) await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<void> _releaseAudio() async {
    if (!_audioTakenOver) return;
    _audioTakenOver = false;
    if (mounted) state = state.copyWith(audioTakenOver: false);
    final pn = _ref.read(playerProvider.notifier);
    final target = state.controller;
    if (target != null && target.value.isInitialized) {
      final vol = _ref.read(volumeProvider).clamp(0.0, 1.0);
      const steps = 6;
      for (var i = 1; i <= steps; i++) {
        final k = (i / steps) * math.pi / 2;
        try {
          await target.setVolume(vol * math.cos(k));
          await pn.setMvSongGain(math.sin(k));
        } catch (_) {
          break;
        }
        if (i < steps) await Future.delayed(const Duration(milliseconds: 30));
      }
      try {
        await target.setVolume(0);
      } catch (e) {
        AppLog.warn('player', 'MV 音量归零失败: $e');
      }
    }
    await pn.setMvAudioOverride(false);
  }

  void alignToAudioSeconds(double secs) {
    if (!state.requested || !state.ready) return;
    final c = state.controller;
    if (c == null || !c.value.isInitialized) return;
    final vd = c.value.duration;
    if (vd <= Duration.zero) return;
    _lastSeekAt = null;
    _stallTicks = 0;
    _lastVposMs = -1;
    final t = _ringTarget(secs * 1000, vd);
    unawaited(c.seekTo(t));
  }

  void seekToMvSeconds(double mvSecs) {
    if (!state.requested || !state.ready) return;
    final c = state.controller;
    if (c == null || !c.value.isInitialized) return;
    final vdMs = c.value.duration.inMilliseconds;
    if (vdMs <= 0) return;
    var off = _syncOffsetMs % vdMs;
    if (off < 0) off += vdMs;
    var tMs = (mvSecs * 1000).round();
    if (tMs < 0) tMs = 0;
    if (tMs > vdMs) tMs = vdMs;
    final songDurMs = (_ref.read(playerProvider).duration * 1000).round();
    if (songDurMs > 0) {
      if (tMs < off) tMs = off;
      final maxSongMs = songDurMs > 800 ? songDurMs - 500 : songDurMs;
      if (tMs - off > maxSongMs) tMs = off + maxSongMs;
      if (tMs >= vdMs) tMs = vdMs - 1;
    } else if (tMs < off) {
      tMs = off;
    }
    final songSecs = (tMs - off) / 1000.0;
    _stallTicks = 0;
    _lastVposMs = -1;
    unawaited(_ref.read(playerProvider.notifier).seek(songSecs));
    _lastSeekAt = DateTime.now();
    unawaited(c.seekTo(Duration(milliseconds: tMs)));
  }

  Future<void> _hardStop() async {
    _requestVersion++;
    final old = state.controller;
    if (_audioTakenOver) await _releaseAudio();
    state = const MvState();
    await old?.dispose();
  }

  String? _lastInitError;
  Timer? _initProgressTimer;

  void _trackInitProgress(VideoPlayerController c) {
    _initProgressTimer?.cancel();
    _initProgressTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final v = c.value;
      final endMs = v.buffered.isEmpty ? 0 : v.buffered.last.end.inMilliseconds;
      final sec = (endMs / 1000).round();
      if (mounted &&
          state.loading &&
          state.phase == 'init' &&
          sec != state.bufferedSec) {
        state = state.copyWith(bufferedSec: sec);
      }
    });
  }

  String _shortMvError(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('timeout') || raw.contains('超时')) return '网络超时';
    if (s.contains('403') || s.contains('forbidden')) return '链接无权限（403）';
    if (s.contains('404') || s.contains('not found')) return '链接已失效（404）';
    if (s.contains('network') || s.contains('socket') || s.contains('连接')) {
      return '网络连接失败';
    }
    if (s.contains('codec') || s.contains('format') || s.contains('decoder')) {
      return '画面格式不支持';
    }
    final t = raw.trim();
    return t.length > 24 ? '${t.substring(0, 24)}…' : t;
  }

  Future<VideoPlayerController?> _initControllerWithFallback(
    MvSource src,
  ) async {
    final candidates = [src.url, ...src.backupUrls];
    Object? lastError;
    // 必须先起代理再取代理 URL，否则 mvProxyUrlFor 全 null、代理轮被跳过
    await AudioProxyServer.instance.ensureStarted();
    final proxied = {
      for (final u in candidates)
        u: AudioProxyServer.instance.mvProxyUrlFor(u, src.headers),
    };
    // 两轮尝试：直连在前（PiliNara 同款——CDN 直连 + ExoPlayer 原生管道
    // 缓冲，Dart 代理逐段转发是真机卡顿主因；MV 只需 Referer 头，ExoPlayer
    // httpHeaders 原生支持），代理伺服作全败兜底（不可达网络下的保险）
    final attempts = <(String, String?)>[
      for (final u in candidates) (u, null),
      if (proxied.values.any((p) => p != null))
        for (final u in candidates)
          if (proxied[u] != null) (u, proxied[u]),
    ];
    for (final (u, proxy) in attempts) {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(proxy ?? u),
        httpHeaders: src.headers,
      );
      try {
        _lastInitError = null;
        _trackInitProgress(c);
        // 不可达 CDN 会「TCP 连上但数据停摆」，initialize 无限挂起——
        // 限时判负立即换下一候选，避免整条初始化链挂死几分钟
        await c.initialize().timeout(const Duration(seconds: 6));
        _initProgressTimer?.cancel();
        if (c.value.hasError) {
          throw StateError(c.value.errorDescription ?? 'init error');
        }
        if (attempts.length > 1) {
          AppLog.debug(
            'mv',
            'init ok url=$u via=${proxy != null ? 'proxy' : 'direct'}',
          );
        }
        return c;
      } catch (e) {
        _initProgressTimer?.cancel();
        _lastInitError = e.toString();
        lastError = e;
        await c.dispose().catchError((_) {});
      }
    }
    _initProgressTimer?.cancel();
    AppLog.warn(
      'mv',
      'init failed all ${attempts.length} candidates: $lastError',
    );
    return null;
  }

  Future<MvSource?> _resolve(Map<String, dynamic> song, String quality) async {
    final emptyKey = _mvEmptyKey(song);
    if (emptyKey != null && _mvNoResultCache.contains(emptyKey)) {
      AppLog.debug('mv', 'MV 探测会话缓存命中(无结果) key=$emptyKey');
      return null;
    }
    _mvResolveAmbiguous = false;
    _mvResolvedDefinitive = false;
    for (final q in _qualityCandidates(quality)) {
      final src = await _resolveQuality(song, q);
      if (src != null && src.url.isNotEmpty) return src;
    }
    // 本源插件明确答复过"无 MV"才缓存，方法不存在/路由异常等未知态不缓存
    if (_mvResolvedDefinitive && emptyKey != null) {
      _mvNoResultCache.add(emptyKey);
    }
    return null;
  }

  /// 歌曲在 MV 探测里的会话级标识：源插件 + 尽力而为的歌曲唯一键
  static String? _mvEmptyKey(Map<String, dynamic> song) {
    final sourceId =
        song['pluginId']?.toString() ?? song['source']?.toString() ?? '';
    final id =
        (song['songmid'] ??
                song['songId'] ??
                song['vid'] ??
                song['hash'] ??
                song['id'])
            ?.toString();
    final title = song['title']?.toString() ?? '';
    final artist = song['artist']?.toString() ?? '';
    if ((id == null || id.isEmpty) && (title.isEmpty || artist.isEmpty)) {
      return null;
    }
    return '$sourceId|$id|$title|$artist';
  }

  static List<String> _qualityCandidates(String quality) {
    const ladder = ['4K', '1080P', '720P', '480P', '360P'];
    final idx = ladder.indexOf(quality);
    final start = idx < 0 ? 2 : idx;
    return [
      for (var i = start; i < ladder.length && i < start + 3; i++) ladder[i],
    ];
  }

  Future<MvSource?> resolveDownloadSource(QueueItem song, String quality) =>
      _resolve(mvSongOf(song), quality);

  Future<MvSource?> _resolveQuality(
    Map<String, dynamic> song,
    String quality,
  ) async {
    String? sourceId = song['pluginId']?.toString();
    sourceId ??= song['source']?.toString();
    if (sourceId == null || sourceId.isEmpty) {
      final plugin = song['plugin'];
      if (plugin is Map) {
        sourceId = plugin['id']?.toString() ?? plugin['name']?.toString();
      } else if (plugin != null) {
        sourceId = plugin.toString();
      }
    }
    if (sourceId == null || sourceId.isEmpty) return null;

    final isLxSong = song['format']?.toString() == 'lx';

    final args = <dynamic>[song, if (quality.isNotEmpty) quality];
    try {
      final engine = await _ref.read(pluginEngineProvider.future);

      if (!isLxSong) {
        try {
          final raw = await engine.call(sourceId, 'getMvSource', args);
          if (raw is Map<String, dynamic> && raw.isNotEmpty) {
            final parsed = MvSource.fromJson(raw);
            if (parsed.url.isNotEmpty) return parsed;
          }
          // 方法存在且答复为空：插件对自家歌曲的权威结论
          _mvResolvedDefinitive = true;
          AppLog.debug('mv', 'getMvSource($sourceId) 无有效结果');
        } catch (e) {
          _mvResolveAmbiguous = true;
          AppLog.debug('mv', 'getMvSource($sourceId) 调用失败: $e');
        }
      }

      final identity = _songIdentityForPluginMatch(song, sourceId);
      final candidates = _matchMfPlugins(
        identity,
      ).where((c) => c.$1 != sourceId).toList();
      for (final (pluginId, _) in candidates) {
        try {
          final raw = await engine.call(pluginId, 'getMvSource', args);
          if (raw is Map<String, dynamic> && raw.isNotEmpty) {
            final parsed = MvSource.fromJson(raw);
            if (parsed.url.isNotEmpty) {
              return parsed;
            }
          }
        } catch (e) {
          _mvResolveAmbiguous = true;
          AppLog.debug('mv', 'getMvSource($pluginId) 调用失败: $e');
        }
      }
    } catch (e) {
      _mvResolveAmbiguous = true;
      AppLog.warn('mv', 'MV 插件路由跳过: $e');
    }

    final host = await resolveHostMvFallback(song: song, quality: quality);
    if (host != null) {
      return host;
    }
    // 全链路无 MV 属常见常态（多数插件未实现 getMvSource），每源仅告警一次
    if (_mvFailWarned.add(sourceId)) {
      AppLog.warn('mv', 'MV 解析失败: plugin=$sourceId q=$quality（插件与宿主兜底均无结果）');
    } else {
      AppLog.debug('mv', 'MV 解析失败: plugin=$sourceId q=$quality（插件与宿主兜底均无结果）');
    }
    return null;
  }

  static String _songIdentityForPluginMatch(
    Map<String, dynamic> song,
    String sourceId,
  ) {
    final raw = song['rawData'];
    final rawMap = raw is Map ? raw : null;
    return [
      sourceId,
      song['source'],
      song['platform'],
      rawMap?['source'],
      rawMap?['platform'],
      song['plugin'],
      song['plugin'] is Map
          ? (song['plugin'] as Map)['name']
          : song['plugin']?.toString(),
    ].whereType<String>().join(' ');
  }

  static const _kSourceToMfKeywords = <String, List<String>>{
    'kg': ['酷狗', 'kugou'],
    'kugou': ['酷狗', 'kugou'],
    'kw': ['酷我', 'kuwo'],
    'kuwo': ['酷我', 'kuwo'],
    'qq': ['QQ音乐', 'qq', 'tencent'],
    'tencent': ['QQ音乐', 'qq', 'tencent'],
    'wy': ['网易云', 'netease', '163'],
    'netease': ['网易云', 'netease', '163'],
    '163': ['网易云', 'netease', '163'],
    'migu': ['咪咕', 'migu', 'mg'],
    'mg': ['咪咕', 'migu', 'mg'],
    'bili': ['bilibili', 'bili', 'B站'],
    'bilibili': ['bilibili', 'bili', 'B站'],
    'qishui': ['汽水', 'qishui'],
    'qishu': ['汽水', 'qishui'],
  };

  List<(String, String)> _matchMfPlugins(String identity) {
    final lower = identity.toLowerCase();
    final keywords = <String>{};
    _kSourceToMfKeywords.forEach((_, kws) {
      for (final kw in kws) {
        if (lower.contains(kw.toLowerCase())) {
          keywords.addAll(kws);
          break;
        }
      }
    });
    if (keywords.isEmpty) return const [];
    final store = _ref.read(pluginManagerProvider);
    final sources = store.sources.where(
      (s) => s.format == PluginFormat.musicfree,
    );
    final matched = <(String, String)>[];
    for (final s in sources) {
      final lowerName = s.name.toLowerCase();
      final lowerId = s.id.toLowerCase();
      for (final kw in keywords) {
        if (lowerName.contains(kw.toLowerCase()) ||
            lowerId.contains(kw.toLowerCase())) {
          matched.add((s.id, s.name));
          break;
        }
      }
    }
    return matched;
  }

  void _syncTimeline() {
    final c = state.controller;
    if (c == null || !c.value.isInitialized) {
      if (!state.requested) return;
      _missCount++;
      if (_missCount % 10 == 1) {
        AppLog.warn(
          'mv',
          'tick skip: hasCtrl=${c != null} '
              'init=${c?.value.isInitialized}',
        );
      }
      return;
    }
    final vd = c.value.duration;
    if (vd <= Duration.zero) return;
    final audio = _ref.read(playerProvider);
    if (audio.current == null) {
      if (c.value.isPlaying) unawaited(c.pause());
      return;
    }
    if (!audio.isPlaying) {
      if (c.value.isPlaying) unawaited(c.pause());
      if (!_seekCooling && !c.value.isBuffering) {
        final t = _ringTarget(audio.position * 1000, vd);
        if ((c.value.position - t).abs() > const Duration(milliseconds: 50)) {
          _lastSeekAt = DateTime.now();
          AppLog.debug(
            'mv',
            'paused align vpos=${c.value.position} '
                'target=$t',
          );
          unawaited(c.seekTo(t));
        }
      }
      return;
    }
    if (!c.value.isPlaying) unawaited(c.play());
    // 桌面端同款：播放中不做持续对齐——合流 MP4 音画同源自洽，
    // 起播/autoSync 各对齐一次即可；这里只做状态镜像与停摆自愈
    if (c.value.isBuffering) {
      if (!_lastBuffering) {
        _lastBuffering = true;
        AppLog.warn('mv', 'buffering start vpos=${c.value.position}');
      }
      return;
    }
    if (_lastBuffering) {
      _lastBuffering = false;
      AppLog.info(
        'mv',
        'buffering end vpos=${c.value.position} '
            'ap=${audio.position}',
      );
    }

    final vposMs = c.value.position.inMilliseconds;
    if (_lastVposMs >= 0) {
      final step = vposMs - _lastVposMs;
      if (step >= -1000 && step < 200) {
        _stallTicks++;
      } else {
        _stallTicks = 0;
      }
    }
    _lastVposMs = vposMs;
    if (_stallTicks >= 4) {
      _stallTicks = 0;
      unawaited(_restartForStall(vposMs));
      return;
    }

    // 歌曲进度被外部拖动（>3s 跳变）时 MV 环形映射跟随（桌面 currentTime
    // watch 同款行为）；MV 自身拖动由 seekToMvSeconds 的冷却期豁免
    final apMs = audio.position * 1000;
    if (_lastApMs >= 0 &&
        (apMs - _lastApMs).abs() > 3000 &&
        !_seekCooling &&
        !c.value.isBuffering) {
      _lastApMs = apMs;
      final t = _ringTarget(apMs, vd);
      _lastSeekAt = DateTime.now();
      AppLog.debug('mv', 'external seek follow ap=$apMs → $t');
      unawaited(c.seekTo(t));
      return;
    }
    _lastApMs = apMs;
  }

  int _missCount = 0;
  bool _lastBuffering = false;

  int _stallTicks = 0;
  int _lastVposMs = -1;
  double _lastApMs = -1;
  DateTime? _lastRestartAt;
  int _restartCount = 0;

  Future<void> _restartForStall(int vposMs) async {
    final now = DateTime.now();
    if (_lastRestartAt != null &&
        now.difference(_lastRestartAt!) < const Duration(seconds: 10)) {
      return;
    }
    if (_restartCount >= 3) {
      AppLog.warn('mv', 'stall restart give up (3 times) vpos=$vposMs');
      return;
    }
    final song = _song;
    final q = state.source?.videoQuality;
    if (song == null) return;
    _lastRestartAt = now;
    _restartCount++;
    AppLog.warn(
      'mv',
      'stall detected, restart #$_restartCount '
          'vpos=$vposMs q=$q',
    );
    await _start(song, quality: q);
  }

  bool get _seekCooling =>
      _lastSeekAt != null &&
      DateTime.now().difference(_lastSeekAt!) < const Duration(seconds: 5);

  DateTime? _lastSeekAt;

  Duration _ringTarget(double audioPosMs, Duration vd) {
    final vdMs = vd.inMilliseconds;
    var t = (audioPosMs.round() + _syncOffsetMs) % vdMs;
    if (t < 0) t += vdMs;
    return Duration(milliseconds: t);
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    state.controller?.dispose();
    super.dispose();
  }
}

final mvProvider = StateNotifierProvider<MvNotifier, MvState>(
  (ref) => MvNotifier(ref),
);
