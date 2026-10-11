import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';

/// 账密 / 短信登录页（httpPassword / smsPassword 范式）。
///
/// 表单按 provider.loginFields 动态渲染；发送验证码按钮仅出现在
/// isSmsCode 字段上，倒计时内禁用。
class CloudPasswordLoginPage extends ConsumerStatefulWidget {
  const CloudPasswordLoginPage({super.key, required this.providerId});

  final String providerId;

  @override
  ConsumerState<CloudPasswordLoginPage> createState() =>
      _CloudPasswordLoginPageState();
}

class _CloudPasswordLoginPageState extends ConsumerState<CloudPasswordLoginPage> {
  late final CloudProvider _provider;
  final Map<String, TextEditingController> _ctrls = {};
  bool _submitting = false;
  bool _sendingSms = false;
  int _smsCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    for (final f in _provider.loginFields) {
      _ctrls[f.key] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
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

  Future<void> _submit() async {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              const SizedBox(height: 20),
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
                onPressed: _submitting ? null : _submit,
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
}
