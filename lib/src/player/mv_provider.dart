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

import '../core/application_logger.dart';
import '../core/settings.dart';
import '../effects/sound_effect_provider.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import 'mv_host_fallback.dart';
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

/// 从歌曲提取稳定的音乐/MV 唯一标识（用于切歌判定）。
/// 在线歌 path 是 `lx://` / `plugin://` 统一前缀、不含歌 ID；标题+歌手在
/// 专辑/榜单/MV 合集类列表行上可能大量相同（同名 EP、合集多首）。只凭
/// path+标题+歌手会把不同歌误判为同一首，导致 MV 切歌不重建（视频不换）。
/// 优先用音乐层的唯一键（mvHash/mvid/bvid/aid/vid/songmid...），都缺才
/// 退回 path+标题+歌手。
String _songIdentity(QueueItem? c) {
  if (c == null) return '';
  final song = mvSongOf(c);
  final buf = <String>[];
  for (final k in const [
    'mv', 'mvHash', 'mvdata', 'mvVid', 'mvId', 'vid', 'vid_hash', 'vhash',
    'bvid', 'aid', 'cid', 'id', 'songmid', 'mvid', 'mid', 'hash',
  ]) {
    final v = song[k];
    if (v != null && v.toString().trim().isNotEmpty) {
      buf.add('$k=$v');
      break; // 命中任一音乐层唯一键即可，不必把同首歌多个 id 字段都拼进去
    }
  }
  if (buf.isNotEmpty) return buf.join('&');
  return '${c.path}|${c.title}|${c.artist}';
}

/// 同一首歌判断：音乐层唯一标识优先（mv/bvid/aid/vid...），缺省回退
/// path+标题+歌手组合。
bool _sameSong(QueueItem? a, QueueItem? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return _songIdentity(a) == _songIdentity(b);
}

class MvNotifier extends StateNotifier<MvState> {
  MvNotifier(this._ref) : super(const MvState()) {
    // 500ms 周期对齐（桌面端 syncBackgroundVideo 由 currentTime 事件驱动，
    // 粒度远细于 1s；移动端用半秒 tick 逼近同一体验）：播放/暂停跟随 +
    // 环形 drift 分层纠偏。**只操作视频控制器，音频侧零干预**——音频永远
    // 放歌（唯一声源），前台只是 MV 视频匹配音频进度。
    _syncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _syncTimeline());
    // ROM 音频策略压制守卫：MV 视频的 ExoPlayer 激活后，部分 ROM 会在
    // 音频 play() 后 200~500ms 把 just_audio 压停（无 Dart 调用、非用户
    // 操作），用户点播放即被打断成「播一下停一下」。MV 激活期间检测到
    // 非用户暂停沿 → 450ms 后自动恢复；60s 内最多恢复 3 次防拉锯。
    _ref.listen<bool>(
      playerProvider.select((s) => s.isPlaying),
      (prev, playing) {
        if (playing) return;
        if (!state.requested || !state.ready) return;
        final pn = _ref.read(playerProvider.notifier);
        if (DateTime.now().difference(pn.lastUserPauseAt).inMilliseconds <
            1500) {
          return; // 用户刚主动暂停，尊重用户意图
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
  }

  int _guardCount = 0;
  DateTime _guardWindowStart = DateTime.fromMillisecondsSinceEpoch(0);

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
    // 置位焦点丢失抑制：MV 视频解码器会诱发 ROM 误报「永久焦点丢失」，
    // 激活期间忽略之，否则音频 play 后 200~500ms 必被压停（播一下停一下）
    _ref.read(playerProvider.notifier).mvSuppressFocusLoss = true;
    _song = c;
    return _start(c);
  }

  /// MV 开启状态下切歌：为新歌自动续接 MV；不支持则关闭（对齐桌面端）。
  void syncSong(QueueItem? c) {
    if (_sameSong(_song, c)) return;
    _song = c;
    // 切歌重置停滞检测与重建配额
    _stallTicks = 0;
    _lastVposMs = -1;
    _restartCount = 0;
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

  /// 关闭 MV：销毁控制器回退封面背景，并恢复焦点丢失正常处理。
  Future<void> stop() async {
    _ref.read(playerProvider.notifier).mvSuppressFocusLoss = false;
    await _hardStop();
  }

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

    // 多源 fallback（对齐 BakaMusic 原生播放器多源候选语义）：主 URL +
    // backupUrls 逐个初始化，任一成功即用；全部失败才报「MV 加载失败」。
    final controller = await _initControllerWithFallback(src);
    if (controller == null) {
      if (ver != _requestVersion || !mounted) return null;
      state = const MvState();
      AppLog.warn('mv', 'init failed for all candidates: ${src.url}');
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
    final vs = controller.value.size;
    AppLog.debug('mv', 'init ok dim=${vs.width.toInt()}x${vs.height.toInt()} '
        'dur=${controller.value.duration} q=$target url=${src.url}');
    return null;
  }

  Future<void> _hardStop() async {
    _requestVersion++;
    final old = state.controller;
    state = const MvState();
    await old?.dispose();
  }

  /// 多源 fallback 初始化（对齐 BakaMusic 原生播放器多源候选语义）：
  /// 主 URL + backupUrls 逐个尝试，首个初始化成功的控制器即用；
  /// 全部失败返回 null。单源挂掉（CDN 失效/防盗链/超时）不再整首 MV 失败。
  Future<VideoPlayerController?> _initControllerWithFallback(MvSource src) async {
    final candidates = [src.url, ...src.backupUrls];
    Object? lastError;
    for (final u in candidates) {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(u),
        httpHeaders: src.headers,
      );
      try {
        await c.initialize();
        if (c.value.hasError) throw StateError(c.value.errorDescription ?? 'init error');
        if (candidates.length > 1) {
          AppLog.debug('mv', 'init ok via backup(${candidates.indexOf(u) + 1}/'
              '${candidates.length}) url=$u');
        }
        return c;
      } catch (e) {
        lastError = e;
        await c.dispose().catchError((_) {});
      }
    }
    AppLog.warn('mv', 'init failed all ${candidates.length} candidates: $lastError');
    return null;
  }

  /// 解析 MV 源：所属插件直调 getMvSource，未命中再按 source 关键词匹配
  /// 已安装的 MusicFree 插件逐个尝试（迁移自页面 _ensureMvReady）。
  ///
  /// 对齐 BakaMusic 多画质候选语义：目标画质失败后按降档序列重试
  /// （4K→1080P→720P→480P→360P，最多试 3 档），避免「目标档接口报错 /
  /// 插件只支持更低档」时整首 MV 无法播放。
  Future<MvSource?> _resolve(Map<String, dynamic> song, String quality) async {
    for (final q in _qualityCandidates(quality)) {
      final src = await _resolveQuality(song, q);
      if (src != null && src.url.isNotEmpty) return src;
    }
    return null;
  }

  /// 目标画质起步的降档候选（对齐 BakaMusic declaredCandidates 择优语义）。
  static List<String> _qualityCandidates(String quality) {
    const ladder = ['4K', '1080P', '720P', '480P', '360P'];
    final idx = ladder.indexOf(quality);
    final start = idx < 0 ? 2 : idx;
    return [
      for (var i = start; i < ladder.length && i < start + 3; i++) ladder[i],
    ];
  }

  /// 单档解析：插件 getMvSource → 宿主兜底（酷狗 mvHash / B 站 BV·AV）。
  Future<MvSource?> _resolveQuality(
      Map<String, dynamic> song, String quality) async {
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

    // 宿主兜底：插件 getMvSource 全链路失败后，用酷狗 mvHash / B 站 BV·AV
    // 从宿主补齐视频源（对齐桌面端 useBilibiliVideoBackground 的 kugou/bili 分支），
    // 避免旧版插件只有歌曲解析没有 MV 接口时误报"此歌曲无 MV"。
    final host = await resolveHostMvFallback(song: song, quality: quality);
    if (host != null) {
      debugPrint('[MV] host fallback hit url=${host.url} q=$quality');
      return host;
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
    if (c == null || !c.value.isInitialized) {
      // 控制器缺失（加载中/已关闭）：每 10 tick 报一次，暴露 tick 异常路径
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
      // 暂停态对齐一次（桌面端 paused 分支），受 seek 冷却保护
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
    // 缓冲中跳过评估：位置停滞是缓冲所致，评估会形成 seek 风暴循环
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

    // 停滞检测：ExoPlayer seek 后解码器可能完全不推进（弱机 codec 卡死），
    // 表现为 vpos 停在 seek 目标不动而音频正常走 → 冷却期一过又 seek →
    // 幻灯片循环。连续 2 秒视频几乎不走（排除循环接缝的负跳变）即重建
    // 控制器（换解码器实例绕开 seek 卡死）。
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
      AppLog.warn('mv', 'hard seek drift=${drift.inMilliseconds}ms '
          'vpos=${c.value.position.inMilliseconds} '
          'ap=${audio.position} spd=${c.value.playbackSpeed}');
      // 环形最近点落位（可能为负或超一圈，取模回 [0, vd)）
      var destMs =
          ((c.value.position.inMilliseconds + driftMs) % vdMs).round();
      if (destMs < 0) destMs += vdMs;
      unawaited(c.setPlaybackSpeed(_audioRate())); // seek 后恢复音频倍速基准
      unawaited(c.seekTo(Duration(milliseconds: destMs)));
      return;
    }
    _applyNudge(c, driftMs);
    // 心跳节流到 1s 一条（纠偏仍是 500ms 粒度），日志密度可控
    _tickCount++;
    if (_tickCount % 2 == 0) {
      AppLog.debug('mv', 'tick vpos=${c.value.position.inMilliseconds} '
          'ap=${audio.position} drift=${driftMs.round()}ms '
          'buf=${c.value.isBuffering} playing=${c.value.isPlaying} '
          'spd=${c.value.playbackSpeed}');
    }
  }

  int _tickCount = 0;
  int _missCount = 0;
  bool _lastBuffering = false;

  // 停滞检测与重建状态
  int _stallTicks = 0;
  int _lastVposMs = -1;
  DateTime? _lastRestartAt;
  int _restartCount = 0;

  /// seek 停滞（ExoPlayer 解码器卡死）时的兜底：用当前画质重建视频控制器。
  /// 重建走完整 _start（重新 resolve，复用用户所选画质），旧控制器原子替换。
  /// 冷却 10s 防连环重建；同一首歌最多 3 次，超出放弃（避免死循环）。
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

  /// 硬 seek 后的冷却期（解码器恢复窗口）。
  bool get _seekCooling =>
      _lastSeekAt != null &&
      DateTime.now().difference(_lastSeekAt!) < const Duration(seconds: 5);

  DateTime? _lastSeekAt;

  /// 倍速微调追偏差（对齐桌面端 nudge）：±8% 内的平滑追赶，避免可见跳帧。
  /// 基准倍速 = 音频倍速（桌面端 audioPlaybackRate 同语义）——否则倍速播放
  /// 时视频永远追不上，drift 持续增大触发周期性硬 seek。
  /// 死区 0.35s：audio.position 是 positionStream 缓存值（滞后 ~200-350ms），
  /// 缓存滞后若被当成偏差修正，视频会被系统性放慢（越走越慢再硬 seek）。
  void _applyNudge(VideoPlayerController c, double driftMs) {
    final base = _audioRate();
    // |drift| ≤ 350ms 视为同步（死区 > position 缓存滞后），恢复基准倍速
    final nudge = driftMs.abs() <= 350
        ? 0.0
        : (driftMs / 1000.0 * 0.5).clamp(-0.08, 0.08);
    final target = base * (1 + nudge);
    if ((c.value.playbackSpeed - target).abs() > 0.001) {
      unawaited(c.setPlaybackSpeed(target));
    }
  }

  /// 音频倍速（音效设置的 playbackRate：50~200 → 0.5~2.0）。
  double _audioRate() {
    try {
      final s = _ref.read(soundEffectProvider).settings.playbackRate;
      return (s.clamp(50.0, 200.0)) / 100.0;
    } catch (_) {
      return 1.0;
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

/// 页面级 MV 状态。**非 autoDispose**：autoDispose 下播放页短暂失去观察者
/// （更多弹窗开合、横竖屏切换、页面转场）即销毁 Notifier——视频控制器被
/// 连带 dispose，重进页面 MV 全没、画面反复黑屏重启。改为常驻生命周期，
/// 控制器只在 stop/切歌/换画质时释放（_hardStop），app 退出随 container 回收。
final mvProvider = StateNotifierProvider<MvNotifier, MvState>(
  (ref) => MvNotifier(ref),
);
