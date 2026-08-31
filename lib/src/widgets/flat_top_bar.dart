import 'package:flutter/material.dart';

/// 纯色平面顶栏（无毛玻璃材质）：与横屏 master-detail 右侧分类标题条同款
/// 观感（纯底色 + 16/w600 标题），「音源」「意见反馈」等页面竖屏路由与横屏
/// 嵌入两种形态统一顶栏材质。
///
/// 高度公式与 [GlassTopBar.height] 一致（状态栏 + kToolbarHeight + bottom），
/// 页面内容区顶部 Padding 无需改动。
class FlatTopBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
