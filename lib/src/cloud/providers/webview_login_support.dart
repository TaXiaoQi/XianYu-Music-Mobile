// WebView 登录捕获支撑。
//
// vendored webview_flutter（鸿蒙 fork，4.6.0）无 getCookies API（上游
// 4.13 才引入，且 fork 未跟进）。Cookie 默认走 JS `document.cookie`
// 通道读取（只能拿非 httpOnly——夸克 kps/sign、UC、139、微云等所需
// 凭据在登录页脚本上下文可读）；捕获规则声明 nativeCookies 时优先走
// 原生 CookieManager 通道（可读 httpOnly，如百度 BDUSS），平台不支持
// 时自动回退 document.cookie（该场景下 httpOnly 凭据即拿不到）。
//
// Token 范式（阿里）走 pollScript 注入轮询：定时执行 JS 片段，返回
// 非空字符串即视为 token 出现。

import 'dart:async';

import 'package:webview_flutter/webview_flutter.dart';

import '../cloud_types.dart';

class CloudWebviewCaptureSession {
  CloudWebviewCaptureSession(this.rule);

  final CloudCaptureRule rule;

  final Map<String, String> _cookies = {};
  String? _token;
  String? _finalUrl;
  Timer? _timer;
  bool _completed = false;

  CloudCaptureResult result() => CloudCaptureResult(
        cookies: Map.of(_cookies),
        token: _token,
        finalUrl: _finalUrl,
      );

  bool get isComplete => _completed;

  /// 页面加载完成 / URL 变化时调用（页面回调里两处都调）。返回是否捕获完成。
  Future<bool> onPageEvent(WebViewController controller, String url) async {
    if (_completed) return true;
    _finalUrl = url;
    if (rule.pollScript != null) {
      // Token 范式：轮询定时器负责采集，URL 只用于展示。
      startPolling(controller);
      return false;
    }
    final doneHit = rule.doneUrlPattern?.hasMatch(url) ?? false;
    await _readCookies(controller);
    // 声明 doneUrlPattern 时只在命中页采集完成（登录前落域名页不算）；
    // 未声明时 Cookie 齐了即算完成。
    if (_cookiesReady && (doneHit || rule.doneUrlPattern == null)) {
      _completed = true;
    }
    return _completed;
  }

  /// 用户手动点「我已登录」强制采集一次（doneUrlPattern 未命中时的兜底）。
  Future<bool> forceCapture(WebViewController controller) async {
    if (_completed) return true;
    if (rule.pollScript != null) {
      await _pollToken(controller);
    } else {
      await _readCookies(controller);
    }
    if (_cookiesReady) _completed = true;
    return _completed;
  }

  void startPolling(WebViewController controller) {
    _timer ??= Timer.periodic(
      Duration(milliseconds: rule.pollIntervalMs),
      (_) => _pollToken(controller),
    );
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  bool get _cookiesReady =>
      rule.cookieNames.isEmpty
          ? _cookies.isNotEmpty
          : rule.cookieNames
              .every((n) => (_cookies[n]?.isNotEmpty ?? false));

  Future<void> _pollToken(WebViewController controller) async {
    if (_completed) {
      dispose();
      return;
    }
    // Token 范式常伴随 Cookie 会话（如微云 openid + cookie），顺带采集。
    await _readCookies(controller);
    final v = await _evalJs(controller, '''
(() => {
  try {
    var t = (${rule.pollScript});
    return t == null ? "" : String(t);
  } catch (e) { return ""; }
})()''');
    if (v.isNotEmpty) {
      _token = v;
      _completed = true;
      dispose();
    }
  }

  Future<void> _readCookies(WebViewController controller) async {
    if (rule.nativeCookies && await _readNativeCookies()) return;
    final raw = await _evalJs(controller, 'document.cookie');
    if (raw.isEmpty) return;
    for (final seg in raw.split(';')) {
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final k = seg.substring(0, eq).trim();
      final v = seg.substring(eq + 1).trim();
      // cookieDomains 仅用于语义声明（document.cookie 天然按当前域返回），
      // 不做硬过滤，避免域名单落后于实际登录域时采不到。
      if (v.isNotEmpty &&
          (rule.cookieNames.isEmpty || rule.cookieNames.contains(k))) {
        _cookies[k] = v;
      }
    }
  }

  /// 原生 CookieManager 通道（可读 httpOnly）。鸿蒙 fork 无 getCookies
  /// 会在此抛错 → 返回 false，回退 document.cookie 通道。
  Future<bool> _readNativeCookies() async {
    final url = _finalUrl;
    if (url == null) return false;
    try {
      final cookies =
          await WebViewCookieManager().getCookies(domain: Uri.parse(url));
      for (final c in cookies) {
        if (c.value.isNotEmpty &&
            (rule.cookieNames.isEmpty || rule.cookieNames.contains(c.name))) {
          _cookies[c.name] = c.value;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 执行 JS 并取字符串结果；平台可能给字符串加引号，剥掉。
  Future<String> _evalJs(WebViewController controller, String expr) async {
    try {
      final r = await controller.runJavaScriptReturningResult(expr);
      var s = r.toString();
      if (s.length >= 2 &&
          ((s.startsWith('"') && s.endsWith('"')) ||
              (s.startsWith("'") && s.endsWith("'")))) {
        s = s.substring(1, s.length - 1);
      }
      return s;
    } catch (_) {
      return '';
    }
  }
}
