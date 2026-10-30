import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _pendingPostLogin = false;
  // postLoginUrl 落地轮询防重入（主站多页跳转会多次触发 onPageFinished）。
  bool _postLoginRunning = false;
  // 校验失败后的自动重采轮数上限：捕获早于登录完成时（jar 残留旧
  // Cookie 提前齐活），用户此刻正在输账密，重试轮询等真登录落定。
  int _finalizeRetries = 0;
  // 首页 storage 清理已执行（只清一次，防误删登录后写入的新凭据）。
  bool _storageCleared = false;

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

  /// 清当前 origin 的 storage（仅首页加载执行一次）：token 型凭据存于
  /// localStorage（迅雷 credentials_*、阿里壳页 token 桥），不清会在
  /// 「添加其他账号」时被轮询脚本直接抓到上一账号。只在登录开始前清——
  /// 登录完成后写入的新凭据绝不能再清（跳转链后续页不清 storage）。
  static const _clearStorageJs = r'''
(function(){try{localStorage.clear();sessionStorage.clear();}catch(e){}})();
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
          // 首页加载即清 storage 残留（此后不再清），再注入轮询脚本——
          // 保证 pollScript 从干净状态开始轮询。
          if (!_storageCleared) {
            _storageCleared = true;
            _controller.runJavaScript(_clearStorageJs).catchError((_) {});
          }
          final inject = _provider.webviewInjectJs;
          if (inject != null) {
            _controller.runJavaScript(inject).catchError((_) {});
          }
          // postLoginUrl 补跳完成：等页面 JS 种完 Cookie 再捕获，
          // 此期间不做 URL 自动判定（SPA 路由会误触发）。
          if (_pendingPostLogin) {
            _pendingPostLogin = false;
            _postLoginCapture();
            return;
          }
          // postLoginUrl 范式：URL 落到主站即启动稳定性轮询收尾——
          // 登录跳转链中间态的 Cookie 未落定，不能按 URL 命中直接完成。
          final post = _provider.captureRule?.postLoginUrl;
          if (post != null) {
            final postHost = Uri.tryParse(post)?.host ?? '';
            if (postHost.isNotEmpty &&
                Uri.tryParse(url)?.host == postHost) {
              _postLoginCapture();
              return;
            }
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
    // 开页前清全局 Cookie（等效桌面端登录窗 incognito 隐身模式）：
    // WebView Cookie 全局持久，上次绑定账号的登录态残留会让「添加其他
    // 账号」时页面直接进已登录态、轮询脚本立刻抓到旧账号。清掉后本轮
    // 会话从未登录开始；本会话内新种的 Cookie 不受影响。
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {
      // 鸿蒙 fork 等 platform 实现缺失时兜底跳过，退回旧行为。
    }
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
      setState(() => _finishing = false);
      // 校验失败后重置捕获完成态：下次手动重试重新采集 Cookie（页面
      // JS 此期间可能已种齐），避免 watch 用旧快照反复失败。
      _session.resetCompletion();
      // postLoginUrl 范式：自动重入稳定性轮询（脏 jar 场景首次捕获早于
      // 真登录完成，用户此刻正在输账密/刚提交——等新会话 Cookie 落定再
      // 过闸），轮次用尽才提示回落手动兜底。
      if (_provider.captureRule?.postLoginUrl != null &&
          _finalizeRetries < 3) {
        _finalizeRetries++;
        _postLoginCapture();
        return;
      }
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('登录信息捕获失败，请重试'),
      );
      _startWatch();
    }
  }

  /// 手动填兜底：Cookie 范式填 Cookie；token 范式（阿里）凭据不在
  /// Cookie 里（refresh_token 存于网页版 localStorage，无接口可换），
  /// 填 refresh_token 或 tokenInfo JSON。
  Future<void> _manualCookie() async {
    if (_finishing || !mounted) return;
    final rule = _provider.captureRule;
    final isTokenKind = _provider.manualTokenInput;
    final names = rule?.cookieNames ?? const [];
    final controller = TextEditingController();
    var raw = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(isTokenKind ? '手动填 Token' : '手动填 Cookie')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _provider.manualInputHint ??
                  (isTokenKind
                      ? tr('粘贴网页版的 refresh_token（浏览器 F12 → Application → '
                          'Local Storage 里找 refresh_token 字段），或完整 tokenInfo JSON')
                      : (names.isEmpty
                          ? tr('粘贴已登录账号的 Cookie')
                          : tr('粘贴已登录账号的 Cookie，需包含 {names}', {
                              'names': names.join('、'),
                            }))),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              // onChanged 收集而非 pop 后读 controller.text——对话框退场
              // 动画期间 widget 树仍在访问 controller，pop 返回后立刻
              // dispose 会触发「used after being disposed」红屏崩溃。
              controller: controller,
              autofocus: true,
              maxLines: 4,
              onChanged: (v) => raw = v,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: isTokenKind
                    ? 'refresh_token'
                    : (names.isEmpty
                        ? 'BDUSS=xxx; STOKEN=xxx'
                        : 'kps=xxx; sign=xxx'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // 长文本粘贴会被输入法截断（实测 10000 字符），改走系统
              // 剪贴板 API 直接填充，无长度限制。
              final text = (await Clipboard.getData('text/plain'))?.text ?? '';
              if (text.isEmpty) return;
              controller.text = text;
              raw = text;
            },
            child: Text(tr('从剪贴板填入')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              raw = controller.text;
              Navigator.pop(ctx, raw.trim().isNotEmpty);
            },
            child: Text(tr('确定')),
          ),
        ],
      ),
    );
    // 不显式 dispose：退场动画仍持有引用，立即释放会崩；
    // 短生命周期对象交给 GC，无实际泄漏。
    if (ok != true || !mounted) return;
    if (isTokenKind) {
      final token = raw.trim();
      if (token.isEmpty) {
        showXianYuToast(context, tr('未识别到 Token'));
        return;
      }
      await _finalizeLogin(CloudCaptureResult(token: token));
      return;
    }
    final cookies = parseCookieText(raw);
    AppLog.info(
        'cloud', '手填 Cookie 解析: ${cookies.length} 键 ${cookies.keys.take(8).join(',')}'
        '${cookies.isEmpty ? '（原始长度 ${raw.length}，开头: ${raw.trim().substring(0, raw.trim().length > 30 ? 30 : raw.trim().length)}）' : ''}');
    if (cookies.isEmpty) {
      showXianYuToast(context, tr('未识别到 Cookie'));
      return;
    }
    await _finalizeLogin(CloudCaptureResult(cookies: cookies));
  }

  Future<void> _forceCapture() async {
    if (_finishing) return;
    // 主站页补跳：登录页上的 Cookie 缺页面侧风控指纹（百度 ndut_fmt
    // 等），先跳主站让 JS 种齐再捕获。已在主站则直接读。
    final post = _provider.captureRule?.postLoginUrl;
    if (post != null) {
      final postHost = Uri.tryParse(post)?.host ?? '';
      final cur = await _controller.currentUrl();
      final curHost = Uri.tryParse(cur ?? '')?.host ?? '';
      if (postHost.isNotEmpty && curHost != postHost) {
        _pendingPostLogin = true;
        await _controller.loadRequest(Uri.parse(post));
        return;
      }
    }
    final done = await _session.forceCapture(_controller);
    if (done) {
      _finishLogin();
    } else if (mounted) {
      await _session.debugDumpAuth(_controller);
      if (mounted) {
        showXianYuToast(context, tr('未捕获到登录信息，请先完成登录'));
      }
    }
  }

  /// postLoginUrl 页面加载完成后的延迟捕获。百度登录落地是 3-4 跳服务端
  /// 重定向，STOKEN 由最终落地页下发——固定 1.5s 会拿到与 BDUSS 不配对
  /// 的中间态旧值（列目录 errno=-6）。改为轮询读稳定性签名，连续两轮
  /// 一致（会话落定）再 finalize；轮次用尽也 finalize（completeLogin
  /// 的主站校验兜底，坏会话会抛错不产生坏账号）。
  Future<void> _postLoginCapture() async {
    if (_postLoginRunning || _finishing) return;
    _postLoginRunning = true;
    try {
      var lastSig = '';
      for (var round = 0; round < 6; round++) {
        await Future<void>.delayed(
            Duration(milliseconds: round == 0 ? 3000 : 2500));
        if (!mounted || _finishing) return;
        final sig = await _session.cookieSignature(_controller);
        if (sig.isEmpty) continue;
        if (sig == lastSig) break;
        lastSig = sig;
      }
      if (!mounted || _finishing) return;
      final done = await _session.forceCapture(_controller);
      if (done) {
        _finishLogin();
      } else if (mounted) {
        showXianYuToast(context, tr('未捕获到登录信息，请先完成登录'));
      }
    } finally {
      _postLoginRunning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 键盘 inset 不压缩 body：压缩会让 HC 模式 WebView 平台视图在键盘
      // 动画期间逐帧 relayout——部分机型上 WebView 因此失焦（输入法弹出
      // 即收起），全程逐帧全树重排也造成输入法明显卡顿。
      resizeToAvoidBottomInset: false,
      // 进一步隔绝子树对 viewInsets 的依赖：键盘动画逐帧上报 inset 不再
      // 触发 WebView 任何 rebuild/relayout，输入法悬浮在 WebView 上方，
      // 焦点输入框由网页自身 scrollIntoView 保证可见。
      body: MediaQuery.removeViewInsets(
        removeBottom: true,
        context: context,
        child: Column(
          children: [
            GlassTopBar(
              leading: const BackButton(),
              title: Text(_provider.displayName),
              actions: [
                PressableScale(
                  pressScale: 0.92,
                  child: TextButton(
                    onPressed: _finishing ? null : _manualCookie,
                    child: Text(tr(_provider.manualTokenInput
                        ? '填 Token'
                        : '填 Cookie')),
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
                  // Android 用 Hybrid Composition 承载：默认 TLHC 纹理模式
                  // 拖动滑块渲染滞后（抬手才刷新），HC 实时。
                  Platform.isAndroid
                      ? WebViewWidget.fromPlatformCreationParams(
                          params: AndroidWebViewWidgetCreationParams(
                            controller:
                                _controller.platform as AndroidWebViewController,
                            displayWithHybridComposition: true,
                          ),
                        )
                      : WebViewWidget(controller: _controller),
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
      ),
    );
  }
}
