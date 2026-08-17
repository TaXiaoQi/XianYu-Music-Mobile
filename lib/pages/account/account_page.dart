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
    final notifier = ref.read(authProvider.notifier);
    final msg = await notifier.sendCode(email, 'register');
    if (!mounted) return;
    _toast(msg);
    if (msg.toLowerCase().contains('失败') || msg.contains('错误')) return;
    _startCountdown();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _submit() async {
    final notifier = ref.read(authProvider.notifier);
    if (_tab.index == 0) {
      await notifier.login(
        ciyuanxiId: _idCtrl.text,
        password: _passwordCtrl.text,
      );
    } else {
      if (_passwordCtrl.text != _confirmCtrl.text) {
        _toast('两次输入的密码不一致');
        return;
      }
      await notifier.register(
        ciyuanxiId: _idCtrl.text,
        nickname: _nicknameCtrl.text,
        password: _passwordCtrl.text,
        email: _emailCtrl.text,
        code: _codeCtrl.text,
      );
    }
    if (!mounted) return;
    final err = ref.read(authProvider).error;
    if (err != null) {
      _toast(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('账号')),
      body: auth.isLoggedIn
          ? _ProfileView(user: auth.user!, notifier: ref.read(authProvider.notifier))
          : _buildAuthForm(context, auth),
    );
  }

  Widget _buildAuthForm(BuildContext context, AuthState auth) {
    return Column(
      children: [
        TabBar(
          controller: _tab,
          tabs: const [Tab(text: '登录'), Tab(text: '注册')],
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
          children: [
            Expanded(
              child: _field(_codeCtrl, '邮箱验证码', hint: '请输入验证码', icon: Icons.verified),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                onPressed: _countdown > 0 ? null : _sendCode,
                child: Text(_countdown > 0 ? '${_countdown}s' : '发送验证码'),
              ),
            ),
          ],
        ),
        _submitButton(context, auth, '注册'),
      ],
    );
  }

  Widget _formScroll({required List<Widget> children}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...children, const SizedBox(height: 8)],
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
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
          border: const OutlineInputBorder(),
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
      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
      child: auth.loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}

/// 已登录资料视图。
class _ProfileView extends ConsumerWidget {
  const _ProfileView({required this.user, required this.notifier});
  final AuthUser user;
  final AuthNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 24),
      children: [
        Center(
          child: CircleAvatar(
            radius: 40,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              user.nickname.isEmpty ? '?' : String.fromCharCode(user.nickname.runes.first),
              style: TextStyle(fontSize: 28, color: scheme.onPrimaryContainer),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(user.nickname,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            user.ciyuanxiId != null && user.ciyuanxiId!.isNotEmpty
                ? '弦予号：${user.ciyuanxiId}'
                : user.email,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 24),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.mail),
          title: const Text('邮箱'),
          trailing: Text(user.email.isEmpty ? '未绑定' : user.email,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            onPressed: () => notifier.logout(),
            icon: const Icon(Icons.logout),
            label: const Text('退出登录'),
          ),
        ),
      ],
    );
  }
}