import 'package:flutter/material.dart';

/// 播放/暂停图标形变过渡：Material 内置 play_pause 形变路径，
/// 三角形与双竖条之间平滑渐变（path 插值，非 cross-fade）。
class PlayPauseMorphIcon extends StatefulWidget {
  const PlayPauseMorphIcon({
    super.key,
    required this.playing,
    this.size,
    this.color,
  });

  final bool playing;
  final double? size;
  final Color? color;

  @override
  State<PlayPauseMorphIcon> createState() => _PlayPauseMorphIconState();
}

class _PlayPauseMorphIconState extends State<PlayPauseMorphIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.playing ? 1.0 : 0.0,
  );
  late final CurvedAnimation _progress =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void didUpdateWidget(covariant PlayPauseMorphIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      widget.playing ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AnimatedIcon 是 StatelessWidget，不主动监听动画，需外层驱动重建
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => AnimatedIcon(
        icon: AnimatedIcons.play_pause,
        progress: _progress,
        size: widget.size,
        color: widget.color,
      ),
    );
  }
}
