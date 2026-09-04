import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'floating_search_bar.dart';

/// 纯色平面顶栏（无毛玻璃材质）：与横屏 master-detail 右侧分类标题条同款
/// 观感（纯底色 + 16/w600 标题），「音源」「意见反馈」等页面竖屏路由与横屏
/// 嵌入两种形态统一顶栏材质。
///
/// 高度公式与 [GlassTopBar.height] 一致（状态栏 + kToolbarHeight + bottom），
/// 页面内容区顶部 Padding 无需改动。
class FlatTopBar extends ConsumerWidget {
  const FlatTopBar({
    super.key,
    this.leading,
    required this.title,
    this.actions = const [],
    this.bottom,
    this.backgroundColor,
  });

  /// 通常为 BackButton；null 时标题左缩进 16（同横屏 master-detail 标题条）。
  final Widget? leading;
  final String title;
  final List<Widget> actions;

  /// 底部附加条（如反馈页 TabBar）。
  final PreferredSizeWidget? bottom;

  /// 条底色，默认页面 Scaffold 底色；建议传 [appScaffoldBackground] 以适配
  /// 壁纸/自定义背景。
  final Color? backgroundColor;

  /// 顶栏总高度（含状态栏、工具栏与底部附加条）：供内容区顶部 Padding 避让。
  static double height(BuildContext context, {double bottom = 0}) {
    return MediaQuery.paddingOf(context).top + kToolbarHeight + bottom;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 竖屏悬浮顶栏模式：与 [GlassTopBar] 同口径整条换装玻璃胶囊组（总高一致，
    // 页面避让零改动）；横屏保持固定平面形态（横屏有壳层全局胶囊顶栏）。
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
        title: Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        actions: actions,
        bottom: bottom,
      );
    }
    return Container(
      color:
          backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top),
          SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                ?leading,
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: leading == null ? 18 : 0,
                      right: 16,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          ?bottom,
        ],
      ),
    );
  }
}
