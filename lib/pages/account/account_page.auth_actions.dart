part of 'account_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _AccountPageAuthActions on _AccountPageState {
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
    final captcha = await _requestHumanCaptcha(
      title: tr('发送验证码前验证'),
      description: tr('完成验证后将向邮箱发送验证码。'),
    );
    if (captcha == null || !mounted) return;
    final notifier = ref.read(authProvider.notifier);
    final isEmailLogin = _tab.index == 0 && _loginByEmail;
    try {
      final msg = await notifier
          .sendCode(email, isEmailLogin ? 'login' : 'register', captcha: captcha);
      if (!mounted) return;
      _toast(msg);
      if (msg.toLowerCase().contains('失败') || msg.contains('错误')) return;
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('验证码发送失败'));
    }
  }

  void _toast(String msg) =>
      showXianYuToast(context, msg, duration: const Duration(seconds: 2));

  Future<void> _submit() async {
    final notifier = ref.read(authProvider.notifier);
    final isLogin = _tab.index == 0;

    if (!_agreed) {
      notifier.setError(tr('请先阅读并同意《用户协议》和《隐私政策》'));
      return;
    }

    if (!isLogin && _passwordCtrl.text != _confirmCtrl.text) {
      notifier.setError(tr('两次输入的密码不一致'));
      return;
    }

    final captcha = await _requestHumanCaptcha(
      title: isLogin ? tr('登录前验证') : tr('注册前验证'),
      description: isLogin ? tr('完成验证后将继续登录当前账号。') : tr('完成验证后将继续创建账号。'),
    );
    if (captcha == null || !mounted) return;

    if (isLogin) {
      if (_loginByEmail) {
        await notifier.loginByEmail(
          email: _emailCtrl.text,
          code: _codeCtrl.text,
          captcha: captcha,
        );
      } else {
        await notifier.login(
          ciyuanxiId: _idCtrl.text,
          password: _passwordCtrl.text,
          captcha: captcha,
        );
      }
    } else {
      await notifier.register(
        ciyuanxiId: _idCtrl.text,
        nickname: _nicknameCtrl.text,
        password: _passwordCtrl.text,
        email: _emailCtrl.text,
        code: _codeCtrl.text,
        captcha: captcha,
      );
    }

    if (mounted && ref.read(authProvider).user != null) {
      await ref.read(syncProvider.notifier).syncOnLoginSuccess(context);
    }
  }

  Future<HumanCaptchaPayload?> _requestHumanCaptcha({
    required String title,
    required String description,
  }) {
    return showHumanCaptchaDialog(
      context,
      notifier: ref.read(authProvider.notifier),
      title: title,
      description: description,
    );
  }

  Future<void> _showSessionExpiredDialog() async {
    final notifier = ref.read(authProvider.notifier);
    await showPredictiveDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('登录状态已失效')),
        content:   Text(tr('登录状态已失效，请重新登录。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:   Text(tr('确认')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child:   Text(tr('登录')),
          ),
        ],
      ),
    );
    notifier.consumeSessionExpired();
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('退出登录')),
        content:   Text(tr('确定要退出当前账号吗？')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('退出')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(authProvider.notifier).logout();
    }
  }
}
