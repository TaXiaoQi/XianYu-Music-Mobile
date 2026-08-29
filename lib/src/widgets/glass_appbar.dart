import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'blur_budget.dart';
import 'glass_settings.dart';

/// 顶栏伪毛玻璃条（透明 + 高斯模糊）。
///
/// 默认用 `BackdropFilter` 高斯模糊 + 半透明白/暗铺底，
/// 结合 `Stack` 把顶栏覆盖在内容之上，列表滚动到顶栏下方时即可看到内容被模糊穿透；
/// 低性能模式回退为与页面一致的纯色顶栏（布局不变）。
///
/// 用法（页面 Scaffold 的 body 改为 Stack）：
/// ```dart
/// Scaffold(
///   backgroundColor: appSurfaceBg(context),
///   body: Stack(
///     children: [
///       /* 内容主体：顶部 Padding 需为 GlassTopBar.height(context, bottom: tabBar) */
///       Positioned(top: 0, left: 0, right: 0, child: GlassTopBar(...)),
///     ],
///   ),
/// )
/// ```
class GlassTopBar extends ConsumerWidget {
  const GlassTopBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.bottom,
    this.titleSpacing,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final double? titleSpacing;

  /// 顶栏总高度（含状态栏、工具栏与底部 TabBar）：供内容区顶部 Padding 避让。
  /// 无论毛玻璃开/关高度一致，可安全用于布局。
  static double height(BuildContext context, {PreferredSizeWidget? bottom}) {
    return MediaQuery.of(context).padding.top +
        kToolbarHeight +
        (bottom?.preferredSize.height ?? 0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    // 伪毛玻璃默认：半透明 + 高斯模糊质感；低性能模式或关闭「毛玻璃」回退纯色。
    // 壁纸模式与普通模式共用同一套样式（壁纸只是替换底色）。
    final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
    // 全局 blur 预算（header 档：滚动/转场时保持模糊，仅缩小输入）。
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));
    final sigma = surfaceBlurSigma(
      base: 16,
      budget: budget,
      type: BlurSurfaceType.header,
    );
    final fill = solid
        ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
        : (isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.52));
    final glassFill =
        solid ? fill : surfaceFillWithBudget(fill, budget);
    final divider = scheme.onSurface.withValues(alpha: 0.06);

    final bar = _bar(context, statusBarHeight);
    final inner = Container(
      decoration: BoxDecoration(
        color: glassFill,
        border: Border(bottom: BorderSide(color: divider)),
      ),
      child: bar,
    );
    if (solid) return inner;

    return ClipRect(
      child: BackdropFilter(
        // sigma 16：具毛玻璃质感又只在顶层细条上重采样，成本可控；
        // 配合更高透明度的铺底呈现 RWAS 那种“通透磨砂”观感；按预算缩放。
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: inner,
      ),
    );
  }

  Widget _bar(BuildContext context, double statusBarHeight) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: statusBarHeight),
        SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: titleSpacing ?? (leading == null ? 16 : 0),
                    right: 16,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      child: title ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              if (actions != null) ...?actions,
            ],
          ),
        ),
        ?bottom,
      ],
    );
  }
}