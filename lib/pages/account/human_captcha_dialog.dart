import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/i18n/i18n.dart';

/// 弹出人机验证弹窗，返回验证通过的 payload；取消返回 null。
///
/// 服务端启用 Turnstile/hCaptcha 时渲染第三方组件（WebView）；
/// 未启用时回退旧算术题（与桌面端 HumanCaptchaModal 一致）。
Future<HumanCaptchaPayload?> showHumanCaptchaDialog(
  BuildContext context, {
  required AuthNotifier notifier,
  required String title,
  required String description,
}) {
  return showPredictiveDialog<HumanCaptchaPayload>(
    context: context,
    barrierDismissible: false,
    builder: (_) => HumanCaptchaDialog(
      title: title,
      description: description,
      notifier: notifier,
    ),
  );
}

/// 人机验证弹窗。
/// 加载服务端配置 → 第三方组件（Turnstile/hCaptcha）或内置算术题 →
/// 验证通过后返回 [HumanCaptchaPayload]。
class HumanCaptchaDialog extends StatefulWidget {
  const HumanCaptchaDialog({
    super.key,
    required this.title,
    required this.description,
    required this.notifier,
  });
  final String title;
  final String description;
  final AuthNotifier notifier;

  @override
  State<HumanCaptchaDialog> createState() => _HumanCaptchaDialogState();
}

class _HumanCaptchaDialogState extends State<HumanCaptchaDialog> {
  HumanCaptchaConfig? _config;
  HumanCaptcha? _captcha;
  bool _loading = true;
  bool _verifying = false;
  String? _error;
  int _webViewEpoch = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _answerCtrl?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
      _webViewEpoch++;
    });
    try {
      // 先取服务端配置：启用第三方组件则渲染 WebView，否则回退算术题。
      final cfg = await widget.notifier.fetchCaptchaConfig();
      if (!mounted) return;
      if (cfg.isProviderEnabled) {
        setState(() {
          _config = cfg;
          _captcha = null;
          _loading = false;
        });
        return;
      }
      final c = await widget.notifier.fetchCaptcha();
      if (!mounted) return;
      setState(() {
        _config = cfg;
        _captcha = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _captcha = null;
        _loading = false;
        _error = e is AuthException ? e.message : tr('验证题加载失败，请稍后重试');
      });
    }
  }

  /// 第三方组件回调：拿到 token 直接返回 payload（服务端直验，无需预校验）。
  void _onProviderMessage(String raw) {
    if (!mounted || _verifying) return;
    String token = '';
    try {
      final j = jsonDecode(raw);
      if (j is Map) token = (j['token'] ?? '').toString();
    } catch (_) {
      token = raw;
    }
    if (token.isEmpty) return;
    final cfg = _config!;
    Navigator.pop(
      context,
      HumanCaptchaPayload(providerToken: token, provider: cfg.provider),
    );
  }

  Future<void> _submit() async {
    final captcha = _captcha;
    if (captcha == null || captcha.captchaId.isEmpty) {
      setState(() => _error = tr('请先加载验证题'));
      return;
    }
    final answer = _answerText;
    if (answer.isEmpty) {
      setState(() => _error = tr('请输入验证答案'));
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    final payload = HumanCaptchaPayload(
      captchaId: captcha.captchaId,
      captchaAnswer: answer,
    );
    try {
      await widget.notifier.verifyCaptcha(payload);
      if (!mounted) return;
      Navigator.pop(context, payload);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = e is AuthException ? e.message : tr('人机验证失败，请重试');
      });
      // 验证失败后自动换一题（旧题可能已失效）。
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isProvider = _config?.isProviderEnabled == true;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(widget.title)),
          if (isProvider && !_loading)
            TextButton(
              onPressed: _refresh,
              child: Text(tr('刷新')),
            ),
        ],
      ),
      content: _loading
          ? SizedBox(
              width: 280,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  tr('正在加载验证…'),
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
            )
          : (isProvider
              ? _buildProviderBody(context, scheme)
              : _buildArithmeticBody(context, scheme)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(tr('取消')),
        ),
        if (!isProvider)
          FilledButton(
            onPressed: (_loading || _verifying || _captcha == null) ? null : _submit,
            child: _verifying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(tr('验证并继续')),
          ),
      ],
    );
  }

  // ─── 第三方组件（Turnstile / hCaptcha，WebView 渲染）──────────────

  Widget _buildProviderBody(BuildContext context, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.description,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: appCardColor(context),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 300,
            height: 88,
            child: _ProviderCaptchaWebView(
              key: ValueKey('captcha-webview-$_webViewEpoch'),
              provider: _config!.provider,
              siteKey: _config!.siteKey,
              onMessage: _onProviderMessage,
              onError: () {
                if (mounted) {
                  setState(() => _error = tr('验证组件加载失败，请检查网络后重试'));
                }
              },
            ),
          ),
        ),
        if (_error != null && _error!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(fontSize: 13, color: scheme.error),
          ),
        ],
      ],
    );
  }

  // ─── 内置算术题模式 ──────────────────────────────────────────────

  TextEditingController? _answerCtrl;

  TextEditingController get _answerCtrlEnsure =>
      _answerCtrl ??= TextEditingController();

  String get _answerText => _answerCtrl?.text.trim() ?? '';

  Widget _buildArithmeticBody(BuildContext context, ColorScheme scheme) {
    final ctrl = _answerCtrlEnsure;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.description,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: appCardColor(context),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _captcha?.question.isNotEmpty == true
                      ? _captcha!.question
                      : tr('验证题加载失败'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: _verifying ? null : _refresh,
                child: Text(tr('换一题')),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          enabled: !_verifying && _captcha != null,
          decoration: InputDecoration(
            labelText: tr('验证答案'),
            hintText: tr('请输入答案'),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null && _error!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(fontSize: 13, color: scheme.error),
          ),
        ],
      ],
    );
  }
}

/// Turnstile / hCaptcha WebView 容器。
///
/// 加载本地 HTML（显式渲染第三方组件），通过 `FlutterCaptcha` JS 通道回调 token：
/// 成功 `{"token": "..."}`，过期/失败 `{"token": ""}`。
class _ProviderCaptchaWebView extends StatefulWidget {
  const _ProviderCaptchaWebView({
    super.key,
    required this.provider,
    required this.siteKey,
    required this.onMessage,
    required this.onError,
  });

  final String provider;
  final String siteKey;
  final ValueChanged<String> onMessage;
  final VoidCallback onError;

  @override
  State<_ProviderCaptchaWebView> createState() =>
      _ProviderCaptchaWebViewState();
}

class _ProviderCaptchaWebViewState extends State<_ProviderCaptchaWebView> {
  late final WebViewController _controller;
  bool _pageLoaded = false;

  String _buildHtml() {
    final siteKey = const HtmlEscape().convert(widget.siteKey);
    final isTurnstile = widget.provider != 'hcaptcha';
    final scriptSrc = isTurnstile
        ? 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit'
        : 'https://js.hcaptcha.com/1/api.js?render=explicit';
    final renderJs = isTurnstile
        ? 'turnstile.render("#box", {sitekey: "$siteKey", callback: onToken, '
            "'expired-callback': onExpire, 'error-callback': onExpire});"
        : 'hcaptcha.render("#box", {sitekey: "$siteKey", callback: onToken, '
            "'expired-callback': onExpire, 'error-callback': onExpire});";
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<script src="$scriptSrc" async defer></script>'
        '<style>html,body{margin:0;padding:0;background:transparent;'
        'display:flex;justify-content:center;align-items:center;min-height:100vh;'
        '-webkit-user-select:none;user-select:none;}</style></head><body>'
        '<div id="box"></div><script>'
        'function post(o){ try { FlutterCaptcha.postMessage(JSON.stringify(o)); } catch(e) {} }'
        'function onToken(t){ post({token: t || ""}); }'
        'function onExpire(){ post({token: ""}); }'
        'window.addEventListener("load", function(){ try { $renderJs } catch(e) { post({token: "", error: String(e)}); } });'
        '</script></body></html>';
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _pageLoaded = true);
        },
        onWebResourceError: (_) => widget.onError(),
      ))
      ..addJavaScriptChannel(
        'FlutterCaptcha',
        onMessageReceived: (m) => widget.onMessage(m.message),
      )
      ..loadHtmlString(_buildHtml());
  }

  @override
  Widget build(BuildContext context) {
    // WebView 渲染为透明背景；加载完成前不遮挡（组件自行呈现 checkbox）。
    return IgnorePointer(
      ignoring: !_pageLoaded,
      child: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (!_pageLoaded)
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }
}
