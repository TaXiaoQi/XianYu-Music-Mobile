import 'package:flutter/material.dart';

/// 底部导航分支容器：左右弹簧横滑过渡（参考 PiliNara 首页 Tab 切换）。
///
/// 替代 `StatefulShellRoute.indexedStack` 默认的 `IndexedStack`（瞬间切换、
/// 无动画）。所有分支始终保留在 widget 树中以维持各 tab 的滚动位置与状态。
///
/// 切换手感：旧分支向一侧平滑滑出、新分支从另一侧同步滑入，二者始终互补覆盖
/// 全屏（无背景闪烁）；动画用 [AnimatedBuilder] 只做位移变换、不复建页面子树，
/// 避免切 tab 掉帧。过渡结束后离屏分支转 `Offstage` 移出布局与绘制，降低常驻开销。
class AnimatedBranchContainer extends StatefulWidget {
  const AnimatedBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
    this.duration = const Duration(milliseconds: 320),
  });

  final int currentIndex;
  final List<Widget> children;
  final Duration duration;

  @override
  State<AnimatedBranchContainer> createState() => _AnimatedBranchContainerState();
}

class _AnimatedBranchContainerState extends State<AnimatedBranchContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late int _prevIndex;
  late List<Widget> _children;
  late final CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    _prevIndex = widget.currentIndex;
    _children = List.of(widget.children);
    _ctrl = AnimationController(vsync: this, value: 1.0);
    _curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void didUpdateWidget(covariant AnimatedBranchContainer old) {
    super.didUpdateWidget(old);
    if (!identical(old.children, widget.children)) {
      _children = List.of(widget.children);
    }
    if (widget.currentIndex != old.currentIndex) {
      _prevIndex = old.currentIndex;
      // 从 0 平滑滑到 1；沿用当前帧（已为静止 1.0）时可重新 forward。
      _ctrl
        ..duration = widget.duration
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 前进（index 增大）新页从右侧滑入、旧页滑出到左侧；后退相反。
    final inDir = (widget.currentIndex > _prevIndex) ? 1.0 : -1.0;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < _children.length; i++)
            _BranchPane(
              key: ValueKey(i),
              animation: _curve,
              inDir: inDir,
              isCurrent: i == widget.currentIndex,
              isPrev: i == _prevIndex && _curve.value < 1.0,
              child: _children[i],
            ),
        ],
      ),
    );
  }
}

/// 单个分支层：按 role（当前页 / 上一页）跟随滑动手势做水平位移。
class _BranchPane extends StatelessWidget {
  const _BranchPane({
    super.key,
    required this.animation,
    required this.inDir,
    required this.isCurrent,
    required this.isPrev,
    required this.child,
  });

  final Animation<double> animation;
  final double inDir;
  final bool isCurrent;
  final bool isPrev;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !(isCurrent || isPrev),
      child: AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final w = MediaQuery.sizeOf(context).width;
          final t = animation.value;
          final Offset offset;
          if (isCurrent) {
            // 新页从 inDir 侧滑入到原位。
            offset = Offset(inDir * w * (1 - t), 0);
          } else if (isPrev) {
            // 旧页滑出到相反一侧。
            offset = Offset(-inDir * w * t, 0);
          } else {
            offset = Offset.zero;
          }
          return Transform.translate(
            offset: offset,
            child: IgnorePointer(ignoring: !isCurrent, child: child!),
          );
        },
      ),
    );
  }
}