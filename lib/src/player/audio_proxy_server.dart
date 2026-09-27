
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

  static const int _cacheChunk = 1 << 20;

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
    return proxyUrlFor(url) ?? url;
  }

  String? proxyUrlFor(String url) {
    final server = _server;
    if (server == null || !running) return null;
    return 'http://127.0.0.1:${server.port}/$_token/audio'
        '?u=${Uri.encodeComponent(url)}';
  }

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
    } catch (e) {
      probeLog('onRequest error path=${req.uri.path} err=$e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

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

  Future<_CacheStatus?> _waitForCacheTotal(
    String target,
    _CacheStatus initial,
  ) async {
    var st = initial;
    final waitStart = DateTime.now();
    while (!st.complete &&
        st.total == null &&
        st.downloaded <= 0 &&
        DateTime.now().difference(waitStart) < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final st2 = await _cacheStatus(target);
      if (st2 == null || st2.failed) {
        return null;
      }
      st = st2;
    }
    if (!st.complete && st.total == null && st.downloaded <= 0) {
      return null;
    }
    return st;
  }

  Future<bool> _tryServeFromCache(
    HttpRequest req,
    String target,
    Map<String, String>? upstreamHeaders,
    AudioHeadEntry? head,
    _ByteRange range,
    bool hasRangeHeader,
  ) async {
    final st0 = await _cacheStatus(target);
    if (st0 == null || !st0.exists || st0.failed) {
      return false;
    }

    _CacheStatus st = st0;
    if (!st0.complete && st0.total == null && head == null) {
      final waited = await _waitForCacheTotal(target, st0);
      if (waited == null) {
        probeLog('tryCache no-total timeout → fallback');
        return false;
      }
      st = waited;
    }

    final int? total = st.complete ? st.total : (head?.totalLength ?? st.total);

    final bool noTotalStream;
    if (total == null || total <= 0) {
      if (range.start == 0 && range.end == null) {
        noTotalStream = true;
      } else {
        return false;
      }
    } else {
      noTotalStream = false;
    }
    final int safeTotal = total ?? 0;

    if (!noTotalStream && range.start >= safeTotal) {
      final res = req.response;
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$safeTotal');
      await res.close();
      return true;
    }

    final res = req.response;
    res.bufferOutput = false;
    final contentType = head?.contentType;
    if (contentType != null && contentType.isNotEmpty) {
      res.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }

    var end = noTotalStream ? -1 : (range.end ?? safeTotal - 1);
    if (!noTotalStream && end >= safeTotal) end = safeTotal - 1;
    if (noTotalStream) {
      res.statusCode = HttpStatus.ok;
      probeLog('tryCache no-total serve dl=${st.downloaded}');
    } else if (hasRangeHeader) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-$end/$safeTotal',
      );
    } else {
      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }
    if (!noTotalStream) {
      res.contentLength = end - range.start + 1;
    }

    var wroteAny = false;
    var pos = range.start;
    final readTimer = Stopwatch()..start();
    try {
      while (noTotalStream || pos <= end) {
        final Uint8List chunk;
        try {
          chunk = await frb.streamCacheReadUrl(
            url: target,
            offset: BigInt.from(pos),
            maxLen: _cacheChunk,
          );
        } catch (e) {
          probeLog('tryCache read-error pos=$pos total=${total ?? '-'} '
              'firstMs=${readTimer.elapsedMilliseconds}ms err=$e');
          break;
        }
        if (chunk.isEmpty) {
          if (!wroteAny && !noTotalStream) {
            return false;
          }
          final st2 = await _cacheStatus(target);
          if (st2 == null || st2.failed) {
            probeLog('tryCache stalled-failed pos=$pos total=${total ?? '-'} '
                'firstMs=${readTimer.elapsedMilliseconds}ms');
            break;
          }
          if (st2.complete && pos >= st2.downloaded) {
            probeLog('tryCache read-EOF pos=$pos total=${total ?? '-'} '
                'firstMs=${readTimer.elapsedMilliseconds}ms');
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 120));
          continue;
        }
        var data = chunk;
        if (!noTotalStream && pos + data.length > end + 1) {
          data = Uint8List.sublistView(data, 0, end + 1 - pos);
        }
        try {
          res.add(data);
          await res.flush();
        } catch (_) {
          probeLog('tryCache client-disconnect pos=$pos total=${total ?? '-'}');
          return true;
        }
        pos += data.length;
        wroteAny = true;
      }
    } catch (e) {
      probeLog('tryCache loop-error pos=$pos total=${total ?? '-'} err=$e');
    }
    final stEnd = await _cacheStatus(target);
    probeLog('tryCache serve-end pos=$pos '
        'end=${noTotalStream ? '-' : '$end'} total=${total ?? '-'} '
        'complete=${stEnd?.complete} failed=${stEnd?.failed} '
        'dl=${stEnd?.downloaded} firstMs=${readTimer.elapsedMilliseconds}ms');
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
        } catch (e) {
          probeLog('tail stream-error status=${uresp.statusCode} '
              'served=${served}B t=${sw.elapsedMilliseconds}ms err=$e');
        }
        probeLog('tail end status=${uresp.statusCode} '
            'served=${served}B stalled=$stalled t=${sw.elapsedMilliseconds}ms');
      } catch (e) {
        probeLog('tail upstream-error err=$e');
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
      } catch (e) {
        probeLog('passthrough stream-error status=${uresp.statusCode} '
            'served=${served}B t=${sw.elapsedMilliseconds}ms err=$e');
      }
      probeLog('passthrough end status=${uresp.statusCode} '
          'cl=${uresp.headers.value(HttpHeaders.contentLengthHeader) ?? '-'} '
          'served=${served}B stalled=$stalled t=${sw.elapsedMilliseconds}ms');
      try {
        await res.close();
      } catch (_) {}
    } catch (e) {
      probeLog('passthrough upstream-error err=$e');
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
