import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/core/app_colors.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/predictive_dialog_route.dart';

/// 网盘绑定页：支持网盘列表 + 已绑定账号管理。
///
/// 绑定入口按 [CloudProvider.loginKind] 路由到对应登录页（WebView /
/// 账密 / 扫码），不做盘名硬编码；每盘支持多账号。
class CloudBindPage extends ConsumerStatefulWidget {
  const CloudBindPage({super.key});

  @override
  ConsumerState<CloudBindPage> createState() => _CloudBindPageState();
}

class _CloudBindPageState extends ConsumerState<CloudBindPage> {
  Map<String, List<CloudAccount>> _accounts = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final map = <String, List<CloudAccount>>{};
    for (final p in cloudProviders) {
      map[p.id] = await CloudCredentialsStore.instance.accountsFor(p.id);
    }
    if (!mounted) return;
    setState(() {
      _accounts = map;
      _loading = false;
    });
  }

  String _kindLabel(CloudLoginKind kind) => switch (kind) {
        CloudLoginKind.webviewCookie ||
        CloudLoginKind.webviewToken =>
          tr('网页登录'),
        CloudLoginKind.httpPassword => tr('账号密码'),
        CloudLoginKind.smsPassword => tr('手机号 + 验证码'),
        CloudLoginKind.qrCode => tr('扫码登录'),
      };

  Future<void> _openLogin(CloudProvider p) async {
    final kind = p.loginKind;
    Future<void> future;
    if (kind == CloudLoginKind.webviewCookie ||
        kind == CloudLoginKind.webviewToken) {
      future = context.push('/cloud/webview-login/${p.id}');
    } else if (kind == CloudLoginKind.qrCode) {
      future = context.push('/cloud/qrcode-login/${p.id}');
    } else {
      future = context.push('/cloud/password-login/${p.id}');
    }
    await future;
    if (!mounted) return;
    _reload();
  }

  Future<void> _unbind(CloudAccount a) async {
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('解除绑定')),
        content: Text(tr('确定要解绑 {name} 吗？', {'name': a.nickname})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('解绑')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await CloudCredentialsStore.instance.removeAccount(a.provider, a.accountId);
    if (!mounted) return;
    showXianYuToast(context, tr('已解绑'));
    _reload();
  }

  void _openBrowser(CloudAccount a) {
    context.push('/cloud/browser/${a.provider}?account=${a.accountId}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              children: [
                _LinkImportCard(),
                const SizedBox(height: 24),
                _sectionTitle(context, tr('支持网盘')),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  for (final p in cloudProviders) ...[
                    _providerCard(context, p, scheme),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: Text(tr('网盘')),
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

  Widget _providerCard(
    BuildContext context,
    CloudProvider p,
    ColorScheme scheme,
  ) {
    final accounts = _accounts[p.id] ?? const [];
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.displayName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _kindLabel(p.loginKind),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _openLogin(p),
                  child: Text(accounts.isEmpty ? tr('绑定') : tr('添加账号')),
                ),
              ],
            ),
          ),
          for (var i = 0; i < accounts.length; i++) ...[
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              thickness: 0.5,
              color: scheme.onSurface.withValues(alpha: 0.08),
            ),
            _accountRow(context, accounts[i], scheme),
          ],
          if (accounts.isNotEmpty) const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _accountRow(
    BuildContext context,
    CloudAccount a,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.nickname.isEmpty ? a.accountId : a.nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  a.accountId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => _openBrowser(a),
            icon: Icon(
              Icons.folder_open_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            tooltip: tr('浏览网盘'),
          ),
          IconButton(
            onPressed: () => _unbind(a),
            icon: Icon(Icons.link_off_rounded, size: 20, color: scheme.error),
            tooltip: tr('解绑'),
          ),
        ],
      ),
    );
  }
}

class _LinkImportCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/cloud/link-import'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.link_rounded, size: 22, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('分享链接导入'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('粘贴网盘分享链接，播放或转存分享内的音乐'),
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
