import 'package:flutter/material.dart';

import '../../src/auth/auth_provider.dart';
import 'human_captcha_dialog.dart';

/// 账号相关弹窗集合：修改密码 / 绑定邮箱 / 修改昵称 / 修改弦予号 / 注销账号 / 找回密码。
///
/// 每个弹窗以 `showXxxDialog(context, notifier)` 打开，返回是否成功。

/// 修改密码弹窗（需邮箱验证码 + 人机验证）。
Future<bool> showChangePasswordDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showDialog<bool>(
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
      _toast('未获取到注册邮箱，请重新登录');
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: '发送修改密码验证码前验证',
      description: '完成验证后将向当前账号的注册邮箱发送修改密码验证码。',
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
      _toast(e is AuthException ? e.message : '验证码发送失败');
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
      _toast('请填写完整的密码信息');
      return;
    }
    if (newPwd != confirm) {
      _toast('两次新密码不一致');
      return;
    }
    if (code.isEmpty) {
      _toast('请输入邮箱验证码');
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.notifier
          .changePassword(oldPassword: oldPwd, newPassword: newPwd, code: code);
      await widget.notifier.logout();
      if (!mounted) return;
      _toast('密码已修改，请重新登录');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '修改密码失败');
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
    final email = widget.notifier.currentState.user?.email ?? '未知邮箱';
    return AlertDialog(
      title: const Text('修改密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '修改成功后需要重新登录，验证码将发送到注册邮箱：$email',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            _pwdField(_oldCtrl, '当前密码', _obscureOld, (v) {
              setState(() => _obscureOld = v);
            }),
            _pwdField(_newCtrl, '新密码', _obscureNew, (v) {
              setState(() => _obscureNew = v);
            }),
            _pwdField(_confirmCtrl, '确认新密码', _obscureNew, (v) {
              setState(() => _obscureNew = v);
            }),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    decoration: InputDecoration(
                      labelText: '邮箱验证码',
                      hintText: '请输入验证码',
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
                          ? '发送中…'
                          : _countdown > 0
                              ? '重新发送(${_countdown}s)'
                              : '发送验证码'),
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
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认修改'),
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

/// 绑定邮箱弹窗（需 type='bind' 的邮箱验证码）。
Future<bool> showBindEmailDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showDialog<bool>(
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
      _toast('请输入正确的邮箱');
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: '发送绑定验证码前验证',
      description: '完成验证后将向该邮箱发送绑定验证码。',
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
      _toast(e is AuthException ? e.message : '验证码发送失败');
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
      _toast('未获取到当前账号信息，请重新登录');
      return;
    }
    if (!email.contains('@')) {
      _toast('请输入正确的邮箱');
      return;
    }
    if (code.isEmpty) {
      _toast('请输入邮箱验证码');
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.notifier
          .bindEmail(ciyuanxiId: ciyuanxiId, email: email, verifyCode: code);
      if (!mounted) return;
      _toast('邮箱绑定成功');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '邮箱绑定失败');
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
      title: const Text('绑定邮箱'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '绑定邮箱后可用于登录与找回密码，请填写常用且可接收邮件的地址。',
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: '邮箱',
              hintText: '请输入邮箱',
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
                    labelText: '邮箱验证码',
                    hintText: '请输入验证码',
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
                        ? '发送中…'
                        : _countdown > 0
                            ? '重新发送(${_countdown}s)'
                            : '发送验证码'),
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
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认绑定'),
        ),
      ],
    );
  }
}

/// 修改昵称弹窗（走审核流程）。
Future<String?> showChangeNicknameDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangeNicknameDialog(notifier: notifier),
  );
}

class ChangeNicknameDialog extends StatefulWidget {
  const ChangeNicknameDialog({super.key, required this.notifier});
  final AuthNotifier notifier;

  @override
  State<ChangeNicknameDialog> createState() => _ChangeNicknameDialogState();
}

class _ChangeNicknameDialogState extends State<ChangeNicknameDialog> {
  late final TextEditingController _nicknameCtrl;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _nicknameCtrl =
        TextEditingController(text: widget.notifier.currentState.user?.nickname ?? '');
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final nickname = _nicknameCtrl.text.trim();
    if (nickname.isEmpty) {
      _toast('请输入昵称');
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await widget.notifier.updateProfile(nickname: nickname);
      if (!mounted) return;
      _toast(result.nicknamePending ? '昵称修改申请已提交，待审核通过后生效' : '昵称已更新');
      Navigator.pop(context, result.user.nickname);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '保存失败');
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
      title: const Text('修改昵称'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '昵称修改需管理员审核，审核通过后生效。',
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nicknameCtrl,
            maxLength: 20,
            decoration: InputDecoration(
              labelText: '新昵称',
              hintText: '请输入新昵称',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('提交申请'),
        ),
      ],
    );
  }
}

/// 修改弦予号弹窗（每月限一次）。
Future<bool> showChangeCiyuanxiDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangeCiyuanxiDialog(notifier: notifier),
  ).then((v) => v ?? false);
}

class ChangeCiyuanxiDialog extends StatefulWidget {
  const ChangeCiyuanxiDialog({super.key, required this.notifier});
  final AuthNotifier notifier;

  @override
  State<ChangeCiyuanxiDialog> createState() => _ChangeCiyuanxiDialogState();
}

class _ChangeCiyuanxiDialogState extends State<ChangeCiyuanxiDialog> {
  final _newIdCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _newIdCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = widget.notifier.currentState.user;
    final oldId = user?.ciyuanxiId ?? user?.id ?? '';
    final target = _newIdCtrl.text.trim();
    final pwd = _passwordCtrl.text;
    if (oldId.isEmpty) {
      _toast('未获取到当前弦予号，请重新登录');
      return;
    }
    if (target.length < 6 || target.length > 20) {
      _toast('弦予号需 6-20 位');
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9]{6,20}$').hasMatch(target)) {
      _toast('弦予号仅支持纯数字、纯字母或数字字母组合');
      return;
    }
    if (pwd.isEmpty) {
      _toast('请输入登录密码');
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.notifier.updateCiyuanxiId(
        oldCiyuanxiId: oldId,
        newCiyuanxiId: target,
        password: pwd,
      );
      if (!mounted) return;
      _toast('弦予号修改成功');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '弦予号修改失败');
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
    final user = widget.notifier.currentState.user;
    final oldId = user?.ciyuanxiId ?? user?.id ?? '';
    return AlertDialog(
      title: const Text('修改弦予号'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '弦予号是登录账号的唯一标识（参考微信号），每月仅可修改一次，请谨慎设置。',
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: TextEditingController(text: oldId),
            readOnly: true,
            decoration: InputDecoration(
              labelText: '当前弦予号',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newIdCtrl,
            decoration: InputDecoration(
              labelText: '新弦予号',
              hintText: '6-20 位，支持纯数字、纯字母或组合',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtrl,
            obscureText: _obscure,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: '登录密码',
              hintText: '请输入当前登录密码',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认修改'),
        ),
      ],
    );
  }
}

/// 注销账号弹窗（密码 + 邮箱验证码双重验证）。
Future<bool> showDeleteAccountDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showDialog<bool>(
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
      _toast('未获取到注册邮箱，请重新登录');
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: '发送注销验证码前验证',
      description: '完成验证后将向当前账号的注册邮箱发送注销验证码。',
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
      _toast(e is AuthException ? e.message : '验证码发送失败');
    } finally {
      if (mounted) setState(() => _codeLoading = false);
    }
  }

  Future<void> _submit() async {
    final password = _passwordCtrl.text;
    final code = _codeCtrl.text.trim();
    if (password.isEmpty) {
      _toast('请输入登录密码');
      return;
    }
    if (code.isEmpty) {
      _toast('请输入邮箱验证码');
      return;
    }
    setState(() => _loading = true);
    try {
      // 先预验证凭据，再弹二级确认。
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
      _toast('账号已注销');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '注销账号失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool?> _showConfirm() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('确认注销账号'),
        content: const Text('注销后账号数据将被清除且无法恢复，确定要注销当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认注销'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final email = widget.notifier.currentState.user?.email ?? '未知邮箱';
    return AlertDialog(
      title: const Text('注销账号'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '注销后账号数据将被清除且无法恢复。验证码将发送到注册邮箱：$email',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              obscureText: _obscure,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '登录密码',
                hintText: '请输入当前登录密码',
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
                      labelText: '邮箱验证码',
                      hintText: '请输入验证码',
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
                          ? '发送中…'
                          : _countdown > 0
                              ? '重新发送(${_countdown}s)'
                              : '发送验证码'),
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
          child: const Text('取消'),
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
              : const Text('注销账号'),
        ),
      ],
    );
  }
}

/// 找回密码弹窗（未登录场景）。
Future<bool> showForgotPasswordDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showDialog<bool>(
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
      _toast('请输入正确的邮箱');
      return;
    }
    final captcha = await showHumanCaptchaDialog(
      context,
      notifier: widget.notifier,
      title: '发送重置验证码前验证',
      description: '完成验证后将向该邮箱发送重置密码验证码。',
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
      _toast(e is AuthException ? e.message : '验证码发送失败');
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
      _toast('请输入正确的邮箱');
      return;
    }
    if (code.isEmpty) {
      _toast('请输入邮箱验证码');
      return;
    }
    if (newPwd.isEmpty || confirm.isEmpty) {
      _toast('请填写完整的新密码');
      return;
    }
    if (newPwd != confirm) {
      _toast('两次新密码不一致');
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.notifier.resetPassword(
        email: email,
        verifyCode: code,
        newPassword: newPwd,
      );
      if (!mounted) return;
      _toast('密码已重置，请使用新密码登录');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '重置密码失败');
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
      title: const Text('找回密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '输入注册邮箱，验证通过后设置新密码。',
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: '邮箱',
                hintText: '请输入注册邮箱',
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
                      labelText: '邮箱验证码',
                      hintText: '请输入验证码',
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
                          ? '发送中…'
                          : _countdown > 0
                              ? '重新发送(${_countdown}s)'
                              : '发送验证码'),
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
                labelText: '新密码',
                hintText: '设置新密码',
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
                labelText: '确认新密码',
                hintText: '再次输入新密码',
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
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('重置密码'),
        ),
      ],
    );
  }
}
