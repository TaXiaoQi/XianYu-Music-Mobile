part of 'bilipai_glass.dart';

/// 玻璃侧连续曲率路径：贴合 shader 圆角 SDF 填充边缘（0.92 缩放），
/// 实现在 squircle.dart（玻璃与内容卡片共用）。
Path squircleGlassPath(
  Rect rect,
  double radius, {
  double radiusScale = 0.92,
}) =>
    appSquirclePath(rect, radius, radiusScale: radiusScale);

/// iOS 26 原生液态玻璃观感的统一精修壳（所有液态面唯一出口）。
/// 参考系统 dock/悬浮容器的反光语言，三层表现（原生**没有可见阴影**，
/// 立体感全靠玻璃表面明暗与 rim，故不画投影）：
///  · rim 双色描边：顶缘亮线（玻璃上缘反光）+ 底缘暗线（折射阴影）
///  · 左上主高光弧：光源左上的镜面反光亮线
///  · 顶部泛光：上半段白色透光渐变（画在内容之上，即玻璃透光）
/// 全部形状走连续曲率（squircle），圆角-直边无曲率突变点。
Widget liquidGlassShell(
  BuildContext context, {
  required Widget child,
  double radius = 999,
  double borderWidth = 0.8,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return CustomPaint(
    foregroundPainter: _LiquidGlassRimPainter(
      isDark: isDark,
      radius: radius,
      strokeWidth: borderWidth,
    ),
    child: child,
  );
}

class _LiquidGlassRimPainter extends CustomPainter {
  _LiquidGlassRimPainter({
    required this.isDark,
    required this.radius,
    required this.strokeWidth,
  });

  final bool isDark;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    final shortest = outer.shortestSide;
    if (shortest <= 0) return;
    final rr = squircleGlassPath(
      outer.deflate(strokeWidth / 2),
      radius.clamp(0.0, shortest / 2),
    );

    // 顶部泛光：玻璃上半段白色透光，画在内容之上（前景层），高光随
    // 内容滚动仍保持在玻璃表面——iOS 原生 dock 的顶部泛光语言
    final glossHeight = shortest.clamp(0.0, outer.height * 0.55);
    final gloss = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.05 : 0.09),
          Colors.white.withValues(alpha: isDark ? 0.015 : 0.03),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, outer.width, glossHeight));
    canvas.drawPath(rr, gloss);

    // 左上主高光弧：沿内缘左上弧段画镜面反光亮线
    final arcPath = squircleGlassPath(
      outer.deflate(strokeWidth * 1.6),
      radius.clamp(0.0, shortest / 2),
    );
    final metrics = arcPath.computeMetrics().toList();
    if (metrics.isNotEmpty) {
      final m = metrics.first;
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 2.2
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.2)
        ..color = Colors.white.withValues(alpha: isDark ? 0.20 : 0.30);
      // 从左缘中段起，扫过左上角到顶缘中段（iOS 光源左上的反光带）
      final start = m.length * 0.60;
      final span = m.length * 0.16;
      canvas.drawPath(
        m.extractPath(start, (start + span).clamp(0.0, m.length)),
        arcPaint,
      );
    }

    // rim 主描边：纵向线性渐变（顶亮→底暗）。原生 rim 是柔光不是
    // 实线——宽笔触 + 模糊 + 低透明度，边缘像「亮起来」而非描边。
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.6);
    const white = Colors.white;
    const black = Colors.black;
    paint.shader = isDark
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              white.withValues(alpha: 0.30),
              white.withValues(alpha: 0.08),
              black.withValues(alpha: 0.06),
              black.withValues(alpha: 0.30),
            ],
          ).createShader(outer)
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              white.withValues(alpha: 0.42),
              white.withValues(alpha: 0.10),
              black.withValues(alpha: 0.03),
              black.withValues(alpha: 0.18),
            ],
          ).createShader(outer);
    canvas.drawPath(rr, paint);
  }

  @override
  bool shouldRepaint(_LiquidGlassRimPainter old) =>
      old.isDark != isDark || old.radius != radius;
}
