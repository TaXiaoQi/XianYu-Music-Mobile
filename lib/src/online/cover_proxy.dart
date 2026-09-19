import 'dart:convert';
import 'dart:typed_data';

import '../rust/api.dart';

class CoverProxy {
  CoverProxy._();

  static const _proxyDomains = <String>[
    'hdslb.com',
    'bilivideo.com',
    'y.gtimg.cn',
    'qpic.cn',
    'sycdn.kuwo.cn',
    'img3.kuwo.cn',
    'img4.kuwo.cn',
    'kwimg',
    'kwcdn.kuwo.cn',
    'music.126.net',
    '163.com',
    'musicapp.migu.cn',
    'migu.cn',
  ];

  static const _maxEntries = 48;
  static const _maxTotalBytes = 24 * 1024 * 1024;
  static final Map<String, Uint8List> _cache = {};
  static int _totalBytes = 0;

  static final Map<String, DateTime> _failed = {};

  static const retryAfter = Duration(seconds: 20);

  static bool needsProxy(String url) {
    if (url.isEmpty) return false;
    if (url.startsWith('data:')) return false;
    if (url.startsWith('http://')) return true;
    return _proxyDomains.any(url.contains);
  }

  static Uint8List? cached(String url) {
    final hit = _cache.remove(url);
    if (hit == null) return null;
    _cache[url] = hit;
    return hit;
  }

  static bool hasFailed(String url) {
    final t = _failed[url];
    if (t == null) return false;
    return DateTime.now().difference(t) < retryAfter;
  }

  static Future<Uint8List?> fetch(String url) async {
    if (url.isEmpty) return null;
    final hit = cached(url);
    if (hit != null) return hit;
    if (hasFailed(url)) return null;

    try {
      final dataUrl = await proxyImage(url: url);
      final bytes = _decodeDataUrl(dataUrl);
      if (bytes == null) {
        _failed[url] = DateTime.now();
        return null;
      }
      final old = _cache.remove(url);
      if (old != null) _totalBytes -= old.length;
      _cache[url] = bytes;
      _totalBytes += bytes.length;
      _evict();
      _failed.remove(url);
      return bytes;
    } catch (_) {
      _failed[url] = DateTime.now();
      return null;
    }
  }

  static void _evict() {
    while (_cache.isNotEmpty &&
        (_cache.length > _maxEntries || _totalBytes > _maxTotalBytes)) {
      final oldest = _cache.keys.first;
      _totalBytes -= _cache.remove(oldest)!.length;
    }
  }

  static Uint8List? _decodeDataUrl(String dataUrl) {
    final idx = dataUrl.indexOf(',');
    if (idx < 0 || !dataUrl.startsWith('data:')) return null;
    try {
      return base64Decode(dataUrl.substring(idx + 1));
    } catch (_) {
      return null;
    }
  }

  static void clear() {
    _cache.clear();
    _totalBytes = 0;
    _failed.clear();
  }
}
