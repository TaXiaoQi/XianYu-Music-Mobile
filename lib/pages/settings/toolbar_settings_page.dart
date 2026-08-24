import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/shell.dart';

/// 底栏与工具栏设置页：支持配置底栏位置（底部/侧边）、悬浮样式与液态玻璃。
class ToolbarSettingsPage extends ConsumerStatefulWidget {
  const ToolbarSettingsPage({super.key});

  @override
  ConsumerState<ToolbarSettingsPage> createState() =>
      _ToolbarSettingsPageState();
}

class _ToolbarSettingsPageState extends ConsumerState<ToolbarSettingsPage>
    with HidesShellChrome {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '底栏与工具栏',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const _AmbientBackground(),
          ListView(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + kToolbarHeight,
              left: 16,
              right: 16,
              bottom: 40,
            ),
            children: [
              _section(context, '悬浮与特效', [
                _GlassSwitchTile(
                  icon: Icons.blur_on,
                  title: '液态玻璃',
                  subtitle: '导航栏与迷你播放条使用 shader 折射与动态光影',
                  value: settings?.liquidGlass ?? true,
                  onChanged: (v) => notifier.setLiquidGlass(v),
                ),
                _GlassSwitchTile(
                  icon: Icons.music_video,
                  title: '歌曲详情页液态玻璃',
                  subtitle: '正在播放页面的控制卡片使用 shader 折射与动态光效',
                  value: settings?.playerLiquidGlass ?? true,
                  onChanged: (v) => notifier.setPlayerLiquidGlass(v),
                ),
              ]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          _GlassCard(children: rows),
        ],
      ),
    );
  }
}

/// 氛围背景。
class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: appSurfaceBg(context)),
          Positioned(
            top: -90,
            right: -70,
            child: _glow(300, scheme.primary.withValues(alpha: isDark ? 0.24 : 0.16)),
          ),
          Positioned(
            bottom: -70,
            left: -90,
            child: _glow(320, scheme.tertiary.withValues(alpha: isDark ? 0.14 : 0.09)),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
            child: Container(color: Colors.transparent),
          ),
        ],
      ),
    );
  }

  Widget _glow(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      );
}

/// 毛玻璃分组卡片。
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 56,
                    color: scheme.onSurface.withValues(alpha: 0.06),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃开关行（支持置灰禁用）。
class _GlassSwitchTile extends StatelessWidget {
  const _GlassSwitchTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: enabled
                  ? scheme.primary.withValues(alpha: 0.12)
                  : scheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              icon,
              size: 18,
              color: enabled
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: enabled
                        ? null
                        : scheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 11,
                      color: enabled
                          ? scheme.onSurfaceVariant.withValues(alpha: 0.8)
                          : scheme.onSurface.withValues(alpha: 0.3),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
