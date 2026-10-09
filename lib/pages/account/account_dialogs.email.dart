part of 'account_dialogs.dart';

Future<bool> showBindEmailDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => BindEmailDialog(notifier: notifier),
  ).then((v) => v ?? false);
}

class BindEmailDialog extends StatefulWidget {
  const BindEmailDialog({super.key, required this.notifier});
  final AuthNotifier notifier;

  @override
  State<BindEmailDialog> createState() => _BindEmailDialogState();
}

class _BindEmailDialogState extends State<BindEmailDialog> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  bool _codeLoading = false;
  int _countdown = 0;

  @override
  void dispose() {
    _emailCtrl.dispose();
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
    final email = _emailCtrl.text.trim();
    if (!email.contains('@')) {
      _toast(tr('请输入正确的邮箱'));
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: tr('发送绑定验证码前验证'),
      description: tr('完成验证后将向该邮箱发送绑定验证码。'),
    );
    if (captcha == null || !mounted) return;
    setState(() => _codeLoading = true);
    try {
      final msg = await widget.notifier
          .sendCode(email, 'bind', captcha: captcha);
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
    final user = widget.notifier.currentState.user;
    final ciyuanxiId = user?.ciyuanxiId ?? user?.id ?? '';
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (ciyuanxiId.isEmpty) {
      _toast(tr('未获取到当前账号信息，请重新登录'));
      return;
    }
    if (!email.contains('@')) {
      _toast(tr('请输入正确的邮箱'));
      return;
    }
    if (code.isEmpty) {
      _toast(tr('请输入邮箱验证码'));
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.notifier
          .bindEmail(ciyuanxiId: ciyuanxiId, email: email, verifyCode: code);
      if (!mounted) return;
      _toast(tr('邮箱绑定成功'));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('邮箱绑定失败'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) =>
      showXianYuToast(context, msg, duration: const Duration(seconds: 2));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title:   Text(tr('绑定邮箱')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('绑定邮箱后可用于登录与找回密码，请填写常用且可接收邮件的地址。'),
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
              hintText: tr('请输入邮箱'),
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
        ],
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
              :   Text(tr('确认绑定')),
        ),
      ],
    );
  }
}

