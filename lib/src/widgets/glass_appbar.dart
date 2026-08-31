import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'cached_frosted.dart';
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
    this.cachedBackdropKey,
    this.flatBackdrop = false,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final double? titleSpacing;

  /// 扁平背板：顶栏下方为已知固定的纯色（无内容穿过）时置 true，跳过
  /// `BackdropFilter` 全屏离屏合成，直接用铺底填充——视觉不变、成本归零。
  /// 典型：设置类页面顶栏（内容从 `GlassTopBar.height` 之后才开始）。
  final bool flatBackdrop;

  /// 离线缓存背板的 RepaintBoundary 的 GlobalKey（可选）。
  ///
  /// 提供时本页内容（`ListView` 等）需包在 `RepaintBoundary(key: 该 key)` 中，
  /// 顶栏改用 [CachedFrosted] 离线缓存：静止/被二级页盖住/弹回时直接 blit
  /// 一张预模糊小图，不再每帧全屏高斯基对背板——切页不卡。滚动中自动回退
  /// 实时 BackdropFilter。细节见 [CachedFrosted]。
  final GlobalKey? cachedBackdropKey;

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
    final wallpaper = wallpaperGlassActive(ref);
    // 模糊度跟随「毛玻璃」档位：切换/滑动/停止语义一致（滑动与停止恒定），
    // 仅转场切页瞬间临时缩档防整页掉帧（见 frostedBlurSigma）。
    // 壁纸透明孔模式下统一抽成极淡磨砂（近乎透明，sigma 收敛）。
    final sigma = wallpaper ? wallpaperGlassSigma(context) : frostedBlurSigma(ref);
    final fill = solid
        ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
        : (wallpaper
            ? wallpaperGlassFill(context)
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
    // 壁纸透明孔模式：顶栏退化为一块「透明孔」——只铺极淡半透明磨砂底让壁纸
    // 透出，不再走 CachedFrosted / 实时 BackdropFilter。
    //
    // 理由：壁纸铺在壳层、页面内容（含顶栏背板）之上又有 RepaintBoundary，
    // 顶栏的模糊采样到不了壳层壁纸（被层边界截断），滑动/停止两态分别走
    // 实时高斯与离线 blit，模糊会忽重忽透、且快照/采样区域与固定壁纸错位
    // → 顶栏后的壁纸「歪」。既是透明孔设计，直接去掉背板模糊，壁纸就稳定、
    // 对齐地透过极淡铺底露出，滑动/停止观感一致。也顺带免掉了切页/滚动期
    // 顶栏的重模糊与快照重抓开销。
    if (solid || flatBackdrop || wallpaper) return inner;

    // 提供离线缓存背板 key 时，走 CachedFrosted（静止直接 blit，滚动才实时）。
    final cachedKey = cachedBackdropKey;
    if (cachedKey != null) {
      return CachedFrosted(
        backdropKey: cachedKey,
        sigma: sigma,
        // 铺底透明度由 inner 承担，此处不叠加，避免双重变暗。
        fill: const Color(0x00000000),
        child: inner,
      );
    }

    // 普通玻璃顶栏：退化为实时 BackdropFilter。sigma 恒定跟随档位，切换/
    // 滑动/停止三态模糊度表现一致。降采样模糊（cheapBackdropBlur）把高斯
    // 工作量降为 1/16，在保持一致观感的同时控制成本。
    return ClipRect(
      child: BackdropFilter(
        filter: cheapBackdropBlur(sigma),
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