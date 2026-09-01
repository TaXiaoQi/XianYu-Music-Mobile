import 'package:flutter/material.dart';

/// 封面「淡进」加载（酷狗应用榜单歌曲列表同款），替换「占位 → 封面」的硬切。
///
/// 提供 [frameBuilder] 传给 Image / Image.memory / Image.file：
/// - 首帧同步就绪（缓存命中）：直接显示，不淡入——列表回滚、飞封面/Hero 飞行
///   等场景封面已在缓存中，保持即时呈现避免闪烁；
/// - 首帧未就绪：显示 [placeholder] 占位；
/// - 首帧就绪：封面从占位淡入，视觉上「缓缓加载出来」。
class CoverFadeIn {
  const CoverFadeIn._();

  /// 淡入时长，与 [CachedNetworkImage]/OctoImage 的淡入时长统一。
  static const Duration duration = Duration(milliseconds: 300);

  static ImageFrameBuilder frameBuilder({required Widget placeholder}) {
    return (context, child, frame, wasSynchronouslyLoaded) {
      if (wasSynchronouslyLoaded) return child;
      if (frame == null) return placeholder;
      return _FadeInOnLoad(child: child);
    };
  }
}

class _FadeInOnLoad extends StatefulWidget {
  const _FadeInOnLoad({required this.child});

  final Widget child;

  @override
  State<_FadeInOnLoad> createState() => _FadeInOnLoadState();
}

class _FadeInOnLoadState extends State<_FadeInOnLoad>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: CoverFadeIn.duration,
      value: 0,
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}
