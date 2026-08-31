import 'package:flutter/material.dart';

/// 「皮肤（壁纸中心）」入口的自定义衣服图标，对齐桌面端顶栏
/// TopBarControlIcon 的 colorScheme 图标（一件衣服的镂空轮廓）。
///
/// 用法与 [Icon] 一致：不传 [size] 时继承外层 IconTheme 的 size（默认 24），
/// 不传 [color] 时继承 IconTheme 的 color，从而自动适配所在页面。
class SkinIcon extends StatelessWidget {
  const SkinIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final iconColor = color ?? theme.color ?? Colors.white;
    final iconSize = size ?? theme.size ?? 24;
    return CustomPaint(
      size: Size.square(iconSize),
      painter: _SkinPainter(color: iconColor),
    );
  }
}

class _SkinPainter extends CustomPainter {
  const _SkinPainter({required this.color});

  final Color color;

  /// Material 内置 Icon 的 glyph 在 em 框内自带留白（视觉约占逻辑尺寸的
  /// ~0.78），而衣服路径铺满 0..24。若按满 24 绘制，同样逻辑尺寸下衣服会比
  /// 旁边的内置图标大一圈（悬浮顶栏观感异常）。因此缩放到中央内容区并居中，
  /// 使衣服视觉尺寸与内置 Material 图标一致（固定视觉大小）。
  static const double _visualScale = 0.72;

  /// 桌面端 colorScheme（衣服）SVG path 的等价 Flutter Path。
  /// 原始 path（viewBox 24）：
  /// M20.38 3.46L16 2a4 4 0 01-8 0L3.62 3.46a2 2 0 00-1.34 2.23l.58 3.47a1 1
  /// 0 00.99.84H6v10c0 1.1.9 2 2 2h8a2 2 0 002-2V10h2.15a1 1 0 00.99-.84l.58
  /// -3.47a2 2 0 00-1.34-2.23z
  /// 描边渲染（fill=none + stroke=2，圆帽圆角）。
  Path _buildPath() {
    final p = Path()
      // 右肩 → 右领口
      ..moveTo(20.38, 3.46)
      ..lineTo(16, 2)
      // 领口弧（右→左，半径 4，顺时针）
      ..arcToPoint(
        const Offset(8, 2),
        radius: const Radius.circular(4),
        largeArc: false,
        clockwise: true,
      )
      // 左肩 → 左袖外沿（逆时针）
      ..lineTo(3.62, 3.46)
      ..arcToPoint(
        const Offset(2.28, 5.69),
        radius: const Radius.circular(2),
        clockwise: false,
      )
      ..lineTo(2.86, 9.16)
      // 左臂下角
      ..arcToPoint(
        const Offset(3.85, 10.0),
        radius: const Radius.circular(1),
        clockwise: false,
      )
      // 左袖底 → 左衣摆 → 底边（圆角）
      ..lineTo(6, 10.0)
      ..lineTo(6, 20.0)
      ..cubicTo(6, 21.1, 6.9, 22, 8, 22)
      ..lineTo(16, 22)
      // 右衣摆角（逆时针）
      ..arcToPoint(
        const Offset(18, 20),
        radius: const Radius.circular(2),
        clockwise: false,
      )
      // 右衣摆 → 右袖底
      ..lineTo(18, 10.0)
      ..lineTo(20.15, 10.0)
      // 右臂下角
      ..arcToPoint(
        const Offset(21.14, 9.16),
        radius: const Radius.circular(1),
        clockwise: false,
      )
      // 右袖外沿 → 右肩，闭合
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
    // 先平移到画布中心，再按 [_visualScale] 把 0..24 的 viewBox 内容缩放居中，
    // 使衣服视觉尺寸固定为逻辑尺寸（不再占满，与内置 Material 图标同观感）。
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