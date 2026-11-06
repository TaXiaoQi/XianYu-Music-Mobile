import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// 苹果式连续曲率（superellipse n=5）圆角：普通圆角在圆弧与直边交接
/// 处曲率从 0 跳到 1/r，有可见「拐点」；超椭圆在轴点处曲率归零，与
/// 直边连续过渡（iOS 原生圆角语言）。角部象限参数采样（每角 20 段）。
///
/// radiusScale<1 用于贴合仍是圆角 SDF 的玻璃填充边缘（rim 侧 0.92），
/// 内容裁剪默认 1.0。
Path appSquirclePath(
  Rect rect,
  double radius, {
  double radiusScale = 1.0,
}) {
  final r = (radius * radiusScale).clamp(0.0, rect.shortestSide / 2);
  final path = Path();
  if (r <= 0.5) {
    path.addRect(rect);
    return path;
  }
  // 自适应指数：小半径下 n=5 超椭圆角部收得太平（视觉发方），苹果
  // 对小尺寸圆角本就近圆。n 随半径从 2.2（≈圆）线性升到 5（应用
  // 图标级），小封面近圆连续、大卡片强 squircle，轴点曲率恒为零。
  final n = (2.2 + (r / 40) * 2.8).clamp(2.2, 5.0);
  const segs = 20;
  final l = rect.left, t = rect.top, rt = rect.right, b = rect.bottom;
  double sp(double v) => math.pow(v, 2 / n).toDouble();

  path.moveTo(l, t + r);
  // 左缘上行 → 左上角（左轴点 → 顶轴点）
  for (var i = 1; i <= segs; i++) {
    final u = math.pi / 2 * i / segs;
    path.lineTo(l + r - r * sp(math.cos(u)), t + r - r * sp(math.sin(u)));
  }
  // 顶缘 → 右上角（顶轴点 → 右轴点）
  path.lineTo(rt - r, t);
  for (var i = 1; i <= segs; i++) {
    final u = math.pi / 2 * i / segs;
    path.lineTo(rt - r + r * sp(math.sin(u)), t + r - r * sp(math.cos(u)));
  }
  // 右缘下行 → 右下角（右轴点 → 底轴点）
  path.lineTo(rt, b - r);
  for (var i = 1; i <= segs; i++) {
    final u = math.pi / 2 * i / segs;
    path.lineTo(rt - r + r * sp(math.cos(u)), b - r + r * sp(math.sin(u)));
  }
  // 底缘 → 左下角（底轴点 → 左轴点）
  path.lineTo(l + r, b);
  for (var i = 1; i <= segs; i++) {
    final u = math.pi / 2 * i / segs;
    path.lineTo(l + r - r * sp(math.sin(u)), b - r + r * sp(math.cos(u)));
  }
  path.close();
  return path;
}

/// 连续曲率裁剪（替代 ClipRRect）。
class ClipSquircle extends StatelessWidget {
  const ClipSquircle({super.key, required this.radius, required this.child});

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _SquircleClipper(radius),
      child: child,
    );
  }
}

class _SquircleClipper extends CustomClipper<Path> {
  _SquircleClipper(this.radius);

  final double radius;

  @override
  Path getClip(Size size) =>
      appSquirclePath(Offset.zero & size, radius);

  @override
  bool shouldReclip(_SquircleClipper old) => old.radius != radius;
}

/// 连续曲率形状（替代 RoundedRectangleBorder / BoxDecoration 的
/// borderRadius），用于 ShapeDecoration。
class SquircleBorder extends ShapeBorder {
  const SquircleBorder({this.radius = 0, this.side = BorderSide.none});

  final double radius;
  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) => SquircleBorder(
        radius: radius * t,
        side: side.scale(t),
      );

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      appSquirclePath(rect.deflate(side.width), radius);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      appSquirclePath(rect, radius);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width <= 0) return;
    canvas.drawPath(
      appSquirclePath(rect.deflate(side.width / 2), radius),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width
        ..color = side.color,
    );
  }

  @override
  ShapeBorder lerpFrom(ShapeBorder? a, double t) {
    if (a is SquircleBorder) {
      return SquircleBorder(
        radius: lerpDouble(a.radius, radius, t)!,
        side: BorderSide.lerp(a.side, side, t),
      );
    }
    return super.lerpFrom(a, t) ?? this;
  }

  @override
  ShapeBorder lerpTo(ShapeBorder? b, double t) {
    if (b is SquircleBorder) {
      return b.lerpFrom(this, t);
    }
    return super.lerpTo(b, t) ?? this;
  }
}
