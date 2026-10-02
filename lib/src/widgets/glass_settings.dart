import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../theme/theme_tint.dart';
import 'blur_budget.dart';

FrostedGlassLevel frostedGlassLevelSetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.frostedGlassLevel ??
        FrostedGlassLevel.light));

bool wallpaperGlassActive(WidgetRef ref) =>
    ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.customBackground.active ?? false));

/// 材质是否实际在渲染：毛玻璃或液态玻璃任一开启且未开性能优先。
/// 离屏缓存（路由快照/chrome 缓存帧/液态预烘焙）与渲显分离（0.01 保底
/// 绘制等玻璃管线配套技术）只在该状态下启用；实底与纯壁纸色块直接
/// 渲染，无 backdrop 采样，无需任何保底
bool glassMaterialActive(WidgetRef ref) {
  if (ref.watch(settingsProvider.select(
      (s) => performancePriority(s.valueOrNull ?? const AppSettings())))) {
    return false;
  }
  return ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.frostedGlass ?? false)) ||
      ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.liquidGlass ?? false));
}

Color wallpaperBlockFill(BuildContext context, WidgetRef ref) {
  final cb =
      ref.watch(settingsProvider.select((s) => s.valueOrNull?.customBackground));
  final alpha = ((cb?.widgetAlpha ?? 30).clamp(0, 90)) / 100.0;
  if (alpha <= 0) return const Color(0x00000000);
  final darkish = cb?.textMode == WallpaperTextColor.dark ||
      (cb?.textMode == WallpaperTextColor.follow &&
          Theme.of(context).brightness == Brightness.light);
  final base =
      darkish ? const Color(0xFFFFFFFF) : const Color(0xFF202020);
  return base.withValues(alpha: alpha);
}

Color wallpaperGlassFill(BuildContext context, WidgetRef ref) =>
    wallpaperBlockFill(context, ref);

List<BoxShadow> navFloatShadows(BuildContext context, WidgetRef ref) {
  if (wallpaperGlassActive(ref)) return const [];
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.2),
      blurRadius: 26,
      offset: const Offset(0, 8),
    ),
  ];
}

double wallpaperGlassSigma(BuildContext context) => 0.0;

double frostedBlurScaleOf(FrostedGlassLevel l) => switch (l) {
      // 旧档位（1.0/0.6/0.4）整体偏重，以原轻档 0.4 为新重档下压
      FrostedGlassLevel.strongest => 0.4,
      FrostedGlassLevel.medium => 0.28,
      FrostedGlassLevel.light => 0.18,
    };

/// 壁纸模式下导航类表面的基础 sigma，实际值随毛玻璃档位缩放
const double kNavSurfaceBlurSigma = 16.0;

/// 共享 backdrop 回读组：同 key 的 BackdropFilter 由引擎合并为单次
/// 模糊+回读（要求成员 sigma 相同且屏幕区域互不重叠）。毛玻璃下顶栏/
/// 底栏/播放条逐帧各做一次全宽 backdrop 回读是转场逐帧掉帧主源，
/// 合并后每帧 N 次回读降为 1 次
final BackdropKey navGlassKey = BackdropKey();

/// 卡片级毛玻璃共享组（frostedCardSurface 非壁纸档恒 8*档位，
/// 列表卡片互不重叠）
final BackdropKey cardGlassKey = BackdropKey();

/// 导航面（悬浮导航/mini 播放条/appbar 等）随档位缩放的模糊强度
double navSurfaceBlurSigma(WidgetRef ref) =>
    kNavSurfaceBlurSigma * frostedBlurScaleOf(frostedGlassLevelSetting(ref));

double frostedBlurSigma(WidgetRef ref) => 16 * frostedBlurScale(ref);

double frostedBlurScale(WidgetRef ref) =>
    frostedBlurScaleOf(frostedGlassLevelSetting(ref));

Widget frostedCardSurface({
  required BuildContext context,
  required WidgetRef ref,
  required double radius,
  required Widget child,
  String? themeSlot,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = wallpaperGlassActive(ref);
  final frostedOn = ref.watch(settingsProvider.select(
      (s) => s.valueOrNull?.frostedGlass ?? false));
  final wallpaperTransparent = wallpaper && !frostedOn;
  // 毛玻璃关恢复实底兜底(回归修复):非壁纸时白0.34+弱blur 读作透底;
  // 壁纸模式不 solid,恒走组件色块滑条(避免毛玻璃关时短路组件底色)
  final solid = !wallpaper && !frostedOn;
  final frostedFill = isDark
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.white.withValues(alpha: 0.34);
  final baseFill = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
      : (wallpaperTransparent
          ? wallpaperGlassFill(context, ref)
          : frostedFill);
  final fill =
      themeSlot == null ? baseFill : themeTint(ref, themeSlot, baseFill);
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
  // 转场期间路由内容已由 RouteStaticSnapshot 冻结为快照，
  // 玻璃保持全量模糊即可呈现「最后一帧」的静止观感
  final sigma = wallpaperTransparent
      ? wallpaperGlassSigma(context)
      : 8.0 * frostedBlurScale(ref);
  if (solid) return surface;
  if (sigma <= 0) return surface;
  // 滚动档不降载：live backdrop 上矩阵降采样链在 Impeller 渲染异常
  // （滚动中模糊失效读作变透明），且毛玻璃 sigma 小、模糊开销∝σ²，
  // 恒用与静置一致的普通 blur 保证观感稳定
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      backdropGroupKey: cardGlassKey,
      child: surface,
    ),
  );
}

Color contrastSearchColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xE62A2A2E)
        : const Color(0xF0FFFFFF);

Color searchBoxFill(BuildContext context, WidgetRef ref) {
  final Color base;
  if (wallpaperGlassActive(ref)) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    base = isDark ? const Color(0x14FFFFFF) : const Color(0x14000000);
  } else {
    base = glassShouldUseSolid(ref, lowPerf: false)
        ? contrastSearchColor(context)
        : const Color(0x00000000);
  }
  return themeTint(ref, 'search.box', base);
}

LiquidGlassQuality liquidGlassQualitySetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.liquidGlassQuality ??
        LiquidGlassQuality.medium));

double bilipaiRefractOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 24.0,
      LiquidGlassQuality.medium => 24.0,
      LiquidGlassQuality.high => 24.0,
    };

double bilipaiChromaOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.0,
      LiquidGlassQuality.high => 0.0,
    };

Color bilipaiGlassTint(bool isDark, LiquidGlassQuality quality) {
  final a = switch (quality) {
    LiquidGlassQuality.low => 0.40,
    LiquidGlassQuality.medium => 0.40,
    LiquidGlassQuality.high => 0.40,
  };
  return isDark
      ? Color.fromARGB((a * 255).round(), 0x26, 0x26, 0x2A)
      : Color.fromARGB((a * 255).round(), 0xFF, 0xFF, 0xFF);
}

Color bilipaiSurfaceTint(BuildContext context, WidgetRef ref,
        LiquidGlassQuality quality) =>
    wallpaperGlassActive(ref)
        // 壁纸模式组件色块：跟随设置的组件色块强度（widgetAlpha）与文字
        // 模式底色，与其他壁纸组件口径一致；此前误用导航面固定强度，
        // 导致组件色块设置在液态组件上无效（恒为满强度）
        ? wallpaperGlassFill(context, ref)
        : bilipaiGlassTint(
            Theme.of(context).brightness == Brightness.dark, quality);

double bilipaiSpecularOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.20,
      LiquidGlassQuality.medium => 0.29,
      LiquidGlassQuality.high => 0.38,
    };

double bilipaiBackdropBlurOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.5,
      LiquidGlassQuality.medium => 2.1,
      LiquidGlassQuality.high => 2.75,
    };

double bilipaiEdgeOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 24.0,
      LiquidGlassQuality.medium => 24.0,
      LiquidGlassQuality.high => 24.0,
    };

double bilipaiSaturationOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.5,
      LiquidGlassQuality.medium => 1.5,
      LiquidGlassQuality.high => 1.5,
    };

double bilipaiIndicatorLensBoostOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.35,
      LiquidGlassQuality.medium => 1.18,
      LiquidGlassQuality.high => 1.0,
    };

double bilipaiIndicatorEdgeBoostOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.40,
      LiquidGlassQuality.medium => 1.20,
      LiquidGlassQuality.high => 1.0,
    };

double bilipaiIndicatorChromaOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.25,
      LiquidGlassQuality.high => 0.5,
    };

bool glassShouldUseSolid(WidgetRef ref, {required bool lowPerf}) {
  if (lowPerf) return true;
  // 壁纸模式下转场还原首帧的采样黑闪由 BiliPaiGlass 的预烘焙图续展
  // （_startTransitionResume）兜住，不再用实底热身切换材质（暗色下
  // 实底本身读作「黑一下再出玻璃」）
  return !(ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.frostedGlass)) ??
      false);
}

/// 转场中快照图是否正以 1.0 不透明度覆盖 backdrop：
/// 就绪时玻璃 shader 采样 backdrop 是安全的（内容=快照图），
/// 未就绪窗口（抓取中/失败）采样≈0.01 透明 live 层≈无内容（黑）
final ValueNotifier<bool> globalSnapshotReady = ValueNotifier<bool>(false);

final Map<double, ImageFilter> _blurFilterCache = <double, ImageFilter>{};
ImageFilter cachedBlur(double sigma) {
  final hit = _blurFilterCache[sigma];
  if (hit != null) return hit;
  if (_blurFilterCache.length > 32) _blurFilterCache.clear();
  return _blurFilterCache[sigma] =
      ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
}

final Map<String, ImageFilter> _cheapBlurCache = <String, ImageFilter>{};

int _resolveBlurDownscale(double sigma) {
  if (sigma >= 20) return 4;
  if (sigma >= 10) return 2;
  return 1;
}

ImageFilter cheapBackdropBlur(double sigma, {int? downscale}) {
  final d = downscale ?? _resolveBlurDownscale(sigma);
  final key = '$sigma/$d';
  final hit = _cheapBlurCache[key];
  if (hit != null) return hit;
  if (_cheapBlurCache.length > 64) _cheapBlurCache.clear();
  return _cheapBlurCache[key] = _composeCheapBlur(sigma, d);
}

ImageFilter cheapBackdropBlurFresh(double sigma, {int? downscale}) =>
    _composeCheapBlur(sigma, downscale ?? _resolveBlurDownscale(sigma));

ImageFilter _composeCheapBlur(double sigma, int downscale) {
  final d = downscale.toDouble();
  return ImageFilter.compose(
    outer: ImageFilter.matrix(Matrix4.diagonal3Values(d, d, 1).storage),
    inner: ImageFilter.compose(
      outer: ImageFilter.blur(sigmaX: sigma / d, sigmaY: sigma / d),
      inner: ImageFilter.matrix(Matrix4.diagonal3Values(1 / d, 1 / d, 1).storage),
    ),
  );
}

Widget pseudoLiquidSurface({
  required BuildContext context,
  required WidgetRef ref,
  required double radius,
  required Widget child,
  BlurSurfaceType surfaceType = BlurSurfaceType.generic,
  BlurBudget? budget,
  double? frostedScale,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = wallpaperGlassActive(ref);
  final frostedOn = ref.watch(settingsProvider.select(
      (s) => s.valueOrNull?.frostedGlass ?? false));
  final wallTransparent = wallpaper && !frostedOn;
  final navSurface = surfaceType == BlurSurfaceType.header ||
      surfaceType == BlurSurfaceType.bottomBar;
  final wallpaperNav = wallpaper && navSurface;
  // 毛玻璃关恢复实底兜底(回归修复):白0.34+弱blur 在浅色页面上读作透底;
  // 壁纸模式不 solid,恒走组件色块滑条(widgetAlpha 驱动),导航面差异只在
  // blur(navSurfaceBlurSigma 档位缩放)
  final solid = !wallpaper && !frostedOn;
  final bg = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
      : (wallTransparent
          ? wallpaperGlassFill(context, ref)
          : (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.34)));
  final borderColor = isDark
      ? Colors.white.withValues(alpha: 0.18)
      : Colors.white.withValues(alpha: 0.5);
  final fill = (budget == null || solid || wallpaper) ? bg : surfaceFillWithBudget(bg, budget);
  final scale = frostedScale ?? frostedBlurScaleOf(FrostedGlassLevel.light);
  // 转场期间路由内容已由 RouteStaticSnapshot 冻结为快照，
  // 玻璃保持全量模糊即可呈现「最后一帧」的静止观感
  final sigma = wallpaperNav
      ? navSurfaceBlurSigma(ref)
      : wallTransparent
          ? wallpaperGlassSigma(context)
          : (budget == null
              ? 8.0 * scale
              : surfaceBlurSigma(
                  base: 8 * scale, budget: budget, type: surfaceType));
  final surface = Container(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      border: solid ? null : Border.all(color: borderColor),
      boxShadow: surfaceType == BlurSurfaceType.header
          ? const []
          : navFloatShadows(context, ref),
    ),
    child: child,
  );
  if (solid) return surface;
  if (sigma <= 0) return surface;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: surface,
    ),
  );
}

