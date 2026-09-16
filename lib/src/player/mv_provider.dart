/// MV（音乐视频）播放状态层，对齐桌面端 useBilibiliVideoBackground 的体验：
///
/// - [MvState.requested]：用户意图开启（桌面端 requested）——开启状态下切歌
///   自动续接新歌 MV（无缝切换），新歌不支持则自动关闭并回退封面背景；
/// - [MvState.ready]：视频控制器就绪（桌面端 isMovieMode = requested && 有画面），
///   播放页据此隐藏封面/歌词，把页面让渡给视频；
/// - 画质：默认取设置 `onlineDefaultMvQuality`（归一为大写档键），音质按钮在
///   MV 开启时切换为「MV 画质」菜单（桌面端底栏同款），点选 setQuality 以
///   新档位重新解析加载；
/// - 视频静音 + 循环 + 进度跟随音频（1s 节流、大偏差硬对齐——对齐桌面端
///   syncBackgroundVideo；音频是唯一声源，视频只做画面）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/settings.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import 'mv_source.dart';
import 'player_provider.dart';

/// MV 画质档归一：插件契约用大写档键（'360P'/'480P'/'720P'/'1080P'/'4K'），
/// 设置存储/历史数据可能是 '720p' 小写，传给插件前统一归一。
String normalizeMvQuality(String q) {
  final t = q.trim();
  if (t.isEmpty) return '';
  if (t.toLowerCase() == '4k') return '4K';
  return t.toUpperCase();
}

/// 当前歌曲是否可能支持 MV（对齐桌面端 supportsMusicVideo）：
/// 仅「插件在线歌曲」且为 MusicFree 格式时为真——LX 格式插件歌曲无 MV 概念
/// （桌面端 source.format !== 'lx'），本地歌曲同样无 MV。
bool mvSupports(QueueItem? c) {
  if (c == null) return false;
  final js = c.onlineSongJson;
  if (js == null || js.isEmpty) return false;
  try {
    final raw = jsonDecode(js);
    if (raw is! Map) return false;
    if (raw['format'] == 'lx') return false;
    final pluginId = raw['pluginId']?.toString() ?? '';
    return pluginId.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// 从 QueueItem 提取传给插件 getMvSource 的歌曲参数（对齐桌面端 song.plugin_id）。
Map<String, dynamic> mvSongOf(QueueItem c) {
  final js = c.onlineSongJson;
  if (js != null && js.isNotEmpty) {
    try {
      final raw = jsonDecode(js) as Map<String, dynamic>;
      // MusicFree 包装格式：{format:musicfree, musicInfo:{...实际歌曲...}}
      if (raw['format'] == 'musicfree' && raw['musicInfo'] is Map) {
        final song = Map<String, dynamic>.from(raw['musicInfo'] as Map);
        // 以 wrapper 顶层 pluginId 定位所属插件
        if (raw['pluginId'] != null) {
          song['pluginId'] = raw['pluginId'];
        }
        // 外层可能有 plugin 描述，拷贝到内层方便后续匹配
        final plugin = raw['plugin'];
        if (plugin != null) {
          song['plugin'] = plugin;
        }
        return song;
      }
      return raw;
    } catch (_) {
      // JSON 异常时退回基础字段。
    }
  }
  return {
    'source': c.source,
    'path': c.path,
    'title': c.title,
    'artist': c.artist,
  };
}

/// MV 播放状态。
class MvState {
  /// 用户意图开启（切歌自动续接的依据）。
  final bool requested;

  /// 视频控制器就绪（页面让渡/视频层渲染的依据）。
  final bool ready;

  /// 探测/加载中（入口按钮 loading）。
  final bool loading;

  /// 当前源（availableVideoQualities / videoQuality 供画质菜单）。
  final MvSource? source;

  /// 视频控制器（就绪后非 null；替换即无缝换画面）。
  final VideoPlayerController? controller;

  const MvState({
    this.requested = false,
    this.ready = false,
    this.loading = false,
    this.source,
    this.controller,
  });

  bool get active => requested;
}

/// 同一首歌判断：path 相同即同一首（切进度/切音质不触发重挂）。
bool _sameSong(QueueItem? a, QueueItem? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.path == b.path;
}

class MvNotifier extends StateNotifier<MvState> {
  MvNotifier(this._ref) : super(const MvState()) {
    // 1s 周期对齐：播放/暂停跟随 + 大偏差硬 seek（节流由周期天然保证）。
    _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) => _syncTimeline());
  }

  final Ref _ref;
  Timer? _syncTimer;

  /// 请求代际号：stop/切歌/换画质递增，过期异步结果一律丢弃（防竞态）。
  int _requestVersion = 0;

  /// 当前绑定歌曲（切歌检测 + 换画质时重新解析的目标）。
  QueueItem? _song;

  // ── 对外命令 ──

  /// 开关 MV（更多弹窗入口）。返回 null=成功，否则为错误文案（页面 toast）。
  Future<String?> toggle(QueueItem c) async {
    if (state.requested) {
      await stop();
      return null;
    }
    _song = c;
    return _start(c);
  }

  /// MV 开启状态下切歌：为新歌自动续接 MV；不支持则关闭（对齐桌面端）。
  void syncSong(QueueItem? c) {
    if (_sameSong(_song, c)) return;
    _song = c;
    if (!state.requested) {
      // 未开启时仅清理上一首的源缓存（控制器本就没有）。
      if (state.source != null) {
        state = const MvState();
      }
      return;
    }
    if (c == null || !mvSupports(c)) {
      _hardStop();
      return;
    }
    // 失败静默：自动续接失败等同关闭（对齐桌面端 start().catch(() => {})）。
    unawaited(_start(c));
  }

  /// 关闭 MV：销毁控制器回退封面背景。
  Future<void> stop() => _hardStop();

  /// MV 播放中切换画质：以新档位重新解析加载（桌面端 setQuality 同款）。
  /// 返回 null=成功，否则错误文案。
  Future<String?> setQuality(String quality) async {
    final song = _song;
    if (song == null || !state.requested) return 'MV 未开启';
    return _start(song, quality: quality);
  }

  // ── 内部实现 ──

  String _defaultQuality() {
    final q = _ref.read(settingsProvider).valueOrNull?.onlineDefaultMvQuality;
    return normalizeMvQuality(q ?? '720P');
  }

  /// 启动/换画质：保留旧画面继续显示，新控制器就绪后原子替换（无缝）。
  Future<String?> _start(QueueItem c, {String? quality}) async {
    final song = mvSongOf(c);
    final ver = ++_requestVersion;
    final target = (quality != null && quality.isNotEmpty)
        ? normalizeMvQuality(quality)
        : _defaultQuality();

    state = MvState(
      requested: true,
      loading: true,
      source: quality == null ? state.source : null, // 换画质时旧列表先失效
    );

    final src = await _resolve(song, target);
    if (ver != _requestVersion) return null;
    if (src == null || src.url.isEmpty) {
      state = const MvState();
      return '此歌曲无 MV 或画质不支持';
    }

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(src.url),
      httpHeaders: src.headers,
    );
    try {
      await controller.initialize();
    } catch (_) {
      await controller.dispose();
      if (ver != _requestVersion || !mounted) return null;
      state = const MvState();
      return 'MV 加载失败';
    }
    if (ver != _requestVersion || !mounted) {
      await controller.dispose();
      return null;
    }

    await controller.setLooping(true);
    // 对齐桌面端 muted：音频是唯一声源，视频只做画面（音画进度由 _syncTimeline 对齐）。
    await controller.setVolume(0);
    // 开局对齐：直接从音频当前进度（取模）起播，消除「从 0 开始 →
    // 首个 tick 硬 seek」的开局抽跳（对齐桌面端 start 语义）。
    final ad = _ref.read(playerProvider);
    final vd0 = controller.value.duration;
    if (ad.current != null && vd0 > Duration.zero) {
      final posMs = (ad.position * 1000).round() % vd0.inMilliseconds;
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
    return null;
  }

  Future<void> _hardStop() async {
    _requestVersion++;
    final old = state.controller;
    state = const MvState();
    await old?.dispose();
  }

  /// 解析 MV 源：所属插件直调 getMvSource，未命中再按 source 关键词匹配
  /// 已安装的 MusicFree 插件逐个尝试（迁移自页面 _ensureMvReady）。
  Future<MvSource?> _resolve(Map<String, dynamic> song, String quality) async {
    // 从多种可能的字段里提取 plugin/source 标识（wrapper 顶层 pluginId 优先）。
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

    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final args = <dynamic>[song, if (quality.isNotEmpty) quality];

      // 先用 sourceId 直接当 pluginId 调一次。
      try {
        final raw = await engine.call(sourceId, 'getMvSource', args);
        if (raw is Map<String, dynamic> && raw.isNotEmpty) {
          final parsed = MvSource.fromJson(raw);
          if (parsed.url.isNotEmpty) return parsed;
        }
      } catch (e) {
        debugPrint('[MV] direct call $sourceId no getMvSource: $e');
      }

      // 关键词匹配：把 sourceId（及 plugin.name）当关键词匹配已安装 MF 插件。
      final candidates = _matchMfPlugins(sourceId);
      if (candidates.isEmpty) {
        final plugin = song['plugin'];
        if (plugin is Map) {
          final extraKw = plugin['name']?.toString();
          if (extraKw != null && extraKw.isNotEmpty) {
            candidates.addAll(_matchMfPlugins(extraKw));
          }
        }
      }
      for (final (pluginId, name) in candidates) {
        try {
          final raw = await engine.call(pluginId, 'getMvSource', args);
          if (raw is Map<String, dynamic> && raw.isNotEmpty) {
            final parsed = MvSource.fromJson(raw);
            if (parsed.url.isNotEmpty) {
              debugPrint('[MV] MF hit via $name($pluginId)');
              return parsed;
            }
          }
        } catch (e) {
          debugPrint('[MV] call $name($pluginId) getMvSource failed: $e');
        }
      }
    } catch (e, st) {
      debugPrint('[MV] resolve error: $e\n$st');
    }
    return null;
  }

  /// LX 格式插件的 source 短代码 → 可能的 MusicFree 插件 name/id 关键字
  /// （MusicFree 生态每个源是独立插件，需按关键字定位对应 pluginId）。
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

  List<(String, String)> _matchMfPlugins(String sourceId) {
    final keywords = _kSourceToMfKeywords[sourceId.toLowerCase()] ?? const [];
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

  /// 视频跟随音频（对齐桌面端 syncBackgroundVideo，PlayerDetailBackground.vue）：
  /// 播放/暂停同步 + 环形 drift + 分层纠偏——大偏差硬 seek、中等偏差
  /// ±8% 倍速微调平滑追赶、小偏差不动。
  ///
  /// 弱机加固（桌面端没有的）：硬 seek 后 5s 冷却期，期内只用倍速追不 seek。
  /// ExoPlayer 的 seek 会中断解码管线重新定位，低端机一次 seek 卡 1~3s，
  /// 「解码慢 → position 不动 → drift 超阈值 → 每 tick 硬 seek」会瘫成
  /// 幻灯片（一段一个画面）——冷却期给解码器喘息，靠倍速慢慢追回。
  void _syncTimeline() {
    final c = state.controller;
    if (c == null || !c.value.isInitialized) return;
    final vd = c.value.duration;
    if (vd <= Duration.zero) return;
    final audio = _ref.read(playerProvider);
    if (audio.current == null) {
      if (c.value.isPlaying) unawaited(c.pause());
      return;
    }
    if (!audio.isPlaying) {
      if (c.value.isPlaying) unawaited(c.pause());
      // 暂停态对齐一次（桌面端 paused 分支），受 seek 冷却保护
      if (!_seekCooling && !c.value.isBuffering) {
        final t = _ringTarget(audio.position * 1000, vd);
        if ((c.value.position - t).abs() > const Duration(milliseconds: 50)) {
          _lastSeekAt = DateTime.now();
          unawaited(c.seekTo(t));
        }
      }
      return;
    }
    if (!c.value.isPlaying) unawaited(c.play());
    // 缓冲中跳过评估：位置停滞是缓冲所致，评估会形成 seek 风暴循环
    if (c.value.isBuffering) return;

    final vdMs = vd.inMilliseconds;
    final target = _ringTarget(audio.position * 1000, vd);
    // 环形距离：视频循环换圈瞬间 position 与 target 分居 0/duration 两端，
    // 线性距离会误判成大偏差回跳（对齐桌面端环形修正）
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
      // 环形最近点落位（可能为负或超一圈，取模回 [0, vd)）
      var destMs =
          ((c.value.position.inMilliseconds + driftMs) % vdMs).round();
      if (destMs < 0) destMs += vdMs;
      unawaited(c.setPlaybackSpeed(1.0)); // 对齐桌面端：seek 后恢复基础倍速
      unawaited(c.seekTo(Duration(milliseconds: destMs)));
      return;
    }
    _applyNudge(c, driftMs);
  }

  /// 硬 seek 后的冷却期（解码器恢复窗口）。
  bool get _seekCooling =>
      _lastSeekAt != null &&
      DateTime.now().difference(_lastSeekAt!) < const Duration(seconds: 5);

  DateTime? _lastSeekAt;

  /// 倍速微调追偏差（对齐桌面端 nudge）：±8% 内的平滑追赶，避免可见跳帧。
  void _applyNudge(VideoPlayerController c, double driftMs) {
    const base = 1.0;
    final nudge = (driftMs / 1000.0 * 0.5).clamp(-0.08, 0.08);
    final nextRate = base + nudge;
    // 靠近同步点后恢复基础倍速（|nudge| 极小视为同步）
    final target = nudge.abs() <= 0.01 ? base : nextRate;
    if ((c.value.playbackSpeed - target).abs() > 0.001) {
      unawaited(c.setPlaybackSpeed(target));
    }
  }

  /// 音频进度对视频时长的环形取模目标。
  Duration _ringTarget(double audioPosMs, Duration vd) {
    final vdMs = vd.inMilliseconds;
    var t = audioPosMs.round() % vdMs;
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

/// 页面级 MV 状态（播放页退出即销毁，视频解码随之释放）。
final mvProvider = StateNotifierProvider.autoDispose<MvNotifier, MvState>(
  (ref) => MvNotifier(ref),
);
