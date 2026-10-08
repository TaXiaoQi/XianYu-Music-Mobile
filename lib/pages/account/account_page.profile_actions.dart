part of 'account_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _ProfileViewActions on _ProfileViewState {
  Future<void> _refreshStatus() async {
    if (_refreshingStatus) return;
    setState(() => _refreshingStatus = true);
    try {
      final avatarSt = await _notifier.getAvatarStatus();
      final nicknameSt = await _notifier.getNicknameStatus();
      if (!mounted) return;
      setState(() {
        _avatarStatus = avatarSt;
        _nicknameStatus = nicknameSt;
      });
      if (avatarSt == 'none' || nicknameSt == 'none') {
        await _notifier.getProfile();
      }
    } catch (e) {
      AppLog.warn('auth', '刷新账号状态失败: $e');
    } finally {
      if (mounted) setState(() => _refreshingStatus = false);
    }
  }

  Future<void> _pickAvatar() async {
    final limit = await _notifier.getAvatarChangeLimitStatus();
    if (!mounted) return;
    if (limit.todayBlocked || limit.status == 'pending') {
      await showProfileEditGate(
        context,
        title: tr('头像暂不能修改'),
        desc: limit.blockMessage.isNotEmpty
            ? limit.blockMessage
            : (limit.status == 'pending' ? tr('头像正在审核中哦') : tr('今日已修改过啦')),
        confirmText: tr('我知道了'),
        blocked: true,
      );
      return;
    }
    final proceed = await showProfileEditGate(
      context,
      title: tr('更换头像提示'),
      desc: tr('头像每日只能修改 1 次，上传后需要等待管理员审核。审核通过前会继续显示当前头像。'),
      confirmText: tr('继续选择头像'),
      note: tr('请确认本次修改内容无误后再继续。'),
    );
    if (!mounted || !proceed) return;
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      _toast(tr('头像不能超过 5MB'));
      return;
    }
    setState(() => _avatarUploading = true);
    try {
      final dataUrl = await _compressAvatar(bytes);
      await _notifier.uploadAvatar(dataUrl);
      if (!mounted) return;
      setState(() => _avatarStatus = 'pending');
      _toast(tr('头像已上传，等待管理员审核'));
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('头像上传失败'));
    } finally {
      if (mounted) setState(() => _avatarUploading = false);
    }
  }

  Future<String> _compressAvatar(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw AuthException(tr('无法解析图片'));
    final resized = img.copyResize(decoded, width: 256);
    final jpg = img.encodeJpg(resized, quality: 75);
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  }

  Future<void> _editNickname() async {
    final limit = await _notifier.getNicknameChangeLimitStatus();
    if (!mounted) return;
    if (limit.todayBlocked || limit.status == 'pending') {
      await showProfileEditGate(
        context,
        title: tr('昵称暂不能修改'),
        desc: limit.blockMessage.isNotEmpty
            ? limit.blockMessage
            : (limit.status == 'pending' ? tr('昵称正在审核中哦') : tr('今日已修改过啦')),
        confirmText: tr('我知道了'),
        blocked: true,
      );
      return;
    }
    final proceed = await showProfileEditGate(
      context,
      title: tr('修改昵称提示'),
      desc: tr('昵称每日只能修改 1 次，提交后需要等待管理员审核。审核通过前会继续显示当前昵称。'),
      confirmText: tr('继续修改昵称'),
      note: tr('请确认本次修改内容无误后再继续。'),
    );
    if (!mounted || !proceed) return;
    final result = await showChangeNicknameDialog(context, _notifier);
    if (result != null && mounted) {
      setState(() => _nicknameStatus = 'pending');
      _refreshStatus();
    }
  }

  void _toast(String msg) =>
      showXianYuToast(context, msg, duration: const Duration(seconds: 2));

  void _copy(BuildContext context, String text, String label) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    showXianYuToast(
      context,
      tr('已复制{label}：{text}', {'label': label, 'text': text}),
      duration: const Duration(seconds: 2),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          color: scheme.primary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
