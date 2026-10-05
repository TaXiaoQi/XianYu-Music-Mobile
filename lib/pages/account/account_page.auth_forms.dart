part of 'account_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _AccountPageAuthForms on _AccountPageState {
  Widget _buildAuthForm(BuildContext context, AuthState auth) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            children: [
              const AppLogo(size: 96, radius: 24),
              const SizedBox(height: 12),
                Text(tr('弦予音乐'),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(tr('登录后同步你的音乐与设置'),
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Container(
            decoration: BoxDecoration(
              color: appCardFill(context, ref),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(4),
            child: TabBar(
              controller: _tab,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              labelColor: scheme.onPrimary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              labelStyle: const TextStyle(fontWeight: FontWeight.w600),
              tabs:   [Tab(text: tr('登录')), Tab(text: tr('注册'))],
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
    final scheme = Theme.of(context).colorScheme;
    return _formScroll(
      children: [
        _loginMethodToggle(scheme),
        if (!_loginByEmail) ...[
          _field(_idCtrl, tr('弦予号'), hint: tr('请输入弦予号'), icon: Icons.tag),
          _field(_passwordCtrl, tr('密码'),
              hint: tr('请输入密码'),
              icon: Icons.lock,
              obscure: _obscure),
        ] else ...[
          _field(_emailCtrl, tr('邮箱'), hint: tr('请输入注册邮箱'),
              icon: Icons.mail, keyboard: TextInputType.emailAddress),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _field(_codeCtrl, tr('邮箱验证码'), hint: tr('请输入验证码'), icon: Icons.verified),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _countdown > 0 ? null : _sendCode,
                    child: Text(_countdown > 0 ? '${_countdown}s' : tr('发送验证码')),
                  ),
                ),
              ),
            ],
          ),
        ],
        _errorBanner(context, auth),
        UserAgreementCheckbox(
          initialAgreed: _agreed,
          onChanged: (v) => setState(() => _agreed = v),
        ),
        _submitButton(context, auth, tr('登录')),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: auth.loading
                ? null
                : () => showForgotPasswordDialog(
                    context, ref.read(authProvider.notifier)),
            child:   Text(tr('忘记密码？')),
          ),
        ),
      ],
    );
  }

  Widget _loginMethodToggle(ColorScheme scheme) {
    Widget item(String label, bool selected, VoidCallback onTap) {
      return Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? scheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            item(tr('密码登录'), !_loginByEmail, () {
              if (_loginByEmail) {
                ref.read(authProvider.notifier).clearError();
                setState(() => _loginByEmail = false);
              }
            }),
            item(tr('邮箱验证码'), _loginByEmail, () {
              if (!_loginByEmail) {
                ref.read(authProvider.notifier).clearError();
                setState(() => _loginByEmail = true);
              }
            }),
          ],
        ),
      ),
    );
  }

  Widget _registerForm(BuildContext context, AuthState auth) {
    return _formScroll(
      children: [
        _field(_idCtrl, tr('弦予号'), hint: tr('6-20 位数字/字母'), icon: Icons.tag),
        _field(_nicknameCtrl, tr('昵称（可选）'), hint: tr('留空使用默认昵称'), icon: Icons.badge),
        _field(_passwordCtrl, tr('密码'), hint: tr('设置登录密码'), icon: Icons.lock, obscure: _obscure),
        _field(_confirmCtrl, tr('确认密码'), hint: tr('再次输入密码'), icon: Icons.lock, obscure: _obscure),
        _field(_emailCtrl, tr('邮箱'), hint: tr('用于接收验证码'), icon: Icons.mail, keyboard: TextInputType.emailAddress),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(_codeCtrl, tr('邮箱验证码'), hint: tr('请输入验证码'), icon: Icons.verified),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _countdown > 0 ? null : _sendCode,
                  child: Text(_countdown > 0 ? '${_countdown}s' : tr('发送验证码')),
                ),
              ),
            ),
          ],
        ),
        _errorBanner(context, auth),
        UserAgreementCheckbox(
          initialAgreed: _agreed,
          onChanged: (v) => setState(() => _agreed = v),
        ),
        _submitButton(context, auth, tr('注册')),
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
    final scheme = Theme.of(context).colorScheme;
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
          fillColor: scheme.onSurface.withValues(alpha: 0.05),
          prefixIcon: icon == null
              ? null
              : Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          border: _inputBorder(),
          enabledBorder: _inputBorder(),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.primary, width: 1.5),
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

  OutlineInputBorder _inputBorder() {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    );
  }

  Widget _submitButton(BuildContext context, AuthState auth, String label) {
    return FilledButton(
      onPressed: auth.loading ? null : _submit,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
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
