library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/application_logger.dart';
import '../core/settings.dart';
import '../effects/sound_effect_provider.dart';
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

/// 歌曲信息里可用的 MV 标识字段（与 _songIdentity 的识别列表一致）。
const _kMvIdKeys = [
  'mv', 'mvHash', 'mvdata', 'mvVid', 'mvId', 'vid', 'vid_hash', 'vhash',
  'bvid', 'aid', 'cid', 'id', 'songmid', 'mvid', 'mid', 'hash',
];

/// 本会话内已探测/确认的歌曲 MV 可用性（pluginId|songId → 有无）。
/// 插件机制下有无 MV 只有解析那一刻才知道；起播后并行静默探测一次，
/// 结果缓存后用于显隐 MV 入口（重启清空，插件可能已更新可重探）。
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
  } catch (_) {}
  return false;
}

bool mvSupports(QueueItem? c) {
  if (c == null) return false;
  final key = _mvProbeKey(c);
  // 第二道：真实探测结论优先（探测确认后修正显隐）。
  if (key.isNotEmpty && _mvProbeResult.containsKey(key)) {
    return _mvProbeResult[key]!;
  }
  // 第一道：字段判定作初始显示，与探测结论一致则静默，
  // 不一致由探测完成后 state.refresh() 更新弹窗。
  return _hasMvIdentityHint(c);
}

Map<String, dynamic> mvSongOf(QueueItem c) {
  final js = c.onlineSongJson;
  if (js != null && js.isNotEmpty) {
    try {
      final raw = jsonDecode(js) as Map<String, dynamic>;
      if (raw['format'] == 'musicfree' && raw['musicInfo'] is Map) {
        final song = Map<String, dynamic>.from(raw['musicInfo'] as Map);
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

  /// 加载阶段：'resolve'=解析地址，'init'=初始化画面。
  final String phase;

  /// 初始化期间的缓冲进度（已缓冲秒数）。
  final int bufferedSec;

  /// 音频已被 MV 自带音轨接管：歌曲通道静音，进度条切换为 MV 时间轴显示。
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

  MvState copyWith(
          {String? phase, int? bufferedSec, bool? audioTakenOver}) =>
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

  /// 无参刷新：生成等值新对象以触发 provider 监听者重建。
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
    _syncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _syncTimeline());
    // 换歌 → 同步 MV。必须挂在 provider 上而不是播放页 widget 上：
    // 播放页退出后它的 ref.listen 会随 State 一起销毁，此时若在别处切歌
    // （歌单 / 迷你条 / 系统「下一首」），旧 MV 不会被替换也不停，
    // 重新打开播放页就还是上一首的 MV 在播。
    _ref.listen<QueueItem?>(
      playerProvider.select((s) => s.current),
      (prev, next) {
        if (prev == next) return;
        syncSong(next);
      },
    );
    _ref.listen<bool>(
      playerProvider.select((s) => s.isPlaying),
      (prev, playing) {
        if (playing) return;
        if (!state.requested || !state.ready) return;
        final pn = _ref.read(playerProvider.notifier);
        if (DateTime.now().difference(pn.lastUserPauseAt).inMilliseconds <
            1500) {
          return;
        }
        final now = DateTime.now();
        if (now.difference(_guardWindowStart) >
            const Duration(minutes: 1)) {
          _guardWindowStart = now;
          _guardCount = 0;
        }
        _guardCount++;
        if (_guardCount > 8) {
          AppLog.warn('mv', 'focus-fight guard give up (8/min)');
          return;
        }
        AppLog.warn('mv',
            'non-user pause while mv active, auto resume #$_guardCount');
        Future.delayed(const Duration(milliseconds: 450), () async {
          if (!mounted || !state.requested || !state.ready) return;
          final s = _ref.read(playerProvider);
          if (s.isPlaying || s.current == null) return;
          await _ref.read(playerProvider.notifier).resumeAfterMvPause();
        });
      },
    );
    // 音频被 MV 接管后，系统音量变化需同步到 MV 音轨（歌曲通道已静音）。
    _ref.listen<double>(volumeProvider, (_, v) {
      final c = state.controller;
      if (_audioTakenOver && c != null && c.value.isInitialized) {
        unawaited(c.setVolume(v.clamp(0.0, 1.0)));
      }
    });
  }

  /// 音频已交给 MV 自带音轨（歌曲音频被静音）的标志。
  bool _audioTakenOver = false;

  /// 最近一次 `_resolve` 过程中是否发生过插件调用异常（鉴权失效/网络/插件
  /// 抛错等）。解析失败但有此标志时，结果视为「存疑」而非「明确无 MV」，
  /// 探测与显式开启路径都不得缓存 false——否则瞬时故障会把有 MV 的歌在
  /// 整个会话内错误隐藏。
  bool _mvResolveAmbiguous = false;

  int _guardCount = 0;
  DateTime _guardWindowStart = DateTime.fromMillisecondsSinceEpoch(0);

  final Ref _ref;
  Timer? _syncTimer;

  int _requestVersion = 0;

  QueueItem? _song;

  /// 频谱对齐偏移（videoPos = audioPos + offsetMs），失败/低置信度回退 0。
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

  /// 起播后静默并行探测：这首歌的插件是否真能解析出 MV。
  /// 不触碰播放状态（不动 requested/loading/controller），结果写缓存，
  /// 供 mvSupports 显隐入口。解析过程中任何插件调用异常都视为「存疑」，
  /// 不写缓存——只有插件全部干净返回无结果才记录 false。
  Future<void> probeMvFor(QueueItem c) async {
    final key = _mvProbeKey(c);
    if (key.isEmpty || _mvProbeResult.containsKey(key)) return;
    bool? has;
    try {
      final src = await _resolve(mvSongOf(c), _defaultQuality());
      has = _mvResolveAmbiguous
          ? null
          : (src != null && src.url.isNotEmpty);
    } catch (_) {
      has = null;
    }
    if (has != null) _mvProbeResult[key] = has;
    if (!mounted) return;
    // 只在探测结论与字段判定不一致（入口显隐真的会变）时才广播重建；
    // 一致或探测失败则静默。无条件全局 notify 会撞上转场/pop 的
    // dispose 窗口，触发 use-after-dispose 崩溃（native peer collected）。
    if (has == null || has == _hasMvIdentityHint(c)) return;
    state = state.refresh();
  }

  /// 队列批量探测：当前歌立即，后续歌逐个错开（避让音质预探测带宽）。
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
    // 重开/切画质时若已接管音频，先还原歌曲通道，待新 MV 就绪后再重新接管。
    if (_audioTakenOver) await _releaseAudio(state.controller);
    final song = mvSongOf(c);
    final ver = ++_requestVersion;
    final target = (quality != null && quality.isNotEmpty)
        ? normalizeMvQuality(quality)
        : _defaultQuality();
    final identity = _songIdentity(c);
    _syncOffsetMs = mvCachedSyncOffset(identity) ?? 0;

    state = MvState(
      requested: true,
      loading: true,
      phase: 'resolve',
      source: quality == null ? state.source : null,
    );

    final src = await _resolve(song, target);
    if (ver != _requestVersion) return null;
    if (src == null || src.url.isEmpty) {
      // 解析过程中有插件异常（鉴权/网络等）时结果存疑，不缓存 false：
      // 否则一次瞬时失败就把入口在整个会话内隐藏。
      if (!_mvResolveAmbiguous) {
        final key = _mvProbeKey(c);
        if (key.isNotEmpty) _mvProbeResult[key] = false;
      }
      state = const MvState();
      return '此歌曲无 MV 或插件未提供 MV 解析';
    }

    state = state.copyWith(phase: 'init', bufferedSec: 0);
    final controller = await _initControllerWithFallback(src);
    if (controller == null) {
      if (ver != _requestVersion || !mounted) return null;
      state = const MvState();
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
    await controller.setVolume(0);
    final ad = _ref.read(playerProvider);
    final vd0 = controller.value.duration;
    if (ad.current != null && vd0 > Duration.zero) {
      final vd0Ms = vd0.inMilliseconds;
      var posMs = ((ad.position * 1000).round() + _syncOffsetMs) % vd0Ms;
      if (posMs < 0) posMs += vd0Ms;
      await controller.seekTo(Duration(milliseconds: posMs));
    }

    final old = state.controller;
    state = MvState(
      requested: true,
      ready: true,
      source: src,
      controller: controller,
    );
    await old?.dispose();
    unawaited(controller.play());
    final vs = controller.value.size;
    AppLog.debug('mv', 'init ok dim=${vs.width.toInt()}x${vs.height.toInt()} '
        'dur=${controller.value.duration} q=$target url=${src.url}');
    // 立即接管：画面起播的同一时刻静音歌曲、淡入 MV 音轨，进度条同步切为
    // MV 时间轴——音频、进度与画面一起替换，不存在「画面先行、音频/进度
    // 慢半拍」的窗口。MV 起播位置已按当前偏移环形映射（未分析时 offset=0，
    // 与歌曲同刻度），音画天然同步。频谱分析命中后仅做一次重对齐 seek。
    await _takeOverAudio(controller);
    unawaited(_runTakeover(c, identity, ver));
    return null;
  }

  /// 后台频谱对齐：以歌曲当前位置为锚跑滑窗匹配，命中后更新偏移并把 MV
  /// 重对齐到匹配点。音频自起播即由 MV 音轨承担（见 _start 的立即接管），
  /// 重对齐只是一次音画一体的 seek，不存在二次音频切换。
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
    if (result == null) return; // 未命中原因由 analyzeMvLocalForSong 记录
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
      // 重对齐：MV（含其音轨）一起 seek 到匹配点，单次干净跳变；歌曲底座
      // 是静音时间基准，不动——歌词进度、切歌时机完全不受影响。
      final target = _ringTarget(now.position * 1000, ctrl.value.duration);
      _lastSeekAt = DateTime.now(); // 冷却压住 _syncTimeline，防重对齐窗口内二次硬跳
      _stallTicks = 0;
      _lastVposMs = -1;
      try {
        await ctrl.seekTo(target);
      } catch (e) {
        // seek 失败不致命：交给 _syncTimeline 后续漂移对齐。
        AppLog.warn('mv', 'realign seek failed: $e');
      }
    }
  }

  /// 把音频切给 MV 自带音轨：与歌曲通道做等功率交叉淡化（见下），全程总
  /// 响度基本恒定。MV 起播位置与歌曲底座同刻度（环形映射），二者同源同曲。
  Future<void> _takeOverAudio(VideoPlayerController c) async {
    if (_audioTakenOver) return;
    _audioTakenOver = true;
    // 同步暴露到状态：播放页进度条收到后整体切换为 MV 时间轴显示与拖动。
    if (mounted) state = state.copyWith(audioTakenOver: true);
    final pn = _ref.read(playerProvider.notifier);
    // 标记接管但不瞬静：歌曲通道增益保持 1，随后与 MV 音轨同步交叉淡化。
    await pn.setMvAudioOverride(true);
    final vol = _ref.read(volumeProvider).clamp(0.0, 1.0);
    // 等功率交叉淡化（≈420ms，30ms 步进）：歌曲通道增益按 cos 衰减、MV 音轨
    // 音量按 sin 上升，二者反向同步，全程总响度基本恒定，听感无「凹坑」。
    const steps = 14;
    for (var i = 1; i <= steps; i++) {
      final k = (i / steps) * math.pi / 2;
      try {
        await pn.setMvSongGain(math.cos(k));
        await c.setVolume(vol * math.sin(k));
      } catch (_) {
        // MV 控制器半路被释放：增益停在当前值，由 _releaseAudio 兜底还原。
        return;
      }
      if (i < steps) await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  /// 还原为歌曲音频通道：MV 音轨快速淡出（≈180ms）的同时歌曲通道淡入，
  /// 反向交叉淡化，随后取消歌曲静音并复位增益。
  Future<void> _releaseAudio(VideoPlayerController? c) async {
    if (!_audioTakenOver) return;
    _audioTakenOver = false;
    // 进度条切回歌曲时间轴。
    if (mounted) state = state.copyWith(audioTakenOver: false);
    final pn = _ref.read(playerProvider.notifier);
    if (c != null && c.value.isInitialized) {
      final vol = _ref.read(volumeProvider).clamp(0.0, 1.0);
      const steps = 6;
      for (var i = 1; i <= steps; i++) {
        final k = (i / steps) * math.pi / 2;
        try {
          await c.setVolume(vol * math.cos(k));
          await pn.setMvSongGain(math.sin(k));
        } catch (_) {
          break;
        }
        if (i < steps) await Future.delayed(const Duration(milliseconds: 30));
      }
      try {
        await c.setVolume(0);
      } catch (_) {}
    }
    await pn.setMvAudioOverride(false);
  }

  /// 用户主动跳转（拖动进度条 / 点歌词行）：立即把 MV 对齐到新的音频位置。
  ///
  /// 不能只依赖 [_syncTimeline] 的 500ms 自动同步：它对**所有** seek 施加
  /// [_seekCooling]（任一 seek 之后的 5 秒内只做 ±8% 变速微调、完全不发 seek），
  /// 用户的拖动很容易落进这个窗口，表现就是「拖了进度条 MV 不动、继续按自己的
  /// 节奏播」。这里显式接收目标秒数、绕过冷却，且在跳转后重置停滞检测，
  /// 避免这次人为跳变被 [_restartForStall] 误判成卡顿而重启视频。
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

  /// 进度条切到 MV 时间轴后（音频接管）的拖动：把 MV 时间换算回歌曲时间轴
  /// seek 静音的歌曲底座，再立即把 MV 对齐到对应点——时间基准仍是歌曲，
  /// 歌词/切歌时机不受影响。
  ///
  /// 歌曲在 MV 时间轴上覆盖不到的区域（MV 片头 / 歌曲结束后的片尾）就近夹回
  /// 可达弧 [offset, offset+songDur)，否则 [_syncTimeline] 会以歌曲位置为准
  /// 把 MV 拽回去，表现为拖了又被弹回。
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
    final songDurMs =
        (_ref.read(playerProvider).duration * 1000).round();
    if (songDurMs > 0) {
      if (tMs < off) tMs = off;
      // 高位夹到歌曲结束前 0.5s，避免 seek 到歌曲末尾立刻触发切歌。
      final maxSongMs = songDurMs > 800 ? songDurMs - 500 : songDurMs;
      if (tMs - off > maxSongMs) tMs = off + maxSongMs;
      if (tMs >= vdMs) tMs = vdMs - 1;
    } else if (tMs < off) {
      tMs = off; // 歌曲时长未知时至少保证落在非负歌曲位置上
    }
    final songSecs = (tMs - off) / 1000.0;
    _stallTicks = 0;
    _lastVposMs = -1;
    // 先 seek 歌曲底座，再立即对齐 MV；冷却窗口压住 _syncTimeline 的硬 seek，
    // 避免歌曲位置尚未落地时被二次拽走。
    unawaited(_ref.read(playerProvider.notifier).seek(songSecs));
    _lastSeekAt = DateTime.now();
    unawaited(c.seekTo(Duration(milliseconds: tMs)));
  }

  Future<void> _hardStop() async {
    _requestVersion++;
    final old = state.controller;
    if (_audioTakenOver) await _releaseAudio(old);
    state = const MvState();
    await old?.dispose();
  }

  String? _lastInitError;
  Timer? _initProgressTimer;

  /// 初始化期间轮询缓冲进度，把已缓冲秒数写进状态供 UI 显示。
  void _trackInitProgress(VideoPlayerController c) {
    _initProgressTimer?.cancel();
    _initProgressTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final v = c.value;
      final endMs = v.buffered.isEmpty ? 0 : v.buffered.last.end.inMilliseconds;
      final sec = (endMs / 1000).round();
      if (mounted && state.loading && state.phase == 'init' &&
          sec != state.bufferedSec) {
        state = state.copyWith(bufferedSec: sec);
      }
    });
  }

  /// 把初始化异常压成一句短原因。
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

  Future<VideoPlayerController?> _initControllerWithFallback(MvSource src) async {
    final candidates = [src.url, ...src.backupUrls];
    Object? lastError;
    // MV 走本地代理伺服（请求头注入 + Range + 在线播放缓存池），
    // 代理未启动时回退直连带原始请求头。
    await AudioProxyServer.instance.ensureStarted();
    for (final u in candidates) {
      final proxy = AudioProxyServer.instance.mvProxyUrlFor(u, src.headers);
      final c = VideoPlayerController.networkUrl(
        Uri.parse(proxy ?? u),
        httpHeaders: src.headers,
      );
      try {
        _lastInitError = null;
        _trackInitProgress(c);
        await c.initialize();
        _initProgressTimer?.cancel();
        if (c.value.hasError) {
          throw StateError(c.value.errorDescription ?? 'init error');
        }
        if (candidates.length > 1) {
          AppLog.debug('mv', 'init ok via backup(${candidates.indexOf(u) + 1}/'
              '${candidates.length}) url=$u');
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
    AppLog.warn('mv', 'init failed all ${candidates.length} candidates: $lastError');
    return null;
  }

  Future<MvSource?> _resolve(Map<String, dynamic> song, String quality) async {
    _mvResolveAmbiguous = false;
    for (final q in _qualityCandidates(quality)) {
      final src = await _resolveQuality(song, q);
      if (src != null && src.url.isNotEmpty) return src;
    }
    return null;
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
      Map<String, dynamic> song, String quality) async {
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

    final args = <dynamic>[song, if (quality.isNotEmpty) quality];
    try {
      final engine = await _ref.read(pluginEngineProvider.future);

      // 与桌面端一致：优先调用歌曲所属插件的 getMvSource（Baka 扩展）。
      try {
        final raw = await engine.call(sourceId, 'getMvSource', args);
        if (raw is Map<String, dynamic> && raw.isNotEmpty) {
          final parsed = MvSource.fromJson(raw);
          if (parsed.url.isNotEmpty) return parsed;
        }
        AppLog.warn('mv', 'getMvSource($sourceId) 无有效结果');
      } catch (e) {
        _mvResolveAmbiguous = true;
        AppLog.warn('mv', 'getMvSource($sourceId) 调用失败: $e');
      }

      // 插件路由失败后，按音源身份匹配同源 musicfree 插件再试。
      final identity = _songIdentityForPluginMatch(song, sourceId);
      final candidates =
          _matchMfPlugins(identity).where((c) => c.$1 != sourceId).toList();
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
          AppLog.warn('mv', 'getMvSource($pluginId) 调用失败: $e');
        }
      }
    } catch (e) {
      _mvResolveAmbiguous = true;
      AppLog.warn('mv', 'MV 插件路由跳过: $e');
    }

    // 宿主兜底：酷狗 mvHash / Bilibili bvid。
    final host = await resolveHostMvFallback(song: song, quality: quality);
    if (host != null) {
      return host;
    }
    AppLog.warn('mv',
        'MV 解析失败: plugin=$sourceId q=$quality（插件与宿主兜底均无结果）');
    return null;
  }

  static String _songIdentityForPluginMatch(
      Map<String, dynamic> song, String sourceId) {
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
    final sources = store.sources.where((s) => s.format == PluginFormat.musicfree);
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
      // MV 未开启时静默跳过：定时器常驻 500ms 空转属正常态，不计数不写日志，
      // 否则每 5s 一条 warn 的纯噪音会刷满日志环、挤掉有用记录。
      if (!state.requested) return;
      _missCount++;
      if (_missCount % 10 == 1) {
        AppLog.warn('mv', 'tick skip: hasCtrl=${c != null} '
            'init=${c?.value.isInitialized}');
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
          AppLog.debug('mv', 'paused align vpos=${c.value.position} '
              'target=$t');
          unawaited(c.seekTo(t));
        }
      }
      return;
    }
    if (!c.value.isPlaying) unawaited(c.play());
    if (c.value.isBuffering) {
      if (!_lastBuffering) {
        _lastBuffering = true;
        AppLog.warn('mv', 'buffering start vpos=${c.value.position}');
      }
      return;
    }
    if (_lastBuffering) {
      _lastBuffering = false;
      AppLog.info('mv', 'buffering end vpos=${c.value.position} '
          'ap=${audio.position}');
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

    final vdMs = vd.inMilliseconds;
    final target = _ringTarget(audio.position * 1000, vd);
    double driftMs = (target.inMilliseconds - c.value.position.inMilliseconds)
        .toDouble();
    if (driftMs.abs() > vdMs / 2) {
      driftMs += driftMs > 0 ? -vdMs : vdMs;
    }
    final drift = Duration(milliseconds: driftMs.round());

    final now = DateTime.now();
    if (_seekCooling) {
      _applyNudge(c, driftMs);
      return;
    }
    if (drift.abs() > const Duration(milliseconds: 1200)) {
      _lastSeekAt = now;
      AppLog.warn('mv', 'hard seek drift=${drift.inMilliseconds}ms '
          'vpos=${c.value.position.inMilliseconds} '
          'ap=${audio.position} spd=${c.value.playbackSpeed}');
      var destMs =
          ((c.value.position.inMilliseconds + driftMs) % vdMs).round();
      if (destMs < 0) destMs += vdMs;
      unawaited(c.setPlaybackSpeed(_audioRate()));
      unawaited(c.seekTo(Duration(milliseconds: destMs)));
      return;
    }
    _applyNudge(c, driftMs);
  }

  int _missCount = 0;
  bool _lastBuffering = false;

  int _stallTicks = 0;
  int _lastVposMs = -1;
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
    AppLog.warn('mv', 'stall detected, restart #$_restartCount '
        'vpos=$vposMs q=$q');
    await _start(song, quality: q);
  }

  bool get _seekCooling =>
      _lastSeekAt != null &&
      DateTime.now().difference(_lastSeekAt!) < const Duration(seconds: 5);

  DateTime? _lastSeekAt;

  void _applyNudge(VideoPlayerController c, double driftMs) {
    final base = _audioRate();
    final nudge = driftMs.abs() <= 350
        ? 0.0
        : (driftMs / 1000.0 * 0.5).clamp(-0.08, 0.08);
    final target = base * (1 + nudge);
    if ((c.value.playbackSpeed - target).abs() > 0.001) {
      unawaited(c.setPlaybackSpeed(target));
    }
  }

  double _audioRate() {
    try {
      final s = _ref.read(soundEffectProvider).settings.playbackRate;
      return (s.clamp(50.0, 200.0)) / 100.0;
    } catch (_) {
      return 1.0;
    }
  }

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
