
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../rust/api.dart' as frb;
import '../core/application_logger.dart';
import 'audio_head_cache.dart';

void probeLog(String msg) {
  AppLog.warn('proxyprobe', msg);
}

class _ByteRange {
  const _ByteRange(this.start, this.end);
  final int start;
  final int? end;
}

class _CacheStatus {
  const _CacheStatus({
    required this.exists,
    required this.complete,
    required this.failed,
    required this.total,
    required this.downloaded,
  });
  final bool exists;
  final bool complete;
  final bool failed;
  final int? total;
  final int downloaded;
}

class AudioProxyServer {
  AudioProxyServer._();

  static final AudioProxyServer instance = AudioProxyServer._();

  /// 每次从 Rust 流缓存读取的分块大小（1MB）。
  static const int _cacheChunk = 1 << 20;

  /// 上游 tail 流饿死看门狗：连续这么久没有新字节即掐断连接，
  /// 让播放器带 Range 重连（新连接通常不再被 CDN 限速饿死）。
  static const Duration _upstreamStall = Duration(seconds: 10);

  HttpServer? _server;
  String _token = '';
  Future<void>? _starting;

  bool get running => _server != null;

  Future<void> ensureStarted() async {
    if (_server != null) return;
    if (_starting != null) {
      await _starting;
      return;
    }
    final f = _start();
    _starting = f;
    try {
      await f;
    } finally {
      _starting = null;
    }
  }

  Future<void> _start() async {
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final rnd = Random.secure();
      _token = List.generate(16, (_) => rnd.nextInt(16).toRadixString(16))
          .join();
      _server = server;
      server.listen(
        (req) {
          unawaited(_onRequest(req));
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {
      _server = null;
    }
  }

  String playUrlFor(String url) {
    final server = _server;
    if (server == null || !running) return url;
    if (!url.startsWith('http')) return url;
    // 无头部探测缓存也走代理：代理可透传（携带注册过的请求头），
    // 同时预热 Rust 流缓存写入磁盘（对齐桌面端在线播放缓存）。
    return proxyUrlFor(url) ?? url;
  }

  String? proxyUrlFor(String url) {
    final server = _server;
    if (server == null || !running) return null;
    return 'http://127.0.0.1:${server.port}/$_token/audio'
        '?u=${Uri.encodeComponent(url)}';
  }

  /// MV 视频复用同一代理端点与在线播放缓存池：注册 MV 请求头后走
  /// /audio 伺服（Range/缓存命中/上游续传与歌曲一致），缓存 key 即
  /// MV 直链 URL，与歌曲同池 LRU 淘汰、同清理。
  String? mvProxyUrlFor(String url, Map<String, String>? headers) {
    if (!url.startsWith('http')) return null;
    AudioHeadCache.instance.registerHeaders(url, headers);
    return proxyUrlFor(url);
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      if (req.method != 'GET' && req.method != 'HEAD') {
        return await _reject(req, HttpStatus.methodNotAllowed);
      }
      if (req.uri.path != '/$_token/audio') {
        return await _reject(req, HttpStatus.notFound);
      }
      final target = req.uri.queryParameters['u'] ?? '';
      if (!target.startsWith('http')) {
        return await _reject(req, HttpStatus.badRequest);
      }

      final upstreamHeaders = AudioHeadCache.instance.headersFor(target);
      final rawRange = req.headers.value(HttpHeaders.rangeHeader);
      final range = _parseRange(rawRange) ?? const _ByteRange(0, null);
      final head = AudioHeadCache.instance.lookupForPlay(target);

      // 在线播放磁盘缓存（对齐桌面端）：先预热流式下载写盘，再尝试本地伺服
      var cacheReady = false;
      if (req.method == 'GET') {
        cacheReady = await _warmStreamCache(target, upstreamHeaders);
      }
      if (cacheReady &&
          await _tryServeFromCache(
            req, target, upstreamHeaders, head, range, rawRange != null,
          )) {
        return;
      }

      if (head != null && range.start < head.bytes.length) {
        await _serveWithHead(req, target, upstreamHeaders, head, range);
      } else {
        await _passthrough(req, target, upstreamHeaders, range);
      }
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 启动/复用该 URL 的 Rust 流式下载（写盘）。已存在时复用，失败条目重下。
  Future<bool> _warmStreamCache(
    String target,
    Map<String, String>? upstreamHeaders,
  ) async {
    try {
      await frb.streamCacheBeginUrlDownload(
        url: target,
        headers: jsonEncode(upstreamHeaders ?? const <String, String>{}),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<_CacheStatus?> _cacheStatus(String target) async {
    try {
      final raw = await frb.streamCacheUrlStatus(url: target);
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final total = m['total'];
      final downloaded = m['downloaded_bytes'];
      return _CacheStatus(
        exists: m['exists'] == true,
        complete: m['complete'] == true,
        failed: m['failed'] == true,
        total: total is num ? total.toInt() : null,
        downloaded: downloaded is num ? downloaded.toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 尝试从磁盘流缓存伺服响应。返回 false 表示回退网络路径
  /// （仅在尚未向响应写入任何字节时才允许回退）。
  Future<bool> _tryServeFromCache(
    HttpRequest req,
    String target,
    Map<String, String>? upstreamHeaders,
    AudioHeadEntry? head,
    _ByteRange range,
    bool hasRangeHeader,
  ) async {
    final st = await _cacheStatus(target);
    if (st == null || !st.exists || st.failed) {
      return false;
    }

    // 总长：完整缓存用实际大小；下载中优先头部探测，其次 Rust 上报的
    // Content-Length（首播无头部探测缓存时也能伺服）
    final int? total = st.complete ? st.total : (head?.totalLength ?? st.total);
    if (total == null || total <= 0) {
      return false;
    }

    // 请求位置还没下载到：不再立即回退直连——read_url_range 会等数据
    // （单次最多 2s）。首播时预热下载器与透传并发开两条上游连接会被
    // 部分 CDN（酷狗）按 token 并发限制饿死其一，表现为起播 10s 超时；
    // 统一从预热缓存伺服后全链路只有一条上游连接。
    // 真长时间不推进（如澎湃节流）也只多等 2s 即回退直连。

    if (range.start >= total) {
      final res = req.response;
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      await res.close();
      return true;
    }

    final res = req.response;
    res.bufferOutput = false;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final contentType = head?.contentType;
    if (contentType != null && contentType.isNotEmpty) {
      res.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }

    var end = range.end ?? total - 1;
    if (end >= total) end = total - 1;
    if (hasRangeHeader) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-$end/$total',
      );
    } else {
      res.statusCode = HttpStatus.ok;
    }
    res.contentLength = end - range.start + 1;

    var wroteAny = false;
    final readTimer = Stopwatch()..start();
    try {
      var pos = range.start;
      while (pos <= end) {
        final Uint8List chunk;
        try {
          chunk = await frb.streamCacheReadUrl(
            url: target,
            offset: BigInt.from(pos),
            maxLen: _cacheChunk,
          );
        } catch (_) {
          break;
        }
        if (chunk.isEmpty) {
          // EOF 或下载失败
          if (!wroteAny) return false; // 尚未写出：回退网络路径
          probeLog('tryCache read-EOF pos=$pos total=$total '
              'firstMs=${readTimer.elapsedMilliseconds}ms');
          break;
        }
        var data = chunk;
        if (pos + data.length > end + 1) {
          data = Uint8List.sublistView(data, 0, end + 1 - pos);
        }
        try {
          res.add(data);
          await res.flush();
        } catch (_) {
          return true;
        }
        pos += data.length;
        wroteAny = true;
      }
    } catch (_) {}
    try {
      await res.close();
    } catch (_) {}
    return true;
  }

  Future<void> _reject(HttpRequest req, int status) async {
    try {
      req.response.statusCode = status;
      await req.response.close();
    } catch (_) {}
  }

  Future<void> _serveWithHead(
    HttpRequest req,
    String target,
    Map<String, String>? upstreamHeaders,
    AudioHeadEntry head,
    _ByteRange range,
  ) async {
    final res = req.response;
    final headLen = head.bytes.length;
    final total = head.totalLength;

    var end = range.end ?? total - 1;
    if (end >= total) end = total - 1;
    if (end < range.start) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$total',
      );
      await res.close();
      return;
    }

    res.statusCode = HttpStatus.partialContent;
    res.bufferOutput = false;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes ${range.start}-$end/$total',
    );
    res.headers.set(
      HttpHeaders.contentTypeHeader,
      head.contentType ?? 'application/octet-stream',
    );
    res.contentLength = end - range.start + 1;

    final headEnd = end < headLen - 1 ? end : headLen - 1;
    if (headEnd >= range.start) {
      res.add(Uint8List.sublistView(head.bytes, range.start, headEnd + 1));
    }

    if (end >= headLen) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final sw = Stopwatch()..start();
      try {
        final ureq = await client.getUrl(Uri.parse(target));
        ureq.headers.set(HttpHeaders.rangeHeader, 'bytes=$headLen-$end');
        _applyUpstreamHeaders(ureq, upstreamHeaders);
        final uresp = await ureq.close().timeout(const Duration(seconds: 20));
        unawaited(res.done.whenComplete(() {
          try {
            ureq.abort();
          } catch (_) {}
        }));
        // CDN 忽略 Range 返回 200 时正文从字节 0 开始：跳过已发给播放器的
        // 部分（head 或 range.start 之前）继续透传，而不是整段丢弃后把响应
        // 截断在 head 末尾（播放器承诺 9MB 实收 630KB 且连接关闭 → 卡 loading）。
        final upstreamFullBody = uresp.statusCode != HttpStatus.partialContent;
        var skip = 0;
        if (upstreamFullBody) {
          skip = headEnd >= range.start ? headEnd + 1 : range.start;
        }
        var served = 0;
        var stalled = false;
        try {
          await for (final chunk
              in uresp.timeout(_upstreamStall, onTimeout: (sink) {
            stalled = true;
            sink.addError(TimeoutException('tail stall'));
          })) {
            var data = chunk;
            if (skip > 0) {
              if (data.length <= skip) {
                skip -= data.length;
                continue;
              }
              data = Uint8List.sublistView(
                  data is Uint8List ? data : Uint8List.fromList(data), skip);
              skip = 0;
            }
            res.add(data);
            served += data.length;
          }
        } catch (_) {}
        if (stalled) {
          probeLog('tail done served=${served}B stalled=$stalled '
              't=${sw.elapsedMilliseconds}ms');
        }
      } catch (_) {
      } finally {
        client.close(force: true);
      }
    }

    try {
      await res.close();
    } catch (_) {}
  }

  Future<void> _passthrough(
    HttpRequest req,
    String target,
    Map<String, String>? upstreamHeaders,
    _ByteRange range,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    HttpClientRequest? ureq;
    try {
      ureq = await client.getUrl(Uri.parse(target));
      if (range.start > 0 || range.end != null) {
        final endStr = range.end?.toString() ?? '';
        ureq.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=${range.start}-$endStr',
        );
      }
      _applyUpstreamHeaders(ureq, upstreamHeaders);
      final uresp = await ureq.close().timeout(const Duration(seconds: 20));

      final res = req.response;
      res.statusCode = uresp.statusCode;
      res.bufferOutput = false;
      _copyHeader(uresp, res, HttpHeaders.contentTypeHeader);
      _copyHeader(uresp, res, HttpHeaders.contentLengthHeader);
      _copyHeader(uresp, res, HttpHeaders.contentRangeHeader);
      _copyHeader(uresp, res, HttpHeaders.acceptRangesHeader);

      final sw = Stopwatch()..start();
      var served = 0;
      var stalled = false;
      unawaited(res.done.whenComplete(() {
        try {
          ureq?.abort();
        } catch (_) {}
      }));
      try {
        await for (final chunk
            in uresp.timeout(_upstreamStall, onTimeout: (sink) {
          stalled = true;
          sink.addError(TimeoutException('passthrough stall'));
        })) {
          res.add(chunk);
          served += chunk.length;
        }
      } catch (_) {}
      if (stalled) {
        probeLog('passthrough done served=${served}B stalled=$stalled '
            't=${sw.elapsedMilliseconds}ms');
      }
      try {
        await res.close();
      } catch (_) {}
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }

  void _applyUpstreamHeaders(
    HttpClientRequest ureq,
    Map<String, String>? headers,
  ) {
    headers?.forEach((k, v) {
      final name = k.trim();
      final value = v.trim();
      if (name.isEmpty || value.isEmpty) return;
      final lower = name.toLowerCase();
      if (lower == 'host' ||
          lower == 'content-length' ||
          lower == 'range') {
        return;
      }
      try {
        ureq.headers.set(name, value);
      } catch (_) {}
    });
  }

  void _copyHeader(
    HttpClientResponse from,
    HttpResponse to,
    String name,
  ) {
    final v = from.headers.value(name);
    if (v == null || v.isEmpty) return;
    try {
      to.headers.set(name, v);
    } catch (_) {}
  }

  _ByteRange? _parseRange(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(raw.trim());
    if (m == null) return null;
    final start = int.tryParse(m.group(1)!);
    if (start == null) return null;
    final endStr = m.group(2);
    final end = endStr == null || endStr.isEmpty ? null : int.tryParse(endStr);
    if (end != null && end < start) return null;
    return _ByteRange(start, end);
  }
}
