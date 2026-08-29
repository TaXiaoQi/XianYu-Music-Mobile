import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/app_colors.dart';
import '../core/settings.dart';
import 'blur_budget.dart';

/// 液态玻璃参数：与底栏同一套观感（厚度/折射/色散），暗色与亮色微调玻璃色。
/// ambientRim/edgeAbsorption 只在 premium(高)档由 shader 消费：ambientRim 渲染全周
/// 边亮环、edgeAbsorption 加边缘雕刻暗带，让高档出"市面那种描边"；glow/light 提升在
/// 低中档也能让边缘辉光更明显一些（标准 shader 读它们）。
/// 注意：edgeAbsorption（meniscus 暗化）与 lightIntensity（高光）过大会在胶囊边缘
/// 形成刺眼的"黑白交界"——背光侧压黑 + 迎光侧提白。已按 0.05/0.6 收敛反差。
LiquidGlassSettings liquidGlassSettings(bool isDark) {
  return LiquidGlassSettings(
    thickness: 30,
    blur: 3,
    chromaticAberration: 0.3,
    lightIntensity: 0.6,
    refractiveIndex: 1.59,
    saturation: 0.7,
    ambientStrength: 1,
    lightAngle: 0.75 * math.pi,
    ambientRim: 0.5,
    edgeAbsorption: 0.05,
    glowIntensity: 1.1,
    // 关掉 light-mode 黑投影：否则它会夹在白描边与白色玻璃之间形成一条深灰
    // "分隔带"，破坏边缘→中心的平滑过渡（投影只在亮色主题绘制）。
    shadow: const [],
    glassColor: isDark
        ? const Color(0x3DFFFFFF)
        : const Color(0x66FFFFFF),
  );
}

/// 从设置读取当前毛玻璃效果档位（low/medium/high 语义映射）。
FrostedGlassLevel frostedGlassLevelSetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.frostedGlassLevel ??
        FrostedGlassLevel.strongest));

/// 毛玻璃模糊强度档位 → sigma 缩放系数。
/// strongest = 1.0（当前默认，观感最强）/ medium = 0.6 / light = 0.16。
/// 该缩放仅作用于非导航类毛玻璃表面（迷你播放条、播放面板等）；
/// 顶栏、底栏、横屏侧栏等导航表面保持各自固定模糊度，不受档位影响。
/// 轻度档 sigma 收敛到很小（播放条 ~1.6 / 面板 ~1.3），近乎透明、仅留一点模糊，
/// 适合壁纸下强调通透的观感。
double frostedBlurScaleOf(FrostedGlassLevel l) => switch (l) {
      FrostedGlassLevel.strongest => 1.0,
      FrostedGlassLevel.medium => 0.6,
      FrostedGlassLevel.light => 0.16,
    };

/// 从设置读取当前毛玻璃档位对应的 sigma 缩放系数。
double frostedBlurScale(WidgetRef ref) =>
    frostedBlurScaleOf(frostedGlassLevelSetting(ref));

/// 毛玻璃卡片表面：墙面圆角卡片（设置页/我的页）的通用玻璃包裹。
///
/// 墙面卡片不单独维护一套毛玻璃状态，而是与全局毛玻璃共用一个开关
/// （`frostedGlass`）和强度（`frostedBlurScale` = 高斯模糊量）。壁纸模式下
/// 数据层已强制 `frostedGlass=true`，卡片自动呈现透明 + 按强度的模糊；
/// 非壁纸/关闭毛玻璃时原样返回实色卡片，不引入模糊开销。
///
/// - [glass]：是否处于毛玻璃开启的墙面（外部用 `wallpaperActiveProvider` 判断，
///   因为普通模式墙面卡片用实色，仅壁纸下卡片走玻璃）
Widget glassCardSurface({
  required Widget child,
  required double radius,
  required bool glass,
  required WidgetRef ref,
}) {
  if (!glass) return child;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: 16 * frostedBlurScale(ref),
        sigmaY: 16 * frostedBlurScale(ref),
      ),
      child: child,
    ),
  );
}

/// 伪毛玻璃卡片：页面内容上的圆角玻璃卡片（首页统计/每日推荐/榜单占位/
/// 听过最多 等）。
///
/// 与全局毛玻璃开关、强度档位联动：
/// - 毛玻璃开 → 半透明白 + 高斯模糊（sigma=16×档位缩放），半透出背景/壁纸
/// - 毛玻璃关 / 低性能 → 高不透明度纯色（无 BackdropFilter，零模糊开销）
///
/// 与 [glassCardSurface] 的区别：后者仅壁纸模式才玻璃（普通模式墙面卡片用
/// 实色）；这里普通模式也跟随 `frostedGlass` 开关呈现磨砂，供内容区那些
/// 原本写死「半透明白」的卡片接入，否则它们永远不受全局开关控制。
Widget frostedCardSurface({
  required BuildContext context,
  required WidgetRef ref,
  required double radius,
  required Widget child,
  bool lowPerf = false,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = ref.watch(wallpaperActiveProvider);
  final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final fill = wallpaper
      ? glassControlFill
      : (solid
          ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
          : (isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.white.withValues(alpha: 0.52)));
  final border = solid
      ? null
      : Border.all(
          color: wallpaper
              ? glassControlBorder
              : (isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.40)),
        );
  final surface = Container(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      border: border,
    ),
    child: child,
  );
  if (solid) return surface;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: 16 * frostedBlurScale(ref),
        sigmaY: 16 * frostedBlurScale(ref),
      ),
      child: surface,
    ),
  );
}

/// 固定对比色搜索框底色：复用播放条「纯色回退」的高不透明度、带一点透明的实色，
/// 不随毛玻璃开关变化，专门用于与玻璃顶栏/页面形成明暗对比（顶栏/我的页/搜索页搜索框）。
Color contrastSearchColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xE62A2A2E)
        : const Color(0xF0FFFFFF);

/// 液态玻璃效果档位 → rendering 质量：
/// low = 伪毛玻璃伪造（不跑 shader，透明底+淡模糊）/
/// medium = standard（真液态轻量片元着色器：折射采样+位移+描边，默认，找回"液态感"）/
/// high = premium（完整折射+色散管线，观感最强，较耗能）。
GlassQuality liquidGlassQualityOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => GlassQuality.minimal,
      LiquidGlassQuality.medium => GlassQuality.standard,
      LiquidGlassQuality.high => GlassQuality.premium,
    };

/// 从设置读取当前液态玻璃效果档位（原始 low/medium/high）。
LiquidGlassQuality liquidGlassQualitySetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.liquidGlassQuality ??
        LiquidGlassQuality.medium));

/// 从设置读取当前液态玻璃效果档位对应的渲染质量。
GlassQuality liquidGlassQualityFromRef(WidgetRef ref) =>
    liquidGlassQualityOf(liquidGlassQualitySetting(ref));

/// BiliPai 化液态玻璃折射强度（滚动波浪位移幅度）按档位映射：
/// medium 更收敛 / high 接近 BiliPai 默认。low 走伪液态毛玻璃不经 shader。
double bilipaiRefractOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.08,
      LiquidGlassQuality.medium => 0.12,
      LiquidGlassQuality.high => 0.18,
    };

/// BiliPai 化液态玻璃色差强度（RGB 通道分离幅度）按档位映射。
double bilipaiChromaOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.2,
      LiquidGlassQuality.medium => 0.35,
      LiquidGlassQuality.high => 0.5,
    };

/// BiliPai 化液态玻璃预乘混合底色：亮色更透明（0.30）避免白底上糊成一片，
/// 暗色 0.18 保持通透。
Color bilipaiGlassTint(bool isDark) => isDark
    ? Colors.white.withValues(alpha: 0.18)
    : Colors.white.withValues(alpha: 0.30);

/// BiliPai 化液态玻璃表面流动高光强度（滚动时在玻璃上扫过的反光带）。
/// low 走伪液态不经 shader；中/高档映射高光强度。
double bilipaiSpecularOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.28,
      LiquidGlassQuality.high => 0.42,
    };

/// 玻璃表面是否回退为「高不透明度纯色」（关闭毛玻璃 / 低性能模式）。
///
/// 规则：低性能模式始终纯色；其余完全跟随「毛玻璃」设置（`frostedGlass`）——
/// 关闭则纯色、开启则透明磨砂。壁纸模型不需要特判：应用壁纸时数据层已把
/// `frostedGlass` 强制为 true（见 `SettingsNotifier.setCustomBackground`），
/// 因此这里只读 `frostedGlass` 一个状态，壁纸与普通模式共用同一套判断。
/// 供所有玻璃表面（顶栏/底栏/播放条/播放页卡）统一判断，避免各处重复口径。
bool glassShouldUseSolid(WidgetRef ref, {required bool lowPerf}) {
  if (lowPerf) return true;
  return !(ref.watch(settingsProvider).valueOrNull?.frostedGlass ?? true);
}

/// 液态玻璃最低档（low）用「伪液态毛玻璃」伪造，不跑 shader。
///
/// 低档不再走 `AdaptiveGlass`（即便 minimal 也要片元着色器），改用
/// [pseudoLiquidSurface]：更淡的高斯模糊 + 更透明的底，模拟液态玻璃的
/// 通透观感，零 shader 开销。中档走真液态（standard 轻量片元着色器）。
bool liquidUseFrosted(WidgetRef ref) =>
    ref.watch(settingsProvider.select((s) =>
        s.valueOrNull?.liquidGlassQuality ?? LiquidGlassQuality.medium)) ==
    LiquidGlassQuality.low;

/// 伪液态毛玻璃表面（液态玻璃 low 档的伪造实现）。
///
/// 透明底 + 比普通毛玻璃更淡的高斯模糊（sigma 8），营造液态玻璃通透观感；
/// 低性能模式 → 高不透明度纯色回退。传入 [budget] 时按全局 blur 预算动态
/// 缩放 sigma、并用铺底透明度补偿（滚动/转场期间降级，接入统一预算策略）。
Widget pseudoLiquidSurface({
  required BuildContext context,
  required WidgetRef ref,
  required double radius,
  required Widget child,
  bool lowPerf = false,
  BlurSurfaceType surfaceType = BlurSurfaceType.generic,
  BlurBudget? budget,
  // 传入非 null 时，模糊强度跟随毛玻璃档位（frostedBlurScale），用于毛玻璃表面
  // （如悬浮搜索框）；液态玻璃 low 档伪液态不传，保持固定淡模糊。
  double? frostedScale,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = ref.watch(wallpaperActiveProvider);
  final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final bg = wallpaper
      ? glassControlFill
      : (solid
          ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
          : (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.34)));
  final border = wallpaper
      ? glassControlBorder
      : (isDark
          ? Colors.white.withValues(alpha: 0.18)
          : Colors.white.withValues(alpha: 0.5));
  final fill = (budget == null || solid) ? bg : surfaceFillWithBudget(bg, budget);
  final scale = frostedScale ?? 1.0;
  final sigma = budget == null
      ? 8.0 * scale
      : surfaceBlurSigma(base: 8 * scale, budget: budget, type: surfaceType);
  final surface = Container(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: border),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.2),
          blurRadius: 26,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: child,
  );
  if (solid) return surface;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      // 比普通毛玻璃（10/14）更淡，配合透明底呈现液态通透感；按预算缩放。
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: surface,
    ),
  );
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
