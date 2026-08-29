import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'blur_budget.dart';

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

/// 伪毛玻璃卡片：页面内容上的圆角玻璃卡片（首页统计/每日推荐/榜单占位/
/// 听过最多 等）。
///
/// 与全局毛玻璃开关、强度档位联动：
/// - 毛玻璃开 → 半透明白 + 高斯模糊（sigma=16×档位缩放），半透出背景/壁纸
/// - 毛玻璃关 / 低性能 → 高不透明度纯色（无 BackdropFilter，零模糊开销）
///
/// 壁纸模式与普通模式共用同一套判断（壁纸只是替换底色，卡片样式不区分）。
Widget frostedCardSurface({
  required BuildContext context,
  required WidgetRef ref,
  required double radius,
  required Widget child,
  bool lowPerf = false,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final fill = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
      : (isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.52));
  final border = solid
      ? null
      : Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.40),
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

  // 响应转场与滚动时的全局 blur 预算：转场/滚动时卡片高斯模糊降级，
  // 避免多个 BackdropFilter 在位移运动时造成 GPU 帧抓取掉帧卡顿。
  final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.drawerOrSheet));
  final sigma = surfaceBlurSigma(
    base: 16 * frostedBlurScale(ref),
    budget: budget,
    type: BlurSurfaceType.drawerOrSheet,
  );

  if (sigma <= 0.1) return surface;

  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
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

/// 从设置读取当前液态玻璃效果档位（原始 low/medium/high）。
LiquidGlassQuality liquidGlassQualitySetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.liquidGlassQuality ??
        LiquidGlassQuality.medium));

/// BiliPai 化液态玻璃折射强度（滚动波浪位移幅度）按档位映射：
/// medium 更收敛 / high 接近 BiliPai 默认。low 走伪液态毛玻璃不经 shader。
double bilipaiRefractOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.10,
      LiquidGlassQuality.medium => 0.17,
      LiquidGlassQuality.high => 0.24,
    };

/// BiliPai 化液态玻璃色差强度（RGB 通道分离幅度）按档位映射。
/// 已全档归零：色差会在亮色内容上产生彩色重影，观感刺眼（用户反馈）；
/// 保留参数位便于日后微调。
double bilipaiChromaOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.0,
      LiquidGlassQuality.high => 0.0,
    };

/// BiliPai 化液态玻璃预乘混合底色：对齐原版 FloatingDockChrome 的
/// `surfaceColor = 主题 surfaceContainer × surfaceAlpha`（balanced 0.40）——
/// 亮色为白 0.40；暗色原版是暗色 surfaceContainer，即深灰烟熏玻璃
/// （此前暗色用白色 0.26 薄纱，透明度过高且发灰）。
Color bilipaiGlassTint(bool isDark) => isDark
    ? const Color(0x6626262A)
    : const Color(0x66FFFFFF);

/// BiliPai 化液态玻璃表面流动高光强度（滚动时在玻璃上扫过的反光带）。
/// low 走伪液态不经 shader；中/高档映射高光强度。
double bilipaiSpecularOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.38,
      LiquidGlassQuality.high => 0.55,
    };

/// BiliPai 化液态玻璃边缘透镜折射幅度（逻辑像素）按档位映射。
/// 固定厚度边带内 edge² 二次衰减、外向位移，把玻璃外的内容拉进边缘一圈，
/// 形成可见的液态折射环；low 走伪液态毛玻璃不经 shader。
double bilipaiEdgeOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      // 中间是 σ8 真高斯的柔和梯度，边缘折射要弯得够深（12-16 逻辑像素）
      // 才能在磨砂上看出「拉出弯折」的液态圈。
      LiquidGlassQuality.medium => 12.0,
      LiquidGlassQuality.high => 16.0,
    };

/// BiliPai 化液态玻璃饱和度增益按档位映射。
/// 原版 balanced 档 saturation 1.5（水晶透亮感核心），frosted 档 1.24。
double bilipaiSaturationOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.0,
      LiquidGlassQuality.medium => 1.45,
      LiquidGlassQuality.high => 1.5,
    };

/// 玻璃表面是否回退为「高不透明度纯色」（关闭毛玻璃 / 低性能模式）。
///
/// 规则：低性能模式始终纯色；其余完全跟随「毛玻璃」设置（`frostedGlass`）——
/// 关闭则纯色、开启则透明磨砂。壁纸模式与普通模式共用同一套判断（壁纸只
/// 是替换底色，不改变玻璃开关行为）。供所有玻璃表面（顶栏/底栏/播放条/
/// 播放页卡）统一判断，避免各处重复口径。
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
/// 直接借用毛玻璃「轻度」档（frostedBlurScaleOf(light) = 0.16）伪装液态玻璃——
/// 极淡模糊（base 8 × 0.16 ≈ 1.3）+ 透明底，实测观感最像液态玻璃；
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
  // 传入非 null 时，模糊强度跟随指定毛玻璃档位（毛玻璃表面如悬浮搜索框用
  // frostedBlurScale(ref) 跟随用户档位）；不传（液态 low 档伪液态）默认用
  // 毛玻璃「轻度」档 0.16。
  double? frostedScale,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final bg = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
      : (isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.white.withValues(alpha: 0.34));
  final border = isDark
      ? Colors.white.withValues(alpha: 0.18)
      : Colors.white.withValues(alpha: 0.5);
  final fill = (budget == null || solid) ? bg : surfaceFillWithBudget(bg, budget);
  final scale = frostedScale ?? frostedBlurScaleOf(FrostedGlassLevel.light);
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

// 注：BiliPai 液态玻璃表面不再叠加白色描边（glassBorder/_GlassBorderPainter
// 已删）——用户实测白描边观感廉价，边缘感由 shader 内内容感知的 rim 光与
// 边缘透镜折射承担（BiliPai 原版同款）。
