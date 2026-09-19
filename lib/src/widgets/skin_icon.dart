import 'package:flutter/material.dart';

class SkinIcon extends StatelessWidget {
  const SkinIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final iconColor = color ?? theme.color ?? Colors.white;
    final iconSize = size ?? theme.size ?? 24;
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Center(
        child: CustomPaint(
          size: Size.square(iconSize),
          painter: _SkinPainter(color: iconColor),
        ),
      ),
    );
  }
}

class _SkinPainter extends CustomPainter {
  const _SkinPainter({required this.color});

  final Color color;

  static const double _visualScale = 0.82;

  Path _buildPath() {
    final p = Path()
      ..moveTo(20.38, 3.46)
      ..lineTo(16, 2)
      ..arcToPoint(
        const Offset(8, 2),
        radius: const Radius.circular(4),
        largeArc: false,
        clockwise: true,
      )
      ..lineTo(3.62, 3.46)
      ..arcToPoint(
        const Offset(2.28, 5.69),
        radius: const Radius.circular(2),
        clockwise: false,
      )
      ..lineTo(2.86, 9.16)
      ..arcToPoint(
        const Offset(3.85, 10.0),
        radius: const Radius.circular(1),
        clockwise: false,
      )
      ..lineTo(6, 10.0)
      ..lineTo(6, 20.0)
      ..cubicTo(6, 21.1, 6.9, 22, 8, 22)
      ..lineTo(16, 22)
      ..arcToPoint(
        const Offset(18, 20),
        radius: const Radius.circular(2),
        clockwise: false,
      )
      ..lineTo(18, 10.0)
      ..lineTo(20.15, 10.0)
      ..arcToPoint(
        const Offset(21.14, 9.16),
        radius: const Radius.circular(1),
        clockwise: false,
      )
      ..lineTo(21.72, 5.69)
      ..arcToPoint(
        const Offset(20.38, 3.46),
        radius: const Radius.circular(2),
        clockwise: false,
      )
      ..close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale((size.width / 24) * _visualScale, (size.height / 24) * _visualScale);
    canvas.translate(-12, -12);
    canvas.drawPath(
      _buildPath(),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SkinPainter old) => old.color != color;
}