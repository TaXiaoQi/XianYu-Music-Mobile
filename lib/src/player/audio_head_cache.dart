// audio_head_cache.dart — 在线音频「15 秒片头」预取缓存（内存 LRU）
//
// 对齐桌面端 audio_head_cache.rs：本首在线歌开播时，预取播放队列之后
// 最多 5 首歌目标音质直链的头部约 15 秒音频字节存入本缓存；随后切歌时
// 本地代理服务（audio_proxy_server.dart）检测到命中，片头字节零网络延迟
// 直出、剩余区间向上游断点续传，达到「切下一首秒开」的效果。
//
// 存储约束（确保占用不多）：
// - 每条仅保存约 15 秒音频（按音质估算 0.25–6MB，见 estimateHeadBytes）
// - 条数上限 12、总字节上限 24MB、TTL 15 分钟，三重上限 + LRU 淘汰
// - 仅驻内存不落盘，进程退出即释放

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'media_url.dart';

/// 单条片头：字节内容 + 元信息。
class AudioHeadEntry {
  const AudioHeadEntry({
    required this.bytes,
    required this.rangeOk,
    required this.totalLength,
    this.contentType,
    required this.storedAt,
  });

  /// 预取到的头部字节（从 0 开始）。
  final Uint8List bytes;

  /// 服务器是否支持 Range（206）；false 时片头无法用于续传。
  final bool rangeOk;

  /// Content-Range 声明的文件总长（未知为 0）。
  final int totalLength;

  /// 上游响应的 Content-Type（代理透传用）。
  final String? contentType;

  /// 写入时刻（TTL 与 LRU 依据）。
  final DateTime storedAt;
}

/// 片头缓存单例。
class AudioHeadCache {
  AudioHeadCache._();

  static final AudioHeadCache instance = AudioHeadCache._();

  static const int _maxEntries = 12;
  static const int _maxTotalBytes = 24 * 1024 * 1024;
  static const Duration _ttl = Duration(minutes: 15);

  /// 预取读取的硬上限，防御异常大响应。
  static const int _maxReadGuard = 8 * 1024 * 1024;

  /// key 为清洗后的直链；LinkedHashMap 插入序实现 LRU。
  final Map<String, AudioHeadEntry> _heads = {};
  int _totalBytes = 0;

  /// 直链 → 请求头登记表：预取与起播都会登记，
  /// 代理续传/透传时按直链取回（对齐播放同源请求头）。
  final Map<String, Map<String, String>> _headersBy = {};

  /// 在途预取集合：同直链并发去重。
  final Set<String> _inflight = {};

  /// 登记直链请求头（空值剔除），供本地代理使用。
  void registerHeaders(String url, Map<String, String>? headers) {
    final key = sanitizeMediaUrl(url);
    if (key.isEmpty || headers == null || headers.isEmpty) return;
    final cleaned = <String, String>{};
    headers.forEach((k, v) {
      final name = k.trim();
      final value = v.trim();
      if (name.isEmpty || value.isEmpty) return;
      // Range 由续传逻辑按需生成，不透传外部值。
      if (name.toLowerCase() == 'range') return;
      cleaned[name] = value;
    });
    if (cleaned.isNotEmpty) _headersBy[key] = cleaned;
  }

  /// 取登记的请求头（无登记返回 null）。
  Map<String, String>? headersFor(String url) {
    final key = sanitizeMediaUrl(url);
    final hit = _headersBy[key];
    if (hit == null) return null;
    return Map<String, String>.of(hit);
  }

  /// 查询片头缓存（命中刷新 LRU 位置；过期即剔除）。
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

  /// 起播注入用：命中且支持 Range、有字节、已知总长时返回片头。
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

  /// 发起片头预取。已有新鲜缓存或在途请求时跳过。
  /// 返回 true 表示成功取得并缓存了片头。
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
      // 覆盖旧条目时先扣除旧字节量。
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

  /// LRU 淘汰：条数与总字节双重上限，淘汰最旧（插入序最前）。
  void _evict() {
    while (_heads.isNotEmpty &&
        (_heads.length > _maxEntries || _totalBytes > _maxTotalBytes)) {
      final oldestKey = _heads.keys.first;
      final entry = _heads.remove(oldestKey);
      if (entry != null) _totalBytes -= entry.bytes.length;
    }
  }

  /// Range 请求抓取片头：
  /// - 206：读取至 maxBytes 为止，解析 Content-Range 总长后缓存；
  /// - 200（服务器不支持 Range）：只读前 maxBytes 预热连接，不缓存
  ///   （无法用于续传，避免无意义占用）；
  /// - 非音频内容类型（防盗链错误页等）一律不缓存。
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
        } catch (_) {/* 非法头名跳过 */}
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
        // 服务器不支持 Range：读一小段预热 TCP/TLS 后断开，不缓存。
        await _readUpTo(resp, 64 * 1024);
        return null;
      }

      await resp.drain<void>().catchError((_) {});
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 从响应流读取至多 [maxBytes] 字节（提前到达即取消订阅断开连接）。
  Future<Uint8List> _readUpTo(HttpClientResponse resp, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
      if (builder.length >= maxBytes) break; // break 会取消订阅并断开连接
    }
    var bytes = builder.takeBytes();
    if (bytes.length > maxBytes) {
      bytes = Uint8List.sublistView(bytes, 0, maxBytes);
    }
    return bytes;
  }

  /// 解析 Content-Range 中的总长：`bytes 0-524287/9435678` → 9435678。
  /// 无效或 `*` 总长返回 0。
  int _parseTotalLength(HttpClientResponse resp) {
    final contentRange =
        resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    final slash = contentRange.lastIndexOf('/');
    if (slash < 0 || slash == contentRange.length - 1) return 0;
    final totalStr = contentRange.substring(slash + 1).trim();
    return int.tryParse(totalStr) ?? 0;
  }

  /// 清空缓存（调试/登出等场景）。
  void clear() {
    _heads.clear();
    _totalBytes = 0;
    _headersBy.clear();
    _inflight.clear();
  }
}
