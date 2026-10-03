part of 'account_dialogs.dart';

Future<String?> showChangeNicknameDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showPredictiveDialog<String>(
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
      _toast(tr('请输入昵称'));
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await widget.notifier.updateProfile(nickname: nickname);
      if (!mounted) return;
      _toast(result.nicknamePending ? tr('昵称修改申请已提交，待审核通过后生效') : tr('昵称已更新'));
      Navigator.pop(context, result.user.nickname);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('保存失败'));
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
      title:   Text(tr('修改昵称')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('昵称修改需管理员审核，审核通过后生效。'),
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nicknameCtrl,
            maxLength: 20,
            decoration: InputDecoration(
              labelText: tr('新昵称'),
              hintText: tr('请输入新昵称'),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context, null),
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
              :   Text(tr('提交申请')),
        ),
      ],
    );
  }
}

Future<bool> showChangeCiyuanxiDialog(
  BuildContext context,
  AuthNotifier notifier,
) {
  return showPredictiveDialog<bool>(
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
      _toast(tr('未获取到当前弦予号，请重新登录'));
      return;
    }
    if (target.length < 6 || target.length > 20) {
      _toast(tr('弦予号需 6-20 位'));
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9]{6,20}$').hasMatch(target)) {
      _toast(tr('弦予号仅支持纯数字、纯字母或数字字母组合'));
      return;
    }
    if (pwd.isEmpty) {
      _toast(tr('请输入登录密码'));
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
      _toast(tr('弦予号修改成功'));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('弦予号修改失败'));
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
      title:   Text(tr('修改弦予号')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('弦予号是登录账号的唯一标识（参考微信号），每月仅可修改一次，请谨慎设置。'),
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: TextEditingController(text: oldId),
            readOnly: true,
            decoration: InputDecoration(
              labelText: tr('当前弦予号'),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newIdCtrl,
            decoration: InputDecoration(
              labelText: tr('新弦予号'),
              hintText: tr('6-20 位，支持纯数字、纯字母或组合'),
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
              :   Text(tr('确认修改')),
        ),
      ],
    );
  }
}

Future<bool> showProfileEditGate(
  BuildContext context, {
  required String title,
  required String desc,
  required String confirmText,
  String note = '',
  bool blocked = false,
}) {
  return showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ProfileEditGateDialog(
      title: title,
      desc: desc,
      confirmText: confirmText,
      note: note,
      blocked: blocked,
    ),
  ).then((v) => v ?? false);
}

class ProfileEditGateDialog extends StatelessWidget {
  const ProfileEditGateDialog({
    super.key,
    required this.title,
    required this.desc,
    required this.confirmText,
    this.note = '',
    this.blocked = false,
  });

  final String title;
  final String desc;
  final String confirmText;
  final String note;
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                blocked ? Icons.block : Icons.rate_review_outlined,
                size: 24,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              desc,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 15, color: const Color(0xFFB45309)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        note,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFB45309)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                if (!blocked) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      child:   Text(tr('取消')),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, !blocked),
                    child: Text(blocked ? tr('关闭') : confirmText),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
