
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'audio_head_cache.dart';

class _ByteRange {
  const _ByteRange(this.start, this.end);
  final int start;
  final int? end;
}

class AudioProxyServer {
  AudioProxyServer._();

  static final AudioProxyServer instance = AudioProxyServer._();

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
    final head = AudioHeadCache.instance.lookupForPlay(url);
    if (head == null) return url;
    return proxyUrlFor(url)!;
  }

  String? proxyUrlFor(String url) {
    final server = _server;
    if (server == null || !running) return null;
    return 'http://127.0.0.1:${server.port}/$_token/audio'
        '?u=${Uri.encodeComponent(url)}';
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
      final range = _parseRange(req.headers.value(HttpHeaders.rangeHeader)) ??
          const _ByteRange(0, null);
      final head = AudioHeadCache.instance.lookupForPlay(target);

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
        if (uresp.statusCode == HttpStatus.partialContent) {
          try {
            await res.addStream(uresp);
          } catch (_) {}
        } else {
          try {
            await uresp.drain<void>().catchError((_) {});
          } catch (_) {}
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

      unawaited(res.done.whenComplete(() {
        try {
          ureq?.abort();
        } catch (_) {}
      }));
      try {
        await res.addStream(uresp);
      } catch (_) {}
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
