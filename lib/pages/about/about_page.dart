import 'dart:async';

import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/server_models.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/developer_mode.dart';
import '../../src/widgets/app_toast.dart';

/// 关于页：版本信息、检查更新、官网/开源/群组链接。
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

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
      showXianYuToast(context, '已进入调试模式');
      return;
    }
    if (_debugTapCount >= _debugTapHintStart) {
      showXianYuToast(
          context, '再点击 ${_debugTapTarget - _debugTapCount} 次即可进入调试模式');
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
      final latest = await ref.read(accountApiProvider).fetchServerUpdate();
      if (!mounted) return;
      if (latest == null) {
        _toast('检查更新失败，请稍后重试');
        return;
      }
      final cmp = _compareVersions(latest.version, appVersion);
      if (cmp > 0) {
        await _showUpdateDialog(latest);
      } else {
        _toast('当前已是最新版本（$appVersion）');
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  /// 版本号比较：a > b 返回 1，a < b 返回 -1，相等返回 0。
  int _compareVersions(String a, String b) {
    final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av > bv) return 1;
      if (av < bv) return -1;
    }
    return 0;
  }

  Future<void> _showUpdateDialog(LatestVersion latest) async {
    await showPredictiveDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('最新版本：${latest.version}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (latest.content.isNotEmpty)
                Text(latest.content,
                    style: const TextStyle(fontSize: 13, height: 1.5)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('暂不更新'),
          ),
          if (latest.downloadUrl.isNotEmpty)
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _openUrl(latest.downloadUrl);
              },
              child: const Text('去下载'),
            ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _toast('无法打开链接');
    } catch (_) {
      _toast('无法打开链接');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final links = <({IconData icon, String label, String url})>[
      if (_config.officialSiteUrl.isNotEmpty)
        (icon: Icons.language, label: _config.officialSiteText, url: _config.officialSiteUrl),
      if (_config.joinGroupUrl.isNotEmpty)
        (icon: Icons.group, label: _config.joinGroupText, url: _config.joinGroupUrl),
      if (_config.projectUrl.isNotEmpty)
        (icon: Icons.code, label: _config.projectText, url: _config.projectUrl),
      if (_config.referenceProjectUrl.isNotEmpty)
        (icon: Icons.book_outlined, label: _config.referenceProjectText, url: _config.referenceProjectUrl),
    ];
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
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
          const Center(
            child: Text('弦予音乐',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 4),
          Center(
            child: _VersionTapBadge(
              label: '版本 $appVersion',
              onTap: _handleVersionTap,
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
              label: Text(_checkingUpdate ? '检查中…' : _config.updateText),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          if (links.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('更多信息',
                style: TextStyle(
                    fontSize: 13,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: appCardColor(context),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < links.length; i++) ...[
                    ListTile(
                      leading: Icon(links[i].icon, color: scheme.primary),
                      title: Text(links[i].label),
                      trailing: Icon(Icons.open_in_new,
                          size: 16, color: scheme.outline),
                      onTap: () => _openUrl(links[i].url),
                    ),
                    if (i != links.length - 1)
                      Divider(
                          height: 1,
                          indent: 52,
                          color: scheme.outlineVariant),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 28),
          Center(
            child: Text(
              '© 2026 弦予音乐',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
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
