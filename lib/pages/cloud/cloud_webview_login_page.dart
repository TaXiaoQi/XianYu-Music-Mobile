import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/cloud/providers/webview_login_support.dart';
import '../../src/core/application_logger.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/press_scale.dart';

/// WebView 网盘登录页（webviewCookie / webviewToken 范式）。
///
/// 页面只做装配：WebViewController + CloudWebviewCaptureSession；
/// Cookie/Token 捕获节奏由 provider 声明的 [CloudCaptureRule] 决定。
class CloudWebviewLoginPage extends StatefulWidget {
  const CloudWebviewLoginPage({super.key, required this.providerId});

  final String providerId;

  @override
  State<CloudWebviewLoginPage> createState() => _CloudWebviewLoginPageState();
}

class _CloudWebviewLoginPageState extends State<CloudWebviewLoginPage> {
  late final CloudProvider _provider;
  late final WebViewController _controller;
  late final CloudWebviewCaptureSession _session;
  Timer? _watch;
  bool _finishing = false;
  bool _pageLoaded = false;

  /// 解锁双指缩放：部分登录页（UC 桌面登录面板、百度 wappass 等）
  /// viewport 声明 user-scalable=no / maximum-scale=1，手机上无法
  /// 双指缩放看细节。仅改写缩放相关键，width / initial-scale /
  /// viewport-fit 保持页面原设置，不影响布局。
  static const _unlockZoomJs = r'''
(function(){
  try {
    var m = document.querySelector('meta[name="viewport"]');
    if (!m) return;
    var c = m.getAttribute('content') || '';
    if (!/user-scalable\s*=\s*no/i.test(c) &&
        !/maximum-scale\s*=\s*1(?:\s*,|\s*$)/i.test(c)) return;
    c = c.replace(/user-scalable\s*=\s*\w+/ig, 'user-scalable=yes')
         .replace(/minimum-scale\s*=\s*[\w.]+/ig, 'minimum-scale=0.2')
         .replace(/maximum-scale\s*=\s*[\w.]+/ig, 'maximum-scale=5');
    m.setAttribute('content', c);
  } catch (e) {}
})();
''';

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _session = CloudWebviewCaptureSession(
      _provider.captureRule ?? const CloudCaptureRule(),
    );
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          if (mounted) setState(() => _pageLoaded = true);
          _controller.runJavaScript(_unlockZoomJs).catchError((_) {});
          final auto = _provider.webviewAutoLoginScript;
          if (auto != null) {
            _controller.runJavaScript(auto).catchError((_) {});
          }
          _onUrl(url);
        },
        onWebResourceError: (_) {},
      ));
    _bootstrap();
    _startWatch();
  }

  /// 部分盘（夸克/UC/微云）需桌面 UA 才出登录入口；UA 设置完成后再加载。
  /// 壳页盘（阿里）渲染 provider 提供的 HTML（内嵌 OAuth iframe +
  /// postMessage 桥），baseUrl 决定壳页 origin。
  Future<void> _bootstrap() async {
    final ua = _provider.webviewUserAgent;
    if (ua != null) {
      try {
        await _controller.setUserAgent(ua);
      } catch (_) {}
    }
    final shell = _provider.webviewShellHtml;
    if (shell != null) {
      try {
        await _controller.loadHtmlString(shell, baseUrl: _provider.webviewShellBaseUrl);
        return;
      } catch (_) {
        // 壳页加载失败兜底直开 OAuth 页（捕获走旧 localStorage 通道）。
      }
    }
    await _controller
        .loadRequest(Uri.parse(_provider.webviewLoginUrl));
  }

  @override
  void dispose() {
    _watch?.cancel();
    _session.dispose();
    super.dispose();
  }

  /// 轮询兜底：捕获会话完成（含 pollScript token 通道）即进入落库。
  void _startWatch() {
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_session.isComplete) _finishLogin();
    });
  }

  Future<void> _onUrl(String url) async {
    try {
      final done = await _session.onPageEvent(_controller, url);
      if (done) _finishLogin();
    } catch (_) {
      // 单次采集异常不打断登录流程，等下一次页面事件。
    }
  }

  Future<void> _finishLogin() async {
    if (_finishing || !mounted) return;
    await _finalizeLogin(_session.result());
  }

  /// 落库（自动捕获与手动填 Cookie 共用）。
  Future<void> _finalizeLogin(CloudCaptureResult captured) async {
    _finishing = true;
    _watch?.cancel();
    if (mounted) setState(() {});
    try {
      final account = await _provider.completeLogin(captured);
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      showXianYuToast(context, tr('绑定成功'));
      context.pop();
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 登录捕获失败: $e');
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('登录信息捕获失败，请重试'),
      );
      setState(() => _finishing = false);
      _startWatch();
    }
  }

  /// 手动填 Cookie 兜底：自动捕获拿不到凭据（如鸿蒙端无原生
  /// getCookies、平台差异导致 Cookie 不可读）时，从浏览器复制
  /// 已登录 Cookie 粘贴落库。
  Future<void> _manualCookie() async {
    if (_finishing || !mounted) return;
    final names = _provider.captureRule?.cookieNames ?? const [];
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('手动填 Cookie')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              names.isEmpty
                  ? tr('粘贴已登录账号的 Cookie')
                  : tr('粘贴已登录账号的 Cookie，需包含 {names}', {
                      'names': names.join('、'),
                    }),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'kps=xxx; sign=xxx',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('确定')),
          ),
        ],
      ),
    );
    final raw = controller.text;
    controller.dispose();
    if (ok != true || !mounted) return;
    final cookies = parseCookieText(raw);
    if (cookies.isEmpty) {
      showXianYuToast(context, tr('未识别到 Cookie'));
      return;
    }
    await _finalizeLogin(CloudCaptureResult(cookies: cookies));
  }

  Future<void> _forceCapture() async {
    if (_finishing) return;
    final done = await _session.forceCapture(_controller);
    if (done) {
      _finishLogin();
    } else if (mounted) {
      showXianYuToast(context, tr('未捕获到登录信息，请先完成登录'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          GlassTopBar(
            leading: const BackButton(),
            title: Text(_provider.displayName),
            actions: [
              PressableScale(
                pressScale: 0.92,
                child: TextButton(
                  onPressed: _finishing ? null : _manualCookie,
                  child: Text(tr('填 Cookie')),
                ),
              ),
              PressableScale(
                pressScale: 0.92,
                child: TextButton(
                  onPressed: _finishing ? null : _forceCapture,
                  child: Text(tr('我已登录完成')),
                ),
              ),
            ],
          ),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (!_pageLoaded)
                  const Center(child: CircularProgressIndicator()),
                if (_finishing)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.35),
                      child: const Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
