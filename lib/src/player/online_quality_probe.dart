
import 'dart:async';
import 'dart:collection';

import 'media_url.dart';

const List<String> kQualityLadder = [
  'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
  'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
];

const int _losslessStart = 4;

const Duration kProbeFailCooldown = Duration(milliseconds: 3000);

final RegExp _rateLimitPattern = RegExp(
  r'请求过于频繁|访问过于频繁|频率限制|请求太频繁|rate.?limit|too many requests|频繁|frequent',
  caseSensitive: false,
);

int _rankOf(String q, List<String> ladder) {
  final i = ladder.indexOf(q);
  return i < 0 ? -1 : i;
}

bool isLosslessQuality(String q) => _rankOf(q, kQualityLadder) >= _losslessStart;

const Set<String> _lossyHints = {
  '.mp3', '.m4a', '.aac', '.ogg', '.wma', '.wmv', '.opus', '.webm',
};

bool isDegradedLossless(String quality, String url) {
  if (!isLosslessQuality(quality)) return false;
  final u = url.toLowerCase().split('?').first;
  return _lossyHints.any(u.contains);
}

String resolveActualQuality(String quality, String url) {
  if (!isDegradedLossless(quality, url)) return quality;
  final idx = _rankOf(quality, kQualityLadder);
  if (idx <= 0) return quality;
  for (var i = idx - 1; i >= 0; i--) {
    if (!isLosslessQuality(kQualityLadder[i])) return kQualityLadder[i];
  }
  return quality;
}

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

  final String? requested;

  final String? ekey;
}

class QualitySizeInfo {
  const QualitySizeInfo({required this.url, required this.bytes});
  final String url;
  final int bytes;
}

class SongQualityProbe {
  SongQualityProbe({required Future<ResolvedMediaUrl?> Function(String quality) resolveQuality, this.maxConcurrency = 3})
      : _resolveQuality = resolveQuality;

  Future<ResolvedMediaUrl?> Function(String quality) _resolveQuality;
  Future<ResolvedMediaUrl?> Function(String quality) get resolveQuality =>
      _resolveQuality;
  final int maxConcurrency;

  final Map<String, Future<QualityProbeResult?>> _perQuality = {};
  final List<QualityProbeResult> _done = [];

  /// 最近一次探测失败的原因（音质: 错误文本），用于失败提示透传。
  String? lastFailureReason;
  List<String> _trustedDeclared = const [];
  final ListQueue<Future<void> Function()> _queue = ListQueue();
  int _active = 0;
  bool _disposed = false;
  DateTime? _cooldownUntil;
  bool _rateLimited = false;
  bool _seeded = false;

  void attachResolver(Future<ResolvedMediaUrl?> Function(String quality) resolve) {
    _resolveQuality = resolve;
  }

  void markFailed() {
    if (_done.isNotEmpty || _rateLimited) return;
    _cooldownUntil = DateTime.now().add(kProbeFailCooldown);
  }

  bool get failedRecently {
    final t = _cooldownUntil;
    return t != null && DateTime.now().isBefore(t);
  }

  bool get rateLimited => _rateLimited;

  bool get seeded => _seeded;

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

  void trustDeclared(List<String> declared) {
    final listed = kQualityLadder.reversed
        .where(declared.contains)
        .toList();
    if (listed.isEmpty) return;
    _trustedDeclared = listed;
  }

  bool get probing => _disposed ? false : _active > 0 || _queue.isNotEmpty;

  Future<QualityProbeResult?> probe(String quality) {
    final existing = _perQuality[quality];
    if (existing != null) return existing;
    if (_disposed) return Future.value(null);
    if (failedRecently || _rateLimited) return Future.value(null);

    final future = _runInSlot(() async {
      if (_disposed) return null;
      if (failedRecently || _rateLimited) return null;
      final ResolvedMediaUrl? res;
      try {
        res = await _resolveQuality(quality);
      } catch (e) {
        lastFailureReason = '$quality: ${e.toString()}';
        if (_rateLimitPattern.hasMatch(e.toString())) {
          _rateLimited = true;
          _queue.clear();
          _cooldownUntil = DateTime.now().add(kProbeFailCooldown);
        }
        return null;
      }
      if (res == null || res.url.isEmpty) {
        lastFailureReason ??= '$quality: 无结果';
        return null;
      }
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

  int _rankOrMax(String q) {
    final r = _rankOf(q, kQualityLadder);
    return r < 0 ? 1 << 30 : r;
  }

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

  List<QualityProbeResult> get resolved => List.unmodifiable(_done);

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
    markFailed();
    return null;
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
  }
}

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
      if (existing.probing ||
          existing.resolved.isNotEmpty ||
          existing.seeded ||
          existing.failedRecently) {
        if (existing.seeded) existing.attachResolver(resolve);
        return existing;
      }
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

final OnlineQualityProbeRegistry onlineQualityProbeRegistry =
    OnlineQualityProbeRegistry(maxConcurrency: 3);