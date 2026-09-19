import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'blur_budget.dart';

FrostedGlassLevel frostedGlassLevelSetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.frostedGlassLevel ??
        FrostedGlassLevel.strongest));

bool wallpaperGlassActive(WidgetRef ref) =>
    ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.customBackground.active ?? false));

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

Color wallpaperNavGlassFill(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0x3DFFFFFF) : const Color(0x6BFFFFFF);
}

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
      FrostedGlassLevel.strongest => 1.0,
      FrostedGlassLevel.medium => 0.6,
      FrostedGlassLevel.light => 0.4,
    };

const double kNavSurfaceBlurSigma = 16.0;

double frostedBlurSigma(WidgetRef ref) => 16 * frostedBlurScale(ref);

double frostedBlurScale(WidgetRef ref) =>
    frostedBlurScaleOf(frostedGlassLevelSetting(ref));

Widget frostedCardSurface({
  required BuildContext context,
  required WidgetRef ref,
  required double radius,
  required Widget child,
  bool lowPerf = false,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = wallpaperGlassActive(ref);
  final frostedOn = ref.watch(settingsProvider.select(
      (s) => s.valueOrNull?.frostedGlass ?? false));
  final wallpaperTransparent = wallpaper && !frostedOn;
  final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final frostedFill = isDark
      ? Colors.white.withValues(alpha: 0.20)
      : Colors.white.withValues(alpha: 0.52);
  final fill = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
      : (wallpaperTransparent
          ? wallpaperGlassFill(context, ref)
          : frostedFill);
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
  final sigma = wallpaperTransparent
      ? wallpaperGlassSigma(context)
      : frostedBlurSigma(ref);
  if (sigma <= 0) return surface;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: cheapBackdropBlur(sigma),
      child: surface,
    ),
  );
}

Color contrastSearchColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xE62A2A2E)
        : const Color(0xF0FFFFFF);

Color searchBoxFill(BuildContext context, WidgetRef ref) {
  if (wallpaperGlassActive(ref)) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0x14FFFFFF) : const Color(0x14000000);
  }
  return glassShouldUseSolid(ref, lowPerf: false)
      ? contrastSearchColor(context)
      : const Color(0x00000000);
}

LiquidGlassQuality liquidGlassQualitySetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.liquidGlassQuality ??
        LiquidGlassQuality.medium));

double bilipaiRefractOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 24.0,
      LiquidGlassQuality.medium => 24.0,
      LiquidGlassQuality.high => 8.0,
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
    LiquidGlassQuality.high => 0.54,
  };
  return isDark
      ? Color.fromARGB((a * 255).round(), 0x26, 0x26, 0x2A)
      : Color.fromARGB((a * 255).round(), 0xFF, 0xFF, 0xFF);
}

Color bilipaiSurfaceTint(BuildContext context, WidgetRef ref,
        LiquidGlassQuality quality) =>
    wallpaperGlassActive(ref)
        ? wallpaperNavGlassFill(context)
        : bilipaiGlassTint(
            Theme.of(context).brightness == Brightness.dark, quality);

double bilipaiSpecularOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.20,
      LiquidGlassQuality.medium => 0.38,
      LiquidGlassQuality.high => 0.55,
    };

double bilipaiBackdropBlurOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.5,
      LiquidGlassQuality.medium => 2.75,
      LiquidGlassQuality.high => 4.0,
    };

double bilipaiEdgeOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 24.0,
      LiquidGlassQuality.medium => 24.0,
      LiquidGlassQuality.high => 8.0,
    };

double bilipaiSaturationOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.5,
      LiquidGlassQuality.medium => 1.5,
      LiquidGlassQuality.high => 1.24,
    };

double bilipaiIndicatorLensBoostOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.35,
      LiquidGlassQuality.medium => 1.0,
      LiquidGlassQuality.high => 0.78,
    };

double bilipaiIndicatorEdgeBoostOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.40,
      LiquidGlassQuality.medium => 1.0,
      LiquidGlassQuality.high => 0.82,
    };

double bilipaiIndicatorChromaOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.5,
      LiquidGlassQuality.high => 0.5,
    };

bool glassShouldUseSolid(WidgetRef ref, {required bool lowPerf}) {
  if (lowPerf) return true;
  if (wallpaperGlassActive(ref)) return false;
  return !(ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.frostedGlass)) ??
      true);
}

final chromeGlassSettlingProvider = StateProvider<bool>((ref) => false);

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
  bool lowPerf = false,
  BlurSurfaceType surfaceType = BlurSurfaceType.generic,
  BlurBudget? budget,
  double? frostedScale,
  bool forceSolid = false,
  bool keepFilter = false,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = wallpaperGlassActive(ref);
  final frostedOn = ref.watch(settingsProvider.select(
      (s) => s.valueOrNull?.frostedGlass ?? false));
  final wallTransparent = wallpaper && !frostedOn;
  final prefSolid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final solid = forceSolid || prefSolid;
  final keepAlive = forceSolid && keepFilter && !prefSolid;
  final navSurface = surfaceType == BlurSurfaceType.header ||
      surfaceType == BlurSurfaceType.bottomBar;
  final wallpaperNav = wallpaper && navSurface;
  final bg = solid
      ? (keepAlive
          ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
          : (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF)))
      : (wallpaperNav
          ? wallpaperNavGlassFill(context)
          : wallTransparent
              ? wallpaperGlassFill(context, ref)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.34)));
  final border = isDark
      ? Colors.white.withValues(alpha: 0.18)
      : Colors.white.withValues(alpha: 0.5);
  final fill = (budget == null || solid || wallpaper) ? bg : surfaceFillWithBudget(bg, budget);
  final scale = frostedScale ?? frostedBlurScaleOf(FrostedGlassLevel.light);
  final sigma = wallpaperNav
      ? kNavSurfaceBlurSigma
      : wallTransparent
          ? wallpaperGlassSigma(context)
          : (budget == null
              ? 8.0 * scale
              : surfaceBlurSigma(base: 8 * scale, budget: budget, type: surfaceType));
  final surface = Container(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: border),
      boxShadow: surfaceType == BlurSurfaceType.header
          ? const []
          : navFloatShadows(context, ref),
    ),
    child: child,
  );
  if (solid && !keepAlive) return surface;
  if (sigma <= 0) return surface;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: cheapBackdropBlur(sigma),
      child: surface,
    ),
  );
}
