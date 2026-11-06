import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/blur_budget.dart' show setTabSwitching;

/// 手动拖拽换页的连续页位置（分支索引单位，小数部分=页间进度）；
/// -1 = 非拖拽态。底栏水滴指示器（_SlidingNavBottom）据此在相邻页签间
/// 等比插值+放大水滴，随页面实时跟手，而非半程才瞬跳
final ValueNotifier<double> tabSwipePageFraction = ValueNotifier<double>(-1);

/// 拖拽松手（弹滚边界）预测的落定页（分支索引）。水滴脱钩弹簧的靶心用
/// 它而非当前 index：快速轻甩常在弹滚过半程前松手，onPageChanged（过半
/// 才触发）尚未变更 index，按旧 index 收敛会先反向飞再被 redirect 纠正。
/// 松手时先写本值再置 tabSwipePageFraction = -1，保证水滴侧读到
final ValueNotifier<int?> tabSwipeReleasePage = ValueNotifier<int?>(null);

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

  // 拖拽帧速度（页/秒）：松手落定页预测的方向票（与 PageScrollPhysics
  // 的 vote 同量纲）
  int _dragPageUs = 0;
  double _dragPagePos = 0;
  double _dragPageVel = 0;

  void _onControllerMoved() {
    if (!_pageDrag || !_controller.hasClients) return;
    final p = _controller.page;
    if (p == null) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    if (_dragPageUs > 0) {
      final dt = (now - _dragPageUs) / 1e6;
      if (dt > 0.001) _dragPageVel = (p - _dragPagePos) / dt;
    }
    _dragPageUs = now;
    _dragPagePos = p;
    tabSwipePageFraction.value = p;
  }

  bool _handlePageDragNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification) {
      if (n.dragDetails != null) {
        _pageDrag = true;
        _dragPageUs = 0;
        _dragPageVel = 0;
        final p = _controller.hasClients ? _controller.page : null;
        tabSwipePageFraction.value = p ?? widget.currentIndex.toDouble();
      }
    } else if (_pageDrag) {
      if (n is ScrollUpdateNotification) {
        // 弹滚首帧即松手：DragScrollActivity（手指拖拽）派发的
        // ScrollUpdate 才带 dragDetails，拖拽中首个 null 帧即弹滚起步。
        // 不能等 ScrollEnd——它要延迟到弹滚模拟跑完才派发（SDK 文档
        // 明确），届时水滴已跟页面爬到停稳，只能原地后补回弹（观感脱节）
        if (n.dragDetails == null) _releasePageDrag();
      } else if (n is ScrollEndNotification) {
        // 慢速松手无弹滚（残余速度不足直接 idle）的兜底
        _releasePageDrag();
      }
    }
    return false;
  }

  /// 松手：水滴即刻脱钩页面、换页弹簧接管（带过冲回弹），与页面弹滚
  /// 并行收敛。落定页按 PageScrollPhysics 预测（round(page ± 0.5 方向
  /// 票)，票阈值 tolerance.velocity 默认 50px/s 换算成页单位）——弹滚
  /// 未过半程时 index 尚未变更，按 index 收敛会先反向飞再被纠正
  void _releasePageDrag() {
    if (!_pageDrag) return;
    _pageDrag = false;
    _dragPageUs = 0;
    var page = _controller.hasClients
        ? (_controller.page ?? widget.currentIndex.toDouble())
        : widget.currentIndex.toDouble();
    if (_controller.hasClients) {
      final vp = _controller.position.viewportDimension;
      final vote = 50.0 / math.max(vp, 1.0);
      if (_dragPageVel < -vote) {
        page -= 0.5;
      } else if (_dragPageVel > vote) {
        page += 0.5;
      }
    }
    tabSwipeReleasePage.value = math
        .min(math.max(page.round(), 0), widget.children.length - 1);
    tabSwipePageFraction.value = -1;
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
    if (_pageDrag) {
      tabSwipeReleasePage.value = widget.currentIndex;
      tabSwipePageFraction.value = -1;
    }
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
