part of 'bilipai_glass.dart';

Widget liquidGlassShell(
  BuildContext context, {
  required Widget child,
  double radius = 999,
  Color? lightBorder,
  Color? darkBorder,
  double borderWidth = 0.8,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return CustomPaint(
    foregroundPainter: _LiquidGlassRimPainter(
      isDark: isDark,
      radius: radius,
      strokeWidth: borderWidth,
      lightBorder: lightBorder,
      darkBorder: darkBorder,
    ),
    child: child,
  );
}

class _LiquidGlassRimPainter extends CustomPainter {
  _LiquidGlassRimPainter({
    required this.isDark,
    required this.radius,
    required this.strokeWidth,
    this.lightBorder,
    this.darkBorder,
  });

  final bool isDark;
  final double radius;
  final double strokeWidth;
  final Color? lightBorder;
  final Color? darkBorder;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    final shortest = outer.shortestSide;
    if (shortest <= 0) return;
    final rr = RRect.fromRectAndRadius(
      outer.deflate(strokeWidth / 2),
      Radius.circular(radius.clamp(0.0, shortest / 2)),
    );
    final base = isDark
        ? (darkBorder ?? Colors.white)
        : (lightBorder ?? Colors.black);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..maskFilter =
          MaskFilter.blur(BlurStyle.normal, isDark ? 0.5 : 2.2);
    paint.shader = isDark
        ? RadialGradient(
            center: const Alignment(0, -1.4),
            radius: 1.6,
            colors: [
              base.withValues(alpha: 0.55),
              base.withValues(alpha: 0.12),
              base.withValues(alpha: 0.03),
            ],
          ).createShader(outer)
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              base.withValues(alpha: 0.05),
              base.withValues(alpha: 0.13),
              base.withValues(alpha: 0.17),
            ],
          ).createShader(outer);
    canvas.drawRRect(rr, paint);
  }

  @override
  bool shouldRepaint(_LiquidGlassRimPainter old) =>
      old.isDark != isDark ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.lightBorder != lightBorder ||
      old.darkBorder != darkBorder;
}