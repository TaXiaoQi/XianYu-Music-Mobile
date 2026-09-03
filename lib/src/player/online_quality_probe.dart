// online_quality_probe.dart - 在线歌曲共享音质探测
//
// 对齐桌面端 qualitySharedProbe / probeDownloadableQualities / audioQualityVerify
// 的能力，为移动端在线引擎补齐：
// - 同一首歌、同一音质档并发/连发去重（一个 Future 共享一次真实解析）
// - 受控并发（最多同时探测的档位数量）
// - 音质降级校验：请求无损档却拿到有损扩展名直链时，识别为被静默降级，
//   并向下回落实际音质，避免菜单/结果虚高
// - 记录真实可用档位，供音质菜单展示、档位切换、下载复用同一轮探测
//
// 本文件只做编排，不直接发网络请求；真正的单档解析由调用方以回调注入。

import 'dart:async';
import 'dart:collection';

import 'media_url.dart';

/// 12 档音质阶梯（低 → 高），与播放器/设置/下载一致。
const List<String> kQualityLadder = [
  'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
  'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
];

/// 首个无损档下标（flac），往下为有损档。
const int _losslessStart = 4;

int _rankOf(String q, List<String> ladder) {
  final i = ladder.indexOf(q);
  return i < 0 ? -1 : i;
}

/// 是否无损档位（flac 及以上）。
bool isLosslessQuality(String q) => _rankOf(q, kQualityLadder) >= _losslessStart;

const Set<String> _lossyHints = {
  '.mp3', '.m4a', '.aac', '.ogg', '.wma', '.wmv', '.opus', '.webm',
};

/// 无损档请求却返回有损扩展名直链 → 判定被静默降级。
bool isDegradedLossless(String quality, String url) {
  if (!isLosslessQuality(quality)) return false;
  final u = url.toLowerCase().split('?').first;
  return _lossyHints.any(u.contains);
}

/// 修正实际音质：被降级的无损档回落到紧邻的较低无损档；再低则落到 320k。
String resolveActualQuality(String quality, String url) {
  if (!isDegradedLossless(quality, url)) return quality;
  final idx = _rankOf(quality, kQualityLadder);
  if (idx <= 0) return quality;
  // 对齐桌面端 audioQualityVerify：从声称档向下找最近的非无损档，而不是硬编码 320k。
  for (var i = idx - 1; i >= 0; i--) {
    if (!isLosslessQuality(kQualityLadder[i])) return kQualityLadder[i];
  }
  return quality;
}

/// 单档探测结果：直链 + 修正后的实际音质 + 可选请求头。
class QualityProbeResult {
  const QualityProbeResult({
    required this.url,
    required this.quality,
    this.headers,
  });
  final String url;
  final String quality;
  final Map<String, String>? headers;
}

/// 档位体积信息：直链 + 实测文件字节数（对齐桌面端弹窗「扩展名 · 体积」）。
class QualitySizeInfo {
  const QualitySizeInfo({required this.url, required this.bytes});
  final String url;
  final int bytes;
}

/// 每首歌共享一轮音质探测。
class SongQualityProbe {
  SongQualityProbe({required this.resolveQuality, this.maxConcurrency = 3});

  /// 单档解析回调（LX 或插件），由调用方按歌曲类型注入。
  final Future<ResolvedMediaUrl?> Function(String quality) resolveQuality;
  final int maxConcurrency;

  final Map<String, Future<QualityProbeResult?>> _perQuality = {};
  final List<QualityProbeResult> _done = [];
  /// 信任声明档位：Baka 插件最高档实测未降级后直接采用声明档列表，免逐档实测。
  List<String> _trustedDeclared = const [];
  final ListQueue<Future<void> Function()> _queue = ListQueue();
  int _active = 0;
  bool _disposed = false;

  /// 信任声明档：将声明档位并入可用列表（对齐桌面 probeDownloadableQualities 的
  /// Baka 快径）。只影响音质菜单展示；直链/体积仍以实际解析结果为准。
  void trustDeclared(List<String> declared) {
    final listed = kQualityLadder.reversed
        .where(declared.contains)
        .toList();
    if (listed.isEmpty) return;
    _trustedDeclared = listed;
  }

  /// 是否仍有档位在排队或解析中。
  bool get probing => _disposed ? false : _active > 0 || _queue.isNotEmpty;

  /// 探测（或复用）指定档位直链。同档并发/连发共享同一个 Future。
  Future<QualityProbeResult?> probe(String quality) {
    final existing = _perQuality[quality];
    if (existing != null) return existing;
    if (_disposed) return Future.value(null);

    final future = _runInSlot(() async {
      if (_disposed) return null;
      final res = await resolveQuality(quality);
      if (res == null || res.url.isEmpty) return null;
      // 优先采用插件报告的实际音质（res.quality）而非请求档位——插件可能把
      // flac 请求静默降级为 128k 并如实报告，此时要修正到报告档，再叠加
      // 无损扩展名校验兜底，避免 UI 出现与体积对不上的「假音质」。
      final actual = resolveActualQuality(res.quality ?? quality, res.url);
      _done.add(QualityProbeResult(
        url: res.url,
        quality: actual,
        headers: res.headers,
      ));
      _dedupeSameUrl();
      return QualityProbeResult(
        url: res.url,
        quality: actual,
        headers: res.headers,
      );
    });
    _perQuality[quality] = future;
    return future;
  }

  /// 档位排名未知（不在阶梯内）时视为最高，不参与「归到最低档」。
  int _rankOrMax(String q) {
    final r = _rankOf(q, kQualityLadder);
    return r < 0 ? 1 << 30 : r;
  }

  /// 同直链去重：部分音源插件对不同档位请求返回同一个低音质直链
  /// （典型表现：音质菜单里每个档位体积都是同一个 ~4MB 文件）。
  /// 同一 URL 被多个档位解析出时，全部归并到该文件实际归属的
  /// 最低档，保证菜单/当前音质/体积展示与真实文件一致。
  /// 探测受控并发完成顺序不定，故在每次新增结果后全量修正一次。
  void _dedupeSameUrl() {
    final byUrl = <String, List<int>>{};
    for (var i = 0; i < _done.length; i++) {
      byUrl.putIfAbsent(_done[i].url, () => []).add(i);
    }
    for (final indices in byUrl.values) {
      if (indices.length < 2) continue;
      var bestIdx = indices.first;
      var bestRank = _rankOrMax(_done[bestIdx].quality);
      for (final i in indices.skip(1)) {
        final r = _rankOrMax(_done[i].quality);
        if (r < bestRank) {
          bestRank = r;
          bestIdx = i;
        }
      }
      for (final i in indices) {
        if (i == bestIdx) continue;
        if (_done[i].quality != _done[bestIdx].quality) {
          _done[i] = QualityProbeResult(
            url: _done[i].url,
            quality: _done[bestIdx].quality,
            headers: _done[i].headers,
          );
        }
      }
    }
  }

  Future<T> _runInSlot<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue.add(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _pump();
    return completer.future;
  }

  void _pump() {
    while (_active < maxConcurrency && _queue.isNotEmpty) {
      _active++;
      final task = _queue.removeFirst();
      task().whenComplete(() {
        _active--;
        _pump();
      });
    }
  }

  /// 可用档位（高 → 低，去重）：
  /// - 信任声明档优先（Baka 信任模式），保证菜单完整、不因逐档未测而残缺；
  /// - 其次并入实际解析完成的档位（按实际音质去重）。
  List<String> get availableQualities {
    final seen = <String>{};
    final out = <String>[];
    for (final q in _trustedDeclared) {
      if (seen.add(q)) out.add(q);
    }
    for (final r in _done.reversed) {
      if (seen.add(r.quality)) out.add(r.quality);
    }
    return out;
  }

  /// 已解析完成的档位结果（直链 + 实际音质 + 请求头），
  /// 供体积探测等复用，不必重复解析直链。
  List<QualityProbeResult> get resolved => List.unmodifiable(_done);

  /// 起播：并行发起候选链，返回首个可播档（首选优先）。
  ///
  /// [candidateChain] 已按起播优先级排序（首选在前）。并行发起既能快速
  /// 命中首选，也能在首选卡顿时尽早拿到降级档，避免串行等待。
  Future<QualityProbeResult?> startBest(
    String preferred,
    List<String> candidateChain, {
    int burst = 3,
  }) async {
    final chain = <String>[
      if (_rankOf(preferred, kQualityLadder) >= 0) preferred,
      ...candidateChain.where((q) => q != preferred),
    ];
    if (burst > 1) chain.take(burst).map(probe).toList();
    for (final q in chain) {
      final res = await probe(q);
      if (res != null && res.url.isNotEmpty) return res;
    }
    return null;
  }

  /// 释放本首探针持有的解析中资源（用于切歌/停止时，避免残留探测）。
  void dispose() {
    _disposed = true;
    _queue.clear();
  }
}

/// 歌曲级探测注册表：同一首歌共享一轮探测；切歌时 invalidate。
final class OnlineQualityProbeRegistry {
  OnlineQualityProbeRegistry({this.maxConcurrency = 3});

  final int maxConcurrency;
  final Map<String, SongQualityProbe> _registry = {};

  SongQualityProbe ensure(
    String songKey,
    Future<ResolvedMediaUrl?> Function(String q) resolve,
  ) {
    return _registry.putIfAbsent(
      songKey,
      () => SongQualityProbe(
        resolveQuality: resolve,
        maxConcurrency: maxConcurrency,
      ),
    );
  }

  /// 取已存在的探针（不创建），供体积探测等只读复用。
  SongQualityProbe? peek(String songKey) => _registry[songKey];

  void invalidate(String songKey) {
    final probe = _registry.remove(songKey);
    probe?.dispose();
  }

  void clear() {
    for (final p in _registry.values) {
      p.dispose();
    }
    _registry.clear();
  }
}

/// 全局共享探测注册表单例。
final OnlineQualityProbeRegistry onlineQualityProbeRegistry =
    OnlineQualityProbeRegistry(maxConcurrency: 3);