import 'package:flutter/material.dart';

/// 应用真实 logo：白色圆角底 + 「予」字形音符 glyph（与启动图标、桌面端同源）。
/// glyph 原色为深炭色，必须放在浅色底上展示。
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 72, this.radius = 20});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: EdgeInsets.all(size * 0.12),
      child: Image.asset(
        'assets/icon/logo.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
