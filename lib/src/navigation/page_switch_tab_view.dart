import 'package:flutter/material.dart';

import '../widgets/blur_budget.dart' show setTabSwitching;

/// 手动拖拽换页的连续页位置（分支索引单位，小数部分=页间进度）；
/// -1 = 非拖拽态。底栏水滴指示器（_SlidingNavBottom）据此在相邻页签间
/// 等比插值+放大水滴，随页面实时跟手，而非半程才瞬跳
final ValueNotifier<double> tabSwipePageFraction = ValueNotifier<double>(-1);

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

  // 用户手指拖拽换页中：只用于驱动指示器跟手（tabSwipePageFraction），
  // 不触碰 tabSwitching 玻璃信号（那套已按用户决策移除，见下方注释）。
  // 入口条件 ScrollStart.dragDetails != null 区分手指拖拽与程序式动画
  bool _pageDrag = false;

  // 拖拽→弹滚切换瞬间 Flutter 会先派发 ScrollEnd 再派发弹滚的
  // ScrollStart（dragDetails==null）。若收到 ScrollEnd 立即解除跟手态，
  // 页面还在弹滚飞行时水滴就退化成默认样式（模拟器实测）。改为帧末
  // 确认没有弹滚接力才收
  bool _pendingDragEnd = false;

  void _onControllerMoved() {
    if (!_pageDrag || !_controller.hasClients) return;
    final p = _controller.page;
    if (p != null) tabSwipePageFraction.value = p;
  }

  bool _handlePageDragNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification) {
      if (n.dragDetails != null) {
        _pageDrag = true;
        _pendingDragEnd = false;
        final p = _controller.hasClients ? _controller.page : null;
        tabSwipePageFraction.value = p ?? widget.currentIndex.toDouble();
      } else if (_pendingDragEnd) {
        // 弹滚接力：延续跟手态，水滴随页面继续飞
        _pageDrag = true;
        _pendingDragEnd = false;
      }
    } else if (n is ScrollEndNotification && _pageDrag) {
      _pendingDragEnd = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pendingDragEnd) return;
        _pendingDragEnd = false;
        _pageDrag = false;
        // 落定解除：指示器交还弹簧动画
        tabSwipePageFraction.value = -1;
      });
    }
    return false;
  }

  // 手势拖拽换页不做任何特别处理（用户决策 2026-11，与安卓对齐）：
  // 曾试过 ScrollStart/End 置位 tabSwitching（拖拽进换页窗口），但
  // didUpdateWidget 会在拖过半程时被 currentIndex 中途变更再入，
  // whenComplete 在页面仍在平移时清零信号 → 抓帧门控失守，非静止屏
  // 全屏抓帧+原点登记被污染 → 顶栏/底栏玻璃裁剪错位（裸 tab/双底栏
  // 残影，iOS 26 模拟器实测）。拖拽期间卡片降载由既有滚动信号
  // （globalIsScrolling）兜住，条带维持普通滚动的玻璃口径
  // （didUpdateWidget 只覆盖底部点按的程序式切换）

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.currentIndex);
    _controller.addListener(_onControllerMoved);
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
    if (_pageDrag) tabSwipePageFraction.value = -1;
    _controller.removeListener(_onControllerMoved);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handlePageDragNotification,
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
