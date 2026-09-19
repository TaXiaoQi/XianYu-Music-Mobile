
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'media_url.dart';

class AudioHeadEntry {
  const AudioHeadEntry({
    required this.bytes,
    required this.rangeOk,
    required this.totalLength,
    this.contentType,
    required this.storedAt,
  });

  final Uint8List bytes;

  final bool rangeOk;

  final int totalLength;

  final String? contentType;

  final DateTime storedAt;
}

class AudioHeadCache {
  AudioHeadCache._();

  static final AudioHeadCache instance = AudioHeadCache._();

  static const int _maxEntries = 12;
  static const int _maxTotalBytes = 24 * 1024 * 1024;
  static const Duration _ttl = Duration(minutes: 15);

  static const int _maxReadGuard = 8 * 1024 * 1024;

  final Map<String, AudioHeadEntry> _heads = {};
  int _totalBytes = 0;

  final Map<String, Map<String, String>> _headersBy = {};

  final Set<String> _inflight = {};

  void registerHeaders(String url, Map<String, String>? headers) {
    final key = sanitizeMediaUrl(url);
    if (key.isEmpty || headers == null || headers.isEmpty) return;
    final cleaned = <String, String>{};
    headers.forEach((k, v) {
      final name = k.trim();
      final value = v.trim();
      if (name.isEmpty || value.isEmpty) return;
      if (name.toLowerCase() == 'range') return;
      cleaned[name] = value;
    });
    if (cleaned.isNotEmpty) _headersBy[key] = cleaned;
  }

  Map<String, String>? headersFor(String url) {
    final key = sanitizeMediaUrl(url);
    final hit = _headersBy[key];
    if (hit == null) return null;
    return Map<String, String>.of(hit);
  }

  AudioHeadEntry? lookup(String url) {
    final key = sanitizeMediaUrl(url);
    final entry = _heads.remove(key);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.storedAt) > _ttl) {
      _totalBytes -= entry.bytes.length;
      return null;
    }
    _heads[key] = entry;
    return entry;
  }

  AudioHeadEntry? lookupForPlay(String url) {
    final entry = lookup(url);
    if (entry == null ||
        !entry.rangeOk ||
        entry.bytes.isEmpty ||
        entry.totalLength <= 0) {
      return null;
    }
    return entry;
  }

  Future<bool> prefetch({
    required String url,
    Map<String, String>? headers,
    required int maxBytes,
  }) async {
    final key = sanitizeMediaUrl(url);
    if (key.isEmpty || !key.startsWith('http')) return false;
    registerHeaders(key, headers);
    if (lookup(key) != null) return false;
    if (!_inflight.add(key)) return false;
    try {
      final entry = await _fetchHead(key, headers, maxBytes);
      if (entry == null) return false;
      final old = _heads.remove(key);
      if (old != null) _totalBytes -= old.bytes.length;
      _heads[key] = entry;
      _totalBytes += entry.bytes.length;
      _evict();
      return true;
    } catch (_) {
      return false;
    } finally {
      _inflight.remove(key);
    }
  }

  void _evict() {
    while (_heads.isNotEmpty &&
        (_heads.length > _maxEntries || _totalBytes > _maxTotalBytes)) {
      final oldestKey = _heads.keys.first;
      final entry = _heads.remove(oldestKey);
      if (entry != null) _totalBytes -= entry.bytes.length;
    }
  }

  Future<AudioHeadEntry?> _fetchHead(
    String url,
    Map<String, String>? headers,
    int maxBytes,
  ) async {
    final clamped = maxBytes.clamp(64 * 1024, _maxReadGuard);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${clamped - 1}');
      headers?.forEach((k, v) {
        final name = k.trim();
        final value = v.trim();
        if (name.isEmpty || value.isEmpty) return;
        final lower = name.toLowerCase();
        if (lower == 'range' || lower == 'host' || lower == 'content-length') {
          return;
        }
        try {
          req.headers.set(name, value);
        } catch (_) {}
      });
      final resp = await req.close().timeout(const Duration(seconds: 20));

      final contentType =
          resp.headers.value(HttpHeaders.contentTypeHeader)?.toLowerCase() ??
              '';
      final nonAudio = contentType.contains('text/html') ||
          contentType.contains('application/json') ||
          contentType.contains('text/plain') ||
          contentType.contains('xml');
      if (nonAudio) {
        await resp.drain<void>().catchError((_) {});
        return null;
      }

      if (resp.statusCode == HttpStatus.partialContent) {
        final bytes = await _readUpTo(resp, clamped);
        if (bytes.isEmpty) return null;
        return AudioHeadEntry(
          bytes: bytes,
          rangeOk: true,
          totalLength: _parseTotalLength(resp),
          contentType: contentType.isNotEmpty ? contentType : null,
          storedAt: DateTime.now(),
        );
      }

      if (resp.statusCode == HttpStatus.ok) {
        await _readUpTo(resp, 64 * 1024);
        return null;
      }

      await resp.drain<void>().catchError((_) {});
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _readUpTo(HttpClientResponse resp, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
      if (builder.length >= maxBytes) break;
    }
    var bytes = builder.takeBytes();
    if (bytes.length > maxBytes) {
      bytes = Uint8List.sublistView(bytes, 0, maxBytes);
    }
    return bytes;
  }

  int _parseTotalLength(HttpClientResponse resp) {
    final contentRange =
        resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    final slash = contentRange.lastIndexOf('/');
    if (slash < 0 || slash == contentRange.length - 1) return 0;
    final totalStr = contentRange.substring(slash + 1).trim();
    return int.tryParse(totalStr) ?? 0;
  }

  void clear() {
    _heads.clear();
    _totalBytes = 0;
    _headersBy.clear();
    _inflight.clear();
  }
}
