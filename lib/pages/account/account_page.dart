import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';

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
    return showDialog<HumanCaptchaPayload>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HumanCaptchaDialog(
        title: title,
        description: description,
        notifier: ref.read(authProvider.notifier),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(auth.isLoggedIn ? '我的' : '账号'),
        centerTitle: true,
      ),
      body: auth.isLoggedIn
          ? _ProfileView(
              user: auth.user!,
              onLogout: () => _confirmLogout(context),
            )
          : _buildAuthForm(context, auth),
    );
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

/// 已登录资料视图。
class _ProfileView extends StatelessWidget {
  const _ProfileView({required this.user, required this.onLogout});
  final AuthUser user;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
      children: [
        // 头像区：干净地居中放在页面背景上，无大色块
        Center(child: _Avatar(user: user)),
        const SizedBox(height: 16),
        Center(
          child: Text(
            user.nickname.isEmpty ? '未命名用户' : user.nickname,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
        if (user.role.isNotEmpty) ...[
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                user.role,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 32),
        // 信息分组卡
        _InfoCard(
          children: [
            _InfoTile(
              icon: Icons.mail_outline,
              label: '邮箱',
              value: user.email.isEmpty ? '未绑定' : user.email,
            ),
            if (user.ciyuanxiId != null && user.ciyuanxiId!.isNotEmpty)
              _InfoTile(
                icon: Icons.tag,
                label: '弦予号',
                value: user.ciyuanxiId!,
              ),
          ],
        ),
        const SizedBox(height: 24),
        // 退出登录
        OutlinedButton.icon(
          onPressed: onLogout,
          icon: Icon(Icons.logout, color: scheme.error),
          label: Text('退出登录', style: TextStyle(color: scheme.error)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
}

/// 头像：有网络头像则加载，否则用昵称首字符 + 主题色实心底占位。
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
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primary,
        border: Border.all(color: scheme.surface, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: hasAvatar
          ? Image.network(
              avatar,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  _fallback(fallbackChar, scheme.onPrimary),
            )
          : _fallback(fallbackChar, scheme.onPrimary),
    );
  }

  Widget _fallback(String char, Color color) {
    return Center(
      child: Text(
        char,
        style: TextStyle(
            fontSize: 40, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}

/// 信息分组卡片容器。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 在项之间插入分隔线。
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(Divider(height: 1, indent: 52, color: scheme.outlineVariant));
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: items),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.primary),
      title: Text(label),
      trailing: Text(
        value,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
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
