import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'blur_budget.dart';

/// 从设置读取当前毛玻璃档位（low/medium/high 语义映射）。
FrostedGlassLevel frostedGlassLevelSetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.frostedGlassLevel ??
        FrostedGlassLevel.strongest));

/// 是否处于「壁纸模式」：启用自定义壁纸时，所有玻璃表面控件统一抽掉实色底，
/// 改为**全透明 + 无模糊**，让壁纸直接透出（不铺磨砂）。
bool wallpaperGlassActive(WidgetRef ref) =>
    ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.customBackground.active ?? false));

/// 壁纸模式下「普通玻璃表面（卡片/搜索框/列表条/悬浮胶囊等）」的反色色块底。
///
/// 原先是全透明（0x00000000）让壁纸完全透出——组件在复杂壁纸上不可辨、文字
/// 难读；现改为根据字体档位取反色基色、按 `customBackground.widgetAlpha`
/// （0~90，0=完全透明）控制不透明度的色块：选亮色字体→深色块、选暗色字体→
/// 浅色块（默认 30%）。供所有透明组件/玻璃表面与 [appCardFill] 组件统一使用，
/// 替换"全部透明组件"。
Color wallpaperBlockFill(BuildContext context, WidgetRef ref) {
  final cb =
      ref.watch(settingsProvider.select((s) => s.valueOrNull?.customBackground));
  final alpha = ((cb?.widgetAlpha ?? 30).clamp(0, 90)) / 100.0;
  if (alpha <= 0) return const Color(0x00000000);
  // 反色判断：字体是否为深色（暗字→浅色块；亮字→深色块）。
  final darkish = cb?.textMode == WallpaperTextColor.dark ||
      (cb?.textMode == WallpaperTextColor.follow &&
          Theme.of(context).brightness == Brightness.light);
  final base =
      darkish ? const Color(0xFFFFFFFF) : const Color(0xFF202020);
  return base.withValues(alpha: alpha);
}

/// 壁纸模式下「普通玻璃表面」的 fill：统一走反色色块（[wallpaperBlockFill]），
/// 不再全透明（避免组件在壁纸上隐没）。
Color wallpaperGlassFill(BuildContext context, WidgetRef ref) =>
    wallpaperBlockFill(context, ref);

/// 壁纸模式下「顶栏 / 固定底栏 / 迷你播放条」的 fill：保持半透明磨砂（薄纱），
/// 配合固定的最深模糊（[kNavSurfaceBlurSigma]）维持磨砂观感——顶/底栏、播放条
/// 在壁纸模式下**模糊保持与原样一致、不透明化**，壁纸透出但仍有玻璃质感。
///
/// 透明度的底线：原先暗色仅 5%、亮色 19%，叠在「带深色遮罩」的壁纸背上几乎
/// 等于黑色（尤以迷你播放条常见「毛玻璃发黑」）。故量值适当提高，确保任何
/// 壁纸上都渲染为可见的半透明磨砂、而非沉成黑色。
Color wallpaperNavGlassFill(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0x26FFFFFF) : const Color(0x4CFFFFFF);
}

/// 浮动导航胶囊（迷你播放条 / 悬浮底栏 / 悬浮顶栏等）的投影。
///
/// 常规（非壁纸）模式下：浮动即「胶囊 + 黑色投影」（该形态设计本体），仅贴边
/// 固定的顶/底栏无投影。但在**壁纸模式**下这些胶囊 fill 是半透明磨砂
/// （[wallpaperNavGlassFill]，~30% 白），黑色投影会透过半透明胶囊透显出来、
/// 整根胶囊看着像黑色块（固定顶/底栏贴边无投影所以正常）。故壁纸模式下去掉
/// 投影，仅靠描边 + 模糊维持浮层层次，避免「胶囊本身黑」。
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

/// 壁纸模式下「普通玻璃表面」的模糊 sigma：归零，不做任何高斯模糊（直接透明）。
double wallpaperGlassSigma(BuildContext context) => 0.0;

/// 毛玻璃模糊强度档位 → sigma 缩放系数。
/// strongest = 1.0（当前默认，观感最强）/ medium = 0.6 / light = 0.4。
/// 该缩放仅作用于非导航类毛玻璃表面（迷你播放条、播放面板等）；
/// 顶栏、底栏、横屏侧栏等导航表面保持各自固定模糊度，不受档位影响。
/// 轻度档曾用 0.16（sigma≈2.6），经降采样模糊（内部再 ÷4 采样）后实际
/// 小图 sigma 仅 0.64，模糊完全不可感知、与纯半透明色块无差别；现提到
/// 0.4（sigma≈6.4）——仍是最通透档位，但「带点模糊」肉眼可辨。
double frostedBlurScaleOf(FrostedGlassLevel l) => switch (l) {
      FrostedGlassLevel.strongest => 1.0,
      FrostedGlassLevel.medium => 0.6,
      FrostedGlassLevel.light => 0.4,
    };

/// 固定式导航表面（顶栏、固定底栏）的统一模糊 sigma。
///
/// 固定且取最深（16，等同「毛玻璃」最强档），**不跟随「毛玻璃强度」档位**
/// 也不随滚动/转场预算缩放；壁纸模式与常规模式一致。强度档只作用于非导航
/// 表面（卡片、迷你播放条、面板等）。
const double kNavSurfaceBlurSigma = 16.0;

/// 当前毛玻璃 sigma（页面级玻璃表面统一入口）：完全跟随「毛玻璃」档位，
/// 滑动/停止/转场三态恒定一致、**不缩档**——转场掉帧改由
/// [RouteStaticSnapshot] 整页快照平移承担，不再用缩减模糊强度换取流畅
/// （不牺牲效果）。
double frostedBlurSigma(WidgetRef ref) => 16 * frostedBlurScale(ref);

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
  final wallpaper = wallpaperGlassActive(ref);
  // 壁纸模式下毛玻璃的观感由「毛玻璃」开关决定：开启则按用户档位渲染玻璃，
  // 关闭才回退全透明透出壁纸（不再由壁纸模式强制覆盖）。
  final frostedOn = ref.watch(settingsProvider.select(
      (s) => s.valueOrNull?.frostedGlass ?? false));
  final wallpaperTransparent = wallpaper && !frostedOn;
  final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final frostedFill = isDark
      ? Colors.white.withValues(alpha: 0.10)
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
  // 模糊度跟随「毛玻璃」档位：滑动/停止三态 sigma 恒定一致，仅转场瞬间
    // 临时缩档防整页掉帧（见 frostedBlurSigma）。降采样模糊（cheapBackdropBlur）
    // 把高斯工作量降为 1/16 控制成本。
  final sigma = wallpaperTransparent
      ? wallpaperGlassSigma(context)
      : frostedBlurSigma(ref);
  // 壁纸模式且毛玻璃关闭：sigma=0、fill=全透明，直接透出壁纸（仅保留描边）。
  if (sigma <= 0) return surface;
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

/// 搜索框底色（随顶栏模糊状态联动）：
/// - 固定顶栏处于模糊态（毛玻璃开启）→ 完全透明，把搜索框「镂空」出来，
///   直接透出顶栏的磨砂模糊（不再用实色块盖住）；
/// - 固定顶栏纯色态（毛玻璃关闭 / 低性能）→ 固定对比色（[contrastSearchColor]），
///   与不透明的顶栏形成明暗对比；
/// - 壁纸模式 → 参考本地页顶栏搜索框（[LibraryPage] 的 8% 半透明白/黑填充），
///   用淡半透明底让搜索框在壁纸上直接显示出来（不再全透明隐没进壁纸）。
/// 所有带搜索框的页面（首页/我的/搜索页/结果页/设置页/横屏顶栏等）统一走本函数。
Color searchBoxFill(BuildContext context, WidgetRef ref) {
  if (wallpaperGlassActive(ref)) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0x14FFFFFF) : const Color(0x14000000);
  }
  return glassShouldUseSolid(ref, lowPerf: false)
      ? contrastSearchColor(context)
      : const Color(0x00000000);
}

/// 从设置读取当前液态玻璃效果档位（原始 low/medium/high）。
LiquidGlassQuality liquidGlassQualitySetting(WidgetRef ref) => ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.liquidGlassQuality ??
        LiquidGlassQuality.medium));

/// BiliPai 化液态玻璃折射强度（边缘透镜最大位移）按档位映射。
/// **逐值对齐官方 LiquidGlassTuning.kt**：refractionAmount =
/// midpointLerp(24, 24, 8, progress) → CLEAR 24 / BALANCED 24 / FROSTED 8。
/// （此前自行配平成 24/20/12 又回滚：BiliPai 三档差异本就主要靠模糊与
/// 底色/白 overlay 体现，折射恒定 24 正是它 CLEAR≈BALANCED 的原味。）
/// 逻辑像素 = BiliPai refractionAmount（64dp dock 名义 24dp），剖面为原版
/// circleMap 圆弧曲线。
double bilipaiRefractOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 24.0,
      LiquidGlassQuality.medium => 24.0,
      LiquidGlassQuality.high => 8.0,
    };

/// BiliPai 化液态玻璃色差强度按档位映射。
/// 官方口径：**shell 恒为无色差**（"Miuix keeps the 24dp shell achromatic"），
/// 0.5 的色散只给移动的**水滴指示器**（UPSTREAM_INDICATOR_CHROMATIC_ABERRATION
/// = 0.5，且 CLEAR 档 allowChromaticAberration=false）。水滴色差见
/// [bilipaiIndicatorChromaOf]。
double bilipaiChromaOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.0,
      LiquidGlassQuality.high => 0.0,
    };

/// BiliPai 化液态玻璃预乘混合底色：对齐原版 FloatingDockChrome 的
/// `surfaceColor = 主题 surfaceContainer × surfaceAlpha`（clear/balanced
/// 0.40，frosted 0.54）——亮色为白；暗色原版是暗色 surfaceContainer，
/// 即深灰烟熏玻璃（此前暗色用白色 0.26 薄纱，透明度过高且发灰）。
Color bilipaiGlassTint(bool isDark, LiquidGlassQuality quality) {
  // **逐值对齐官方 LiquidGlassTuning.kt**：surfaceAlpha =
  // midpointLerp(0.40, 0.40, 0.54, progress) → 0.40 / 0.40 / 0.54。
  final a = switch (quality) {
    LiquidGlassQuality.low => 0.40,
    LiquidGlassQuality.medium => 0.40,
    LiquidGlassQuality.high => 0.54,
  };
  return isDark
      ? Color.fromARGB((a * 255).round(), 0x26, 0x26, 0x2A)
      : Color.fromARGB((a * 255).round(), 0xFF, 0xFF, 0xFF);
}

/// BiliPai 化液态玻璃表面流动高光强度（滚动时在玻璃上扫过的反光带）。
/// 全档真液态：低档轻量高光，中/高档渐强。
double bilipaiSpecularOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.20,
      LiquidGlassQuality.medium => 0.38,
      LiquidGlassQuality.high => 0.55,
    };

/// BiliPai 化液态玻璃背景模糊半径（逻辑像素）按档位映射。
/// **逐值对齐官方 LiquidGlassTuning.kt**：backdropBlurRadius =
/// midpointLerp(0, 4, 24, progress) → CLEAR 0（水晶玻璃，「液态感」核心）/
/// BALANCED 4dp（原版默认档）/ FROSTED 24dp（重磨砂）。
double bilipaiBackdropBlurOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 4.0,
      LiquidGlassQuality.high => 24.0,
    };

/// BiliPai 化液态玻璃边缘透镜折射幅度（逻辑像素）按档位映射。
/// **逐值对齐官方 LiquidGlassTuning.kt**：refractionHeight =
/// midpointLerp(24, 24, 8, progress) → 24 / 24 / 8。剖面为原版 circleMap，
/// 位移集中在贴边 1/2 带内（半带处仅 ~13%），不会「还没靠近就弯」；
/// 小表面另有 0.42×短边安全钳制。
double bilipaiEdgeOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 24.0,
      LiquidGlassQuality.medium => 24.0,
      LiquidGlassQuality.high => 8.0,
    };

/// BiliPai 化液态玻璃饱和度增益按档位映射。
/// **逐值对齐官方 LiquidGlassTuning.kt**：saturation =
/// midpointLerp(1.5, 1.5, 1.24, progress) → 1.5 / 1.5 / 1.24。
double bilipaiSaturationOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.5,
      LiquidGlassQuality.medium => 1.5,
      LiquidGlassQuality.high => 1.24,
    };

/// —— BiliPai 水滴指示器专属档位（官方 LiquidGlassTuning.kt）——
/// shell 参数之上，水滴指示器另有三组随档位衰减的增强系数：
///   indicatorLensBoost     = midpointLerp(1.35, 1, 0.78)  → 折射量
///   indicatorEdgeWarpBoost = midpointLerp(1.40, 1, 0.82)  → 边带/边缘扭曲
///   indicatorChromaticBoost= midpointLerp(1.20, 1, 0.70)  → 色差
/// CLEAR 档水滴折射/边缘最强（1.35/1.40）——低档无模糊全靠透镜水滴撑「液态感」；
/// FROSTED 档收弱（0.78/0.82）避免重磨砂上过度扭曲。

/// 水滴折射量增强按档位映射（官方 indicatorLensBoost 三锚点）。
double bilipaiIndicatorLensBoostOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.35,
      LiquidGlassQuality.medium => 1.0,
      LiquidGlassQuality.high => 0.78,
    };

/// 水滴边带/边缘扭曲增强按档位映射（官方 indicatorEdgeWarpBoost 三锚点）。
double bilipaiIndicatorEdgeBoostOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 1.40,
      LiquidGlassQuality.medium => 1.0,
      LiquidGlassQuality.high => 0.82,
    };

/// 水滴色差强度按档位映射。官方：色散只给水滴不给 shell，
/// 上限 UPSTREAM_INDICATOR_CHROMATIC_ABERRATION = 0.5；CLEAR 档
/// allowChromaticAberration=false → 0（无色差，保持水晶纯净）。
double bilipaiIndicatorChromaOf(LiquidGlassQuality q) => switch (q) {
      LiquidGlassQuality.low => 0.0,
      LiquidGlassQuality.medium => 0.5,
      LiquidGlassQuality.high => 0.5,
    };

/// 玻璃表面是否回退为「高不透明度纯色」（关闭毛玻璃 / 低性能模式）。
///
/// 规则：低性能模式始终纯色；其余完全跟随「毛玻璃」设置（`frostedGlass`）——
/// 关闭则纯色、开启则透明磨砂。壁纸模式与普通模式共用同一套判断（壁纸只
/// 是替换底色，不改变玻璃开关行为）。供所有玻璃表面（顶栏/底栏/播放条/
/// 播放页卡）统一判断，避免各处重复口径。
bool glassShouldUseSolid(WidgetRef ref, {required bool lowPerf}) {
  if (lowPerf) return true;
  // 壁纸透明孔模式：始终走极淡磨砂，不回退纯色（实色底板会盖住壁纸）。
  if (wallpaperGlassActive(ref)) return false;
  // 只 select frostedGlass 字段：本函数被所有玻璃表面调用，若 watch 整个
  // settingsProvider，设置页任意开关变化都会让全部玻璃表面重建重绘。
  return !(ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.frostedGlass)) ??
      true);
}

/// 底栏/悬浮顶栏显隐动画窗口开关：二级页进出（navBarHidden 计数切换）时这些
/// 玻璃表面要经过 Opacity/Scale 动画，BackdropFilter 处于透明度动画层内背板
/// 采样会渲染成黑帧（表现为「返回一级时玻璃黑一下再加载」）。动画窗口内置
/// true，相关表面强制纯色铺底，动画结束后恢复毛玻璃。仅在竖屏由壳层驱动。
final chromeGlassSettlingProvider = StateProvider<bool>((ref) => false);

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
/// 1/downscale²（4x 时 1/16）。**downscale 自适应**（见 [_resolveBlurDownscale]）：
/// 小 sigma 时降采样会把模糊稀释到不可见（4dp÷4=1px，放大后几乎纯色，
/// 与零模糊的轻度档无法区分），必须走全分辨率才对得起 BiliPai 的真高斯观感。
/// filter 按 (sigma, downscale) 缓存复用。
final Map<String, ImageFilter> _cheapBlurCache = <String, ImageFilter>{};

/// 按目标 sigma 选择降采样倍率：保证小图上的等效模糊 ≥ ~5px（缩放回去后
/// 糊感不流失）。sigma ≥ 20 → 1/4（省 16 倍）；≥ 10 → 1/2；更小全分辨率。
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

/// 非缓存变体：每次新建 filter 实例（组合结构相同）。
///
/// 用于液态玻璃拖拽场景：Impeller 对 BackdropFilterLayer 的背板快照可能按
/// filter 实例命中缓存，复用全局缓存的同一 filter 对象时，玻璃平移（层
/// 实例已每帧新建）仍可能读到拖拽起点的旧背板——折射采样停在旧位置，
/// 「拖拽时折射效果留在原地/不明显」的根因之一。拖拽期间每帧新建实例
/// 强制重新抓背板，拖拽结束回到缓存路径，无常态开销。
ImageFilter cheapBackdropBlurFresh(double sigma, {int? downscale}) =>
    _composeCheapBlur(sigma, downscale ?? _resolveBlurDownscale(sigma));

ImageFilter _composeCheapBlur(double sigma, int downscale) {
  final d = downscale.toDouble();
  return ImageFilter.compose(
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

/// 伪液态毛玻璃表面（液态玻璃关闭时的毛玻璃回退实现）。
///
/// 借用毛玻璃档位缩放（frostedBlurScaleOf）做「透明底 + 淡模糊」表面：
/// 低性能模式 → 高不透明度纯色回退。传入 [budget] 时按全局 blur 预算动态
/// 缩放 sigma、并用铺底透明度补偿（滚动/转场期间降级，接入统一预算策略）。
/// 液态玻璃开启时不再走这里（全档真液态 shader）。
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
  // 毛玻璃「轻度」档缩放（0.4，见 frostedBlurScaleOf）。
  double? frostedScale,
  // true 时无视玻璃设置直接纯色铺底（跳过 BackdropFilter/shader）。
  // 用于底栏/悬浮顶栏的显隐动画窗口：BackdropFilter 处于 Opacity 动画层内
  // 背板采样会渲染成黑帧（「玻璃黑一下再加载」），动画期间强制纯色。
  bool forceSolid = false,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = wallpaperGlassActive(ref);
  // 壁纸模式是否回退透明（仅当「毛玻璃」关闭）：开启则按档位渲染玻璃，
  // 关闭时仅导航类表面保留极淡磨砂，其余表面全透明透出壁纸。
  final frostedOn = ref.watch(settingsProvider.select(
      (s) => s.valueOrNull?.frostedGlass ?? false));
  final wallTransparent = wallpaper && !frostedOn;
  final solid = forceSolid || glassShouldUseSolid(ref, lowPerf: lowPerf);
  // 壁纸模式：导航类表面（顶栏 header、底栏/迷你播放条 bottomBar、顶栏液态
  // 胶囊等）恒定极淡半透明磨砂（wallpaperNavGlassFill + 最深固定模糊），与
  // GlassTopBar 一致、不随「毛玻璃」开关变化——壁纸仍透出但有玻璃质感；其余
  // 表面在毛玻璃关闭时才全透明透出壁纸，开启则按用户档位正常渲染玻璃。
  final navSurface = surfaceType == BlurSurfaceType.header ||
      surfaceType == BlurSurfaceType.bottomBar;
  final wallpaperNav = wallpaper && navSurface;
  final bg = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
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
      boxShadow: navFloatShadows(context, ref),
    ),
    child: child,
  );
  if (solid) return surface;
  // 壁纸模式 sigma=0、fill=全透明：不铺任何模糊，直接透出壁纸（仅保留描边）。
  if (sigma <= 0) return surface;
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
