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
import '../../src/i18n/i18n.dart';

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
  Future<void> _confirmLogout() async {
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

  @override
  Widget build(BuildContext context) {
    // 仅订阅 user 字段：loading/error/sessionExpired 等变化不重建整页。
    final user = ref.watch(authProvider.select((s) => s.user));
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: RepaintBoundary(
        child: Stack(
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
              _sectionTitle(context, tr('账号状态')),
              _AccountStatusCard(
                user: user,
                onManage: () => context.push('/account'),
                onLogout: user != null ? _confirmLogout : null,
              ),
              const SizedBox(height: 24),

              // 2. 服务端设置
              _sectionTitle(context, tr('服务端设置')),
              const _ServerConfigCard(),
              const SizedBox(height: 24),

              // 3. 上传
              _sectionTitle(context, tr('上传')),
              _UploadConfigCard(),
              const SizedBox(height: 24),

              // 4. 手动同步
              if (user != null) ...[
                _sectionTitle(context, tr('手动同步')),
                _ManualSyncCard(),
                const SizedBox(height: 24),
              ],

              // 5. 自动同步
              if (user != null) ...[
                _sectionTitle(context, tr('自动同步')),
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
              title:   Text(tr('账号')),
            ),
          ),
        ],
      ),
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
                        ? (user!.nickname.isEmpty ? tr('弦予用户') : user!.nickname)
                        : tr('未登录'),
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
                            ? tr('弦予号：{id}', {'id': user!.ciyuanxiId ?? ''})
                            : (user!.email.isNotEmpty ? user!.email : tr('已登录')))
                        : tr('登录后可同步个人资料到云端服务器'),
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
                tooltip: tr('退出登录'),
              ),
            IconButton(
              onPressed: onManage,
              icon: Icon(Icons.chevron_right_rounded,
                  size: 22, color: scheme.onSurfaceVariant),
              tooltip: tr('账号与安全'),
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
///
/// 状态（输入框、密钥可见性、脏状态）全部内聚在本卡片内，输入时只重建
/// 本卡片，不触发整页重建。
class _ServerConfigCard extends ConsumerStatefulWidget {
  const _ServerConfigCard();

  @override
  ConsumerState<_ServerConfigCard> createState() => _ServerConfigCardState();
}

class _ServerConfigCardState extends ConsumerState<_ServerConfigCard> {
  final _baseUrlCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  String _initialBaseUrl = defaultAuthBaseUrl;
  String _initialSecret = '';
  bool _secretVisible = false;
  bool _secretFocused = false;

  bool get _dirty =>
      _baseUrlCtrl.text.trim() != _initialBaseUrl ||
      _secretCtrl.text.trim() != _initialSecret;

  @override
  void initState() {
    super.initState();
    _loadServerConfig();
    _baseUrlCtrl.addListener(_onConfigChanged);
    _secretCtrl.addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    _baseUrlCtrl.removeListener(_onConfigChanged);
    _secretCtrl.removeListener(_onConfigChanged);
    _baseUrlCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  void _onConfigChanged() {
    if (mounted) setState(() {});
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
      showXianYuToast(context, tr('后端连接配置已更新'));
    } catch (_) {
      if (!mounted) return;
      showXianYuToast(context, tr('后端连接配置保存失败，请重试'));
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
      showXianYuToast(context, tr('已恢复默认后端连接配置'));
    } catch (_) {
      if (!mounted) return;
      showXianYuToast(context, tr('默认后端连接配置保存失败，请重试'));
    }
  }

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
          _label(context, tr('服务器 API')),
          const SizedBox(height: 6),
          TextField(
            controller: _baseUrlCtrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: _inputDecoration(context,
                hint: 'https://example.com/api'),
          ),
          const SizedBox(height: 14),
          _label(context, tr('服务器密钥')),
          const SizedBox(height: 6),
          Focus(
            onFocusChange: (v) => setState(() => _secretFocused = v),
            child: TextField(
              controller: _secretCtrl,
              obscureText: !_secretVisible,
              autocorrect: false,
              enableSuggestions: false,
              decoration: _inputDecoration(context,
                  hint: tr('API 签名密钥'),
                  suffixIcon: (_secretFocused && _secretCtrl.text.isNotEmpty)
                      ? IconButton(
                          icon: Icon(
                            _secretVisible
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                          onPressed: () =>
                              setState(() => _secretVisible = !_secretVisible),
                        )
                      : null),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                onPressed: _dirty ? _saveServerConfig : null,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child:   Text(tr('保存'), style: TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _resetServerConfig,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child:   Text(tr('恢复默认'), style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr('登录、注册、找回密码等接口的根地址和签名密钥。自建后端时，请在服务端后台仪表盘复制服务器 API 与 API 签名密钥后填入。默认地址：{url}', {'url': defaultAuthBaseUrl}),
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
    // 仅订阅 uploadConfig：同步状态变化不重建本卡。
    final config = ref.watch(syncProvider.select((s) => s.uploadConfig));
    final notifier = ref.read(syncProvider.notifier);

    return _GlassCard(
      children: [
        _SwitchTile(
          title: tr('歌单'),
          subtitle: tr('同步本地创建与编辑的歌单'),
          value: config.playlists,
          onChanged: (v) =>
              notifier.updateUploadConfig(config.copyWith(playlists: v)),
        ),
        _SwitchTile(
          title: tr('收藏'),
          subtitle: tr('同步我的收藏歌曲'),
          value: config.favorites,
          onChanged: (v) =>
              notifier.updateUploadConfig(config.copyWith(favorites: v)),
        ),
        _SwitchTile(
          title: tr('插件'),
          subtitle: tr('同步已安装的插件配置'),
          value: config.plugins,
          onChanged: (v) =>
              notifier.updateUploadConfig(config.copyWith(plugins: v)),
        ),
        _SwitchTile(
          title: tr('本地设置'),
          subtitle: tr('同步播放设置、歌词设置等偏好配置'),
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
    // 仅订阅 4 个同步条目状态：uploadConfig/autoSyncConfig 变化不重建本卡。
    final sync = ref.watch(syncProvider.select((s) => (
          s.playlistSync,
          s.favoritesSync,
          s.pluginSync,
          s.settingsSync,
        )));
    final notifier = ref.read(syncProvider.notifier);

    return _GlassCard(
      children: [
        _SyncActionTile(
          title: tr('歌单'),
          state: sync.$1,
          onUpload: notifier.syncPlaylistsUpload,
          onDownload: notifier.syncPlaylistsDownload,
        ),
        _SyncActionTile(
          title: tr('收藏'),
          state: sync.$2,
          onUpload: notifier.syncFavoritesUpload,
          onDownload: notifier.syncFavoritesDownload,
        ),
        _SyncActionTile(
          title: tr('插件'),
          state: sync.$3,
          onUpload: notifier.syncPluginsUpload,
          onDownload: notifier.syncPluginsDownload,
        ),
        _SyncActionTile(
          title: tr('设置'),
          state: sync.$4,
          onUpload: notifier.syncSettingsUpload,
          onDownload: notifier.syncSettingsDownload,
          onSync: () => notifier.syncSettings(context),
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
    // 仅订阅 autoSyncConfig：同步状态变化不重建本卡。
    final config = ref.watch(syncProvider.select((s) => s.autoSyncConfig));
    final notifier = ref.read(syncProvider.notifier);

    return _GlassCard(
      children: [
        _SwitchTile(
          title: tr('启用自动同步'),
          subtitle: tr('后台定时增量同步'),
          value: config.enabled,
          onChanged: (v) =>
              notifier.updateAutoSyncConfig(config.copyWith(enabled: v)),
        ),
        if (config.enabled) ...[
          _DropdownTile(
            title: tr('同步间隔'),
            value: config.syncIntervalSeconds,
            values: const [1800, 3600, 7200, 21600],
            labels:   [tr('30 分钟'), tr('1 小时'), tr('2 小时'), tr('6 小时')],
            onChanged: (v) => notifier.updateAutoSyncConfig(
              config.copyWith(syncIntervalSeconds: v),
            ),
          ),
          _DropdownTile(
            title: tr('繁忙延后上限'),
            value: config.maxDelayMinutes,
            values: const [15, 30, 60],
            labels:   [tr('15 分钟'), tr('30 分钟'), tr('1 小时')],
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

/// 手动同步条目：标题 + 上次同步摘要 + 上传/下载按钮（可选「同步」双向按钮）。
class _SyncActionTile extends StatelessWidget {
  const _SyncActionTile({
    required this.title,
    required this.state,
    required this.onUpload,
    required this.onDownload,
    this.onSync,
  });

  final String title;
  final SyncItemState state;
  final VoidCallback onUpload;
  final VoidCallback onDownload;

  /// 双向同步（带冲突检测与弹窗），仅「设置」条目提供。
  final VoidCallback? onSync;

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
                  if (onSync != null) ...[
                    FilledButton(
                      onPressed: state.syncing ? null : onSync,
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child:   Text(tr('同步'), style: TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.tonal(
                    onPressed: state.syncing ? null : onUpload,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child:   Text(tr('上传'), style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: state.syncing ? null : onDownload,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child:   Text(tr('下载'), style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
          if (state.syncing)
              Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(tr('正在同步...'), style: TextStyle(fontSize: 12, color: Colors.blue)),
            )
          else if (state.lastSummary != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                tr('上次：{summary}{time}', {'summary': state.lastSummary ?? '', 'time': lastTimeStr != null ? ' · $lastTimeStr' : ''}),
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
                  tr('后台定时增量同步时使用'),
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
