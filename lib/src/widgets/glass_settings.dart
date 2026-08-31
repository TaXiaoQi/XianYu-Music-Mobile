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
  // 接入全局 blur 预算：滚动/转场期间按档位缩 sigma。降采样模糊
  // （cheapBackdropBlur）把模糊工作量降为 1/16，运动期可保持玻璃恒定
  // （RwaS 口径：不跳模糊、无观感跳变），静止后恢复满档 sigma。
  final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.generic));
  final sigma = surfaceBlurSigma(
    base: 16 * frostedBlurScale(ref),
    budget: budget,
    type: BlurSurfaceType.generic,
  );
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: cheapBackdropBlur(sigma),
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

/// BiliPai 化液态玻璃折射强度（边缘透镜最大位移）按档位映射。
double bilipaiRefractOf(LiquidGlassQuality q) => switch (q) {
      // 逻辑像素 = BiliPai refractionAmount（64dp dock 名义 24dp）。剖面已
      // 换成原版 circleMap 圆弧曲线（位移集中在贴边一圈），可以回到原版
      // 位移量级；medium 略收敛适配矮表面。
      LiquidGlassQuality.low => 6.0,
      LiquidGlassQuality.medium => 16.0,
      LiquidGlassQuality.high => 24.0,
    };

/// BiliPai 化液态玻璃色差强度按档位映射。
/// BiliPai shell 恒为无色差（"Miuix keeps the shell achromatic"），全档归零；
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
/// 固定厚度边带内 circleMap 圆弧衰减、SDF 外向位移，把玻璃外的内容拉进
/// 边缘一圈，形成可见的液态折射环；low 走伪液态毛玻璃不经 shader。
double bilipaiEdgeOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      // 边带厚度 = BiliPai refractionHeight（64dp dock 名义 24dp）。剖面换成
      // 原版 circleMap 后位移集中在贴边 1/2 带内（半带处仅 ~13%），带可以
      // 开回原版量级而不「还没靠近就弯」；小表面另有 0.42×短边安全钳制。
      LiquidGlassQuality.medium => 16.0,
      LiquidGlassQuality.high => 24.0,
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
  // 只 select frostedGlass 字段：本函数被所有玻璃表面调用，若 watch 整个
  // settingsProvider，设置页任意开关变化都会让全部玻璃表面重建重绘。
  return !(ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.frostedGlass)) ??
      true);
}

/// 高斯模糊 filter 缓存（渲染一次、保存状态）。
///
/// Impeller 下新建 `ImageFilter` 即新管线对象，玻璃表面随 provider 变化频繁
/// rebuild 时每次新建会反复触发引擎侧重编译/重采样。模糊只由 sigma 决定，
/// 按 sigma 缓存复用同一实例；缓存超上限整体清空防膨胀（sigma 由离散档位
/// ×dpr 组成，实际取值很少）。
final Map<double, ImageFilter> _blurFilterCache = <double, ImageFilter>{};

/// 取（或创建并缓存）[sigma] 对应的高斯模糊 filter。
ImageFilter cachedBlur(double sigma) {
  final hit = _blurFilterCache[sigma];
  if (hit != null) return hit;
  if (_blurFilterCache.length > 32) _blurFilterCache.clear();
  return _blurFilterCache[sigma] =
      ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
}

/// 降采样高斯模糊（借鉴 RwaS/Kyant Backdrop 的 GPU RenderEffect 思路）。
///
/// RwaS 里模糊是 GPU 合成期一次性效果，便宜到可以常驻（运动期不降级、无观感
/// 跳变）。Flutter 的 BackdropFilter 每实例每帧各自捕获背板，模糊按全分辨率
/// 像素算，这是切页掉帧根因。等价优化：先把背板按 1/[downscale] 采样缩小、
/// 在小图上做 sigma/downscale 的模糊、再放大回去——模糊像素工作量降为
/// 1/downscale²（4x 时 1/16），观感与全分辨率高斯几乎无差（模糊本身低频）。
/// filter 按 (sigma, downscale) 缓存复用。
final Map<String, ImageFilter> _cheapBlurCache = <String, ImageFilter>{};

ImageFilter cheapBackdropBlur(double sigma, {int downscale = 4}) {
  final key = '$sigma/$downscale';
  final hit = _cheapBlurCache[key];
  if (hit != null) return hit;
  if (_cheapBlurCache.length > 64) _cheapBlurCache.clear();
  final d = downscale.toDouble();
  return _cheapBlurCache[key] = ImageFilter.compose(
    // 最后一步：把小图模糊结果放大回原尺寸。
    outer: ImageFilter.matrix(Matrix4.diagonal3Values(d, d, 1).storage),
    inner: ImageFilter.compose(
      // 第二步：在小图上做等效模糊（sigma 同步缩小，视觉半径不变）。
      outer: ImageFilter.blur(sigmaX: sigma / d, sigmaY: sigma / d),
      // 第一步：把背板采样缩小到 1/downscale。
      inner: ImageFilter.matrix(Matrix4.diagonal3Values(1 / d, 1 / d, 1).storage),
    ),
  );
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
  // 降采样模糊（cheapBackdropBlur）把运动期模糊成本降为 1/16，玻璃可恒定
  // 渲染（RwaS 口径：运动期不跳模糊、无观感跳变），sigma 仍按预算档位缩放。
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      // 比普通毛玻璃（10/14）更淡，配合透明底呈现液态通透感；按预算缩放。
      filter: cheapBackdropBlur(sigma),
      child: surface,
    ),
  );
}

// 注：BiliPai 液态玻璃表面不再叠加白色描边（glassBorder/_GlassBorderPainter
// 已删）——用户实测白描边观感廉价，边缘感由 shader 内内容感知的 rim 光与
// 边缘透镜折射承担（BiliPai 原版同款）。
