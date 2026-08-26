import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/db_path.dart';
import '../../src/rust/api.dart' as rust;
import '../../src/sync/sync_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/user_avatar.dart';

/// 账号设置页：从「设置」页进入，参考桌面端 SettingsAccount。
///
/// 包含：
/// - 账号状态（登录信息 + 跳转「账号与安全」管理入口）
/// - 服务端设置（服务器 API / 密钥，自建后端时填写）
/// - 上传（选择同步到云端的数据类型）
/// - 手动同步（歌单/收藏/插件/设置 上传与下载）
/// - 自动同步（定时增量同步开关与间隔）
class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  final _baseUrlCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  bool _secretVisible = false;
  bool _secretFocused = false;
  String _initialBaseUrl = defaultAuthBaseUrl;
  String _initialSecret = '';

  @override
  void initState() {
    super.initState();
    _loadServerConfig();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  /// 读取 auth 目录下已保存的服务器配置（base_url / api_secret）。
  Future<void> _loadServerConfig() async {
    final dir = await ref.read(appDataDirProvider.future);
    String baseUrl = defaultAuthBaseUrl;
    String secret = '';
    try {
      final baseUrlFile = File('$dir/auth/base_url.txt');
      if (await baseUrlFile.exists()) {
        final c = (await baseUrlFile.readAsString()).trim();
        if (c.isNotEmpty) baseUrl = c;
      }
      final secretFile = File('$dir/auth/api_secret.txt');
      if (await secretFile.exists()) {
        final c = (await secretFile.readAsString()).trim();
        // 文件里存的是默认密钥时视为「未自定义」，输入框留空。
        if (c.isNotEmpty && c != defaultAuthApiSecret) secret = c;
      }
    } catch (_) {
      // 读取失败沿用默认值。
    }
    if (!mounted) return;
    setState(() {
      _initialBaseUrl = baseUrl;
      _initialSecret = secret;
      _baseUrlCtrl.text = baseUrl;
      _secretCtrl.text = secret;
    });
  }

  bool get _isDirty {
    final baseUrl = _baseUrlCtrl.text.trim();
    final secret = _secretCtrl.text.trim();
    return baseUrl != _initialBaseUrl || secret != _initialSecret;
  }

  Future<void> _saveServerConfig() async {
    final dir = await ref.read(appDataDirProvider.future);
    final baseUrl = _baseUrlCtrl.text.trim();
    final secret = _secretCtrl.text.trim();
    try {
      await rust.authSetBaseUrl(
        dataDir: dir,
        baseUrl: baseUrl.isEmpty ? defaultAuthBaseUrl : baseUrl,
      );
      await rust.authSetApiSecret(dataDir: dir, apiSecret: secret);
      if (!mounted) return;
      setState(() {
        _initialBaseUrl = baseUrl.isEmpty ? defaultAuthBaseUrl : baseUrl;
        _initialSecret = secret;
      });
      showXianYuToast(context, '后端连接配置已更新');
    } catch (_) {
      if (!mounted) return;
      showXianYuToast(context, '后端连接配置保存失败，请重试');
    }
  }

  Future<void> _resetServerConfig() async {
    final dir = await ref.read(appDataDirProvider.future);
    setState(() {
      _baseUrlCtrl.text = defaultAuthBaseUrl;
      _secretCtrl.text = '';
    });
    try {
      await rust.authSetBaseUrl(dataDir: dir, baseUrl: defaultAuthBaseUrl);
      await rust.authSetApiSecret(dataDir: dir, apiSecret: '');
      if (!mounted) return;
      setState(() {
        _initialBaseUrl = defaultAuthBaseUrl;
        _initialSecret = '';
      });
      showXianYuToast(context, '已恢复默认后端连接配置');
    } catch (_) {
      if (!mounted) return;
      showXianYuToast(context, '默认后端连接配置保存失败，请重试');
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showPredictiveDialog<bool>(
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

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              GlassTopBar.height(context),
              16,
              40 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              // 1. 账号状态
              _sectionTitle(context, '账号状态'),
              _AccountStatusCard(
                user: auth.user,
                onManage: () => context.push('/account'),
                onLogout: auth.isLoggedIn ? _confirmLogout : null,
              ),
              const SizedBox(height: 24),

              // 2. 服务端设置
              _sectionTitle(context, '服务端设置'),
              _ServerConfigCard(
                baseUrlCtrl: _baseUrlCtrl,
                secretCtrl: _secretCtrl,
                secretVisible: _secretVisible,
                secretFocused: _secretFocused,
                isDirty: _isDirty,
                onSecretVisibility: () =>
                    setState(() => _secretVisible = !_secretVisible),
                onSecretFocus: (v) => setState(() => _secretFocused = v),
                onSave: _saveServerConfig,
                onReset: _resetServerConfig,
              ),
              const SizedBox(height: 24),

              // 3. 上传
              _sectionTitle(context, '上传'),
              _UploadConfigCard(),
              const SizedBox(height: 24),

              // 4. 手动同步
              if (auth.isLoggedIn) ...[
                _sectionTitle(context, '手动同步'),
                _ManualSyncCard(),
                const SizedBox(height: 24),
              ],

              // 5. 自动同步
              if (auth.isLoggedIn) ...[
                _sectionTitle(context, '自动同步'),
                _AutoSyncCard(),
                const SizedBox(height: 28),
              ],
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: const Text('账号'),
            ),
          ),
        ],
      ),
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

/// 账号状态卡片：登录时展示头像/昵称/弦予号与「账号与安全」入口，未登录展示登录引导。
class _AccountStatusCard extends ConsumerWidget {
  const _AccountStatusCard({
    required this.user,
    required this.onManage,
    required this.onLogout,
  });

  final AuthUser? user;
  final VoidCallback onManage;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isLoggedIn = user != null;
    final fallbackChar = isLoggedIn && user!.nickname.isNotEmpty
        ? String.fromCharCode(user!.nickname.runes.first)
        : '?';

    return Container(
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
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
              ),
              padding: const EdgeInsets.all(2),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surface,
                ),
                clipBehavior: Clip.antiAlias,
                child: isLoggedIn && user!.avatar != null
                    ? UserAvatarImage(
                        avatar: user!.avatar,
                        fallback: _fallback(fallbackChar, scheme),
                      )
                    : _fallback(fallbackChar, scheme),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isLoggedIn
                        ? (user!.nickname.isEmpty ? '弦予用户' : user!.nickname)
                        : '未登录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    isLoggedIn
                        ? (user!.ciyuanxiId != null &&
                                user!.ciyuanxiId!.isNotEmpty
                            ? '弦予号：${user!.ciyuanxiId}'
                            : (user!.email.isNotEmpty ? user!.email : '已登录'))
                        : '登录后可同步个人资料到云端服务器',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isLoggedIn && onLogout != null)
              IconButton(
                onPressed: onLogout,
                icon: Icon(Icons.logout_rounded,
                    size: 20, color: scheme.error),
                tooltip: '退出登录',
              ),
            IconButton(
              onPressed: onManage,
              icon: Icon(Icons.chevron_right_rounded,
                  size: 22, color: scheme.onSurfaceVariant),
              tooltip: '账号与安全',
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallback(String char, ColorScheme scheme) {
    return Container(
      color: scheme.primary,
      child: Center(
        child: Text(
          char.toUpperCase(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: scheme.onPrimary,
          ),
        ),
      ),
    );
  }
}

/// 服务端设置卡片：服务器 API + 密钥输入框 + 保存/恢复默认。
class _ServerConfigCard extends StatelessWidget {
  const _ServerConfigCard({
    required this.baseUrlCtrl,
    required this.secretCtrl,
    required this.secretVisible,
    required this.secretFocused,
    required this.isDirty,
    required this.onSecretVisibility,
    required this.onSecretFocus,
    required this.onSave,
    required this.onReset,
  });

  final TextEditingController baseUrlCtrl;
  final TextEditingController secretCtrl;
  final bool secretVisible;
  final bool secretFocused;
  final bool isDirty;
  final VoidCallback onSecretVisibility;
  final ValueChanged<bool> onSecretFocus;
  final VoidCallback onSave;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, '服务器 API'),
          const SizedBox(height: 6),
          TextField(
            controller: baseUrlCtrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: _inputDecoration(context,
                hint: 'https://example.com/api'),
          ),
          const SizedBox(height: 14),
          _label(context, '服务器密钥'),
          const SizedBox(height: 6),
          Focus(
            onFocusChange: onSecretFocus,
            child: TextField(
              controller: secretCtrl,
              obscureText: !secretVisible,
              autocorrect: false,
              enableSuggestions: false,
              decoration: _inputDecoration(context,
                  hint: 'API 签名密钥',
                  suffixIcon: (secretFocused && secretCtrl.text.isNotEmpty)
                      ? IconButton(
                          icon: Icon(
                            secretVisible
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                          onPressed: onSecretVisibility,
                        )
                      : null),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                onPressed: isDirty ? onSave : null,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: const Text('保存', style: TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: onReset,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: const Text('恢复默认', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '登录、注册、找回密码等接口的根地址和签名密钥。自建后端时，请在服务端后台仪表盘复制服务器 API 与 API 签名密钥后填入。默认地址：$defaultAuthBaseUrl',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  InputDecoration _inputDecoration(BuildContext context,
      {required String hint, Widget? suffixIcon}) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: scheme.onSurface.withValues(alpha: 0.05),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      suffixIcon: suffixIcon,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 1.2),
      ),
    );
  }
}

/// 上传配置卡片：选择同步到云端的数据类型。
class _UploadConfigCard extends ConsumerWidget {
  const _UploadConfigCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final notifier = ref.read(syncProvider.notifier);
    final config = syncState.uploadConfig;

    return _GlassCard(
      children: [
        _SwitchTile(
          title: '歌单',
          subtitle: '同步本地创建与编辑的歌单',
          value: config.playlists,
          onChanged: (v) =>
              notifier.updateUploadConfig(config.copyWith(playlists: v)),
        ),
        _SwitchTile(
          title: '收藏',
          subtitle: '同步我的收藏歌曲',
          value: config.favorites,
          onChanged: (v) =>
              notifier.updateUploadConfig(config.copyWith(favorites: v)),
        ),
        _SwitchTile(
          title: '插件',
          subtitle: '同步已安装的插件配置',
          value: config.plugins,
          onChanged: (v) =>
              notifier.updateUploadConfig(config.copyWith(plugins: v)),
        ),
        _SwitchTile(
          title: '本地设置',
          subtitle: '同步播放设置、歌词设置等偏好配置',
          value: config.settings,
          onChanged: (v) =>
              notifier.updateUploadConfig(config.copyWith(settings: v)),
        ),
      ],
    );
  }
}

/// 手动同步卡片：歌单/收藏/插件/设置的上传与下载。
class _ManualSyncCard extends ConsumerWidget {
  const _ManualSyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final notifier = ref.read(syncProvider.notifier);

    return _GlassCard(
      children: [
        _SyncActionTile(
          title: '歌单',
          state: syncState.playlistSync,
          onUpload: notifier.syncPlaylistsUpload,
          onDownload: notifier.syncPlaylistsDownload,
        ),
        _SyncActionTile(
          title: '收藏',
          state: syncState.favoritesSync,
          onUpload: notifier.syncFavoritesUpload,
          onDownload: notifier.syncFavoritesDownload,
        ),
        _SyncActionTile(
          title: '插件',
          state: syncState.pluginSync,
          onUpload: notifier.syncPluginsUpload,
          onDownload: notifier.syncPluginsDownload,
        ),
        _SyncActionTile(
          title: '设置',
          state: syncState.settingsSync,
          onUpload: notifier.syncSettingsUpload,
          onDownload: notifier.syncSettingsDownload,
        ),
      ],
    );
  }
}

/// 自动同步卡片：启用开关 + 同步间隔 + 繁忙延后上限。
class _AutoSyncCard extends ConsumerWidget {
  const _AutoSyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final notifier = ref.read(syncProvider.notifier);
    final config = syncState.autoSyncConfig;

    return _GlassCard(
      children: [
        _SwitchTile(
          title: '启用自动同步',
          subtitle: '后台定时增量同步',
          value: config.enabled,
          onChanged: (v) =>
              notifier.updateAutoSyncConfig(config.copyWith(enabled: v)),
        ),
        if (config.enabled) ...[
          _DropdownTile(
            title: '同步间隔',
            value: config.syncIntervalSeconds,
            values: const [1800, 3600, 7200, 21600],
            labels: const ['30 分钟', '1 小时', '2 小时', '6 小时'],
            onChanged: (v) => notifier.updateAutoSyncConfig(
              config.copyWith(syncIntervalSeconds: v),
            ),
          ),
          _DropdownTile(
            title: '繁忙延后上限',
            value: config.maxDelayMinutes,
            values: const [15, 30, 60],
            labels: const ['15 分钟', '30 分钟', '1 小时'],
            onChanged: (v) => notifier.updateAutoSyncConfig(
              config.copyWith(maxDelayMinutes: v),
            ),
          ),
        ],
      ],
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
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(children: items),
    );
  }
}

/// 手动同步条目：标题 + 上次同步摘要 + 上传/下载按钮。
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
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                ),
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

/// 开关条目。
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

/// 下拉选择条目（自动同步：同步间隔 / 繁忙延后上限）。
class _DropdownTile extends StatelessWidget {
  const _DropdownTile({
    required this.title,
    required this.value,
    required this.values,
    required this.labels,
    required this.onChanged,
  });
  final String title;
  final int value;
  final List<int> values;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = values.contains(value) ? value : values.first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
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
                  '后台定时增量同步时使用',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<int>(
            value: v,
            underline: const SizedBox.shrink(),
            items: [
              for (var i = 0; i < values.length; i++)
                DropdownMenuItem(value: values[i], child: Text(labels[i])),
            ],
            onChanged: (nv) {
              if (nv != null) onChanged(nv);
            },
          ),
        ],
      ),
    );
  }
}
