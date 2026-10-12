import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/cloud/providers/webview_login_support.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';

/// 账号登录页（Cookie / 账密双模式，按 provider 能力展示）。
///
/// 手动填 Cookie（captureRule.cookieNames 非空）与账密/短信表单
/// （loginFields 非空）都支持时以 SegmentedButton 互相切换，Cookie
/// 优先；仅支持其一时直接展示对应表单，无切换 UI。Cookie/账密都
/// 不支持的盘（token 范式）不经本页，绑定页直接路由网页登录。
enum _LoginMode { cookie, fields }

class CloudPasswordLoginPage extends ConsumerStatefulWidget {
  const CloudPasswordLoginPage({super.key, required this.providerId});

  final String providerId;

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

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _supportsCookie = (_provider.captureRule?.cookieNames.isNotEmpty ?? false);
    _supportsFields = _provider.loginFields.isNotEmpty;
    if (_supportsCookie && _supportsFields) _mode = _LoginMode.cookie;
    for (final f in _provider.loginFields) {
      _ctrls[f.key] = TextEditingController();
    }
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
    if (fields.values.any((v) => v.isEmpty)) {
      showXianYuToast(context, tr('请填写完整'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final account = await _provider.loginWithFields(fields);
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      showXianYuToast(context, tr('绑定成功'));
      context.pop();
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
      context.pop();
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
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              24,
              GlassTopBar.height(context) + 24,
              24,
              40 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              Text(
                tr('登录{name}后即可播放网盘内的音乐', {'name': _provider.displayName}),
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
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
                  onSelectionChanged: (s) =>
                      setState(() => _mode = s.first),
                ),
              ],
              const SizedBox(height: 20),
              if (showCookie)
                _buildCookieForm(scheme)
              else
                _buildFieldsForm(scheme),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(_provider.displayName),
            ),
          ),
        ],
      ),
    );
  }

  /// 手动填 Cookie 表单（webviewCookie 范式盘的默认登录方式）。
  Widget _buildCookieForm(ColorScheme scheme) {
    final names = _provider.captureRule?.cookieNames ?? const [];
    _cookieCtrl ??= TextEditingController();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        const SizedBox(height: 14),
        TextField(
          controller: _cookieCtrl,
          maxLines: 5,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr('Cookie'),
            hintText: '${names.join('=xxx; ')}=xxx',
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 22),
        FilledButton(
          onPressed: _submitting ? null : _submitCookie,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('登录并绑定')),
        ),
      ],
    );
  }

  /// 账密 / 短信表单（httpPassword / smsPassword 范式，按 loginFields
  /// 动态渲染；发送验证码按钮仅出现在 isSmsCode 字段上）。
  Widget _buildFieldsForm(ColorScheme scheme) {
    return Column(
      children: [
        for (final f in _provider.loginFields) ...[
          TextField(
            controller: _ctrls[f.key],
            obscureText: f.obscure,
            autocorrect: false,
            enableSuggestions: !f.obscure,
            keyboardType: f.isPhone
                ? TextInputType.phone
                : (f.obscure
                    ? TextInputType.visiblePassword
                    : TextInputType.text),
            decoration: InputDecoration(
              labelText: tr(f.label),
              isDense: true,
              suffixIcon: f.isSmsCode
                  ? TextButton(
                      onPressed:
                          (_sendingSms || _smsCooldown > 0) ? null : _sendSms,
                      child: Text(
                        _smsCooldown > 0
                            ? tr('{s} 秒', {'s': '$_smsCooldown'})
                            : tr('发送验证码'),
                      ),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _submitting ? null : _submitFields,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('登录并绑定')),
        ),
      ],
    );
  }
}
