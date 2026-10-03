part of 'account_dialogs.dart';

Future<bool> showChangePasswordDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangePasswordDialog(notifier: notifier),
  ).then((v) => v ?? false);
}

class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key, required this.notifier});
  final AuthNotifier notifier;

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _loading = false;
  bool _codeLoading = false;
  int _countdown = 0;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    Future.doWhile(() async {
      if (_countdown <= 0) return false;
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() => _countdown--);
      return true;
    });
  }

  Future<void> _sendCode() async {
    final email = widget.notifier.currentState.user?.email;
    if (email == null || email.isEmpty) {
      _toast(tr('未获取到注册邮箱，请重新登录'));
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: tr('发送修改密码验证码前验证'),
      description: tr('完成验证后将向当前账号的注册邮箱发送修改密码验证码。'),
    );
    if (captcha == null || !mounted) return;
    setState(() => _codeLoading = true);
    try {
      final msg = await widget.notifier.sendCode(email, 'change_password',
          captcha: captcha);
      if (!mounted) return;
      _toast(msg);
      if (msg.toLowerCase().contains('失败') || msg.contains('错误')) return;
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('验证码发送失败'));
    } finally {
      if (mounted) setState(() => _codeLoading = false);
    }
  }

  Future<void> _submit() async {
    final oldPwd = _oldCtrl.text;
    final newPwd = _newCtrl.text;
    final confirm = _confirmCtrl.text;
    final code = _codeCtrl.text.trim();
    if (oldPwd.isEmpty || newPwd.isEmpty || confirm.isEmpty) {
      _toast(tr('请填写完整的密码信息'));
      return;
    }
    if (newPwd != confirm) {
      _toast(tr('两次新密码不一致'));
      return;
    }
    if (code.isEmpty) {
      _toast(tr('请输入邮箱验证码'));
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.notifier
          .changePassword(oldPassword: oldPwd, newPassword: newPwd, code: code);
      await widget.notifier.logout();
      if (!mounted) return;
      _toast(tr('密码已修改，请重新登录'));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('修改密码失败'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final email = widget.notifier.currentState.user?.email ?? tr('未知邮箱');
    return AlertDialog(
      title:   Text(tr('修改密码')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('修改成功后需要重新登录，验证码将发送到注册邮箱：{email}', {'email': email}),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            _pwdField(_oldCtrl, tr('当前密码'), _obscureOld, (v) {
              setState(() => _obscureOld = v);
            }),
            _pwdField(_newCtrl, tr('新密码'), _obscureNew, (v) {
              setState(() => _obscureNew = v);
            }),
            _pwdField(_confirmCtrl, tr('确认新密码'), _obscureNew, (v) {
              setState(() => _obscureNew = v);
            }),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    decoration: InputDecoration(
                      labelText: tr('邮箱验证码'),
                      hintText: tr('请输入验证码'),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed:
                          (_codeLoading || _loading || _countdown > 0)
                              ? null
                              : _sendCode,
                      child: Text(_codeLoading
                          ? tr('发送中…')
                          : _countdown > 0
                              ? tr('重新发送({n}s)', {'n': _countdown})
                              : tr('发送验证码')),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context, false),
          child:   Text(tr('取消')),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              :   Text(tr('确认修改')),
        ),
      ],
    );
  }

  Widget _pwdField(TextEditingController ctrl, String label, bool obscure,
      ValueChanged<bool> onToggle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          suffixIcon: IconButton(
            icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => onToggle(!obscure),
          ),
        ),
      ),
    );
  }
}

Future<bool> showForgotPasswordDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ForgotPasswordDialog(notifier: notifier),
  ).then((v) => v ?? false);
}

class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({super.key, required this.notifier});
  final AuthNotifier notifier;

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  bool _codeLoading = false;
  int _countdown = 0;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    Future.doWhile(() async {
      if (_countdown <= 0) return false;
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() => _countdown--);
      return true;
    });
  }

  Future<void> _sendCode() async {
    final email = _emailCtrl.text.trim();
    if (!email.contains('@')) {
      _toast(tr('请输入正确的邮箱'));
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: tr('发送重置验证码前验证'),
      description: tr('完成验证后将向该邮箱发送重置密码验证码。'),
    );
    if (captcha == null || !mounted) return;
    setState(() => _codeLoading = true);
    try {
      final msg = await widget.notifier.sendCode(email, 'reset_password',
          captcha: captcha);
      if (!mounted) return;
      _toast(msg);
      if (msg.toLowerCase().contains('失败') || msg.contains('错误')) return;
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('验证码发送失败'));
    } finally {
      if (mounted) setState(() => _codeLoading = false);
    }
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final newPwd = _newCtrl.text;
    final confirm = _confirmCtrl.text;
    if (!email.contains('@')) {
      _toast(tr('请输入正确的邮箱'));
      return;
    }
    if (code.isEmpty) {
      _toast(tr('请输入邮箱验证码'));
      return;
    }
    if (newPwd.isEmpty || confirm.isEmpty) {
      _toast(tr('请填写完整的新密码'));
      return;
    }
    if (newPwd != confirm) {
      _toast(tr('两次新密码不一致'));
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: tr('重置密码前验证'),
      description: tr('完成验证后将重置该邮箱账号的密码。'),
    );
    if (captcha == null || !mounted) return;
    setState(() => _loading = true);
    try {
      await widget.notifier.resetPassword(
        email: email,
        verifyCode: code,
        newPassword: newPwd,
        captcha: captcha,
      );
      if (!mounted) return;
      _toast(tr('密码已重置，请使用新密码登录'));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('重置密码失败'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title:   Text(tr('找回密码')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('输入注册邮箱，验证通过后设置新密码。'),
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: tr('邮箱'),
                hintText: tr('请输入注册邮箱'),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    decoration: InputDecoration(
                      labelText: tr('邮箱验证码'),
                      hintText: tr('请输入验证码'),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed:
                          (_codeLoading || _loading || _countdown > 0)
                              ? null
                              : _sendCode,
                      child: Text(_codeLoading
                          ? tr('发送中…')
                          : _countdown > 0
                              ? tr('重新发送({n}s)', {'n': _countdown})
                              : tr('发送验证码')),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newCtrl,
              obscureText: _obscure,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr('新密码'),
                hintText: tr('设置新密码'),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmCtrl,
              obscureText: _obscure,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr('确认新密码'),
                hintText: tr('再次输入新密码'),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context, false),
          child:   Text(tr('取消')),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              :   Text(tr('重置密码')),
        ),
      ],
    );
  }
}

