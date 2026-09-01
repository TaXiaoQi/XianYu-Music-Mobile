import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/server_models.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/developer_mode.dart';
import '../../src/update/app_update.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/i18n/i18n.dart';

/// 关于页：版本信息、检查更新、官网/开源/群组链接。
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key, this.embedded = false});

  /// 横屏嵌入 mode：由 master-detail 右侧薄顶栏接管标题，隐藏自带顶栏与顶部避让。
  final bool embedded;

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  AboutConfig _config = const AboutConfig();
  bool _checkingUpdate = false;

  /// 版本号连点开启调试模式（对齐安卓开发者模式：1.5s 内连点 10 次，最后几次提示剩余次数）。
  /// 开启后设置页出现「调试」入口，点击进入调试页。
  static const _debugTapTarget = 10;
  static const _debugTapHintStart = 7;
  static const _debugTapInterval = Duration(milliseconds: 1500);
  int _debugTapCount = 0;
  DateTime? _lastDebugTap;

  /// 开发者名单（与桌面端一致），点击跳转 GitHub 主页。
  static List<(String, String)> get _developers => <(String, String)>[
    ('@ShenYichenCN', 'https://github.com/ShenYichenCN'),
    ('@TaXiaoQi', 'https://github.com/TaXiaoQi'),
  ];

  /// 随开发者名单一起划入致谢名单的贡献者（本地静态成员，与服务端致谢合并展示）。
  static List<AcknowledgementItem> get _extraAcknowledgements =>
      const <AcknowledgementItem>[
        AcknowledgementItem(
            name: '@知难辞', url: 'https://github.com/88541'),
        AcknowledgementItem(
            name: '@绛狐', url: 'https://github.com/kaishui-server'),
      ];

  /// 服务端致谢 + 本地静态致谢，去重后再展示。
  List<AcknowledgementItem> get _allAcknowledgements {
    final merged = <AcknowledgementItem>[
      ..._config.acknowledgements,
      ..._extraAcknowledgements,
    ];
    final seen = <String>{};
    return merged
        .where((it) => seen.add(it.name))
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _handleVersionTap() {
    final now = DateTime.now();
    if (_lastDebugTap == null ||
        now.difference(_lastDebugTap!) > _debugTapInterval) {
      _debugTapCount = 0;
    }
    _lastDebugTap = now;
    _debugTapCount++;
    if (_debugTapCount >= _debugTapTarget) {
      _debugTapCount = 0;
      ref.read(developerModeProvider.notifier).enable();
      showXianYuToast(context, tr('已进入调试模式'));
      return;
    }
    if (_debugTapCount >= _debugTapHintStart) {
      showXianYuToast(
          context, tr('再点击 {n} 次即可进入调试模式', {'n': _debugTapTarget - _debugTapCount}));
    }
  }

  Future<void> _loadConfig() async {
    final config = await ref.read(accountApiProvider).fetchAboutConfig();
    if (!mounted) return;
    setState(() => _config = config);
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      await checkAppUpdate(context, ref);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _openUrl(String url) async => openExternalUrl(context, url);

  /// 点击「致谢名单」弹出的名单弹窗（统一走 showSheetDialog，对齐项目弹窗口径，
  /// 壁纸/明暗模式自适应），成员可点击跳转主页。
  Future<void> _showAcknowledgements(List<AcknowledgementItem> items) {
    final scheme = Theme.of(context).colorScheme;
    final chipItems = List<AcknowledgementItem>.from(items);
    return showSheetDialog<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('致谢名单'),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              tr('感谢以下项目创意或功能的贡献者，排名不分先后'),
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (chipItems.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  tr('暂无致谢名单'),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final it in chipItems)
                    _DeveloperChip(
                        name: it.name, url: it.url, onOpen: _openUrl),
                ],
              ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(tr('知道了')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final links = <({IconData icon, String label, String url})>[
      if (_config.officialSiteUrl.isNotEmpty)
        (icon: Icons.language, label: tr('前往官网'), url: _config.officialSiteUrl),
      if (_config.joinGroupUrl.isNotEmpty)
        (icon: Icons.group, label: tr('加入群组'), url: _config.joinGroupUrl),
      if (_config.projectUrl.isNotEmpty)
        (icon: Icons.code, label: tr('开源地址'), url: _config.projectUrl),
      if (_config.referenceProjectUrl.isNotEmpty)
        (icon: Icons.book_outlined, label: tr('参考项目'), url: _config.referenceProjectUrl),
    ];
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
                top: widget.embedded ? 0 : GlassTopBar.height(context)),
            child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // 品牌区
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.3),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(Icons.music_note, size: 38, color: scheme.onPrimary),
            ),
          ),
          const SizedBox(height: 14),
            Center(
            child: Text(tr('弦予音乐'),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 4),
          Center(
            child: _VersionTapBadge(
              label: tr('版本 {v}', {'v': appVersion}),
              onTap: _handleVersionTap,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              tr('将音乐给予你'),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 20),
          // 检查更新
          if (_config.updateEnabled)
            FilledButton.icon(
              onPressed: _checkingUpdate ? null : _checkUpdate,
              icon: _checkingUpdate
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt, size: 18),
              label: Text(_checkingUpdate ? tr('检查中…') : tr('检查更新')),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          if (links.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text(tr('更多信息'),
                style: TextStyle(
                    fontSize: 13,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                // 壁纸模式抽透明：卡片底色随其他页面一致透出壁纸，配合壁纸
                // 「亮/暗字」档位下翻转的前景，避免卡片实色与翻转后的明暗冲突。
                color: appCardFill(context, ref),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  for (final item in links) ...[
                    ListTile(
                      leading: Icon(item.icon, color: scheme.primary),
                      title: Text(item.label),
                      trailing: Icon(Icons.open_in_new,
                          size: 16, color: scheme.outline),
                      onTap: () => _openUrl(item.url),
                    ),
                    Divider(height: 1, indent: 52, color: scheme.outlineVariant),
                  ],
                  if (_allAcknowledgements.isNotEmpty)
                    ListTile(
                      leading: Icon(Icons.favorite_outline, color: scheme.primary),
                      title: Text(tr('致谢名单')),
                      trailing: Icon(Icons.chevron_right,
                          size: 18, color: scheme.outline),
                      onTap: () => _showAcknowledgements(_allAcknowledgements),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 28),
          Center(
            child: Text(
              tr('开发者名单（排名不分先后）'),
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final d in _developers)
                _DeveloperChip(name: d.$1, url: d.$2, onOpen: _openUrl),
            ],
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              tr('© 2026 弦予音乐 · Licensed under AGPL-3.0-only'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
          ),
          if (!widget.embedded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title:   Text(tr('关于')),
              ),
            ),
        ],
      ),
    );
  }
}

/// 开发者名字标签：点击调用外部浏览器打开对应 GitHub 主页。
class _DeveloperChip extends ConsumerStatefulWidget {
  const _DeveloperChip({
    required this.name,
    required this.url,
    required this.onOpen,
  });

  final String name;
  final String url;
  final void Function(String url) onOpen;

  @override
  ConsumerState<_DeveloperChip> createState() => _DeveloperChipState();
}

class _DeveloperChipState extends ConsumerState<_DeveloperChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () => widget.onOpen(widget.url),
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _pressed
                ? scheme.primary.withValues(alpha: 0.14)
                : appCardFill(context, ref),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _pressed
                  ? scheme.primary.withValues(alpha: 0.5)
                  : scheme.outlineVariant,
            ),
          ),
          child: Text(
            widget.name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _pressed ? scheme.primary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// 版本号徽标：点击时缩放 + 主题色高亮回弹特效（连点 5 次进入调试页）。
class _VersionTapBadge extends StatefulWidget {
  const _VersionTapBadge({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_VersionTapBadge> createState() => _VersionTapBadgeState();
}

class _VersionTapBadgeState extends State<_VersionTapBadge> {
  bool _pressed = false;
  Timer? _releaseTimer;

  @override
  void dispose() {
    _releaseTimer?.cancel();
    super.dispose();
  }

  void _press() {
    _releaseTimer?.cancel();
    setState(() => _pressed = true);
  }

  void _release() {
    _releaseTimer?.cancel();
    // 松手后保持按压态一小段时间再回弹，避免快速点击时反馈一闪而过。
    _releaseTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  void _cancel() {
    _releaseTimer?.cancel();
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _press(),
      onTapUp: (_) => _release(),
      onTapCancel: _cancel,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: Duration(milliseconds: _pressed ? 120 : 280),
        curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _pressed
                ? scheme.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              color: _pressed ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: _pressed ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
