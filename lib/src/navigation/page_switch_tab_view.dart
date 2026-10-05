import 'package:flutter/material.dart';

import '../widgets/blur_budget.dart' show setTabSwitching;

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

  // 换页动画代数：连续快速点按会中断上一个动画，旧 future 的
  // whenComplete 不得把新动画的 tabSwitching 提前清掉
  int _switchGen = 0;

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
      // 换页滑动广播 tabSwitching：玻璃侧按转场口径静默（mini 条不逐帧
      // live、backing 不逐帧重绘、缓存帧不滚动抓帧），retained 层由合成器
      // 继续采样 backdrop，液态观感跟随滑动手势
      final gen = ++_switchGen;
      setTabSwitching(true);
      _controller.animateToPage(
        widget.currentIndex,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
      ).whenComplete(() {
        if (gen == _switchGen) setTabSwitching(false);
      });
    }
  }

  @override
  void dispose() {
    if (_switchGen > 0) setTabSwitching(false);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
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
    );
  }
}

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
