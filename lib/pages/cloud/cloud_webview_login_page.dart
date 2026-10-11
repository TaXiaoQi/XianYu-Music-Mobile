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
          _onUrl(url);
        },
        onWebResourceError: (_) {},
      ))
      ..loadRequest(Uri.parse(_provider.webviewLoginUrl));
    _startWatch();
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
    _finishing = true;
    _watch?.cancel();
    if (mounted) setState(() {});
    try {
      final account = await _provider.completeLogin(_session.result());
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
