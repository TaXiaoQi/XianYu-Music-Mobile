// 网盘曲目头部元数据预取（自桌面端 features/playback/cloudHeadMeta.ts 移植）。
//
// 网盘列表/播放接口不返回内嵌标签：这里逐曲解析直链后调
// rust.cloudMetaProbeHead（Rust 侧 Range 拉头 2MB 渐进解析），结果回填到
// 本服务的状态表（按 cloud:// path 索引），列表 UI watch 后显示内嵌封面/
// 时长；歌词供 LyricsRepository 命中内嵌优先。会话内按 path 去重、并发 4，
// 避免直链请求风暴；本地索引（Rust 落盘）命中零网络。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/application_logger.dart';
import '../core/db_path.dart';
import '../rust/api.dart' as rust;
import 'cloud_credentials_store.dart';
import 'cloud_registry.dart';
import 'cloud_types.dart';
import 'direct_link_cache.dart';
import '../player/player_provider.dart' show CloudPlayContext;

/// 单条网盘曲目元数据（对齐 Rust cloud_meta payload，camelCase）。
class CloudHeadMetaEntry {
  const CloudHeadMetaEntry({
    required this.cloudPath,
    this.coverPath,
    this.lyricsRaw,
    this.durationSecs,
  });

  final String cloudPath;
  final String? coverPath;
  final String? lyricsRaw;
  final int? durationSecs;

  factory CloudHeadMetaEntry.fromJson(Map<String, dynamic> j) =>
      CloudHeadMetaEntry(
        cloudPath: (j['cloudPath'] ?? '').toString(),
        coverPath: (j['coverPath'] as String?)?.isEmpty == true
            ? null
            : j['coverPath'] as String?,
        lyricsRaw: (j['lyricsRaw'] as String?)?.isEmpty == true
            ? null
            : j['lyricsRaw'] as String?,
        durationSecs: (j['durationSecs'] as num?)?.toInt(),
      );
}

/// 状态 = cloud:// path → 已知元数据（索引 + 本次会话探测结果）。
final cloudHeadMetaProvider =
    NotifierProvider<CloudHeadMetaNotifier, Map<String, CloudHeadMetaEntry>>(
      CloudHeadMetaNotifier.new,
    );

class CloudHeadMetaNotifier extends Notifier<Map<String, CloudHeadMetaEntry>> {
  /// 已探测/已入队的曲目（会话级去重）。
  final _scheduled = <String>{};

  /// 本会话探测失败的曲目（等待方据此提前放弃，不再傻等）。
  final _failed = <String>{};

  /// 索引装载单次闸。
  Future<void>? _indexLoad;

  /// 启动期装载本地索引：命中即直接可用于 UI/歌词，零网络。
  Future<void> _ensureIndexLoaded() {
    _indexLoad ??= () async {
      try {
        final dataDir = await ref.read(appDataDirProvider.future);
        final json = await rust.cloudMetaLoadIndex(dataDir: dataDir);
        final raw = jsonDecode(json) as Map<String, dynamic>;
        final entries = <String, CloudHeadMetaEntry>{
          for (final e in raw.entries)
            e.key: CloudHeadMetaEntry.fromJson(e.value as Map<String, dynamic>),
        };
        // 只补已知键，不覆盖会话内新探测结果
        state = {...entries, ...state};
      } catch (e) {
        AppLog.warn('cloud', '网盘元数据索引装载失败: $e');
      }
    }();
    return _indexLoad!;
  }

  @override
  Map<String, CloudHeadMetaEntry> build() {
    // 懒触发装载；失败静默（探测照常走网络）
    unawaited(_ensureIndexLoaded());
    return const {};
  }

  /// 索引/会话已有该曲目元数据。
  CloudHeadMetaEntry? entryFor(String cloudPath) => state[cloudPath];

  /// 对网盘曲目安排一次头部元数据探测（幂等、限并发、失败静默）。
  void scheduleCloudContext(
    CloudPlayContext ctx, {
    int durationHintSecs = 0,
    bool highPriority = false,
  }) {
    final path = ctx.path;
    if (_scheduled.contains(path)) return;
    _scheduled.add(path);
    // 索引已有条目（此前探测成功过）：无需再走网络
    if (state[path] != null) return;
    // 入池为闭包，_probeTask 不在这里直接调用（否则绕过并发池）
    _enqueue(
      () => _probeTask(ctx, durationHintSecs),
      highPriority: highPriority,
    );
  }

  /// 播放期兜底：手里已有新鲜直链（起播成功后调用），直接探测不再解析直链。
  /// 列表期同曲探测在途时改为等待其结果；返回拿到的条目，均无则 null。
  Future<CloudHeadMetaEntry?> probeWithDirectLink(
    String url,
    Map<String, String> headers,
    String cloudPath, {
    int durationHintSecs = 0,
  }) async {
    if (_scheduled.contains(cloudPath)) return waitFor(cloudPath);
    _scheduled.add(cloudPath);
    final existing = state[cloudPath];
    if (existing != null) return existing;
    return _probeDirect(url, headers, cloudPath, durationHintSecs);
  }

  /// 等待该曲目的探测结果（在途时短暂轮询）；已失败/未在途立即返回
  /// 当前值（可能为 null）。索引未装载完时先等装载，避免误判未探测。
  Future<CloudHeadMetaEntry?> waitFor(
    String cloudPath, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    await _ensureIndexLoaded();
    final deadline = DateTime.now().add(timeout);
    while (!_failed.contains(cloudPath)) {
      final e = state[cloudPath];
      if (e != null) return e;
      if (!_scheduled.contains(cloudPath) || DateTime.now().isAfter(deadline)) {
        return state[cloudPath];
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return state[cloudPath];
  }

  // ── 工作池：并发 4（每连接独立限速，并行即加速） ──────────────────
  static const _maxConcurrent = 4;
  final _queue = <Future<void> Function()>[];
  int _active = 0;

  void _enqueue(Future<void> Function() task, {required bool highPriority}) {
    if (highPriority) {
      _queue.insert(0, task);
    } else {
      _queue.add(task);
    }
    _pump();
  }

  void _pump() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _active++;
      task().whenComplete(() {
        _active--;
        _pump();
      });
    }
  }

  /// 列表期探测：解析直链 → 探头。
  Future<void> _probeTask(CloudPlayContext ctx, int durationHintSecs) async {
    try {
      await _ensureIndexLoaded();
      if (state[ctx.path] != null) return;
      final provider = cloudProviderById(ctx.provider);
      if (provider == null) return;

      // 凭据：先按绑定的 accountId 精确取，再退该盘单账号便捷读取
      var cred = ctx.accountId == '_' || ctx.accountId.isEmpty
          ? null
          : await CloudCredentialsStore.instance.credFor(
              provider.id,
              ctx.accountId,
            );
      cred ??= await CloudCredentialsStore.instance.soleCredFor(provider.id);
      final fromShare = ctx.share != null && ctx.share!.directPlayable;
      if (cred == null && !fromShare) return;

      CloudDirectLink link;
      final cached = await DirectLinkCache.instance.get(
        ctx.path,
        provider.directLinkTtl,
      );
      if (cached != null) {
        link = cached;
      } else {
        link = await (fromShare
            ? provider.getShareDirectLink(
                cred ?? const {},
                ctx.share!,
                ctx.file,
              )
            : provider.getDirectLink(cred ?? const {}, ctx.file));
        DirectLinkCache.instance.put(ctx.path, link);
      }
      await _probeDirect(link.url, link.headers, ctx.path, durationHintSecs);
    } catch (e) {
      // 失败静默：列表期探测不打扰用户（播放期探针仍会兜底）
      AppLog.debug('cloud', '头部元数据预探失败: ${ctx.file.name} $e');
    }
  }

  /// 调 Rust 探头并回填状态表。
  Future<CloudHeadMetaEntry?> _probeDirect(
    String url,
    Map<String, String> headers,
    String cloudPath,
    int durationHintSecs,
  ) async {
    try {
      final dataDir = await ref.read(appDataDirProvider.future);
      final cacheRoot = await ref.read(coverCacheRootProvider.future);
      final json = await rust.cloudMetaProbeHead(
        dataDir: dataDir,
        cacheRoot: cacheRoot,
        url: url,
        headersJson: headers.isEmpty ? '' : jsonEncode(headers),
        cloudPath: cloudPath,
        durationHintSecs: durationHintSecs < 0 ? 0 : durationHintSecs,
      );
      final entry = CloudHeadMetaEntry.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      state = {...state, cloudPath: entry};
      return entry;
    } catch (e) {
      _failed.add(cloudPath);
      AppLog.debug('cloud', '头部元数据探测失败: $cloudPath $e');
      return null;
    }
  }
}
