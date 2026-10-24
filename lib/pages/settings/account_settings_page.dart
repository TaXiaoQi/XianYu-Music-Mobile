import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/responsive/landscape.dart';
import '../../src/core/db_path.dart';
import '../../src/rust/api.dart' as rust;
import '../../src/sync/sync_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_subscriptions.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/user_avatar.dart';
import '../../src/i18n/i18n.dart';
import '../../src/navigation/shell.dart'
    show landscapeSettingsCategoryProvider;

/// 子页入口：横屏改挂设置右面板容器（/cloud、/account 已注册为嵌入
/// 面板，导航栏管理同款），竖屏维持全屏路由推送
void _openSubPanel(BuildContext context, WidgetRef ref, String path) {
  if (MediaQuery.of(context).orientation == Orientation.landscape) {
    ref.read(landscapeSettingsCategoryProvider.notifier).state = path;
  } else {
    context.push(path);
  }
}

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key, this.embedded = false});

  final bool embedded;

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
    final user = ref.watch(authProvider.select((s) => s.user));

    final items = <Widget>[
      _sectionTitle(context, tr('账号状态')),
      _AccountStatusCard(
        user: user,
        onManage: () => _openSubPanel(context, ref, '/account'),
        onLogout: user != null ? _confirmLogout : null,
      ),
      const SizedBox(height: 24),
      _sectionTitle(context, tr('网盘')),
      const _CloudEntryCard(),
      const SizedBox(height: 24),
      if (user != null) ...[
        _sectionTitle(context, tr('手动同步')),
        _ManualSyncCard(),
        const SizedBox(height: 24),
      ],
      if (user != null) ...[
        _sectionTitle(context, tr('自动同步')),
        _AutoSyncCard(),
        const SizedBox(height: 24),
      ],
      _sectionTitle(context, tr('服务端设置')),
      const _ServerConfigCard(),
    ];

    if (widget.embedded) {
      // 横屏面板宿主顶栏覆盖式（悬浮/固定同构）：顶距自垫栏高，滚动
      // 内容从宿主顶栏下穿过被实时模糊
      final panelBand = landscapePanelBand(context, ref);
      return ListView(
        padding: EdgeInsets.fromLTRB(16, panelBand + 8, 16, 40),
        children: items,
      );
    }

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
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
            children: items,
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

    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
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
                        size: 42,
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

class _CloudEntryCard extends ConsumerWidget {
  const _CloudEntryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openSubPanel(context, ref, '/cloud'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.cloud_rounded, size: 22, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('网盘账号绑定'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('绑定百度、阿里、夸克等网盘，播放网盘内的音乐'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
        // 文件只会在用户保存过自定义密钥时存在（历史版本写入的默认值
        // 由 Rust 侧读取时自动迁移删除），内容即自定义密钥
        final c = (await secretFile.readAsString()).trim();
        if (c.isNotEmpty) secret = c;
      }
    } catch (e) {
      AppLog.debug('settings', '读取后端连接配置失败: $e');
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
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      child: Padding(
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

/// 覆盖对比行：label 域名 / unit 计数单位 / cloud、local 双端数量
typedef OverwriteStatRow = ({String label, String unit, int cloud, int local});

/// 手动覆盖同步确认弹窗：手动按钮=强制覆盖（上传覆盖云端/下载覆盖本地），
/// 自动同步仍走对比合并。文案与桌面端 SettingsAccount 完全一致。
/// [compare] 在弹窗内异步取「云端 vs 本地」数量对比，取数失败仅提示、
/// 不阻断覆盖；[sourceIsCloud]=true 表示下载（云端是覆盖源），覆盖源
/// 全为 0 时红字警告"覆盖后将被清空"，避免云端空数据误覆盖本地。
Future<void> _confirmOverwriteSync(
  BuildContext context, {
  required String title,
  required String message,
  required Future<void> Function() action,
  Future<List<OverwriteStatRow>> Function()? compare,
  bool sourceIsCloud = false,
}) async {
  final ok = await showPredictiveDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr(title)),
      content: SingleChildScrollView(
        child: _OverwriteConfirmBody(
          message: message,
          compare: compare,
          sourceIsCloud: sourceIsCloud,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(tr('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('确认覆盖')),
        ),
      ],
    ),
  );
  if (ok == true) await action();
}

/// 手动同步进度浮层（桌面端同款「可取消的小进度提示」）：手动入口挂桥，
/// 插件域逐项推进文案与进度，取消后服务在下一项边界软停止（已完成项保留）；
/// 自动同步/登录同步不经过这里，保持静默只写行内状态
Future<void> _runManualSync(
  BuildContext context, {
  required String label,
  required bool cancellable,
  required SyncItemState Function(SyncState st) pick,
  required Future<void> Function(SyncManualCtx? manual) action,
}) async {
  // 跨域互斥：任一域在途时拒绝发起新同步（对齐桌面端 anyDomainSyncing），
  // 并发会互踩行内状态且进度消息串门
  final container = ProviderScope.containerOf(context, listen: false);
  final st0 = container.read(syncProvider);
  final busy = st0.playlistSync.syncing ||
      st0.favoritesSync.syncing ||
      st0.pluginSync.syncing ||
      st0.settingsSync.syncing;
  if (busy) {
    showXianYuToast(context, tr('已有同步任务进行中，请稍候'));
    return;
  }
  XianYuProgressToastHandle? toastRef;
  final manual = cancellable
      ? SyncManualCtx(onStep: (done, total, name) {
          toastRef?.update(
            tr('正在同步插件 "{name}" ({done}/{total})...', {
              'name': name,
              'done': done,
              'total': total,
            }),
            progress: done / total,
          );
        })
      : null;
  final handle = showXianYuProgressToast(
    context,
    label,
    onCancel: manual == null ? null : () => manual.cancelled = true,
  );
  toastRef = handle;
  try {
    await action(manual);
    final st = container.read(syncProvider);
    final item = pick(st);
    if (manual?.cancelled == true) {
      handle.complete(tr('已取消同步'));
    } else if (item.errors.isNotEmpty) {
      handle.fail(item.errors.first);
    } else {
      handle.complete(item.lastSummary ?? tr('同步完成'));
    }
  } catch (_) {
    handle.fail(tr('同步失败，请稍后重试'));
  }
}

/// 弹窗正文：无对比取数时直接显示静态文案；有取数时先显示加载中，
/// 成功后将文案替换为「将用云端 N …覆盖本地 M …」带数量的对比描述，
/// 失败则保留静态文案并附错误提示（不阻断覆盖）。
class _OverwriteConfirmBody extends StatelessWidget {
  const _OverwriteConfirmBody({
    required this.message,
    required this.compare,
    required this.sourceIsCloud,
  });

  final String message;
  final Future<List<OverwriteStatRow>> Function()? compare;
  final bool sourceIsCloud;

  static String _detail(List<OverwriteStatRow> rows, bool cloudSide) =>
      rows.map((r) => '${cloudSide ? r.cloud : r.local} ${r.unit}${r.label}').join('、');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (compare == null) return Text(tr(message));
    return FutureBuilder<List<OverwriteStatRow>>(
      future: compare!(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Text(
            tr('正在获取云端与本地数据…'),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          );
        }
        final rows = snap.data;
        final failed = rows == null || rows.isEmpty;
        final pattern = sourceIsCloud
            ? '将用云端 {a}覆盖本地 {b}，操作不可逆，确定继续吗？'
            : '将用本地 {a}覆盖云端 {b}，操作不可逆，确定继续吗？';
        final text = failed
            ? tr(message)
            : tr(pattern)
                .replaceAll('{a}', _detail(rows, true))
                .replaceAll('{b}', _detail(rows, false));
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr('云端与本地数据获取失败'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 歌单对比：本地读 PlaylistStore，云端走 file_sync_download 快照
Future<List<OverwriteStatRow>> _playlistCompareStats(WidgetRef ref) async {
  final local = await PlaylistStore().loadAll();
  final localSongs = local.fold<int>(0, (n, p) => n + p.songs.length);
  final data = await ref.read(accountApiProvider).fileSyncDownload();
  final cloudPls =
      ((data?['playlists'] as List?) ?? const []).whereType<Map>().toList();
  final cloudSongs = cloudPls.fold<int>(
      0, (n, pl) => n + ((pl['songs'] as List?) ?? const []).length);
  return [
    (label: '歌单', unit: '个', cloud: cloudPls.length, local: local.length),
    (label: '歌曲', unit: '首', cloud: cloudSongs, local: localSongs),
  ];
}

/// 收藏对比
Future<List<OverwriteStatRow>> _favoritesCompareStats(WidgetRef ref) async {
  final localCount = ref.read(favoritesProvider).entries.length;
  final cloud = await ref.read(accountApiProvider).downloadFavorites();
  return [
    (label: '歌曲', unit: '首', cloud: cloud.favorites.length, local: localCount),
  ];
}

/// 插件对比（不含内置插件，口径与覆盖下载清除范围一致）
Future<List<OverwriteStatRow>> _pluginsCompareStats(WidgetRef ref) async {
  final localPlugins = ref
      .read(pluginManagerProvider)
      .sources
      .where((p) => !p.isBuiltin)
      .length;
  final localSubs = ref.read(pluginSubscriptionsProvider).length;
  final snapshot = await ref.read(accountApiProvider).downloadPluginSnapshot();
  return [
    (
      label: '插件',
      unit: '个',
      cloud: ((snapshot['plugins'] as List?) ?? const []).length,
      local: localPlugins,
    ),
    (
      label: '订阅',
      unit: '条',
      cloud: ((snapshot['subscriptions'] as List?) ?? const []).length,
      local: localSubs,
    ),
  ];
}

class _ManualSyncCard extends ConsumerWidget {
  const _ManualSyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          onUpload: () => _confirmOverwriteSync(
            context,
            title: '覆盖上传歌单',
            message: '将用本地歌单全量覆盖云端，云端多出的歌单会被移除，操作不可逆，确定继续吗？',
            compare: () => _playlistCompareStats(ref),
            action: () => _runManualSync(
              context,
              label: tr('正在上传歌单...'),
              cancellable: false,
              pick: (s) => s.playlistSync,
              action: (m) => notifier.syncPlaylistsUpload(overwrite: true),
            ),
          ),
          onDownload: () => _confirmOverwriteSync(
            context,
            title: '覆盖下载歌单',
            message: '将用云端歌单全量覆盖本地，本地多出的歌单会被移除，操作不可逆，确定继续吗？',
            compare: () => _playlistCompareStats(ref),
            sourceIsCloud: true,
            action: () => _runManualSync(
              context,
              label: tr('正在下载歌单...'),
              cancellable: false,
              pick: (s) => s.playlistSync,
              action: (m) => notifier.syncPlaylistsDownload(overwrite: true),
            ),
          ),
        ),
        _SyncActionTile(
          title: tr('收藏'),
          state: sync.$2,
          onUpload: () => _confirmOverwriteSync(
            context,
            title: '覆盖上传收藏',
            message: '将用本地收藏全量覆盖云端，云端多出的收藏会被移除，操作不可逆，确定继续吗？',
            compare: () => _favoritesCompareStats(ref),
            action: () => _runManualSync(
              context,
              label: tr('正在上传收藏...'),
              cancellable: false,
              pick: (s) => s.favoritesSync,
              action: (m) => notifier.syncFavoritesUpload(overwrite: true),
            ),
          ),
          onDownload: () => _confirmOverwriteSync(
            context,
            title: '覆盖下载收藏',
            message: '将用云端收藏全量覆盖本地，本地多出的收藏会被移除，操作不可逆，确定继续吗？',
            compare: () => _favoritesCompareStats(ref),
            sourceIsCloud: true,
            action: () => _runManualSync(
              context,
              label: tr('正在下载收藏...'),
              cancellable: false,
              pick: (s) => s.favoritesSync,
              action: (m) => notifier.syncFavoritesDownload(overwrite: true),
            ),
          ),
        ),
        _SyncActionTile(
          title: tr('插件'),
          state: sync.$3,
          onUpload: () => _confirmOverwriteSync(
            context,
            title: '覆盖上传插件',
            message: '将用本地插件全量覆盖云端，云端多出的插件与订阅会被移除，操作不可逆，确定继续吗？',
            compare: () => _pluginsCompareStats(ref),
            action: () => _runManualSync(
              context,
              label: tr('正在上传插件...'),
              cancellable: true,
              pick: (s) => s.pluginSync,
              action: (m) => notifier.syncPluginsUpload(overwrite: true, manual: m),
            ),
          ),
          onDownload: () => _confirmOverwriteSync(
            context,
            title: '覆盖下载插件',
            message: '将清空本地插件与订阅，并按云端内容重新安装，操作不可逆，确定继续吗？',
            compare: () => _pluginsCompareStats(ref),
            sourceIsCloud: true,
            action: () => _runManualSync(
              context,
              label: tr('正在恢复插件...'),
              cancellable: true,
              pick: (s) => s.pluginSync,
              action: (m) => notifier.syncPluginsDownload(overwrite: true, manual: m),
            ),
          ),
        ),
        _SyncActionTile(
          title: tr('设置'),
          state: sync.$4,
          onUpload: () => _confirmOverwriteSync(
            context,
            title: '覆盖上传设置',
            message: '将用本地设置覆盖云端设置，操作不可逆，确定继续吗？',
            action: () => _runManualSync(
              context,
              label: tr('正在上传设置...'),
              cancellable: false,
              pick: (s) => s.settingsSync,
              action: (m) => notifier.syncSettingsUpload(),
            ),
          ),
          onDownload: () => _confirmOverwriteSync(
            context,
            title: '覆盖下载设置',
            message: '将用云端设置覆盖本地设置，操作不可逆，确定继续吗？',
            action: () => _runManualSync(
              context,
              label: tr('正在下载设置...'),
              cancellable: false,
              pick: (s) => s.settingsSync,
              action: (m) => notifier.syncSettingsDownload(),
            ),
          ),
        ),
        // 网盘账号无手动同步按钮（对齐桌面端）：登录后变更实时触发上传
      ],
    );
  }
}

class _AutoSyncCard extends ConsumerWidget {
  const _AutoSyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(syncProvider.select((s) => s.autoSyncConfig));
    final upload = ref.watch(syncProvider.select((s) => s.uploadConfig));
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
        // 自动同步内容开关（对齐桌面端）：仅约束自动同步范围，手动同步不受限制
        _SwitchTile(
          title: tr('歌单'),
          subtitle: tr('自动同步本地创建与编辑的歌单'),
          value: upload.playlists,
          onChanged: (v) =>
              notifier.updateUploadConfig(upload.copyWith(playlists: v)),
        ),
        _SwitchTile(
          title: tr('收藏'),
          subtitle: tr('自动同步我的收藏歌曲'),
          value: upload.favorites,
          onChanged: (v) =>
              notifier.updateUploadConfig(upload.copyWith(favorites: v)),
        ),
        _SwitchTile(
          title: tr('插件'),
          subtitle: tr('自动同步已安装的插件配置'),
          value: upload.plugins,
          onChanged: (v) =>
              notifier.updateUploadConfig(upload.copyWith(plugins: v)),
        ),
        _SwitchTile(
          title: tr('本地设置'),
          subtitle: tr('自动同步播放设置、歌词设置等偏好配置'),
          value: upload.settings,
          onChanged: (v) =>
              notifier.updateUploadConfig(upload.copyWith(settings: v)),
        ),
        _SwitchTile(
          title: tr('网盘账号'),
          subtitle: tr('自动加密同步已绑定的网盘登录状态'),
          value: upload.cloudCreds,
          onChanged: (v) =>
              notifier.updateUploadConfig(upload.copyWith(cloudCreds: v)),
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

class _GlassCard extends ConsumerWidget {
  const _GlassCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      themeSlot: useLandscape(ref) ? 'ls-settings.detail' : null,
      child: Column(children: items),
    );
  }
}

class _SyncActionTile extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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
              // 后台同步（登录同步/自动同步）与手动同步共用 syncing 标志，
              // 有来源标注时区分显示，避免误以为手动同步被自动调用
              child: Text(
                () {
                  final bg = ref.watch(bgSyncSourceProvider);
                  return bg != null ? '$bg中...' : tr('正在同步...');
                }(),
                style: TextStyle(fontSize: 12, color: Colors.blue),
              ),
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
