import 'package:flutter/material.dart';

/// 横屏播放页顶栏/底栏自动隐藏容器（对齐桌面版）。
///
/// 由 [_PlayerShell] 横屏分支以「浮层」方式挂在内容之上：显隐只做淡入淡出
/// 与朝屏幕边缘的小幅滑出，【不参与布局】——中区高度恒定，歌词/封面不会被
/// 逐帧改高（旧实现用 AnimatedSize 收缩占位，进退栏时中区每帧 reflow，
/// 歌词大小/位置抽搐，已废弃）。
///
/// 任意触摸由外层 Listener 唤回。竖屏播放页不经过本容器（顶/底栏常驻占位）。
class AutoHideChrome extends StatelessWidget {
  const AutoHideChrome({
    super.key,
    required this.visible,
    required this.alignment,
    required this.child,
  });

  /// 是否可见：false 时淡出并朝所属边缘小幅滑出，同时不再响应指针。
  final bool visible;

  /// 所属边缘：顶栏用 [Alignment.topCenter]（向上滑出），底栏用
  /// [Alignment.bottomCenter]（向下滑出）。
  final AlignmentGeometry alignment;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final up = alignment == Alignment.topCenter;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        // 位移是纯变换不参与布局，中区（歌词/封面）布局恒定不抽搐。
        offset: visible ? Offset.zero : Offset(0, up ? -0.35 : 0.35),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          opacity: visible ? 1 : 0,
          // 浮层压在封面/歌词之上：朝所属边缘渐深的暗色渐变底保证可读性
          // （播放页强制暗色主题，黑系渐变对两套样式都成立）。
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: up ? Alignment.topCenter : Alignment.bottomCenter,
                end: up ? Alignment.bottomCenter : Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.40),
                  Colors.black.withValues(alpha: 0.0),
                ],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
