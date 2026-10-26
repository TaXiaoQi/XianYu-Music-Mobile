import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/cloud/providers/webview_login_support.dart';
import '../../src/core/application_logger.dart';
import '../../src/i18n/i18n.dart';
import '../../src/navigation/shell.dart'
    show landscapeSettingsCategoryProvider;
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/press_scale.dart';
import 'cloud_login_form_kit.dart';

/// 自绘账密登录页（webviewFields 范式：UC CAS 逆向通道）。
///
/// 表单阶段：原生账密表单收账密（凭据不经网页表单）。提交后切换
/// WebView 执行器：加载 provider 声明的 CAS 登录页 → 注入脚本自动
/// 填表、等阿里云盾回调（无痕自动过；触发滑块时用户直接在 WebView
/// 内拖动）→ hook 抓 service_ticket → 导航兑换页种网盘 Cookie →
/// 复用捕获链收尾落库。
class CloudWebviewFieldsLoginPage extends ConsumerStatefulWidget {
  const CloudWebviewFieldsLoginPage({
    super.key,
    required this.providerId,
    this.embedded = false,
  });

  final String providerId;

  /// 横屏设置面板嵌入：不画自身 Scaffold/顶栏，成功后回网盘面板
  final bool embedded;

  @override
  ConsumerState<CloudWebviewFieldsLoginPage> createState() =>
      _CloudWebviewFieldsLoginPageState();
}

enum _Stage { form, running }

class _CloudWebviewFieldsLoginPageState
    extends ConsumerState<CloudWebviewFieldsLoginPage> {
  late final CloudProvider _provider;
  late final CloudWebviewCaptureSession _session;

  _Stage _stage = _Stage.form;
  bool _submitting = false;
  bool _finishing = false;
  bool _pageLoaded = false;
  String _hint = '';

  // 表单字段按 provider.loginFields 泛化（UC/夸克=账密两字段；迅雷=
  // 手机号 + 服务密码选填切换）。首个非 obscure 字段为账号、obscure
  // 字段为密码，凭据经 webviewFieldsScript(account, password) 传入。
  final Map<String, TextEditingController> _ctrls = {};
  String? _accountKey;
  String? _passwordKey;

  /// 已展开的 optional 字段（多通道二选一切换态，如迅雷服务密码）。
  final Set<String> _expandedFields = {};

  bool _obscure = true;
  bool _rememberPwd = false;

  WebViewController? _controller;
  String _lastMsg = '';
  int _msgSeq = 0;
  int _finalizeRetries = 0;

  // CAS 页是 PC 排版且 viewport 禁缩放，手机上看不清滑块——解锁同
  // WebView 登录页的缩放改写。
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
    for (final f in _provider.loginFields) {
      _ctrls[f.key] = TextEditingController();
      if (f.obscure) {
        _passwordKey ??= f.key;
      } else if (!f.isSmsCode) {
        _accountKey ??= f.key;
      }
    }
    _loadLoginHint();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _session.dispose();
    super.dispose();
  }

  /// 回填上次登录的账号/密码（自绘账密登录页同款语义：账号恒回填，
  /// 密码仅勾选过「记住密码」时回填并同步勾选态；回填了密码则自动
  /// 展开密码通道）。
  Future<void> _loadLoginHint() async {
    final hint = await CloudLoginHintStore.instance.hintFor(_provider.id);
    if (hint == null || !mounted) return;
    setState(() {
      final accountCtrl = _accountKey == null ? null : _ctrls[_accountKey];
      if (hint.account.isNotEmpty &&
          accountCtrl != null &&
          accountCtrl.text.isEmpty) {
        accountCtrl.text = hint.account;
      }
      final pwdCtrl = _passwordKey == null ? null : _ctrls[_passwordKey];
      if (hint.rememberPassword && pwdCtrl != null && pwdCtrl.text.isEmpty) {
        pwdCtrl.text = hint.password;
        _rememberPwd = true;
        _expandedFields.add(_passwordKey!);
      }
    });
  }

  Future<void> _saveLoginHint() async {
    final accountKey = _accountKey;
    if (accountKey == null) return;
    await CloudLoginHintStore.instance.save(
      _provider.id,
      _ctrls[accountKey]!.text.trim(),
      _passwordKey == null ? '' : _ctrls[_passwordKey]!.text,
      _rememberPwd,
    );
  }

  /// optional 字段是否处于折叠态（switchLabel 为空的不折叠）。
  bool _fieldCollapsed(CloudLoginField f) =>
      f.optional && f.switchLabel != null && !_expandedFields.contains(f.key);

  // ── WebView 执行器 ────────────────────────────────────────

  void _startWebviewFlow() {
    setState(() {
      _stage = _Stage.running;
      _hint = tr('正在打开安全验证…');
      _lastMsg = '';
    });
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'XianYuLogin',
        onMessageReceived: _onChannelMessage,
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) => _onPageFinished(url),
        onWebResourceError: (_) {},
      ));
    setState(() => _controller = controller);
    _bootstrap(controller);
  }

  Future<void> _bootstrap(WebViewController controller) async {
    final ua = _provider.webviewUserAgent;
    if (ua != null) {
      try {
        await controller.setUserAgent(ua);
      } catch (_) {}
    }
    try {
      await controller.loadRequest(Uri.parse(_provider.webviewFieldsLoginUrl));
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} CAS 页加载失败: $e');
      if (!mounted) return;
      _backToForm(tr('安全验证页打开失败，请重试'));
    }
  }

  Future<void> _onPageFinished(String url) async {
    if (!mounted) return;
    setState(() => _pageLoaded = true);
    final controller = _controller;
    if (controller == null) return;
    await controller.runJavaScript(_unlockZoomJs).catchError((_) {});

    final u = Uri.tryParse(url);
    if (u != null && _provider.isWebviewFieldsLoginPage(u)) {
      // 执行页就绪：注入执行脚本（填表 + 等验证 + 提交 + 回传 hook）。
      final script = _provider.webviewFieldsScript(
        _accountKey == null ? '' : _ctrls[_accountKey]!.text.trim(),
        _passwordKey == null ? '' : _ctrls[_passwordKey]!.text,
      );
      await controller.runJavaScript(script).catchError((_) {});
      if (mounted) {
        setState(() => _hint = tr('等待安全验证（出现滑块时请拖动）…'));
      }
      return;
    }
    final post = _provider.captureRule?.postLoginUrl;
    final postHost =
        post == null ? null : Uri.tryParse(post)?.host;
    // 排除执行页自身（同 host 不同 path 的盘，如迅雷 /login/ = 主站域）。
    final loginUri = Uri.tryParse(_provider.webviewFieldsLoginUrl);
    final isExecPage = loginUri != null &&
        u != null &&
        u.host == loginUri.host &&
        u.path == loginUri.path;
    if (postHost != null &&
        postHost.isNotEmpty &&
        postHost == (u?.host ?? '') &&
        !isExecPage) {
      // 主站落地页：__puus 由 init 请求数秒后才签发，稳定性轮询收尾。
      await _postLoginCapture();
      return;
    }
    if (u != null && _provider.isTicketExchangePage(u)) {
      // 兑换页 Set-Cookie 已下发，跳主站等 __puus 签发再捕获。
      if (post != null && _finishing == false) {
        if (mounted) setState(() => _hint = tr('验证通过，正在写入登录态…'));
        await controller.loadRequest(Uri.parse(post));
      }
    }
  }

  /// 主站落地后的 Cookie 稳定性轮询（与 WebView 登录页同款节奏）：
  /// 连续两轮签名一致视为会话落定，再捕获收尾。
  Future<void> _postLoginCapture() async {
    if (_finishing || !mounted) return;
    setState(() => _hint = tr('正在写入登录态…'));
    final controller = _controller;
    if (controller == null) return;
    try {
      var lastSig = '';
      for (var round = 0; round < 6; round++) {
        await Future<void>.delayed(
            Duration(milliseconds: round == 0 ? 3000 : 2500));
        if (!mounted || _finishing) return;
        final sig = await _session.cookieSignature(controller);
        if (sig.isEmpty) continue;
        if (sig == lastSig) break;
        lastSig = sig;
      }
      if (!mounted || _finishing) return;
      final done = await _session.forceCapture(controller);
      if (done) {
        await _finishLogin();
      } else if (mounted) {
        _backToForm(tr('登录态写入失败，请重试'));
      }
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} CAS 登录捕获失败: $e');
      if (!mounted) return;
      _backToForm(tr('登录态写入失败，请重试'));
    }
  }

  /// CAS 页回传处理：TICKET: 抓到 service_ticket → 兑换；MSG: 盾/表单
  /// 错误透传（官方文案直接面向用户）。MSG 在提交前后可能多次触发，
  /// 同文案只提示一次。
  Future<void> _onChannelMessage(JavaScriptMessage message) async {
    final raw = message.message;
    if (_finishing) return;
    if (raw.startsWith('TICKET:')) {
      final ticket = _extractTicket(raw.substring(7));
      if (ticket.isEmpty) {
        _backToForm(tr('登录票据获取失败，请重试'));
        return;
      }
      final controller = _controller;
      if (controller == null) return;
      if (mounted) setState(() => _hint = tr('登录成功，正在写入登录态…'));
      try {
        await controller
            .loadRequest(Uri.parse(_provider.ticketExchangeUrl(ticket)));
      } catch (e) {
        AppLog.warn('cloud', '${_provider.id} ticket 兑换失败: $e');
        if (mounted) _backToForm(tr('登录票据兑换失败，请重试'));
      }
      return;
    }
    if (raw.startsWith('MSG:')) {
      final msg = raw.substring(4).trim();
      if (msg.isEmpty || msg == _lastMsg) return;
      _lastMsg = msg;
      _msgSeq++;
      final seq = _msgSeq;
      AppLog.warn('cloud', '${_provider.id} CAS 提示: $msg');
      if (!mounted) return;
      // 盾交互提示（如「请按住滑块」）不是失败，不打断流程；只 toast。
      showXianYuToast(context, msg);
      // 密码错误类提示出现两次以上大概率账密有误，提示可返回修改。
      if (msg.contains('密码') && seq >= 2) {
        _backToForm(null);
      }
      return;
    }
    if (raw.startsWith('DIAG:')) {
      // 执行页环境诊断：仅落日志（CSS/JS 资源加载失败排查用）。
      AppLog.warn('cloud', '${_provider.id} CAS 诊断: ${raw.substring(5)}');
    }
  }

  /// pm 模式回传的 data 兼容两种形态：纯 ticket 字符串（redirect 模式
  /// 拼接语义）或 JSON 对象（含 service_ticket/st/ticket 字段之一）。
  String _extractTicket(String raw) {
    final t = raw.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        final j = jsonDecode(t);
        if (j is Map) {
          for (final k in const ['service_ticket', 'st', 'ticket']) {
            final v = j[k];
            if (v is String && v.trim().isNotEmpty) return v.trim();
          }
        }
      } catch (_) {}
    }
    return t;
  }

  Future<void> _finishLogin() async {
    if (_finishing || !mounted) return;
    _finishing = true;
    if (mounted) setState(() {});
    try {
      final account = await _provider.completeLogin(_session.result());
      await CloudCredentialsStore.instance.saveAccount(account);
      await _saveLoginHint();
      if (!mounted) return;
      showXianYuToast(context, tr('绑定成功'));
      if (widget.embedded) {
        // 横屏设置面板嵌入：切回网盘面板（无路由栈可弹）。
        ref.read(landscapeSettingsCategoryProvider.notifier).state = '/cloud';
      } else {
        context.pop();
      }
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} CAS 登录落库失败: $e');
      _finishing = false;
      _session.resetCompletion();
      if (!mounted) return;
      // completeLogin 的会话闸门未过时先重试一轮（Cookie 落定竞态），
      // 轮次用尽回表单。
      if (_finalizeRetries < 2) {
        _finalizeRetries++;
        await _postLoginCapture();
        return;
      }
      _backToForm(e is CloudException ? e.message : null);
    }
  }

  /// 回表单阶段（WebView 销毁，下次提交重建），toast 可选。
  void _backToForm(String? toast) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.form;
      _controller = null;
      _pageLoaded = false;
      _hint = '';
      _finishing = false;
      _submitting = false;
      _finalizeRetries = 0;
    });
    if (toast != null && toast.isNotEmpty) showXianYuToast(context, toast);
  }

  void _submit() {
    if (_submitting) return;
    // 必填字段非空即可提交：optional 字段折叠时不校验（留空走另一
    // 通道），展开即视为选择该通道、参与必填校验。
    final requiredKeys = {
      for (final f in _provider.loginFields)
        if (!f.optional || _expandedFields.contains(f.key)) f.key,
    };
    if (requiredKeys.any((k) => (_ctrls[k]?.text.trim() ?? '').isEmpty)) {
      showXianYuToast(context, tr('请填写完整'));
      return;
    }
    _submitting = true;
    _startWebviewFlow();
  }

  // ── UI（样式对齐天翼账密登录页）──────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 横屏设置面板嵌入：整块表单收进玻璃胶囊卡片，标题由统一带 head 位承载
    if (widget.embedded) {
      return cloudLoginEmbeddedCard(
        context: context,
        ref: ref,
        child: _buildBody(scheme),
      );
    }
    return cloudLoginScaffold(
      context: context,
      ref: ref,
      title: _provider.displayName,
      body: _buildBody(scheme),
      actions: [
        PressableScale(
          pressScale: 0.92,
          child: TextButton(
            onPressed: () =>
                context.push('/cloud/webview-login/${_provider.id}'),
            child: Text(tr('网页登录')),
          ),
        ),
      ],
    );
  }

  /// 主体：表单阶段 = 说明文案 + 账密表单；执行阶段 = WebView 盾执行器。
  Widget _buildBody(ColorScheme scheme) {
    return _stage == _Stage.running
        ? _buildRunner()
        : _buildFieldsForm(scheme);
  }

  /// 账密表单（天翼同款公共 kit，字段按 provider.loginFields 泛化）：
  /// optional 字段折叠为切换入口（自绘账密登录页同款交互），展开后
  /// 参与必填校验并可切回。
  Widget _buildFieldsForm(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CloudLoginHintText(
          text: tr('登录{name}后即可播放网盘内的音乐',
              {'name': _provider.displayName}),
        ),
        const SizedBox(height: 20),
        for (final f in _provider.loginFields)
          if (_fieldCollapsed(f))
            Padding(
              padding: const EdgeInsets.only(bottom: 26),
              child: TextButton(
                onPressed: () => setState(() => _expandedFields.add(f.key)),
                child: Text(tr(f.switchLabel!)),
              ),
            )
          else ...[
            CloudLoginFieldBox(
              _ctrls[f.key]!,
              label: tr(f.label),
              icon: f.obscure
                  ? Icons.lock_outline
                  : (f.isPhone ? Icons.smartphone : Icons.person_outline),
              obscure: f.obscure ? _obscure : false,
              keyboard: f.isPhone
                  ? TextInputType.phone
                  : (f.obscure
                      ? TextInputType.visiblePassword
                      : TextInputType.emailAddress),
              suffixIcon: f.obscure
                  ? CloudLoginEyeToggle(
                      obscured: _obscure,
                      onToggle: () => setState(() => _obscure = !_obscure),
                    )
                  : null,
              onSubmitted:
                  f.obscure && _obscure ? (_) => _submit() : null,
            ),
            if (f.collapseLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 26),
                child: TextButton(
                  onPressed: () {
                    _ctrls[f.key]!.clear();
                    setState(() => _expandedFields.remove(f.key));
                  },
                  child: Text(tr(f.collapseLabel!)),
                ),
              ),
          ],
        CloudLoginRememberRow(
          value: _rememberPwd,
          onChanged: (v) => setState(() => _rememberPwd = v),
        ),
        CloudLoginSubmitButton(
          label: tr('登录并绑定'),
          submitting: _submitting,
          onPressed: _submit,
        ),
        const SizedBox(height: 14),
        Text(
          tr('提交后自动填入官方登录页；若出现滑块请按提示拖动'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        // 嵌入面板无顶栏 actions 位：网页登录兜底入口放表单尾部。
        if (widget.embedded && _provider.webviewLoginUrl.isNotEmpty)
          CloudLoginWebFallbackButton(providerId: _provider.id),
      ],
    );
  }

  /// 执行阶段：WebView 可见（滑块交互需要）+ 顶部状态条 + 返回修改。
  Widget _buildRunner() {
    final controller = _controller;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              PressableScale(
                pressScale: 0.92,
                child: TextButton(
                  onPressed: () => _backToForm(null),
                  child: Text(tr('返回修改')),
                ),
              ),
            ],
          ),
        ),
        AspectRatio(
          // CAS 页为 PC 排版，横竖屏统一 4:3 视口保滑块可点区域
          aspectRatio: 0.9,
          child: controller == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      // Android 用 Hybrid Composition 承载：默认 TLHC
                      // 纹理模式拖动滑块渲染滞后（抬手才刷新），HC 实时。
                      child: Platform.isAndroid
                          ? WebViewWidget.fromPlatformCreationParams(
                              params: AndroidWebViewWidgetCreationParams(
                                controller:
                                    controller.platform as AndroidWebViewController,
                                displayWithHybridComposition: true,
                              ),
                            )
                          : WebViewWidget(controller: controller),
                    ),
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
    );
  }
}
