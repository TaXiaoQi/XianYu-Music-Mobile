// online_precache.dart — 在线歌曲预缓存编排（移动端）
//
// 对齐桌面端 onlinePrecache.ts：本首在线歌开播成功后，对播放队列之后
// 最多 5 首在线歌串行预取，让用户切下一首时即点即播：
//   1. 音质元数据 + 目标音质直链（以播放设置为主；不可用按回退策略
//      降级/升级；'pause' 策略严格只试首选）——结果播种进共享音质探测
//      注册表，起播时直接命中已完成探测，跳过插件解析等待；
//   2. 封面（CoverProxy LRU，有界 48 条 / 24MB）；
//   3. 歌词（LyricsRepository 内存缓存，有界 24 条）；
//   4. 目标音质的约 15 秒片头音频字节（AudioHeadCache，内存 LRU
//      12 条 / 24MB / 15 分钟 TTL，仅缓存支持 Range 的直链）。
//
// 切歌应用链路：起播解析命中播种直链（无插件等待）→ 本地代理直出片头
// → 歌词/封面命中缓存 → 秒开。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lyrics/lyrics_repository.dart';
import '../online/cover_proxy.dart';
import 'audio_head_cache.dart';
import 'media_url.dart';
import 'online_quality_probe.dart';
import 'player_provider.dart';

/// 预取范围：队列后续 5 首。
const int _maxPrefetchSongs = 5;

/// 同一首歌预取结果复用窗口：窗口内不重复请求。
const Duration _prefetchTtl = Duration(minutes: 10);

/// 单首预取整体限时：超时放弃该首，继续下一首。
const Duration _perSongTimeout = Duration(seconds: 45);

/// 各音质档「15 秒片头」估算字节数（≈15s × 档位码率 × 1.1 余量）。
/// 与桌面端 HEAD_BYTES_BY_QUALITY 对齐；缓存侧另有 8MB 硬上限兜底。
int estimateHeadBytes(String quality) {
  switch (quality) {
    case 'mgg':
    case '128k':
      return 260_000;
    case '192k':
      return 380_000;
    case '320k':
      return 630_000;
    case 'flac':
      return 2_700_000;
    case 'flac24bit':
    case 'vinyl':
    case 'dolby':
    case 'atmos':
      return 3_300_000;
    case 'hires':
      return 4_600_000;
    case 'atmos_plus':
      return 4_400_000;
    case 'master':
      return 5_800_000;
    default:
      return 2_700_000;
  }
}

/// 预缓存编排器（单例）。
class OnlinePrecache {
  OnlinePrecache._();

  static final OnlinePrecache instance = OnlinePrecache._();

  /// 歌曲探测 key → 最近一次预取时刻（TTL 去重）。
  final Map<String, DateTime> _recent = {};

  /// 调代数：新一轮调度发起后，旧调度串行循环检测到代差即退出，
  /// 避免连续切歌时预取队列堆积。
  int _generation = 0;

  /// 本首在线歌开播成功后调用：确定可预知的「下一首」序列并逐首预取。
  ///
  /// - 单曲循环（1）：无下一首，跳过
  /// - 随机模式（2）：下一首不可预知，跳过（避免无意义流量）
  /// - 主队列当前歌曲之后的顺序列表（不绕回），过滤在线歌取前 5 首
  void schedule({
    required Ref ref,
    required PlayerNotifier notifier,
    required List<QueueItem> queue,
    required int queueIndex,
    required int playMode,
    required String? currentPath,
    required String preferred,
    required String fallback,
  }) {
    try {
      if (playMode == 1 || playMode == 2) return;
      if (currentPath == null || currentPath.isEmpty) return;
      if (queueIndex < 0 || queueIndex + 1 >= queue.length) return;

      final upcoming = queue
          .sublist(queueIndex + 1)
          .where((s) => s.isOnline)
          .take(_maxPrefetchSongs)
          .toList();
      if (upcoming.isEmpty) return;

      final gen = ++_generation;
      unawaited(_run(gen, ref, notifier, upcoming, preferred, fallback));
    } catch (_) {
      // 预缓存调度失败不影响播放。
    }
  }

  Future<void> _run(
    int gen,
    Ref ref,
    PlayerNotifier notifier,
    List<QueueItem> upcoming,
    String preferred,
    String fallback,
  ) async {
    // 候选链由播放设置推导：'lower' 向下降级 / 'higher' 向上升级 /
    // 'pause' 严格只试首选（与起播链一致，保证预取音质 = 将来播放音质）。
    final candidates = notifier.precacheCandidates(preferred, fallback);
    // 串行逐首预取：避免 5 首并发打满带宽影响当前播放缓冲。
    for (final item in upcoming) {
      if (gen != _generation) return;
      try {
        await _prefetchOne(gen, ref, notifier, item, candidates)
            .timeout(_perSongTimeout, onTimeout: () {});
      } catch (_) {
        // 单首预取失败不阻塞后续。
      }
    }
  }

  /// 预取单首歌：音质直链（播种共享探针）→ 歌词 → 封面 → 15 秒片头。
  Future<void> _prefetchOne(
    int gen,
    Ref ref,
    PlayerNotifier notifier,
    QueueItem item,
    List<String> candidates,
  ) async {
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json == null || json.isEmpty) return;
    final Map<String, dynamic> songJson;
    try {
      songJson = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final key = notifier.precacheProbeKey(songJson, item);

    // TTL 去重：窗口内不重复预取同一首。
    final now = DateTime.now();
    _recent.removeWhere((_, t) => now.difference(t) > _prefetchTtl);
    if (_recent.containsKey(key)) return;
    _recent[key] = now;

    // 1) 音质元数据 + 目标音质直链：按候选链顺序探测（探测结果落在
    //    共享探针注册表内，起播 startBest 直接命中，无插件解析等待）。
    final probe = notifier.precacheProbeEnsure(songJson, item, key);
    QualityProbeResult? resolved;
    for (final q in candidates) {
      if (gen != _generation) return;
      try {
        final r = await probe.probe(q).timeout(
              const Duration(seconds: 12),
              onTimeout: () => null,
            );
        if (r != null && r.url.isNotEmpty) {
          resolved = r;
          break;
        }
      } catch (_) {}
    }
    if (resolved == null || resolved.url.isEmpty) return;

    // 2) 歌词预热：LyricsRepository 内存缓存按 path 有界 24 条。
    try {
      await ref.read(lyricsRepositoryProvider).fetchLyrics(item).timeout(
            const Duration(seconds: 10),
            onTimeout: () => const [],
          );
    } catch (_) {}

    // 3) 封面预热：CoverProxy LRU 有界（48 条 / 24MB）。
    final cover = item.coverUrl;
    if (cover != null && cover.isNotEmpty && !cover.startsWith('file:')) {
      unawaited(CoverProxy.fetch(cover));
    }

    // 4) 15 秒片头：与播放同源请求头（normalizeMediaRequestHeaders 补齐
    //    防盗链 Referer/Origin/UA），仅缓存支持 Range 的直链。
    final headers = normalizeMediaRequestHeaders(resolved.url, resolved.headers);
    await AudioHeadCache.instance.prefetch(
      url: resolved.url,
      headers: headers,
      maxBytes: estimateHeadBytes(resolved.quality),
    );
  }
}
