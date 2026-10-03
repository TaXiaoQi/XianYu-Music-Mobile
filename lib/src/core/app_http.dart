// app_http.dart - Dart 侧统一 HTTP 出口
//
// 背景：仓库内约 18 处直接 `HttpClient()` 的调用此前各自建连、自动跟随
// 重定向，不带任何 SSRF 校验——下载 URL 若来自远端数据（主题包壁纸 ref、
// 分享图、MV 兜底源等），可能被恶意重定向到内网。Rust 侧
// (rust/src/security/ssrf.rs + plugin_host/http.rs) 已有同款防护，本文件
// 把 Dart 侧散落的请求收口到同一出口。
//
// 防护语义与 Rust 侧对齐：
// - 逐跳校验：手动跟随重定向，每一跳的目标 host 都重新校验
// - 默认拒绝私网/回环/链路本地地址；访问本地 DLNA httpd、音频代理等
//   受信目标时由调用方显式传 `allowPrivateHost: true`
// - 已知局限：校验与建连之间存在 DNS TOCTOU 窗口（与主流客户端一致；
//   Rust 侧用 DNS pinning 收得更紧）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

HttpClient _newClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 12)
  ..autoUncompress = true;

HttpClient _clientInstance = _newClient();

/// 共享客户端：复用连接池，避免每请求重建。
HttpClient get sharedHttpClient => _clientInstance;

/// 是否私网/回环/链路本地地址（IP 字面量直接判定；域名返回 false，
/// 域名的私网判定走 DNS 解析，见 [hostResolvesPrivate]）。
bool isPrivateHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return true;
  if (h == 'localhost' || h == '::1' || h == '[::1]' || h == '0.0.0.0') {
    return true;
  }
  if (h.startsWith('[')) {
    // IPv6 字面量
    final inner = h.substring(1, h.endsWith(']') ? h.length - 1 : h.length);
    if (inner == '::1') return true;
    if (inner.startsWith('fe8') ||
        inner.startsWith('fe9') ||
        inner.startsWith('fea') ||
        inner.startsWith('feb')) {
      return true; // 链路本地 fe80::/10
    }
    if (inner.startsWith('fc') || inner.startsWith('fd')) return true; // ULA fc00::/7
    return false;
  }
  final parts = h.split('.');
  if (parts.length == 4) {
    final octets = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return false; // 非 IPv4 字面量
      octets.add(v);
    }
    if (octets[0] == 10 || octets[0] == 127) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    if (octets[0] == 169 && octets[1] == 254) return true; // 链路本地
    if (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) return true; // CGNAT
    return false;
  }
  return false; // 域名：由 DNS 解析结果判定
}

/// 解析域名并检查是否解析到私网/回环地址。
Future<bool> hostResolvesPrivate(String host) async {
  try {
    final addrs = await InternetAddress.lookup(host);
    for (final a in addrs) {
      if (a.isLoopback || a.isLinkLocal) return true;
      final parts = a.address.split('.');
      if (parts.length == 4) {
        final o = parts.map(int.parse).toList();
        if (o[0] == 10 || o[0] == 127) return true;
        if (o[0] == 192 && o[1] == 168) return true;
        if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true;
        if (o[0] == 100 && o[1] >= 64 && o[1] <= 127) return true;
      }
    }
    return false;
  } on SocketException {
    return false; // 解析失败交给后续连接报错
  }
}

/// 校验单跳目标；[allowPrivateHost] 为 true 时跳过私网校验
/// （本地 DLNA httpd、音频代理、桌面协同等受信链路专用）。
Future<void> validateHop(Uri uri, bool allowPrivateHost) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw HttpException('不支持的协议: ${uri.scheme}', uri: uri);
  }
  if (allowPrivateHost) return;
  final host = uri.host;
  if (isPrivateHost(host)) {
    throw HttpException('拒绝访问私网地址: $host', uri: uri);
  }
  final isV4Literal = host.split('.').length == 4 &&
      host.split('.').every((p) => int.tryParse(p) != null);
  final isV6Literal = host.startsWith('[');
  if (!isV4Literal && !isV6Literal && await hostResolvesPrivate(host)) {
    throw HttpException('拒绝解析到私网的域名: $host', uri: uri);
  }
}

/// 统一 HTTP 请求入口：逐跳 SSRF 校验 + 手动跟随重定向。
///
/// - [method] GET/POST/HEAD 等
/// - [headers] 逐跳都携带（不自动透传 Cookie 到跳转目标域，避免凭据外漏）
/// - [bodyBytes]/[body] 二选一；重定向方法降级语义与 dart:io 默认一致
/// - [allowPrivateHost] 允许私网目标（本地受信链路专用）
/// - [maxRedirects] 重定向上限，超限抛 HttpException
///
/// 返回最终（非 3xx）响应；响应体由调用方负责消费/关闭。
Future<HttpClientResponse> appRequest(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  List<int>? bodyBytes,
  String? body,
  bool allowPrivateHost = false,
  int maxRedirects = 5,
}) async {
  var current = uri;
  var m = method.toUpperCase();
  for (var hop = 0; hop <= maxRedirects; hop++) {
    await validateHop(current, allowPrivateHost);
    final req = await sharedHttpClient.openUrl(m, current);
    req.followRedirects = false;
    req.maxRedirects = 0;
    headers?.forEach(req.headers.set);
    if (bodyBytes != null) {
      req.add(bodyBytes);
    } else if (body != null) {
      req.add(utf8.encode(body));
    }
    final resp = await req.close();
    final status = resp.statusCode;
    if (status >= 300 && status < 400) {
      final loc = resp.headers.value(HttpHeaders.locationHeader);
      await resp.drain<void>();
      if (loc == null || loc.isEmpty) {
        throw HttpException('重定向缺少 Location: $current', uri: current);
      }
      if (hop == maxRedirects) {
        throw HttpException('重定向次数超限: $current', uri: current);
      }
      // 303 / 302(非 GET) 按惯例降级为 GET；307/308 保持方法
      if (status == 303 || (status == 302 && m != 'GET')) {
        m = 'GET';
        bodyBytes = null;
        body = null;
      }
      current = current.resolve(loc);
      continue;
    }
    return resp;
  }
  throw HttpException('请求未完成: $uri', uri: uri);
}

/// 便捷 GET：内容下载场景（公网资源），默认拒绝私网目标。
Future<HttpClientResponse> appGet(
  Uri uri, {
  Map<String, String>? headers,
  bool allowPrivateHost = false,
  int maxRedirects = 5,
}) =>
    appRequest(
      'GET',
      uri,
      headers: headers,
      allowPrivateHost: allowPrivateHost,
      maxRedirects: maxRedirects,
    );
