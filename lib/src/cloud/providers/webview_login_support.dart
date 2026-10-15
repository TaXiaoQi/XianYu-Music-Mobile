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
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../../core/application_logger.dart';
import '../cloud_types.dart';

/// 剔除 WebView 偶发产出的脏 Cookie（空名 / `undefined` 名 / `undefined`
/// 值）——拼进 Cookie 头会破坏百度等服务的会话判定（实测 /api/list
/// errno 由 0 变 1）。
bool validCookiePair(String k, String v) =>
    k.isNotEmpty && k != 'undefined' && v != 'undefined';

/// 解析用户粘贴的 Cookie（容忍 "Cookie:" 前缀与分号/换行分隔；亦支持
/// EditThisCookie 等浏览器插件导出的 JSON 格式），手动填 Cookie 共用。
Map<String, String> parseCookieText(String raw) {
  final t = raw.trim();
  if (t.startsWith('[') || t.startsWith('{')) {
    try {
      return _fromJsonCookies(jsonDecode(t));
    } catch (_) {
      // 非 JSON 或结构不符，落回文本解析。
    }
  }
  final cookies = <String, String>{};
  for (var seg in raw.split(RegExp(r'[;\n]'))) {
    seg = seg.trim();
    if (seg.toLowerCase().startsWith('cookie:')) seg = seg.substring(7).trim();
    final eq = seg.indexOf('=');
    if (eq <= 0) continue;
    final k = seg.substring(0, eq).trim();
    final v = seg.substring(eq + 1).trim();
    if (validCookiePair(k, v) && !k.contains(' ')) cookies[k] = v;
  }
  return cookies;
}

/// EditThisCookie / Cookie-Editor 导出格式：[{name, value}, ...] 或
/// 单对象 {name, value}。
Map<String, String> _fromJsonCookies(dynamic json) {
  final out = <String, String>{};
  final items = json is List ? json : (json is Map ? [json] : const []);
  for (final e in items) {
    if (e is! Map) continue;
    final name = (e['name'] ?? e['Name'] ?? '').toString().trim();
    final value = (e['value'] ?? e['Value'] ?? '').toString().trim();
    if (validCookiePair(name, value)) out[name] = value;
  }
  return out;
}

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
    // postLoginUrl 范式（百度）：登录落地是 3-4 跳服务端重定向，STOKEN
    // 由最终落地页下发——URL 命中不代表会话落定，禁止在此自动完成，
    // 由 postLoginUrl 补跳后的稳定性轮询或用户手动确认收尾。
    if (!rule.manualDoneOnly &&
        rule.postLoginUrl == null &&
        _cookiesReady &&
        (doneHit || rule.doneUrlPattern == null)) {
      _completed = true;
    }
    return _completed;
  }

  /// completeLogin 校验失败后重置完成态：下次 forceCapture 重新采集
  /// （页面 JS 此期间可能已种齐 Cookie），避免用旧快照反复失败。
  void resetCompletion() => _completed = false;

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

  /// 只读不判定完成：返回当前 Cookie 稳定性签名（键数|STOKEN|BDUSS 尾 4），
  /// 空串 = 还没读到有效 Cookie。登录落地轮询用——百度落地是 3-4 跳
  /// 服务端重定向，STOKEN 由最终落地页下发，过早捕获会拿到与 BDUSS
  /// 不配对的中间态值（列目录 errno=-6）。
  Future<String> cookieSignature(WebViewController controller) async {
    await _readCookies(controller);
    final bd = _cookies['BDUSS'] ?? '';
    if (bd.isEmpty) return '';
    return '${_cookies.length}|${_cookies['STOKEN'] ?? ''}|'
        '${bd.substring(bd.length - 4)}';
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
    if (rule.nativeCookies && await _readNativeCookies()) {
      // 原生通道调用成功，但目标 Cookie 一个都没拿到时继续走
      // document.cookie 兜底——部分厂商 WebView/URL 变体下 getCookie
      // 会返回空，不能因为「通道成功」就放弃采集。
      if (rule.cookieNames.isEmpty ||
          rule.cookieNames.any(_cookies.containsKey)) {
        return;
      }
      AppLog.warn('cloud', '原生 Cookie 通道未取到 ${rule.cookieNames.join('/')}，回退 document.cookie');
    }
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
          validCookiePair(k, v) &&
          (rule.cookieNames.isEmpty || rule.cookieNames.contains(k))) {
        _cookies[k] = v;
      }
    }
  }

  /// 原生 CookieManager 通道（可读 httpOnly）。getCookies 是 webview_flutter
  /// 4.14+ 的 API，鸿蒙 fork（4.6.0）无此方法——静态调用在 fork 态直接编译
  /// 失败，故走 dynamic 派发：官方态运行时真调原生通道；fork 态运行时抛
  /// NoSuchMethodError → 返回 false，回退 document.cookie 通道。
  ///
  /// 注意：原生 handler 随插件原生代码编译。若 run 会话是在依赖升级前
  /// 启动的，热重载/热重启都不会重编原生层，这里会持续抛 MissingPlugin
  /// 类异常——必须完全重启 flutter run。失败时打日志，避免静默回退黑盒。
  ///
  /// 读地址优先取捕获规则的首个 cookieDomains：移动端登录流会落在
  /// h5.sm.cn / broccoli.uc.cn 等入口域，而凭据在 .quark.cn / .uc.cn /
  /// .baidu.com 上，按当前页 URL 读会漏。
  ///
  /// 厂商 WebView（华为 hwschromium 等）对裸域（https://baidu.com/）与
  /// 子域（https://pan.baidu.com/）的 domain-match 实现存在差异——逐个
  /// 地址读合并，任一命中即拿到凭据；每地址失败均留痕。
  Future<bool> _readNativeCookies() async {
    final urls = <String>{
      for (final d in rule.cookieDomains) 'https://$d/',
      ?_finalUrl,
    };
    if (urls.isEmpty) return false;
    try {
      final dynamic cookieManager = WebViewCookieManager();
      var anyOk = false;
      // 原生通道单轮即全量快照：以本轮结果整体覆盖累积缓冲。登录跳转
      // 链中服务端会清键（PANPSC 置过期删除）与轮换（STOKEN），累积
      // 残留会把中间态旧值混进最终凭据（百度列目录 errno=-6 的根因：
      // 捕获到与 BDUSS 不配对的旧 STOKEN）。
      final snapshot = <String, String>{};
      for (final url in urls) {
        try {
          final cookies = await cookieManager.getCookies(domain: Uri.parse(url))
              as List<WebViewCookie>;
          anyOk = true;
          for (final c in cookies) {
            if (c.value.isNotEmpty &&
                validCookiePair(c.name, c.value) &&
                (rule.cookieNames.isEmpty ||
                    rule.cookieNames.contains(c.name))) {
              snapshot[c.name] = c.value;
            }
          }
        } catch (e) {
          AppLog.warn('cloud', '原生 Cookie 读取失败 $url: $e');
        }
      }
      if (snapshot.isNotEmpty) {
        _cookies
          ..clear()
          ..addAll(snapshot);
      }
      if (!anyOk) return false;
      AppLog.debug('cloud', '原生 Cookie 通道读到: ${_cookies.keys.join(',')}');
      return true;
    } catch (e) {
      AppLog.warn('cloud', '原生 Cookie 通道失败(将回退 document.cookie): $e');
      return false;
    }
  }

  /// 执行 JS 并取字符串结果；平台可能给字符串加引号，剥掉。
  Future<String> _evalJs(WebViewController controller, String expr) async {
    try {
      final r = await controller.runJavaScriptReturningResult(expr);
      var s = r.toString();
      // Android evaluateJavascript 返回 JSON 文本：字符串值带引号且内部
      // 引号转义为 \"（如 JSON.stringify 的 tokenInfo）。此时整体仍是
      // 合法 JSON 字符串字面量——先整体 jsonDecode（同时完成剥引号与
      // 反转义）；先手工剥引号再 decode 剩余部分会因 \" 非法而必失败。
      if (s.length >= 2 &&
          ((s.startsWith('"') && s.endsWith('"')) ||
              (s.startsWith("'") && s.endsWith("'")))) {
        try {
          final dec = jsonDecode(s);
          if (dec is String) return dec;
        } catch (_) {}
        s = s.substring(1, s.length - 1);
      }
      return s;
    } catch (_) {
      return '';
    }
  }
}
