// 单行滚动文本（跑马灯）。
//
// 文本不超宽时按普通 Text 居左显示（无动画开销）；超宽时循环横向滚动，
// 用于列表行歌名/歌手等「省略号会丢信息」的场景（播放页 _Marquee 同款
// 逻辑提炼为公共组件）。无障碍朗读走 tooltip 保留完整文本。

import 'dart:async';

import 'package:flutter/material.dart';

class ScrollingText extends StatefulWidget {
  const ScrollingText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines = 1,
  });

  final String text;

  final TextStyle style;

  final int maxLines;

  @override
  State<ScrollingText> createState() => _ScrollingTextState();
}

class _ScrollingTextState extends State<ScrollingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _textWidth = 0;
  static const _gap = 60.0;
  static const _speed = 42.0;
  // 滚完一轮停留：停稳再开下一轮，避免无限连滚观感奇怪
  static const _pause = Duration(milliseconds: 1200);
  bool _pausing = false;
  Timer? _pauseTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addListener(() {
        setState(() {});
        if (_controller.status == AnimationStatus.completed && !_pausing) {
          _pausing = true;
          _pauseTimer?.cancel();
          _pauseTimer = Timer(_pause, () {
            if (!mounted) return;
            _pausing = false;
            _controller.forward(from: 0);
          });
        }
      });
    _measure();
  }

  @override
  void didUpdateWidget(covariant ScrollingText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) {
      _pauseTimer?.cancel();
      _pausing = false;
      _controller.value = 0;
      _measure();
    }
  }

  void _measure() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textWidth = tp.width;
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final maxWidth = cons.maxWidth;
        if (!maxWidth.isFinite || _textWidth <= maxWidth) {
          _controller.stop();
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              maxLines: widget.maxLines,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: widget.style,
            ),
          );
        }
        final total = _textWidth + _gap;
        final seconds = total / _speed;
        if ((_controller.duration?.inMilliseconds ?? 0) !=
            (seconds * 1000).round()) {
          _controller.duration = Duration(
            milliseconds: (seconds * 1000).round(),
          );
        }
        if (!_pausing && !_controller.isAnimating) {
          _controller.forward(from: _controller.value >= 1 ? 0 : null);
        }
        final dx = -_controller.value * total;
        final lineHeight = widget.style.fontSize != null
            ? (widget.style.fontSize! * 1.2).ceilToDouble()
            : 20.0;
        return Semantics(
          label: widget.text,
          child: MouseRegion(
            cursor: SystemMouseCursors.basic,
            child: GestureDetector(
              onTapDown: (_) => _controller.stop(),
              onTapUp: (_) {
                if (!_pausing && !_controller.isAnimating) {
                  _controller.forward(from: _controller.value >= 1 ? 0 : null);
                }
              },
              child: ClipRect(
                child: SizedBox(
                  height: lineHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: dx,
                        top: 0,
                        child: Text(
                          widget.text,
                          maxLines: 1,
                          softWrap: false,
                          style: widget.style,
                        ),
                      ),
                      Positioned(
                        left: dx + _textWidth + _gap,
                        top: 0,
                        child: Text(
                          widget.text,
                          maxLines: 1,
                          softWrap: false,
                          style: widget.style,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
