import 'package:flutter/material.dart';

/// 底部导航分支容器：带淡入淡出 + 轻微缩放的过渡。
///
/// 替代 `StatefulShellRoute.indexedStack` 默认的 `IndexedStack`（瞬间切换、
/// 无动画）。所有分支始终保留在 widget 树中以维持各 tab 的滚动位置与状态；
/// 非活跃分支淡出后用 `Offstage` 移出布局与绘制，避免持续开销。
class AnimatedBranchContainer extends StatelessWidget {
  const AnimatedBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
    this.duration = const Duration(milliseconds: 220),
  });

  final int currentIndex;
  final List<Widget> children;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (var i = 0; i < children.length; i++)
          _BranchLayer(
            key: ValueKey(i),
            isActive: i == currentIndex,
            duration: duration,
            child: children[i],
          ),
      ],
    );
  }
}

/// 单个分支层：驱动显隐动画，并在淡出结束后移出布局。
class _BranchLayer extends StatefulWidget {
  const _BranchLayer({
    super.key,
    required this.isActive,
    required this.duration,
    required this.child,
  });

  final bool isActive;
  final Duration duration;
  final Widget child;

  @override
  State<_BranchLayer> createState() => _BranchLayerState();
}

class _BranchLayerState extends State<_BranchLayer> {
  /// 是否参与布局与绘制。激活时立即为 true；失活时等淡出动画结束再置 false，
  /// 保证淡出过程可见。
  late bool _visible = widget.isActive;

  @override
  void didUpdateWidget(_BranchLayer old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !_visible) {
      setState(() => _visible = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !_visible,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.isActive ? 1.0 : 0.0),
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        onEnd: () {
          if (mounted && !widget.isActive && _visible) {
            setState(() => _visible = false);
          }
        },
        builder: (context, t, child) {
          // 非活跃分支不接收手势，避免隐藏页面误响应点击。
          return IgnorePointer(
            ignoring: !widget.isActive,
            child: Opacity(
              opacity: t,
              // 轻微缩放：入场从 0.98 放大到 1.0，观感更顺滑。
              child: Transform.scale(scale: 0.98 + 0.02 * t, child: child),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}
