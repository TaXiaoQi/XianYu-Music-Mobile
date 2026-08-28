import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/settings.dart';

/// 液态玻璃参数：与底栏同一套观感（厚度/折射/色散），暗色与亮色微调玻璃色。
/// ambientRim/edgeAbsorption 只在 premium(高)档由 shader 消费：ambientRim 渲染全周
/// 边亮环、edgeAbsorption 加边缘雕刻暗带，让高档出"市面那种描边"；glow/light 提升在
/// 低中档也能让边缘辉光更明显一些（标准 shader 读它们）。
LiquidGlassSettings liquidGlassSettings(bool isDark) {
  return LiquidGlassSettings(
    thickness: 30,
    blur: 3,
    chromaticAberration: 0.3,
    lightIntensity: 0.9,
    refractiveIndex: 1.59,
    saturation: 0.7,
    ambientStrength: 1,
    lightAngle: 0.75 * math.pi,
    ambientRim: 0.5,
    edgeAbsorption: 0.12,
    glowIntensity: 1.1,
    // 关掉 light-mode 黑投影：否则它会夹在白描边与白色玻璃之间形成一条深灰
    // "分隔带"，破坏边缘→中心的平滑过渡（投影只在亮色主题绘制）。
    shadow: const [],
    glassColor: isDark
        ? const Color(0x3DFFFFFF)
        : const Color(0x66FFFFFF),
  );
}

/// 液态玻璃效果档位 → rendering 质量：
/// low = minimal（纯高斯模糊+描边，最省电）/
/// medium = standard（轻量片元着色器，性能/观感均衡，默认）/
/// high = premium（完整折射+色散管线，观感最强，较耗能）。
GlassQuality liquidGlassQualityOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => GlassQuality.minimal,
      LiquidGlassQuality.medium => GlassQuality.standard,
      LiquidGlassQuality.high => GlassQuality.premium,
    };

/// 从设置读取当前液态玻璃效果档位对应的渲染质量。
GlassQuality liquidGlassQualityFromRef(WidgetRef ref) => liquidGlassQualityOf(
    ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.liquidGlassQuality ?? LiquidGlassQuality.medium)));

/// 玻璃表面是否回退为「高不透明度纯色」（关闭毛玻璃 / 低性能模式）。
///
/// 规则：低性能模式始终纯色；自定义壁纸启用时始终玻璃（透明+模糊，否则壁纸下
/// 太难看清）；其余情况跟随「毛玻璃」设置（`frostedGlass`）——关闭则纯色，
/// 开启则透明磨砂。供所有玻璃表面（顶栏/底栏/播放条/播放页卡）统一判断，
/// 避免各处重复实现导致口径不一致。
bool glassShouldUseSolid(WidgetRef ref,
    {required bool lowPerf, required bool wallpaper}) {
  if (lowPerf) return true;
  if (wallpaper) return false;
  return !(ref.watch(settingsProvider).valueOrNull?.frostedGlass ?? true);
}

/// 给玻璃表面手工叠一圈亮色描边 + 顶部高光（经典玻璃"倒角"）。
///
/// 任何质量档（低/中/高）都稳定生效，弥补标准 shader 在浅色模式下把上边光源
/// rim 压到 8%（iOS 26 对齐）导致"没描边"的问题；高档的 premium shader 描边
/// 在此基础上再叠加（结合使用）。描边统一用亮白色系并向外发光，最外圈始终
/// 可见一圈亮边。
Widget glassBorder({
  required BuildContext context,
  required double radius,
  required Widget child,
}) {
  return CustomPaint(
    // 必须用 foregroundPainter：painter 会在 child 之下绘制，亮描边会被玻璃本体
    // 盖住只剩"里亮外黑"；foregroundPainter 才叠在玻璃最外层之上，让最外圈亮边可见。
    foregroundPainter: _GlassBorderPainter(
      radius: radius,
      isDark: Theme.of(context).brightness == Brightness.dark,
    ),
    child: child,
  );
}

class _GlassBorderPainter extends CustomPainter {
  _GlassBorderPainter({required this.radius, required this.isDark});

  final double radius;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );

    // 最外围亮边：两层白色描边由外向内逐渐变实，柔和过渡进玻璃本体，
    // 避免"白色描边 / 深色带 / 白色玻璃"三色硬拼接。
    const glowLayers = [(2.2, 0x10), (1.0, 0x26)];
    final glow = Paint()..style = PaintingStyle.stroke;
    for (final (width, alpha) in glowLayers) {
      final a = (alpha * (isDark ? 1.0 : 0.85)).round();
      glow
        ..strokeWidth = width
        ..color = Colors.white.withValues(alpha: a / 255.0);
      // 外扩绘制，让亮边落在玻璃最外缘，并向外逐层淡出。
      canvas.drawRRect(rrect.inflate(width), glow);
    }

    // 主轮廓 hairline：贴近玻璃外缘的一圈细亮白线。
    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.white.withValues(alpha: isDark ? 0.78 : 0.6);
    canvas.drawRRect(rrect, hair);
  }

  @override
  bool shouldRepaint(_GlassBorderPainter old) =>
      old.radius != radius || old.isDark != isDark;
}
