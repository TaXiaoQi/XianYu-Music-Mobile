import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../theme/theme_tint.dart';
import 'floating_search_bar.dart';
import 'glass_settings.dart';

class GlassTopBar extends ConsumerWidget {
  const GlassTopBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.bottom,
    this.bottomTabController,
    this.titleSpacing,
    this.flatBackdrop = false,
    this.forceDocked = false,
    this.themeSlot,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  /// 悬浮态下传给 FloatingTabPill 启用水滴选择块;固定态忽略
  final TabController? bottomTabController;

  final double? titleSpacing;

  final bool forceDocked;

  final bool flatBackdrop;

  /// 主题色块槽位 id；该组件被多页复用，只在需要叠色的页面传入。
  final String? themeSlot;

  static double height(BuildContext context, {PreferredSizeWidget? bottom}) {
    return MediaQuery.of(context).padding.top +
        kToolbarHeight +
        (bottom?.preferredSize.height ?? 0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final floating = !forceDocked &&
        !landscape &&
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
        bottomTabController: bottomTabController,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final wallpaper = wallpaperGlassActive(ref);
    final frostedOn = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.frostedGlass ?? false));
    // 毛玻璃关恢复实底兜底:非壁纸时白0.52+弱blur(navSurfaceBlurSigma 随
    // light 档仅≈2.9)读作透底;壁纸模式不 solid,恒走组件色块滑条
    final solid = !wallpaper && !frostedOn;
    final sigma = navSurfaceBlurSigma(ref);
    // 壁纸模式组件色块:跟随设置的组件色块强度(widgetAlpha)与文字模式
    // 底色,与底栏/mini 条/卡片口径一致;此前用导航面固定强度导致顶栏
    // 与其他组件观感割裂
    final fill = solid
        ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
        : wallpaper
            ? wallpaperGlassFill(context, ref)
            : (isDark
                ? Colors.white.withValues(alpha: 0.20)
                : Colors.white.withValues(alpha: 0.52));
    final slot = themeSlot;
    final glassFill = slot == null ? fill : themeTint(ref, slot, fill);

    final bar = _bar(context, statusBarHeight);
    final inner = Container(
      decoration: BoxDecoration(
        color: glassFill,
        border: null,
      ),
      child: bar,
    );
    if (solid || flatBackdrop) return inner;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        // 与底栏/播放条共享一次 backdrop 回读（同 sigma、区域不重叠）
        backdropGroupKey: navGlassKey,
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