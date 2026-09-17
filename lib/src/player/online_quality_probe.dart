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

/// 失败冷却窗口（对齐桌面 PROBE_FAIL_TTL_MS=3000）：整轮探测全空后，
/// 短窗口内复用失败态，不再重复请求音源。
const Duration kProbeFailCooldown = Duration(milliseconds: 3000);

/// 风控错误文案（对齐桌面 rateLimitPattern）：命中后清空队列停手冷却，
/// 避免继续打音源接口被风控加重。
final RegExp _rateLimitPattern = RegExp(
  r'请求过于频繁|访问过于频繁|频率限制|请求太频繁|rate.?limit|too many requests|频繁|frequent',
  caseSensitive: false,
);

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
    this.requested,
    this.headers,
    this.ekey,
  });
  final String url;
  final String quality;
  final Map<String, String>? headers;

  /// 发起探测时请求的档位（可能因插件静默降级而高于 [quality]）。
  /// 体积表按键需对齐菜单展示档，降级时靠它把实测体积挂回请求档。
  final String? requested;

  /// 可选 QMC2 加密密钥（base64）：加密源经探针转交播放端下载解密链路。
  final String? ekey;
}

/// 档位体积信息：直链 + 实测文件字节数（对齐桌面端弹窗「扩展名 · 体积」）。
class QualitySizeInfo {
  const QualitySizeInfo({required this.url, required this.bytes});
  final String url;
  final int bytes;
}

/// 每首歌共享一轮音质探测。
class SongQualityProbe {
  SongQualityProbe({required Future<ResolvedMediaUrl?> Function(String quality) resolveQuality, this.maxConcurrency = 3})
      : _resolveQuality = resolveQuality;

  /// 单档解析回调（LX 或插件），由调用方按歌曲类型注入；播种探针重建时
  /// 经 [attachResolver] 替换，保留已注入直链。
  Future<ResolvedMediaUrl?> Function(String quality) _resolveQuality;
  Future<ResolvedMediaUrl?> Function(String quality) get resolveQuality =>
      _resolveQuality;
  final int maxConcurrency;

  final Map<String, Future<QualityProbeResult?>> _perQuality = {};
  final List<QualityProbeResult> _done = [];
  /// 信任声明档位：Baka 插件最高档实测未降级后直接采用声明档列表，免逐档实测。
  List<String> _trustedDeclared = const [];
  final ListQueue<Future<void> Function()> _queue = ListQueue();
  int _active = 0;
  bool _disposed = false;
  /// 失败冷却：整轮探测全空后短窗口内复用失败态（对齐桌面 PROBE_FAIL_TTL_MS）。
  DateTime? _cooldownUntil;
  /// 风控停手：命中「请求过于频繁」等文案后清空队列，冷却窗口内不再发起探测。
  bool _rateLimited = false;
  /// 预取直链播种标记：仅全新探针可注入（对齐桌面 seedSharedProbeUrl）。
  bool _seeded = false;

  /// 替换单档解析回调（对齐桌面 seeded 探针就地重建完整探测轮）。
  void attachResolver(Future<ResolvedMediaUrl?> Function(String quality) resolve) {
    _resolveQuality = resolve;
  }

  /// 整轮探测失败（所有档位均未解析出直链）后标记：进入失败冷却，
  /// 冷却窗口内 [probe] 快速返回 null，避免反复请求音源。
  void markFailed() {
    if (_done.isNotEmpty || _rateLimited) return;
    _cooldownUntil = DateTime.now().add(kProbeFailCooldown);
  }

  /// 是否处于失败冷却窗口内。
  bool get failedRecently {
    final t = _cooldownUntil;
    return t != null && DateTime.now().isBefore(t);
  }

  /// 是否已因风控停手（清空队列 + 冷却窗口内不再发起任何探测）。
  bool get rateLimited => _rateLimited;

  /// 是否已注入预取直链（起播复用，尚无真实整轮探测）。
  bool get seeded => _seeded;

  /// 预取直链播种：仅当本轮尚无任何真实解析结果时注入（对齐桌面
  /// seedSharedProbeUrl 的「运行中/已有真实结果不覆盖」语义），并把该档
  /// 直链同时写入档位缓存，后续 [probe] 直接命中不重复解析。
  void seed(String quality, String url,
      {Map<String, String>? headers, String? ekey}) {
    if (_seeded || _done.isNotEmpty || _rateLimited || url.isEmpty) return;
    _seeded = true;
    final result = QualityProbeResult(
      url: url,
      quality: quality,
      requested: quality,
      headers: headers,
      ekey: ekey,
    );
    _done.add(result);
    _perQuality[quality] = Future.value(result);
  }

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
    // 失败冷却/风控停手窗口内快速返回，不再重复请求音源（对齐桌面 fail TTL）。
    if (failedRecently || _rateLimited) return Future.value(null);

    final future = _runInSlot(() async {
      if (_disposed) return null;
      if (failedRecently || _rateLimited) return null;
      final ResolvedMediaUrl? res;
      try {
        res = await _resolveQuality(quality);
      } catch (e) {
        // 单档解析异常不抛给调用方；命中风控文案时清空队列停手并进入冷却
        // （对齐桌面 worker 检测到「请求过于频繁」后清队抛错停止整轮）。
        if (_rateLimitPattern.hasMatch(e.toString())) {
          _rateLimited = true;
          _queue.clear();
          _cooldownUntil = DateTime.now().add(kProbeFailCooldown);
        }
        return null;
      }
      if (res == null || res.url.isEmpty) return null;
      // 优先采用插件报告的实际音质（res.quality）而非请求档位——插件可能把
      // flac 请求静默降级为 128k 并如实报告，此时要修正到报告档，再叠加
      // 无损扩展名校验兜底，避免 UI 出现与体积对不上的「假音质」。
      final actual = resolveActualQuality(res.quality ?? quality, res.url);
      _done.add(QualityProbeResult(
        url: res.url,
        quality: actual,
        requested: quality,
        headers: res.headers,
        ekey: res.ekey,
      ));
      _dedupeSameUrl();
      return QualityProbeResult(
        url: res.url,
        quality: actual,
        requested: quality,
        headers: res.headers,
        ekey: res.ekey,
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
            requested: _done[i].requested,
            headers: _done[i].headers,
            ekey: _done[i].ekey,
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
    // 整轮起播全空 → 标记失败冷却，冷却窗口内重复起播不再反复请求音源
    // （对齐桌面整轮探测全空后 failAt 冷却）。
    markFailed();
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
    final existing = _registry[songKey];
    if (existing != null) {
      // 运行中、已有成果（含播种直链）或失败冷却内 → 复用同一轮探测。
      // 播种探针：保留已注入直链，替换解析回调后继续补探测
      // （对齐桌面 ensureSharedQualityProbe 对 seeded 探针就地重建完整轮）。
      if (existing.probing ||
          existing.resolved.isNotEmpty ||
          existing.seeded ||
          existing.failedRecently) {
        if (existing.seeded) existing.attachResolver(resolve);
        return existing;
      }
      // 冷却已过且无成果 → 重建（dispose 旧探针，避免残留探测继续跑）。
      _registry.remove(songKey);
      existing.dispose();
    }
    final probe = SongQualityProbe(
      resolveQuality: resolve,
      maxConcurrency: maxConcurrency,
    );
    _registry[songKey] = probe;
    return probe;
  }

  /// 预取直链播种（对齐桌面 seedSharedProbeUrl）：起播拿到直链后注入注册表，
  /// 仅当该歌尚无真实探测轮时生效；已有真实结果/运行中不覆盖。无探针时以
  /// 空解析回调创建（后续 ensure 命中播种探针会替换为真实回调）。
  void seed(String songKey, String quality, String url,
      {Map<String, String>? headers, String? ekey}) {
    final probe = _registry[songKey];
    if (probe == null) {
      _registry[songKey] = SongQualityProbe(
        resolveQuality: (_) async => null,
        maxConcurrency: maxConcurrency,
      )..seed(quality, url, headers: headers, ekey: ekey);
      return;
    }
    probe.seed(quality, url, headers: headers, ekey: ekey);
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