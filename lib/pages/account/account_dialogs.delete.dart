part of 'account_dialogs.dart';

Future<bool> showDeleteAccountDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DeleteAccountDialog(notifier: notifier),
  ).then((v) => v ?? false);
}

class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.notifier});
  final AuthNotifier notifier;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _passwordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  bool _codeLoading = false;
  int _countdown = 0;

  @override
  void dispose() {
    _passwordCtrl.dispose();
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
      title: tr('发送注销验证码前验证'),
      description: tr('完成验证后将向当前账号的注册邮箱发送注销验证码。'),
    );
    if (captcha == null || !mounted) return;
    setState(() => _codeLoading = true);
    try {
      final msg = await widget.notifier.sendCode(email, 'delete_account',
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
    final password = _passwordCtrl.text;
    final code = _codeCtrl.text.trim();
    if (password.isEmpty) {
      _toast(tr('请输入登录密码'));
      return;
    }
    if (code.isEmpty) {
      _toast(tr('请输入邮箱验证码'));
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.notifier
          .preVerifyDeleteAccount(verifyCode: code, password: password);
      if (!mounted) return;
      setState(() => _loading = false);
      final confirmed = await _showConfirm();
      if (confirmed != true || !mounted) return;
      setState(() => _loading = true);
      await widget.notifier
          .deleteAccount(verifyCode: code, password: password);
      if (!mounted) return;
      _toast(tr('账号已注销'));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('注销账号失败'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool?> _showConfirm() {
    return showPredictiveDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('确认注销账号')),
        content:   Text(tr('注销后账号数据将被清除且无法恢复，确定要注销当前账号吗？')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('确认注销')),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) =>
      showXianYuToast(context, msg, duration: const Duration(seconds: 2));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final email = widget.notifier.currentState.user?.email ?? tr('未知邮箱');
    return AlertDialog(
      title:   Text(tr('注销账号')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('注销后账号数据将被清除且无法恢复。验证码将发送到注册邮箱：{email}', {'email': email}),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              obscureText: _obscure,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr('登录密码'),
                hintText: tr('请输入当前登录密码'),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context, false),
          child:   Text(tr('取消')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
          ),
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              :   Text(tr('注销账号')),
        ),
      ],
    );
  }
}

