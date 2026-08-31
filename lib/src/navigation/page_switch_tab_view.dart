import 'package:flutter/material.dart';

import '../widgets/blur_budget.dart';

/// 竖屏底部导航 tab 容器（PageView 实现）：手指左右拖动即可跟手切换 tab，
/// 松手由自定义弹簧物理吸附到整页，参考 PiliNara 的首页 Tab 切换手感。
///
/// 竖屏专用——横屏是独立模式，主 tab 切换走 [LandscapeTabSwitcher]
/// （out-in），两套 UI/动画/手势互不掺和。分支状态在横竖屏互换容器时由
/// routes.dart 的分支 GlobalKey 跨容器保留。
///
/// 所有分支通过 keepAlive 常驻 widget 树以保留各自滚动/播放状态，离屏分支
/// 保留但不参与绘制。双向同步：
/// - 程序化切换（点击底栏 / 预测返回 commit）：外部 `currentIndex` 变化驱动
///   切页动画。
/// - 手指拖动切换：页面整页停留后通过 [onPageSettled] 回调通知外部更新当前索引。
class PageSwitchTabView extends StatefulWidget {
  const PageSwitchTabView({
    super.key,
    required this.currentIndex,
    required this.children,
    this.onPageSettled,
    this.duration = const Duration(milliseconds: 320),
  });

  final int currentIndex;
  final List<Widget> children;
  final ValueChanged<int>? onPageSettled;
  final Duration duration;

  @override
  State<PageSwitchTabView> createState() => _PageSwitchTabViewState();
}

class _PageSwitchTabViewState extends State<PageSwitchTabView> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.currentIndex);
  }

  @override
  void didUpdateWidget(covariant PageSwitchTabView old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex == old.currentIndex) return;
    if (_controller.hasClients &&
        _controller.page?.round() != widget.currentIndex) {
      // 主 tab 切换不是路由 push/pop，TransitionTracker（NavigatorObserver）
      // 感知不到；显式标记转场活动，激活全局 blur 预算的转场降级通道，
      // 避免整页平移期间所有玻璃表面满档重算模糊导致掉帧。
      markTransitionActivity();
      _controller.animateToPage(
        widget.currentIndex,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      // 手指拖动切 tab 同样是整页平移（非路由转场）：标记滚动活动，
      // 让 blur 预算在拖动全程保持降级（markScrollActivity 内部防抖）。
      onNotification: (n) {
        if (n.depth == 0) markScrollActivity();
        return false;
      },
      child: PageView(
        controller: _controller,
        physics: const _TabPageScrollPhysics(),
        onPageChanged: (page) {
          if (page != widget.currentIndex) {
            widget.onPageSettled?.call(page);
          }
        },
        children: [
          for (final child in widget.children) TabKeepAlivePage(child: child),
        ],
      ),
    );
  }
}

/// keepAlive 包装：让离屏分支常驻 widget 树，保留各自的滚动位置与状态。
/// 竖屏 PageView 与横屏切换器共用。
class TabKeepAlivePage extends StatefulWidget {
  const TabKeepAlivePage({super.key, required this.child});

  final Widget child;

  @override
  State<TabKeepAlivePage> createState() => _TabKeepAlivePageState();
}

class _TabKeepAlivePageState extends State<TabKeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// PageView 的弹簧吸附物理：轻微欠阻尼，松手绑住到整页且带一丝回弹。
class _TabPageScrollPhysics extends PageScrollPhysics {
  const _TabPageScrollPhysics({super.parent});

  @override
  _TabPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TabPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring =>
      const SpringDescription(mass: 1.0, stiffness: 150.0, damping: 22.0);
}
