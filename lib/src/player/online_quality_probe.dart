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
  final idx = _rankOf(quality, kQualityLadder);
  if (idx >= _losslessStart && isDegradedLossless(quality, url)) {
    return idx > _losslessStart ? kQualityLadder[idx - 1] : '320k';
  }
  return quality;
}

/// 单档探测结果：直链 + 修正后的实际音质。
class QualityProbeResult {
  const QualityProbeResult({required this.url, required this.quality});
  final String url;
  final String quality;
}

/// 每首歌共享一轮音质探测。
class SongQualityProbe {
  SongQualityProbe({required this.resolveQuality, this.maxConcurrency = 3});

  /// 单档解析回调（LX 或插件），由调用方按歌曲类型注入。
  final Future<String?> Function(String quality) resolveQuality;
  final int maxConcurrency;

  final Map<String, Future<QualityProbeResult?>> _perQuality = {};
  final List<QualityProbeResult> _done = [];
  final ListQueue<Future<void> Function()> _queue = ListQueue();
  int _active = 0;
  bool _disposed = false;

  /// 是否仍有档位在排队或解析中。
  bool get probing => _disposed ? false : _active > 0 || _queue.isNotEmpty;

  /// 探测（或复用）指定档位直链。同档并发/连发共享同一个 Future。
  Future<QualityProbeResult?> probe(String quality) {
    final existing = _perQuality[quality];
    if (existing != null) return existing;
    if (_disposed) return Future.value(null);

    final future = _runInSlot(() async {
      if (_disposed) return null;
      final url = await resolveQuality(quality);
      if (url == null || url.isEmpty) return null;
      final actual = resolveActualQuality(quality, url);
      _done.add(QualityProbeResult(url: url, quality: actual));
      return QualityProbeResult(url: url, quality: actual);
    });
    _perQuality[quality] = future;
    return future;
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

  /// 探测完成的真实可用档位（按实际音质去重，高 → 低）。
  List<String> get availableQualities {
    final seen = <String>{};
    final out = <String>[];
    for (final r in _done.reversed) {
      if (seen.add(r.quality)) out.add(r.quality);
    }
    return out;
  }

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
    Future<String?> Function(String q) resolve,
  ) {
    return _registry.putIfAbsent(
      songKey,
      () => SongQualityProbe(
        resolveQuality: resolve,
        maxConcurrency: maxConcurrency,
      ),
    );
  }

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