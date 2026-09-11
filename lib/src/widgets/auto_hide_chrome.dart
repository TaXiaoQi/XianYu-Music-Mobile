import 'package:flutter/material.dart';

/// 横屏播放页顶栏/底栏自动隐藏容器（对齐桌面版）：
/// 收起时淡出并让位（AnimatedSize 收缩高度，中区内容自动占满/放大），
/// 任意触摸由外层 Listener 唤回。竖屏播放页传 visible 恒 true 即常显。
///
/// 注：曾试过「浮层化」（栏盖在内容上、中区高度恒定），观感上栏会压在
/// 歌词/封面上穿透显示，已弃用；布局参与式的中区内容随栏进退缩放才是
/// 期望行为。AnimatedSize 逐帧 reflow 若再引出歌词抽搐，优先从歌词视图
/// 内部对视口变化做平滑处理，而非改这里的动画方式。
class AutoHideChrome extends StatelessWidget {
  const AutoHideChrome({
    super.key,
    required this.visible,
    required this.alignment,
    required this.child,
  });

  /// 是否可见：false 时淡出并收缩为 0 高度（不再占位）。
  final bool visible;

  /// 收缩对齐方向：顶栏用 [Alignment.topCenter]，底栏用 [Alignment.bottomCenter]。
  final AlignmentGeometry alignment;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOutCubic,
        alignment: alignment,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          opacity: visible ? 1 : 0,
          child: visible
              ? child
              : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }
}
