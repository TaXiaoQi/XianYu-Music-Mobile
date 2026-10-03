import 'dart:io';

import 'package:flutter/services.dart';

import 'application_logger.dart';

/// 播放链路诊断辅助：线程堆栈转储与直链连通性探测。
/// 与播放器状态无耦合，独立为顶层工具。

const MethodChannel _diagChannel = MethodChannel('xianyu/diag');

/// 通过平台通道转储播放器线程堆栈快照（仅 Android 实现）。
Future<void> dumpPlayerThreads() async {
  try {
    final out = await _diagChannel.invokeMethod<String>('threadDump');
    AppLog.warn('exodump', '播放器线程堆栈快照:\n${out ?? 'null'}');
  } catch (e) {
    AppLog.warn('exodump', '线程转储失败: $e');
  }
}

/// 直连探测 url 连通性与吞吐（8s 连接/响应超时、3s 读流采样），仅记日志。
Future<void> diagProbeUrl(String url, Map<String, String>? headers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final sw = Stopwatch()..start();
  try {
    final req = await client.getUrl(Uri.parse(url));
    (headers ?? {}).forEach((k, v) {
      try {
        req.headers.set(k, v);
      } catch (e) {
        AppLog.debug('player', '诊断请求头设置失败: $e');
      }
    });
    final res = await req.close().timeout(const Duration(seconds: 8));
    final type = res.headers.contentType?.toString() ?? '-';
    final len = res.contentLength;
    AppLog.warn('probe',
        'conn ok t=${sw.elapsedMilliseconds}ms status=${res.statusCode} type=$type len=$len');
    var got = 0;
    await for (final chunk in res.timeout(const Duration(seconds: 3))) {
      got += chunk.length;
      if (sw.elapsedMilliseconds >= 3000) break;
    }
    final secs = sw.elapsedMilliseconds ~/ 1000 + 1;
    AppLog.warn('probe',
        'bytes=$got in ${sw.elapsedMilliseconds}ms rate=${(got ~/ secs) ~/ 1024}KB/s');
  } catch (e) {
    AppLog.warn('probe', 'probe failed after ${sw.elapsedMilliseconds}ms: $e');
  } finally {
    client.close(force: true);
  }
}
