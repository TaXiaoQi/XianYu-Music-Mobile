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
  bool _outPhase = false;
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

  @override
  void didUpdateWidget(covariant PageSwitchTabView old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex == old.currentIndex) return;
    if (_landscape) {
      if (!widget.fadeEnabled) {
        if (_controller.hasClients) _controller.jumpToPage(widget.currentIndex);
        return;
      }
      // 桌面版 page-fade 同款 out-in。pending 始终同步为最新目标（不设
      // page 守卫，避免 A→B→A 快速切换时 pending 滞后导致循环跳页）。
      _pendingIndex = widget.currentIndex;
      if (_animating) {
        // out 阶段并入当前周期；in 阶段被打断则重启一轮 out。
        if (!_outPhase) _beginOut();
      } else if (_controller.hasClients) {
        _beginOut();
      }
    } else if (_controller.hasClients &&
        _controller.page?.round() != widget.currentIndex) {
      _controller.animateToPage(
        widget.currentIndex,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// out 阶段：旧页淡出（上移 6px、缩至 0.996），完成后跳到目标页进入 in 阶段。
  ///
  /// [_gen] 代数守卫：_anim.value 赋值会强停运行中的 ticker，被打断的旧
  /// forward 的 whenComplete 会以 TickerCanceled 触发，必须忽略，否则会把
  /// 刚置位的 _animating 清掉导致动效失效。
  int _gen = 0;

  void _beginOut() {
    _animating = true;
    _outPhase = true;
    final gen = ++_gen;
    // 关键：同步把动画值归零再 forward。forward(from: 0) 不会同步修改 value，
    // 若 value 仍停留在上一轮 in 结束的 1.0，本帧 paint 时 out 映射
    // opacity = 1 - 1 = 0，旧页会先满帧消失一拍（硬闪）。
    _anim.value = 0;
    _anim.forward().whenComplete(() {
      if (!mounted || gen != _gen) return;
      _onOutComplete();
    });
  }

  void _onOutComplete() {
    if (!mounted) return;
    final target = _pendingIndex;
    // 先同步切到 in 映射并把 value 归零、再跳页：跳页后的首帧新页以 opacity 0
    // 出现。否则 value 仍为 1.0、in 映射 opacity = 1，新页会满帧闪现一拍。
    _outPhase = false;
    _anim.value = 0;
    _controller.jumpToPage(target);
    if (target != widget.currentIndex) {
      // out 期间目标又变了：再来一轮 out。
      _beginOut();
      return;
    }
    // in 阶段：新页自下方 8px、scale 0.996 淡入归位。
    final gen = _gen;
    _anim.forward().whenComplete(() {
      if (!mounted || gen != _gen) return;
      _onInComplete();
    });
  }

  void _onInComplete() {
    if (!mounted) return;
    setState(() => _animating = false);
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
    final pageView = PageView(
      controller: _controller,
      // 横屏侧边栏模式下禁用横滑手势，竖屏保持弹簧吸附横滑。
      physics: _landscape
          ? const NeverScrollableScrollPhysics()
          : const _TabPageScrollPhysics(),
      onPageChanged: (page) {
        if (page != widget.currentIndex) {
          widget.onPageSettled?.call(page);
        }
      },
      children: [
        for (final child in widget.children) _KeepAlivePage(child: child),
      ],
    );

    if (!_animating) return pageView;
    return AnimatedBuilder(
      animation: _anim,
      child: pageView,
      builder: (context, child) {
        final t = _curved.value;
        final double opacity;
        final double dy;
        final double scale;
        if (_outPhase) {
          opacity = 1 - t;
          dy = -6 * t;
          scale = 1 - 0.004 * t;
        } else {
          opacity = t;
          dy = 8 * (1 - t);
          scale = 0.996 + 0.004 * t;
        }
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              child: _outPhase ? IgnorePointer(child: child) : child,
            ),
          ),
        );
      },
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
