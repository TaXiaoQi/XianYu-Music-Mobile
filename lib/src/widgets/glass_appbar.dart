import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

/// 顶栏毛玻璃条（安卓原生磨砂质感）。
///
/// 开启「毛玻璃材质」(frostedGlass) 时用 `BackdropFilter` 高斯模糊 + 半透明白/暗铺底，
/// 结合 `Stack` 把顶栏覆盖在内容之上，列表滚动到顶栏下方时即可看到内容被模糊穿透；
/// 关闭时回退为与页面一致的纯色顶栏（布局不变）。
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
    final frosted =
        ref.watch(settingsProvider.select((s) => s.valueOrNull?.frostedGlass)) ??
            true;

    final bar = _bar(context, statusBarHeight);
    if (!frosted) {
      // 关闭毛玻璃：纯色顶栏（与页面背景一致，无高斯模糊）。
      return Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6),
          border: Border(
            bottom: BorderSide(
              color: scheme.onSurface.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: bar,
      );
    }

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xCC222222)
                : const Color(0xD9F7F7F9),
            border: Border(
              bottom: BorderSide(
                color: scheme.onSurface.withValues(alpha: 0.06),
              ),
            ),
          ),
          child: bar,
        ),
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