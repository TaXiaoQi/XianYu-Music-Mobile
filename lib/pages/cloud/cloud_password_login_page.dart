import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/press_scale.dart';
import 'cloud_login_form_kit.dart';

/// 账号登录页（Cookie / 账密双模式，按 provider 能力展示）。
///
/// 手动填 Cookie（captureRule.cookieNames 非空）与账密/短信表单
/// （loginFields 非空）都支持时以 SegmentedButton 互相切换，Cookie
/// 优先；仅支持其一时直接展示对应表单，无切换 UI。Cookie/账密都
/// 不支持的盘（token 范式）不经本页，绑定页直接路由网页登录。
enum _LoginMode { cookie, fields }

/// StatefulBuilder setter 尚未就绪时的占位（对比用，避免空指针）。
void _noopSet(void Function() _) {}

class CloudPasswordLoginPage extends ConsumerStatefulWidget {
  const CloudPasswordLoginPage({
    super.key,
    required this.providerId,
    this.embedded = false,
  });

  final String providerId;

  /// 横屏设置面板嵌入：不画自身 Scaffold/顶栏，成功后回网盘面板
  final bool embedded;

  @override
  ConsumerState<CloudPasswordLoginPage> createState() =>
      _CloudPasswordLoginPageState();
}

class _CloudPasswordLoginPageState extends ConsumerState<CloudPasswordLoginPage> {
  late final CloudProvider _provider;
  late final bool _supportsCookie;
  late final bool _supportsFields;

  /// 双模式时当前选择；单模式为 null（按能力直接渲染）。
  _LoginMode? _mode;

  final Map<String, TextEditingController> _ctrls = {};
  TextEditingController? _cookieCtrl;
  bool _submitting = false;
  bool _sendingSms = false;
  int _smsCooldown = 0;
  Timer? _cooldownTimer;

  // 弦予号登录同款：密码明文切换（小眼睛）与「记住密码」勾选状态。
  bool _obscure = true;
  bool _rememberPwd = false;

  /// 已展开的 optional 字段（多通道二选一切换态，如 139 服务密码）。
  final Set<String> _expandedFields = {};

  /// 登录提示落盘定位：首个非密码非验证码字段为账号，obscure 字段为密码。
  String? _accountKey;
  String? _passwordKey;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _supportsCookie = (_provider.captureRule?.cookieNames.isNotEmpty ?? false);
    _supportsFields = _provider.loginFields.isNotEmpty;
    if (_supportsCookie && _supportsFields) _mode = _LoginMode.cookie;
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
    _cooldownTimer?.cancel();
    _cookieCtrl?.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _fields => {
        for (final e in _ctrls.entries) e.key: e.value.text.trim(),
      };

  /// 回填上次登录的账号/密码：账号默认回填；密码仅在勾选过「记住密码」
  /// 时回填并同步勾选状态（会话失效重登免重复输入）。
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
        // 回填了记住的密码：自动展开密码通道，用户点登录即走账密。
        _expandedFields.add(_passwordKey!);
      }
    });
  }

  /// 登录成功后落盘登录提示：账号恒记；勾选「记住密码」才存密码，
  /// 未勾选则顺带清除旧密码（换号或取消勾选后不残留）。
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

  Future<void> _sendSms() async {
    if (_sendingSms || _smsCooldown > 0) return;
    setState(() => _sendingSms = true);
    try {
      await _provider.sendLoginSms(_fields);
      if (!mounted) return;
      showXianYuToast(context, tr('验证码已发送'));
      setState(() => _smsCooldown = 60);
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          if (--_smsCooldown <= 0) {
            _smsCooldown = 0;
            _cooldownTimer?.cancel();
          }
        });
      });
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 发送验证码失败: $e');
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('验证码发送失败'),
      );
    } finally {
      if (mounted) setState(() => _sendingSms = false);
    }
  }

  Future<void> _submitFields() async {
    if (_submitting) return;
    final fields = _fields;
    // 必填字段非空即可提交：optional 字段折叠时不校验（留空走另一通
    // 道），展开即视为选择该通道、参与必填校验。
    final requiredKeys = {
      for (final f in _provider.loginFields)
        if (!f.optional || _expandedFields.contains(f.key)) f.key,
    };
    if (requiredKeys.any((k) => (fields[k] ?? '').isEmpty)) {
      showXianYuToast(context, tr('请填写完整'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final account = await _provider.loginWithFields(fields);
      await CloudCredentialsStore.instance.saveAccount(account);
      await _saveLoginHint();
      if (!mounted) return;
      showXianYuToast(context, tr('绑定成功'));
      _finish();
    } on CloudSmsRequiredException catch (e) {
      // 风控/主动短信校验：provider 已自动发码，弹窗收码续登（天翼/139
      // 共用同一弹窗；139 走 e.hint 说明文案）。
      if (!mounted) return;
      setState(() => _submitting = false);
      await _promptSmsCode(e.username, hint: e.hint);
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 账密登录失败: $e');
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('登录失败，请重试'),
      );
      setState(() => _submitting = false);
    }
  }

  /// 验证码输入弹窗（同新建歌单的输入范式）：打开时不自动发码，弹窗内
  /// 「发送验证码」按钮手动触发，60 秒冷却防连点；确认后提交完成绑定。
  /// [hint] 覆盖默认「新设备登录」说明行（139 等主动短信登录盘用）。
  Future<void> _promptSmsCode(String username, {String? hint}) async {
    final controller = TextEditingController();
    // 弹窗内状态放外层闭包：StatefulBuilder 重建不会重置。
    var cooldown = 0;
    var sending = false;
    Timer? timer;
    var setDlg = _noopSet;
    void safeSet(void Function() fn) {
      if (setDlg != _noopSet) setDlg(fn);
    }

    Future<void> send() async {
      if (sending || cooldown > 0) return;
      safeSet(() => sending = true);
      try {
        await _provider.resendDeviceSms(username);
        if (!mounted) return;
        showXianYuToast(context, tr('验证码已发送'));
        safeSet(() => cooldown = 60);
        timer?.cancel();
        timer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (!mounted) {
            t.cancel();
            return;
          }
          safeSet(() {
            if (--cooldown <= 0) {
              cooldown = 0;
              t.cancel();
            }
          });
        });
      } catch (e) {
        AppLog.warn('cloud', '${_provider.id} 发送验证码失败: $e');
        if (!mounted) return;
        showXianYuToast(
          context,
          e is CloudException ? e.message : tr('验证码发送失败'),
        );
      } finally {
        safeSet(() => sending = false);
      }
    }

    final code = await showPredictiveDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('输入短信验证码')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(hint ??
                tr('检测到新设备登录，验证码将发送至 {username}',
                    {'username': username})),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(hintText: tr('短信验证码')),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          PressableScale(
            pressScale: 0.92,
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:   Text(tr('取消')),
            ),
          ),
          PressableScale(
            pressScale: 0.92,
            child: StatefulBuilder(
              builder: (ctx, setSb) {
                setDlg = setSb;
                return TextButton(
                  onPressed: (sending || cooldown > 0) ? null : send,
                  child: Text(
                    sending
                        ? tr('发送中…')
                        : (cooldown > 0
                            ? tr('{s} 秒', {'s': '$cooldown'})
                            : tr('发送验证码')),
                  ),
                );
              },
            ),
          ),
          PressableScale(
            pressScale: 0.92,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child:   Text(tr('确定')),
            ),
          ),
        ],
      ),
    );
    timer?.cancel();
    if (code == null || code.isEmpty) return;
    if (!mounted) return;
    setState(() => _submitting = true);
    try {
      final account = await _provider.submitSmsCode(username, code);
      await CloudCredentialsStore.instance.saveAccount(account);
      await _saveLoginHint();
      if (!mounted) return;
      showXianYuToast(context, tr('绑定成功'));
      context.pop();
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 验证码校验失败: $e');
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('登录失败，请重试'),
      );
      setState(() => _submitting = false);
    }
  }

  /// 绑定完成收尾：全屏页 pop；嵌入面板回网盘面板（面板重建重新拉取
  /// 已绑账号）。短信弹窗内的成功走 dialog 自身 pop，不经这里
  void _finish() {
    if (widget.embedded) {
      ref.read(landscapeSettingsCategoryProvider.notifier).state = '/cloud';
    } else {
      context.pop();
    }
  }

  Future<void> _submitCookie() async {
    if (_submitting) return;
    final raw = _cookieCtrl?.text ?? '';
    final cookies = parseCookieText(raw);
    if (cookies.isEmpty) {
      showXianYuToast(context, tr('未识别到 Cookie'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final account =
          await _provider.completeLogin(CloudCaptureResult(cookies: cookies));
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      showXianYuToast(context, tr('绑定成功'));
      _finish();
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} Cookie 登录失败: $e');
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('登录失败，请重试'),
      );
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showCookie = _supportsCookie && _mode != _LoginMode.fields;
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CloudLoginHintText(
          text: tr('登录{name}后即可播放网盘内的音乐',
              {'name': _provider.displayName}),
        ),
        if (_supportsCookie && _supportsFields) ...[
          const SizedBox(height: 16),
          SegmentedButton<_LoginMode>(
            segments: [
              ButtonSegment(
                value: _LoginMode.cookie,
                label: Text(tr('Cookie 登录')),
              ),
              ButtonSegment(
                value: _LoginMode.fields,
                label: Text(tr('账号密码')),
              ),
            ],
            selected: {_mode!},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ],
        // 嵌入卡片内 16、全屏 24（保持两处既有间距口径）
        SizedBox(height: widget.embedded ? 16 : 24),
        if (showCookie)
          _buildCookieForm(scheme)
        else
          _buildFieldsForm(scheme),
      ],
    );
    // 横屏设置面板嵌入：整块表单收进玻璃胶囊卡片，标题由统一带 head 位承载
    if (widget.embedded) {
      return cloudLoginEmbeddedCard(context: context, ref: ref, child: body);
    }
    return cloudLoginScaffold(
      context: context,
      ref: ref,
      title: _provider.displayName,
      body: body,
      // 顶栏「网页登录」：自绘表单之外的兜底通道（如 139 网页版捕获链）。
      // 嵌入面板无顶栏位，不展示；无 webviewLoginUrl 的盘不展示。
      actions: widget.embedded || _provider.webviewLoginUrl.isEmpty
          ? null
          : [
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

  /// 手动填 Cookie 表单（webviewCookie 范式盘的默认登录方式）。
  /// 输入框与按钮同弦予号登录页风格（填充底色 + 16 圆角）。
  Widget _buildCookieForm(ColorScheme scheme) {
    final names = _provider.captureRule?.cookieNames ?? const [];
    _cookieCtrl ??= TextEditingController();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('电脑浏览器登录 {name} 网页版后，按 F12 → 应用 → Cookie，'
              '复制整串粘贴到下方', {'name': _provider.displayName}),
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
          ),
        ),
        if (names.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            tr('需包含：{names}', {'names': names.join('、')}),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ],
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.only(bottom: 26),
          child: TextField(
            controller: _cookieCtrl,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: tr('Cookie'),
              hintText: '${names.join('=xxx; ')}=xxx',
              filled: true,
              fillColor: scheme.onSurface.withValues(alpha: 0.05),
              border: cloudLoginBorder(),
              enabledBorder: cloudLoginBorder(),
              focusedBorder: cloudLoginFocusedBorder(context),
            ),
          ),
        ),
        CloudLoginSubmitButton(
          label: tr('登录并绑定'),
          submitting: _submitting,
          onPressed: _submitCookie,
        ),
      ],
    );
  }

  /// 账密 / 短信表单（httpPassword / smsPassword 范式，按 loginFields
  /// 动态渲染）：公共 kit 输入框（前图标 + 填充底色 + 16 圆角），
  /// 密码框小眼睛切换明文，下方「记住密码」勾选（账号默认记住）。
  /// optional 字段（多通道二选一）默认折叠为切换入口，点击展开输入框
  /// 并显示切回链接；展开即视为选择该通道，提交时参与必填校验。
  Widget _buildFieldsForm(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in _provider.loginFields)
          if (_fieldCollapsed(f))
            Padding(
              padding: const EdgeInsets.only(bottom: 26),
              child: TextButton(
                onPressed: () =>
                    setState(() => _expandedFields.add(f.key)),
                child: Text(tr(f.switchLabel!)),
              ),
            )
          else ...[
            CloudLoginFieldBox(
              _ctrls[f.key]!,
              label: tr(f.label),
              icon: _iconFor(f),
              obscure: f.obscure ? _obscure : false,
              keyboard: f.isPhone
                  ? TextInputType.phone
                  : (f.obscure
                      ? TextInputType.visiblePassword
                      : (f.isSmsCode
                          ? TextInputType.number
                          : TextInputType.text)),
              suffixIcon: _suffixFor(f),
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
          onPressed: _submitFields,
        ),
      ],
    );
  }

  /// optional 字段是否处于折叠态（switchLabel 为空的不折叠）。
  bool _fieldCollapsed(CloudLoginField f) =>
      f.optional && f.switchLabel != null && !_expandedFields.contains(f.key);

  /// 字段前图标：密码锁、验证码短信、手机号、其余按账号处理。
  IconData _iconFor(CloudLoginField f) {
    if (f.obscure) return Icons.lock_outline;
    if (f.isSmsCode) return Icons.sms_outlined;
    if (f.isPhone) return Icons.smartphone_outlined;
    return Icons.person_outline;
  }

  /// 字段后缀：密码框小眼睛（点击切换明文），验证码字段发码按钮。
  Widget? _suffixFor(CloudLoginField f) {
    if (f.obscure) {
      return CloudLoginEyeToggle(
        obscured: _obscure,
        onToggle: () => setState(() => _obscure = !_obscure),
      );
    }
    if (f.isSmsCode) {
      return TextButton(
        onPressed: (_sendingSms || _smsCooldown > 0) ? null : _sendSms,
        child: Text(
          _smsCooldown > 0
              ? tr('{s} 秒', {'s': '$_smsCooldown'})
              : tr('发送验证码'),
        ),
      );
    }
    return null;
  }
}
