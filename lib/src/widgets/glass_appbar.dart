import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'floating_search_bar.dart';
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
    this.flatBackdrop = false,
    this.forceSolid = false,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final double? titleSpacing;

  /// true 时无视玻璃设置直接纯色铺底（跳过 BackdropFilter）。用于壳层固定
  /// 顶栏的显隐动画窗口（[chromeGlassSettlingProvider]）：BackdropFilter 处于
  /// Opacity 动画层内背板采样会渲染成黑帧，动画期间强制纯色。
  final bool forceSolid;

  /// 扁平背板：顶栏下方为已知固定的纯色（无内容穿过）时置 true，跳过
  /// `BackdropFilter` 全屏离屏合成，直接用铺底填充——视觉不变、成本归零。
  /// 典型：设置类页面顶栏（内容从 `GlassTopBar.height` 之后才开始）。
  final bool flatBackdrop;

  /// 顶栏总高度（含状态栏、工具栏与底部 TabBar）：供内容区顶部 Padding 避让。
  /// 无论毛玻璃开/关高度一致，可安全用于布局。
  static double height(BuildContext context, {PreferredSizeWidget? bottom}) {
    return MediaQuery.of(context).padding.top +
        kToolbarHeight +
        (bottom?.preferredSize.height ?? 0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 竖屏悬浮顶栏模式：整条换装为「玻璃胶囊组」（返回钮/标题/动作/底部搜索
    // 或 Tab 气泡，见 floatingChromeBar），总高度与固定形态逐像素一致，页面
    // 内容顶部避让零改动；forceSolid/flatBackdrop 为固定条专属，胶囊自管材质。
    // 横屏不换装——横屏有壳层全局胶囊顶栏，页面条保持固定形态。
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final floating = !landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    if (floating) {
      return floatingChromeBar(
        context,
        leading: leading,
        title: title ?? const SizedBox.shrink(),
        actions: actions ?? const [],
        bottom: bottom,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    // 伪毛玻璃默认：半透明 + 高斯模糊质感；低性能模式或关闭「毛玻璃」回退纯色。
    // 壁纸模式与普通模式共用同一套样式（壁纸只是替换底色）。
    final solid = forceSolid || glassShouldUseSolid(ref, lowPerf: lowPerf);
    final wallpaper = wallpaperGlassActive(ref);
    // 固定顶栏：模糊度恒定最深，不跟随「毛玻璃强度」档位、不随壁纸/滚动
    // 预算变化（见 kNavSurfaceBlurSigma）。四处玻璃表面观感统一、切换/
    // 滑动/停止一致。强度档只影响非导航表面。
    final sigma = kNavSurfaceBlurSigma;
    final fill = solid
        ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
        : (wallpaper
            ? wallpaperNavGlassFill(context)
            : (isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.52)));
    final glassFill = fill;
    final divider = scheme.onSurface.withValues(alpha: 0.06);

    final bar = _bar(context, statusBarHeight);
    final inner = Container(
      decoration: BoxDecoration(
        color: glassFill,
        border: Border(bottom: BorderSide(color: divider)),
      ),
      child: bar,
    );
    // 顶栏模糊度恒定最深（[kNavSurfaceBlurSigma]），壁纸模式与常规模式一致：
    // 仅低性能/纯色回退与扁平背板跳过模糊，其余保持最深的固定模糊（顶/底栏
    // 观感两态一致，不随壁纸/滚动/预算变化）。
    if (solid || flatBackdrop) return inner;

    // 顶栏与固定底栏一致，始终走实时 BackdropFilter，静止/滚动/切换三态
    // 观感稳定、不再有快照态与实时态之间的视觉跳变。sigma 恒定
    // （kNavSurfaceBlurSigma）。顶栏此处用**全分辨率**高斯模糊（不做降采样）：
    // cheapBackdropBlur 的 1/4 降采样再放大，采样网格与物理像素不对齐时会
    // 产生约 1~2px 的水平相位偏移（细长条贴邻屏幕边缘最明显，观感像"往右歪、
    // 和背底没对上"）。全分辨率 blur(sigma) 与 cheapBackdropBlur 的等效半径一致，
    // 但按原始像素精确对齐背板。顶栏仅一条窄带，全分辨率成本可控。
    return ClipRect(
      child: BackdropFilter(
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

/// 任意 Widget 的 PreferredSize 包装：让组合底段（内容 tab + 来源条等）能作为
/// [GlassTopBar] 的 bottom 参与总高与避让计算（height 由调用方按内容实算）。
class PreferredSizeProxy extends StatelessWidget implements PreferredSizeWidget {
  const PreferredSizeProxy({
    super.key,
    required this.height,
    required this.child,
  });

  final double height;
  final Widget child;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) => child;
}