// audio_proxy_server.dart — 本地回环音频代理（片头秒开 + 断点续传）
//
// ExoPlayer 无自定义 DataSource 注入入口，故用极简本地 HTTP 代理承接起播：
// - 片头缓存命中：首个 206 响应的头部字节直接从内存直出（零网络等待），
//   后续区间向上游 CDN 以 Range 续传，管道拼接为同一个响应流；
// - 未命中：纯透传代理（Range 原样转发）。
// 仅绑定 127.0.0.1 随机端口 + 随机路径 token，不对外暴露；
// Android 侧 network_security_config 已放行明文（回环流量不出设备）。

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'audio_head_cache.dart';

/// 解析后的 Range 头（仅支持单区间 `bytes=a-b`）。
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

  /// 懒启动（幂等）。失败时保持未启动，起播自动回退原直链。
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

  /// 起播地址：片头缓存命中 → 本地代理地址；否则返回原直链。
  String playUrlFor(String url) {
    final server = _server;
    if (server == null || !running) return url;
    final head = AudioHeadCache.instance.lookupForPlay(url);
    if (head == null) return url;
    return proxyUrlFor(url)!;
  }

  /// 强制代理地址（不走片头命中判断）：供 Rust DSP 管线消费——Rust 无法
  /// 携带插件请求头（Referer/User-Agent/Cookie），由代理查
  /// [AudioHeadCache] 注册表注入上游请求头并转发 Range 续传。
  /// 服务器未启动返回 null（调用方回退 ExoPlayer 原直链）。
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

  /// 片头命中路径：头部区间走内存直出，超出部分向上游续传并拼接。
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
      // 416：请求起点越界（理论上 ExoPlayer 不会）。
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

    // 1) 片头内存段：立即可读，起播零网络等待。
    final headEnd = end < headLen - 1 ? end : headLen - 1;
    if (headEnd >= range.start) {
      res.add(Uint8List.sublistView(head.bytes, range.start, headEnd + 1));
    }

    // 2) 片头之后：向上游断点续传（客户端断开即中止上游）。
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
          // 上游未按续传语义响应：无法保证声明长度，截断交给客户端重试。
          try {
            await uresp.drain<void>().catchError((_) {});
          } catch (_) {}
        }
      } catch (_) {
        // 续传失败：仅输出已写出的片头段（客户端感知为流提前结束）。
      } finally {
        client.close(force: true);
      }
    }

    try {
      await res.close();
    } catch (_) {}
  }

  /// 透传路径：Range 原样转发上游，状态与长度头照抄。
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
      // Host/Content-Length 由 HttpClient 自管；Range 由本代理按需生成。
      if (lower == 'host' ||
          lower == 'content-length' ||
          lower == 'range') {
        return;
      }
      try {
        ureq.headers.set(name, value);
      } catch (_) {/* 非法头名跳过 */}
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

  /// 解析单区间 Range 头：`bytes=a-b` / `bytes=a-`；缺失或多区间返回 null。
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
