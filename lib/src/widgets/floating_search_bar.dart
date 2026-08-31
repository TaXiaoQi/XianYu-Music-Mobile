import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import 'glass_settings.dart';

/// 首页/我的页「悬浮搜索框」：独立悬浮胶囊，固定悬浮在顶栏下方，不随内容滚动。
///
/// 材质跟随全局玻璃设置：
/// - 液态玻璃开启 → 中/高档走 [AdaptiveGlass]（shader 折射 + 高光，与底栏/迷你条
///   同一套参数），低档走伪液态毛玻璃（不跑 shader）；
/// - 液态玻璃关闭 → 毛玻璃（透明磨砂）/ 纯色回退，口径同底栏 `_frostedGlass`。
class FloatingSearchBar extends ConsumerWidget {
  const FloatingSearchBar({super.key, required this.onTap, this.onRecognize});

  final VoidCallback onTap;

  /// 听歌识曲入口（可选：首页带话筒，我的页不带）。
  final VoidCallback? onRecognize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('搜索歌曲、歌手、专辑'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (onRecognize != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRecognize,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.mic_none,
                      size: 17,
                      color: Color(0xFFEC4141),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // 材质外壳统一走 [FloatingGlassSurface]（与横屏搜索输入框同口径）。
    return FloatingGlassSurface(child: content);
  }
}

/// 悬浮玻璃表面容器：与 [FloatingSearchBar] 完全同一套材质口径（液态 shader /
/// 伪液态毛玻璃 / 毛玻璃 / 纯色回退，BlurSurfaceType.header），供搜索胶囊与
/// 横屏顶栏搜索输入框等 44 高胶囊控件复用，保证形态切换（点击进搜索）时
/// 材质连续不跳变。
class FloatingGlassSurface extends ConsumerWidget {
  const FloatingGlassSurface({super.key, required this.child, this.radius = 22});

  final Widget child;

  /// 视觉圆角：44 高胶囊用 22（半高）。
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));

    if (liquid) {
      // 液态玻璃低档：不跑 shader，用伪液态毛玻璃伪造（透明底 + 淡模糊）。
      if (liquidUseFrosted(ref)) {
        return pseudoLiquidSurface(
          context: context,
          ref: ref,
          radius: radius,
          child: child,
          lowPerf: lowPerf,
          surfaceType: BlurSurfaceType.header,
          budget: budget,
        );
      }
      final quality = liquidGlassQualitySetting(ref);
      return BiliPaiGlass(
        radius: radius,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: 4,
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: bilipaiGlassTint(isDark),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: child,
      );
    }
    // 液态玻璃关闭：毛玻璃/纯色回退，复用伪液态表面口径（透明底 + 淡模糊）。
    // 搜索胶囊是毛玻璃表面，模糊强度跟随毛玻璃档位（frostedBlurScale）。
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: child,
      lowPerf: lowPerf,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
    );
  }
}

/// BiliPai 风格小液态玻璃胶囊/圆钮：跟随全局玻璃设置（液态 shader / 伪液态
/// 毛玻璃 / 毛玻璃 / 纯色），材质口径与 [FloatingSearchBar] 完全一致。
/// 用于顶栏标题、图标按钮等小控件的玻璃包裹（BiliPai 首页顶部按钮观感）。
class BiliPaiPill extends ConsumerWidget {
  const BiliPaiPill({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 20,
  });

  final Widget child;

  /// 为 null 时不可点（无涟漪，等同 disabled）。
  final VoidCallback? onTap;

  /// 视觉圆角：40px 高胶囊/圆钮用 20（半高），搜索胶囊 44 高用 22。
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );

    if (liquid) {
      // 液态玻璃低档：不跑 shader，用伪液态毛玻璃伪造（透明底 + 淡模糊）。
      if (liquidUseFrosted(ref)) {
        return pseudoLiquidSurface(
          context: context,
          ref: ref,
          radius: radius,
          child: content,
          lowPerf: lowPerf,
          surfaceType: BlurSurfaceType.header,
          budget: budget,
        );
      }
      final quality = liquidGlassQualitySetting(ref);
      return BiliPaiGlass(
        radius: radius,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: 4,
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: bilipaiGlassTint(isDark),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: content,
      );
    }
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: content,
      lowPerf: lowPerf,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
    );
  }
}

/// 40×40 圆形玻璃图标按钮（[BiliPaiPill] 包裹），BiliPai 首页顶部按钮观感。
class BiliPaiIconButton extends StatelessWidget {
  const BiliPaiIconButton({
    super.key,
    this.icon,
    this.iconChild,
    this.onTap,
    this.color,
    this.tooltip,
  });

  final IconData? icon;
  final Widget? iconChild;
  final VoidCallback? onTap;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // IconTheme 包裹：内置 Icon 用显式 color/size；iconChild（如自定义 SkinIcon）
    // 不传 color 时也能从 IconTheme 继承按钮标准色与尺寸。
    final iconWidget = SizedBox(
      width: 40,
      height: 40,
      child: IconTheme(
        data: const IconThemeData(size: 20).copyWith(
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: iconChild ??
            Icon(
              icon,
              size: 20,
              color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
    return BiliPaiPill(
      onTap: onTap,
      child: tooltip == null
          ? iconWidget
          : Tooltip(message: tooltip!, child: iconWidget),
    );
  }
}

/// 竖屏悬浮顶部栏（首页/我的页共用）：[标题玻璃胶囊] [搜索胶囊·自适应宽]
/// [右侧玻璃小按钮]。直接悬浮在状态栏下方，取代页面自带的 GlassTopBar 标题行。
class FloatingTopBar extends StatelessWidget {
  const FloatingTopBar({
    super.key,
    required this.title,
    required this.onSearchTap,
    this.onRecognize,
    this.actions = const [],
  });

  /// 标题内容（由调用方传入已带样式文本，胶囊内左对齐垂直居中）。
  final Widget title;

  final VoidCallback onSearchTap;

  /// 听歌识曲入口（可选：首页带话筒）。
  final VoidCallback? onRecognize;

  /// 右侧 [BiliPaiIconButton] 列表。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        BiliPaiPill(
          radius: 20,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              height: 40,
              child: Align(alignment: Alignment.centerLeft, child: title),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FloatingSearchBar(
            onTap: onSearchTap,
            onRecognize: onRecognize,
          ),
        ),
        for (final action in actions) ...[
          const SizedBox(width: 10),
          action,
        ],
      ],
    );
  }
}
