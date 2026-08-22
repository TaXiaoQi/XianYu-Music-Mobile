import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/sync/sync_provider.dart';
import 'account_dialogs.dart';
import 'human_captcha_dialog.dart';

/// 账号认证页：未登录时展示登录/注册，已登录时展示个人资料。
class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _nicknameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _obscure = true;
  int _countdown = 0;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    // 切换登录/注册时清空内联错误，避免旧错误残留。
    _tab.addListener(() {
      if (_tab.indexIsChanging) {
        ref.read(authProvider.notifier).clearError();
      }
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _nicknameCtrl.dispose();
    _idCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
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
    // 发送验证码前先过人机验证。
    final captcha = await _requestHumanCaptcha(
      title: '发送验证码前验证',
      description: '完成验证后将向邮箱发送注册验证码。',
    );
    if (captcha == null || !mounted) return;
    final notifier = ref.read(authProvider.notifier);
    try {
      final msg = await notifier.sendCode(email, 'register', captcha: captcha);
      if (!mounted) return;
      _toast(msg);
      if (msg.toLowerCase().contains('失败') || msg.contains('错误')) return;
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '验证码发送失败');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _submit() async {
    final notifier = ref.read(authProvider.notifier);
    final isLogin = _tab.index == 0;

    // 注册时先做本地密码一致性校验，避免无谓的人机验证。
    if (!isLogin && _passwordCtrl.text != _confirmCtrl.text) {
      notifier.setError('两次输入的密码不一致');
      return;
    }

    // 登录/注册前先过人机验证。
    final captcha = await _requestHumanCaptcha(
      title: isLogin ? '登录前验证' : '注册前验证',
      description: isLogin ? '完成验证后将继续登录当前账号。' : '完成验证后将继续创建账号。',
    );
    if (captcha == null || !mounted) return;

    if (isLogin) {
      await notifier.login(
        ciyuanxiId: _idCtrl.text,
        password: _passwordCtrl.text,
        captcha: captcha,
      );
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
    // 错误已通过 authProvider.error 反映到内联错误条，无需再弹 SnackBar。
  }

  /// 弹出人机验证弹窗，返回验证通过的 payload；取消返回 null。
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

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    // 会话失效：弹窗提示并回到登录态。
    if (auth.sessionExpired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showSessionExpiredDialog();
      });
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          auth.isLoggedIn ? '账号与安全' : '账号认证',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _AmbientBackground(),
          SafeArea(
            child: auth.isLoggedIn
                ? _ProfileView(
                    user: auth.user!,
                    onLogout: () => _confirmLogout(context),
                  )
                : _buildAuthForm(context, auth),
          ),
        ],
      ),
    );
  }

  Future<void> _showSessionExpiredDialog() async {
    final notifier = ref.read(authProvider.notifier);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('登录状态已失效'),
        content: const Text('登录状态已失效，请重新登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确认'),
          ),
          FilledButton(
            // 本页即账号页，关闭弹窗后自动回到登录表单。
            onPressed: () => Navigator.pop(ctx),
            child: const Text('登录'),
          ),
        ],
      ),
    );
    notifier.consumeSessionExpired();
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(authProvider.notifier).logout();
    }
  }

  Widget _buildAuthForm(BuildContext context, AuthState auth) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // 品牌头部
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(Icons.music_note, size: 34, color: scheme.onPrimary),
              ),
              const SizedBox(height: 12),
              const Text('弦予音乐',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('登录后同步你的音乐与设置',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        // 分段式 Tab
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(4),
            child: TabBar(
              controller: _tab,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(9),
              ),
              labelColor: scheme.onPrimary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              labelStyle: const TextStyle(fontWeight: FontWeight.w600),
              tabs: const [Tab(text: '登录'), Tab(text: '注册')],
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _loginForm(context, auth),
              _registerForm(context, auth),
            ],
          ),
        ),
      ],
    );
  }

  Widget _loginForm(BuildContext context, AuthState auth) {
    return _formScroll(
      children: [
        _field(_idCtrl, '弦予号', hint: '请输入弦予号', icon: Icons.tag),
        _field(_passwordCtrl, '密码',
            hint: '请输入密码',
            icon: Icons.lock,
            obscure: _obscure),
        _errorBanner(context, auth),
        _submitButton(context, auth, '登录'),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: auth.loading
                ? null
                : () => showForgotPasswordDialog(
                    context, ref.read(authProvider.notifier)),
            child: const Text('忘记密码？'),
          ),
        ),
      ],
    );
  }

  Widget _registerForm(BuildContext context, AuthState auth) {
    return _formScroll(
      children: [
        _field(_idCtrl, '弦予号', hint: '6-20 位数字/字母', icon: Icons.tag),
        _field(_nicknameCtrl, '昵称（可选）', hint: '留空使用默认昵称', icon: Icons.badge),
        _field(_passwordCtrl, '密码', hint: '设置登录密码', icon: Icons.lock, obscure: _obscure),
        _field(_confirmCtrl, '确认密码', hint: '再次输入密码', icon: Icons.lock, obscure: _obscure),
        _field(_emailCtrl, '邮箱', hint: '用于接收验证码', icon: Icons.mail, keyboard: TextInputType.emailAddress),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(_codeCtrl, '邮箱验证码', hint: '请输入验证码', icon: Icons.verified),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _countdown > 0 ? null : _sendCode,
                  child: Text(_countdown > 0 ? '${_countdown}s' : '发送验证码'),
                ),
              ),
            ),
          ],
        ),
        _errorBanner(context, auth),
        _submitButton(context, auth, '注册'),
      ],
    );
  }

  Widget _formScroll({required List<Widget> children}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...children, const SizedBox(height: 8)],
      ),
    );
  }

  /// 内联错误条：登录/注册失败时在提交按钮上方显示，不会一闪而过。
  Widget _errorBanner(BuildContext context, AuthState auth) {
    final scheme = Theme.of(context).colorScheme;
    final error = auth.error;
    if (error == null || error.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    String? hint,
    IconData? icon,
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboard,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          suffixIcon: obscure
              ? IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                )
              : null,
        ),
      ),
    );
  }

  Widget _submitButton(BuildContext context, AuthState auth, String label) {
    return FilledButton(
      onPressed: auth.loading ? null : _submit,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: auth.loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    );
  }
}

/// 已登录资料视图：英雄头图 + 毛玻璃分组，头像/昵称可编辑，含账号管理入口。
class _ProfileView extends ConsumerStatefulWidget {
  const _ProfileView({required this.user, required this.onLogout});
  final AuthUser user;
  final VoidCallback onLogout;

  @override
  ConsumerState<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends ConsumerState<_ProfileView> {
  AuthNotifier get _notifier => ref.read(authProvider.notifier);

  bool _avatarUploading = false;
  String _avatarStatus = 'none'; // pending / rejected / none
  String _nicknameStatus = 'none';
  bool _refreshingStatus = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  /// 查询头像/昵称审核状态；任一审核通过时重新拉取用户信息。
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
    } catch (_) {
      // 查询失败静默，保持当前状态。
    } finally {
      if (mounted) setState(() => _refreshingStatus = false);
    }
  }

  /// 点击头像：选图 → 压缩 → 上传（走审核流程）。
  Future<void> _pickAvatar() async {
    final limit = await _notifier.getAvatarChangeLimitStatus();
    if (!mounted) return;
    if (limit.todayBlocked) {
      _toast(limit.blockMessage.isNotEmpty ? limit.blockMessage : '今日已修改过啦');
      return;
    }
    if (limit.status == 'pending') {
      _toast('头像正在审核中哦');
      return;
    }
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      _toast('头像不能超过 5MB');
      return;
    }
    setState(() => _avatarUploading = true);
    try {
      final dataUrl = await _compressAvatar(bytes);
      await _notifier.uploadAvatar(dataUrl);
      if (!mounted) return;
      setState(() => _avatarStatus = 'pending');
      _toast('头像已上传，等待管理员审核');
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '头像上传失败');
    } finally {
      if (mounted) setState(() => _avatarUploading = false);
    }
  }

  /// 压缩头像：256px 宽度、JPEG 质量 75%（与桌面端一致），输出 base64 data URL。
  Future<String> _compressAvatar(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw AuthException('无法解析图片');
    final resized = img.copyResize(decoded, width: 256);
    final jpg = img.encodeJpg(resized, quality: 75);
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  }

  /// 点击昵称：弹修改昵称弹窗（走审核流程）。
  Future<void> _editNickname() async {
    final limit = await _notifier.getNicknameChangeLimitStatus();
    if (!mounted) return;
    if (limit.todayBlocked) {
      _toast(limit.blockMessage.isNotEmpty ? limit.blockMessage : '今日已修改过啦');
      return;
    }
    if (limit.status == 'pending') {
      _toast('昵称正在审核中哦');
      return;
    }
    final result = await showChangeNicknameDialog(context, _notifier);
    if (result != null && mounted) {
      setState(() => _nicknameStatus = 'pending');
      _refreshStatus();
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _copy(BuildContext context, String text, String label) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制$label：$text'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final user = widget.user;
    final syncState = ref.watch(syncProvider);
    final syncNotifier = ref.read(syncProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // 1. 英雄头图卡片（头像可点击上传、昵称可点击修改）
        _ProfileHeaderCard(
          user: user,
          onCopy: _copy,
          avatarUploading: _avatarUploading,
          onAvatarTap: _avatarUploading ? null : _pickAvatar,
          onNicknameTap: _editNickname,
        ),
        // 头像/昵称审核状态
        _StatusBadge(
          status: _avatarStatus,
          pendingText: '头像审核中',
          rejectedText: '头像未通过',
          onRefresh: _refreshStatus,
          refreshing: _refreshingStatus,
        ),
        _StatusBadge(
          status: _nicknameStatus,
          pendingText: '改名审核中',
          rejectedText: '改名未通过',
          onRefresh: _refreshStatus,
          refreshing: _refreshingStatus,
        ),

        const SizedBox(height: 24),

        // 2. 「基本信息」分组卡片
        _sectionTitle(context, '基本信息'),
        _GlassCard(
          children: [
            _GlassTile(
              icon: Icons.mail_outline_rounded,
              title: '绑定邮箱',
              value: user.email.isEmpty ? '未绑定' : user.email,
              onTap: user.email.isEmpty
                  ? () => showBindEmailDialog(context, _notifier)
                  : null,
            ),
            if (user.ciyuanxiId != null && user.ciyuanxiId!.isNotEmpty)
              _GlassTile(
                icon: Icons.tag_rounded,
                title: '弦予号',
                value: user.ciyuanxiId!,
                onTap: () => _copy(context, user.ciyuanxiId!, '弦予号'),
                trailing: Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),

        const SizedBox(height: 24),

        // ==================== 云端同步与上传板块 ====================
        _sectionTitle(context, '云端同步与上传'),

        // 上传开关配置卡片
        _GlassCard(
          children: [
            _SwitchTile(
              title: '歌单',
              subtitle: '同步本地创建与编辑的歌单',
              value: syncState.uploadConfig.playlists,
              onChanged: (val) => syncNotifier.updateUploadConfig(
                syncState.uploadConfig.copyWith(playlists: val),
              ),
            ),
            _SwitchTile(
              title: '收藏',
              subtitle: '同步我的收藏歌曲',
              value: syncState.uploadConfig.favorites,
              onChanged: (val) => syncNotifier.updateUploadConfig(
                syncState.uploadConfig.copyWith(favorites: val),
              ),
            ),
            _SwitchTile(
              title: '插件',
              subtitle: '同步已安装的插件配置',
              value: syncState.uploadConfig.plugins,
              onChanged: (val) => syncNotifier.updateUploadConfig(
                syncState.uploadConfig.copyWith(plugins: val),
              ),
            ),
            _SwitchTile(
              title: '本地设置',
              subtitle: '同步播放设置、歌词设置等偏好配置',
              value: syncState.uploadConfig.settings,
              onChanged: (val) => syncNotifier.updateUploadConfig(
                syncState.uploadConfig.copyWith(settings: val),
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 手动同步数据卡片
        _GlassCard(
          children: [
            _SyncActionTile(
              title: '歌单同步',
              state: syncState.playlistSync,
              onUpload: syncNotifier.syncPlaylistsUpload,
              onDownload: syncNotifier.syncPlaylistsDownload,
            ),
            _SyncActionTile(
              title: '收藏同步',
              state: syncState.favoritesSync,
              onUpload: syncNotifier.syncFavoritesUpload,
              onDownload: syncNotifier.syncFavoritesDownload,
            ),
            _SyncActionTile(
              title: '插件同步',
              state: syncState.pluginSync,
              onUpload: syncNotifier.syncPluginsUpload,
              onDownload: syncNotifier.syncPluginsDownload,
            ),
            _SyncActionTile(
              title: '设置同步',
              state: syncState.settingsSync,
              onUpload: syncNotifier.syncSettingsUpload,
              onDownload: syncNotifier.syncSettingsDownload,
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 定时与自动同步及本地备份导入卡片
        _GlassCard(
          children: [
            _SwitchTile(
              title: '自动同步',
              subtitle: '后台定时增量同步',
              value: syncState.autoSyncConfig.enabled,
              onChanged: (val) => syncNotifier.updateAutoSyncConfig(
                syncState.autoSyncConfig.copyWith(enabled: val),
              ),
            ),
            _GlassTile(
              icon: Icons.file_upload_outlined,
              title: '从本地备份恢复数据',
              subtitle: '导入应用备份 JSON 文件的歌单与收藏',
              onTap: () async {
                final msg = await syncNotifier.importLocalBackupFile();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(msg)),
                  );
                }
              },
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // 3. 「账号安全与隐私」分组卡片
        _sectionTitle(context, '账号安全与隐私'),
        _GlassCard(
          children: [
            _GlassTile(
              icon: Icons.lock_reset_rounded,
              title: '修改密码',
              subtitle: '定期更新密码提升安全等级',
              onTap: () => showChangePasswordDialog(context, _notifier),
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
            if (user.ciyuanxiId != null && user.ciyuanxiId!.isNotEmpty)
              _GlassTile(
                icon: Icons.tag_rounded,
                title: '修改弦予号',
                subtitle: '每月限一次',
                onTap: () => showChangeCiyuanxiDialog(context, _notifier),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            _GlassTile(
              icon: Icons.delete_outline_rounded,
              title: '注销账号',
              subtitle: '注销后数据将无法恢复',
              onTap: () => showDeleteAccountDialog(context, _notifier),
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.error.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),

        const SizedBox(height: 28),

        // 4. 警示型毛玻璃退出登录卡片
        Container(
          decoration: BoxDecoration(
            color: scheme.error.withValues(alpha: isDark ? 0.12 : 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: scheme.error.withValues(alpha: isDark ? 0.25 : 0.18),
            ),
          ),
          child: ListTile(
            onTap: widget.onLogout,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            leading: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.error.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.logout_rounded,
                  size: 20, color: scheme.error),
            ),
            title: Text(
              '退出登录',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: scheme.error,
              ),
            ),
            subtitle: Text(
              '注销当前设备上的身份凭据',
              style: TextStyle(
                fontSize: 12,
                color: scheme.error.withValues(alpha: 0.7),
              ),
            ),
            trailing: Icon(
              Icons.arrow_forward_ios_rounded,
              size: 15,
              color: scheme.error.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
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

/// 审核状态小徽章（pending/rejected 时显示，可点击刷新）。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.status,
    required this.pendingText,
    required this.rejectedText,
    required this.onRefresh,
    required this.refreshing,
  });
  final String status;
  final String pendingText;
  final String rejectedText;
  final VoidCallback onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    if (status != 'pending' && status != 'rejected') {
      return const SizedBox(height: 4);
    }
    final isPending = status == 'pending';
    final color = isPending ? const Color(0xFFB45309) : const Color(0xFFE11D48);
    final bg = isPending
        ? const Color(0x1AB45309)
        : const Color(0x1AE11D48);
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isPending ? Icons.hourglass_top : Icons.close,
                size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              isPending ? pendingText : rejectedText,
              style: TextStyle(fontSize: 11, color: color),
            ),
            if (isPending) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: refreshing ? null : onRefresh,
                child: refreshing
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: color),
                      )
                    : Icon(Icons.refresh, size: 13, color: color),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 英雄头图区：大尺寸头像 + 2px 渐变描边 + 弥散光影 + 身份胶囊。
/// 头像可点击上传（带相机角标），昵称可点击修改。
class _ProfileHeaderCard extends StatelessWidget {
  const _ProfileHeaderCard({
    required this.user,
    required this.onCopy,
    this.avatarUploading = false,
    this.onAvatarTap,
    this.onNicknameTap,
  });

  final AuthUser user;
  final Function(BuildContext, String, String) onCopy;
  final bool avatarUploading;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onNicknameTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: isDark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          // 大尺寸头像与弥散光环（可点击上传）
          GestureDetector(
            onTap: onAvatarTap,
            child: Stack(
              children: [
                _Avatar(user: user),
                if (onAvatarTap != null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                      child: avatarUploading
                          ? Padding(
                              padding: const EdgeInsets.all(6),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimary),
                            )
                          : Icon(Icons.photo_camera,
                              size: 15, color: scheme.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // 昵称（可点击修改）
          InkWell(
            onTap: onNicknameTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      user.nickname.isEmpty ? '弦予用户' : user.nickname,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onNicknameTap != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.edit, size: 16, color: scheme.onSurfaceVariant),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 身份胶囊
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_user_rounded,
                      size: 14,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      user.role.isNotEmpty ? user.role : '标准会员',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              if (user.ciyuanxiId != null && user.ciyuanxiId!.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => onCopy(context, user.ciyuanxiId!, '弦予号'),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'ID: ${user.ciyuanxiId}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.copy_rounded,
                          size: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 头像：支持网络图片 / 首字符兜底 + 弥散光影与 2px 描边。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.user});
  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = user.avatar;
    final hasAvatar = avatar != null && avatar.isNotEmpty;
    final fallbackChar = user.nickname.isEmpty
        ? '?'
        : String.fromCharCode(user.nickname.runes.first);

    return Container(
      width: 92,
      height: 92,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            scheme.primary,
            scheme.primary.withValues(alpha: 0.6),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(2.5),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.surface,
        ),
        clipBehavior: Clip.antiAlias,
        child: hasAvatar
            ? Image.network(
                avatar,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    _fallback(fallbackChar, scheme.primary, scheme.onPrimary),
              )
            : _fallback(fallbackChar, scheme.primary, scheme.onPrimary),
      ),
    );
  }

  Widget _fallback(String char, Color bg, Color fg) {
    return Container(
      color: bg,
      child: Center(
        child: Text(
          char.toUpperCase(),
          style: TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.bold,
            color: fg,
          ),
        ),
      ),
    );
  }
}

/// 全高透毛玻璃分组卡片。
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            height: 1,
            indent: 58,
            endIndent: 14,
            thickness: 0.5,
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? scheme.surfaceContainer
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(children: items),
    );
  }
}

/// 毛玻璃列表条目：软色图标框 + 标题/副标题 + 尾部动作。
class _GlassTile extends StatelessWidget {
  const _GlassTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // 图标软背景框
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: scheme.primary),
            ),
            const SizedBox(width: 14),
            // 左侧标题区（单行防折行）
            if (subtitle != null)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              Text(
                title,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
            ],
            // 右侧 Value 值区（完整展示邮箱等文本）
            if (value != null && value!.isNotEmpty) ...[
              if (subtitle == null) const Spacer(),
              Flexible(
                child: Text(
                  value!,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _SyncActionTile extends StatelessWidget {
  const _SyncActionTile({
    required this.title,
    required this.state,
    required this.onUpload,
    required this.onDownload,
  });

  final String title;
  final SyncItemState state;
  final VoidCallback onUpload;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lastTimeStr = state.lastTime != null
        ? '${state.lastTime!.month.toString().padLeft(2, '0')}-${state.lastTime!.day.toString().padLeft(2, '0')} ${state.lastTime!.hour.toString().padLeft(2, '0')}:${state.lastTime!.minute.toString().padLeft(2, '0')}'
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
              Row(
                children: [
                  FilledButton.tonal(
                    onPressed: state.syncing ? null : onUpload,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('上传', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: state.syncing ? null : onDownload,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('下载', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
          if (state.syncing)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('正在同步...', style: TextStyle(fontSize: 12, color: Colors.blue)),
            )
          else if (state.lastSummary != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '上次：${state.lastSummary}${lastTimeStr != null ? ' · $lastTimeStr' : ''}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant.withValues(alpha: 0.75)),
              ),
            ),
          if (state.errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                state.errors.first,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// 沉浸氛围背景。
class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return IgnorePointer(
      child: Container(color: scheme.surface),
    );
  }
}

/// 人机验证弹窗（内置算术题模式）。
/// 加载题目 → 输入答案 → 预校验通过后返回 [HumanCaptchaPayload]。
class _HumanCaptchaDialog extends StatefulWidget {
  const _HumanCaptchaDialog({
    required this.title,
    required this.description,
    required this.notifier,
  });
  final String title;
  final String description;
  final AuthNotifier notifier;

  @override
  State<_HumanCaptchaDialog> createState() => _HumanCaptchaDialogState();
}

class _HumanCaptchaDialogState extends State<_HumanCaptchaDialog> {
  final _answerCtrl = TextEditingController();
  HumanCaptcha? _captcha;
  bool _loading = false;
  bool _verifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _answerCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
      _answerCtrl.clear();
    });
    try {
      final c = await widget.notifier.fetchCaptcha();
      if (!mounted) return;
      setState(() {
        _captcha = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _captcha = null;
        _loading = false;
        _error = e is AuthException ? e.message : '验证题加载失败，请稍后重试';
      });
    }
  }

  Future<void> _submit() async {
    final captcha = _captcha;
    if (captcha == null || captcha.captchaId.isEmpty) {
      setState(() => _error = '请先加载验证题');
      return;
    }
    final answer = _answerCtrl.text.trim();
    if (answer.isEmpty) {
      setState(() => _error = '请输入验证答案');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    final payload = HumanCaptchaPayload(
      captchaId: captcha.captchaId,
      captchaAnswer: answer,
    );
    try {
      await widget.notifier.verifyCaptcha(payload);
      if (!mounted) return;
      Navigator.pop(context, payload);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = e is AuthException ? e.message : '人机验证失败，请重试';
        _answerCtrl.clear();
      });
      // 验证失败后自动换一题（旧题可能已失效）。
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.description,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          // 题目区
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _loading
                        ? '正在加载验证题…'
                        : (_captcha?.question.isNotEmpty == true
                            ? _captcha!.question
                            : '验证题加载失败'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: _loading || _verifying ? null : _refresh,
                  child: Text(_loading ? '刷新中…' : '换一题'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _answerCtrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            enabled: !_loading && !_verifying && _captcha != null,
            decoration: InputDecoration(
              labelText: '验证答案',
              hintText: '请输入答案',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null && _error!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(fontSize: 13, color: scheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _verifying ? null : () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_loading || _verifying || _captcha == null) ? null : _submit,
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('验证并继续'),
        ),
      ],
    );
  }
}
