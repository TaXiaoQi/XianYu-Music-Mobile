import 'package:flutter/material.dart';

/// 底部导航 tab 容器（PageView 实现）：手指左右拖动即可跟手切换 tab，
/// 松手由自定义弹簧物理吸附到整页，参考 PiliNara 的首页 Tab 切换手感。
///
/// 所有分支通过 keepAlive 常驻 widget 树以保留各自滚动/播放状态，离屏分支
/// 保留但不参与绘制。双向同步：
/// - 程序化切换（点击底栏 / 预测返回 commit）：外部 `currentIndex` 变化驱动
///   切页动画。
/// - 手指拖动切换：页面整页停留后通过 [onPageSettled] 回调通知外部更新当前索引。
///
/// 竖屏：PageView 整页弹簧横滑。横屏：桌面版 page-fade 同款 out-in
/// （旧页淡出微上移缩小 → 跳页 → 新页自下方微上移淡入），PageView 始终挂载
/// 以保留分支状态。
class PageSwitchTabView extends StatefulWidget {
  const PageSwitchTabView({
    super.key,
    required this.currentIndex,
    required this.children,
    this.onPageSettled,
    this.duration = const Duration(milliseconds: 320),
    this.fadeEnabled = true,
  });

  final int currentIndex;
  final List<Widget> children;
  final ValueChanged<int>? onPageSettled;
  final Duration duration;

  /// 横屏切换动画开关（对齐外观设置中的「横屏切换动画」）；false 时横屏硬切。
  final bool fadeEnabled;

  @override
  State<PageSwitchTabView> createState() => _PageSwitchTabViewState();
}

class _PageSwitchTabViewState extends State<PageSwitchTabView>
    with SingleTickerProviderStateMixin {
  late final PageController _controller;
  late final AnimationController _anim;
  late final CurvedAnimation _curved;

  /// 横屏 out-in 切换状态：out 阶段旧页在 PageView 上整体淡出，完成后跳页，
  /// in 阶段新页淡入。对齐桌面版 page-fade（0.22s，expo-out，±6/8px + 0.996）。
  bool _animating = false;
  int _pendingIndex = -1;

  static const _fadeDuration = Duration(milliseconds: 220);
  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.currentIndex);
    _anim = AnimationController(vsync: this, duration: _fadeDuration);
    _curved = CurvedAnimation(parent: _anim, curve: _ease);
  }

  /// 横屏判定（与 shell.dart 一致：宽 ≥ 高 × 1.05）。
  bool get _landscape {
    final size = MediaQuery.sizeOf(context);
    return size.width >= size.height * 1.05;
  }

  int _fromIndex = 0;
  int _gen = 0;

  void _startFadeTransition() {
    setState(() {
      _animating = true;
    });
    final gen = ++_gen;
    _anim.value = 0;
    _anim.forward().whenComplete(() {
      if (!mounted || gen != _gen) return;
      setState(() {
        _animating = false;
        _fromIndex = _pendingIndex;
      });
    });
  }

  @override
  void didUpdateWidget(covariant PageSwitchTabView old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex == old.currentIndex) return;
    if (_landscape) {
      if (!widget.fadeEnabled) {
        if (_controller.hasClients) _controller.jumpToPage(widget.currentIndex);
        return;
      }
      _fromIndex = old.currentIndex;
      _pendingIndex = widget.currentIndex;
      _startFadeTransition();
    } else if (_controller.hasClients &&
        _controller.page?.round() != widget.currentIndex) {
      _controller.animateToPage(
        widget.currentIndex,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _anim.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_landscape) {
      return Container(
        color: Theme.of(context).colorScheme.surface,
        child: AnimatedBuilder(
          animation: _curved,
          builder: (context, _) {
            final t = _curved.value;
            final children = <Widget>[];

            if (!_animating) {
              // 非动画状态：仅当前页可见
              for (var i = 0; i < widget.children.length; i++) {
                final isCurrent = i == widget.currentIndex;
                children.add(
                  Positioned.fill(
                    key: ValueKey(i),
                    child: Offstage(
                      offstage: !isCurrent,
                      child: IgnorePointer(ignoring: !isCurrent, child: widget.children[i]),
                    ),
                  ),
                );
              }
            } else {
              // 动画状态：
              // 1. 先放非活跃分支（Offstage 隐藏）
              for (var i = 0; i < widget.children.length; i++) {
                if (i != _fromIndex && i != _pendingIndex) {
                  children.add(
                    Positioned.fill(
                      key: ValueKey(i),
                      child: const Offstage(offstage: true, child: SizedBox.shrink()),
                    ),
                  );
                }
              }
              // 2. 旧页（isFrom）无论 Index 是 0 还是 1，必须【先加】在 Stack 底层打底
              if (_fromIndex >= 0 && _fromIndex < widget.children.length) {
                children.add(
                  Positioned.fill(
                    key: ValueKey(_fromIndex),
                    child: Offstage(
                      offstage: false,
                      child: IgnorePointer(child: widget.children[_fromIndex]),
                    ),
                  ),
                );
              }
              // 3. 新页（isTo）无论 Index 是 0 还是 1，必须【后加】盖在 Stack 最顶层淡入
              if (_pendingIndex >= 0 &&
                  _pendingIndex < widget.children.length &&
                  _pendingIndex != _fromIndex) {
                final opacity = t.clamp(0.0, 1.0);
                children.add(
                  Positioned.fill(
                    key: ValueKey(_pendingIndex),
                    child: Opacity(
                      opacity: opacity,
                      child: Transform.translate(
                        offset: Offset(0, 8 * (1 - t)),
                        child: Transform.scale(
                          scale: 0.996 + 0.004 * t,
                          child: widget.children[_pendingIndex],
                        ),
                      ),
                    ),
                  ),
                );
              }
            }

            return Stack(
              children: children,
            );
          },
        ),
      );
    }

    return PageView(
      controller: _controller,
      physics: const _TabPageScrollPhysics(),
      onPageChanged: (page) {
        if (page != widget.currentIndex) {
          widget.onPageSettled?.call(page);
        }
      },
      children: [
        for (final child in widget.children) _KeepAlivePage(child: child),
      ],
    );
  }
}

/// keepAlive 包装：让离屏分支常驻 widget 树，保留各自的滚动位置与状态。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
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
