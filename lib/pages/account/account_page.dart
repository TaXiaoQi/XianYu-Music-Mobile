import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/shell.dart';
import '../../src/sync/sync_provider.dart' show syncProvider;
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/app_logo.dart';
import '../../src/widgets/user_agreement.dart';
import '../../src/widgets/user_avatar.dart';
import 'account_dialogs.dart';
import 'human_captcha_dialog.dart';
import '../../src/i18n/i18n.dart';

part 'account_page.auth_actions.dart';
part 'account_page.auth_forms.dart';
part 'account_page.profile_actions.dart';
part 'account_page.profile_widgets.dart';
part 'account_page.glass_widgets.dart';

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key, this.embedded = false, this.onBack});

  final bool embedded;
  final VoidCallback? onBack;

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage>
    with SingleTickerProviderStateMixin, HidesShellChrome, HideMiniBar {
  late final TabController _tab;
  final _nicknameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _obscure = true;
  int _countdown = 0;
  bool _agreed = false;
  bool _loginByEmail = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
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

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (auth.sessionExpired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showSessionExpiredDialog();
      });
    }
    final portraitFloating = !widget.embedded &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: RepaintBoundary(child: Stack(
        fit: StackFit.expand,
        children: [
          const _AmbientBackground(),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(
                  top: GlassTopBar.height(context) +
                      (portraitFloating ? 6 : 0)),
              child: auth.isLoggedIn
                  ? _ProfileView(
                      user: auth.user!,
                      onLogout: () => _confirmLogout(context),
                    )
                  : _buildAuthForm(context, auth),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: widget.embedded
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: widget.onBack,
                    )
                  : const BackButton(),
              title: Text(auth.isLoggedIn ? tr('账号与安全') : tr('账号认证')),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

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
  String _avatarStatus = 'none';
  String _nicknameStatus = 'none';
  bool _refreshingStatus = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  static String _formatEmail(String email) {
    if (email.isEmpty) return tr('未绑定');
    final parts = email.split('@');
    if (parts.length != 2) return email;
    final username = parts[0];
    final domain = parts[1];
    if (username.length <= 4) {
      return email;
    }
    final start = username.substring(0, 2);
    final end = username.substring(username.length - 2);
    return '$start***$end@$domain';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final user = widget.user;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _ProfileHeaderCard(
          user: user,
          onCopy: _copy,
          avatarUploading: _avatarUploading,
          onAvatarTap: _avatarUploading ? null : _pickAvatar,
          onNicknameTap: _editNickname,
        ),
        _StatusBadge(
          status: _avatarStatus,
          pendingText: tr('头像审核中'),
          rejectedText: tr('头像未通过'),
          onRefresh: _refreshStatus,
          refreshing: _refreshingStatus,
        ),
        _StatusBadge(
          status: _nicknameStatus,
          pendingText: tr('改名审核中'),
          rejectedText: tr('改名未通过'),
          onRefresh: _refreshStatus,
          refreshing: _refreshingStatus,
        ),

        const SizedBox(height: 24),

        _sectionTitle(context, tr('基本信息')),
        _GlassCard(
          children: [
            _GlassTile(
              icon: Icons.mail_outline_rounded,
              title: tr('绑定邮箱'),
              value: _formatEmail(user.email),
              onTap: user.email.isEmpty
                  ? () => showBindEmailDialog(context, _notifier)
                  : () => _copy(context, user.email, tr('绑定邮箱')),
            ),
            if (user.ciyuanxiId != null && user.ciyuanxiId!.isNotEmpty)
              _GlassTile(
                icon: Icons.tag_rounded,
                title: tr('弦予号'),
                value: user.ciyuanxiId!,
                onTap: () => _copy(context, user.ciyuanxiId!, tr('弦予号')),
                trailing: Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),

        const SizedBox(height: 24),

        _sectionTitle(context, tr('账号安全与隐私')),
        _GlassCard(
          children: [
            _GlassTile(
              icon: Icons.lock_reset_rounded,
              title: tr('修改密码'),
              subtitle: tr('定期更新密码提升安全等级'),
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
                title: tr('修改弦予号'),
                subtitle: tr('每月限一次'),
                onTap: () async {
                  final proceed = await showProfileEditGate(
                    context,
                    title: tr('修改弦予号提示'),
                    desc: tr('弦予号是登录账号的唯一标识（参考微信号），每月仅可修改一次，请谨慎设置。'),
                    confirmText: tr('继续修改弦予号'),
                    note: tr('请确认本次修改内容无误后再继续。'),
                  );
                  if (proceed && context.mounted) {
                    await showChangeCiyuanxiDialog(context, _notifier);
                  }
                },
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            _GlassTile(
              icon: Icons.delete_outline_rounded,
              title: tr('注销账号'),
              subtitle: tr('注销后数据将无法恢复'),
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
              tr('退出登录'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: scheme.error,
              ),
            ),
            subtitle: Text(
              tr('注销当前设备上的身份凭据'),
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
}
