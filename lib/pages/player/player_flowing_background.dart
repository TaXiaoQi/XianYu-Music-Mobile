import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 播放页高级模式的低开销多边形流光叠层。
///
/// 桌面端使用 GPU Voronoi 片元着色；移动端保留“随时间漂移的多边形色场”
/// 这一核心视觉，改为低密度三角网格，避免全屏逐像素着色带来的功耗压力。
///
/// 深浅适配：播放页固定以深色渲染，但浅色主题下的页面底色明显偏灰，
/// 固定叠加强度会让流光发灰发脏。因此按 [baseColor] 的实际明度调整
/// 色块浓淡与暗角强度，使两种主题下观感一致。
class PlayerFlowingBackground extends StatefulWidget {
  const PlayerFlowingBackground({
    super.key,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.baseColor,
  });

  final Color primary;
  final Color secondary;
  final Color tertiary;

  /// 播放页在该主题下的实际底色，用于推导叠加强度
  final Color baseColor;

  @override
  State<PlayerFlowingBackground> createState() =>
      _PlayerFlowingBackgroundState();
}

class _PlayerFlowingBackgroundState extends State<PlayerFlowingBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // 底色越深 → depth 越接近 1（流光可更浓、暗角可更重）；
    // 底色偏灰（浅色主题）→ depth 降低，减淡色块与暗角，避免糊成一片灰雾。
    final luma = widget.baseColor.computeLuminance().clamp(0.0, 1.0);
    final depth = ((0.30 - luma) / 0.30).clamp(0.0, 1.0);
    return RepaintBoundary(
      child: TickerMode(
        enabled: !reduceMotion,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _FlowingMeshPainter(
              progress: reduceMotion ? 0 : _controller.value,
              primary: widget.primary,
              secondary: widget.secondary,
              tertiary: widget.tertiary,
              vesselAlpha: 0.13 + 0.075 * depth,
              vignetteAlpha: 0.08 + 0.085 * depth,
              lift: 0.10 * depth,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _FlowingMeshPainter extends CustomPainter {
  const _FlowingMeshPainter({
    required this.progress,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.vesselAlpha,
    required this.vignetteAlpha,
    required this.lift,
  });

  final double progress;
  final Color primary;
  final Color secondary;
  final Color tertiary;

  /// 单个多边形的叠加强度（按底色深浅自适应）
  final double vesselAlpha;

  /// 四周暗角强度（按底色深浅自适应）
  final double vignetteAlpha;

  /// 色块向白色提亮的比例：深色底需要提亮才透得出光泽，
  /// 浅色主题的灰底则不提亮，避免整体发白
  final double lift;

  static const int _columns = 5;
  static const int _rows = 8;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final points = <Offset>[];
    final colors = <Color>[];
    final dx = size.width / _columns;
    final dy = size.height / _rows;
    final palette = <Color>[
      primary,
      Color.lerp(primary, secondary, 0.5)!,
      secondary,
      Color.lerp(secondary, tertiary, 0.5)!,
      tertiary,
      Color.lerp(tertiary, primary, 0.5)!,
    ].map((c) => Color.lerp(c, Colors.white, lift)!).toList();

    for (var row = 0; row <= _rows; row++) {
      for (var column = 0; column <= _columns; column++) {
        final edge =
            row == 0 || row == _rows || column == 0 || column == _columns;
        final seed = row * 17.0 + column * 31.0;
        final phase = progress * math.pi * 2;
        final driftX = math.sin(phase + seed) * dx * 0.14;
        final driftY = math.cos(phase * 0.8 + seed * 1.7) * dy * 0.11;
        points.add(
          Offset(
            column * dx + (edge ? 0 : driftX),
            row * dy + (edge ? 0 : driftY),
          ),
        );
        final color = palette[(row * 3 + column * 5) % palette.length];
        colors.add(color.withValues(alpha: vesselAlpha));
      }
    }

    final indices = <int>[];
    final stride = _columns + 1;
    for (var row = 0; row < _rows; row++) {
      for (var column = 0; column < _columns; column++) {
        final topLeft = row * stride + column;
        final topRight = topLeft + 1;
        final bottomLeft = topLeft + stride;
        final bottomRight = bottomLeft + 1;
        final flip = (row + column).isOdd;
        if (flip) {
          indices.addAll([
            topLeft,
            topRight,
            bottomLeft,
            topRight,
            bottomRight,
            bottomLeft,
          ]);
        } else {
          indices.addAll([
            topLeft,
            topRight,
            bottomRight,
            topLeft,
            bottomRight,
            bottomLeft,
          ]);
        }
      }
    }

    final meshPaint = Paint()..blendMode = BlendMode.srcOver;
    canvas.drawVertices(
      ui.Vertices(
        ui.VertexMode.triangles,
        points,
        colors: colors,
        indices: indices,
      ),
      BlendMode.srcOver,
      meshPaint,
    );

    final vignette = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.9,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: vignetteAlpha),
        ],
        stops: const [0.48, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);
  }

  @override
  bool shouldRepaint(covariant _FlowingMeshPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary ||
      oldDelegate.tertiary != tertiary ||
      oldDelegate.vesselAlpha != vesselAlpha ||
      oldDelegate.vignetteAlpha != vignetteAlpha ||
      oldDelegate.lift != lift;
}
