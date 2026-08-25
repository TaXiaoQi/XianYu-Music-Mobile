import 'dart:async';

import 'package:flutter/material.dart';

/// 当前正在展示的 toast 路由（同一时刻只保留一个，新 toast 直接替换旧的）。
OverlayEntry? _currentToast;

/// 全局提示（toast）：底部居中的小胶囊，宽度随提示文本收缩（带最大宽度约束），
/// 显示过程为「淡入 → 停留 → 淡出」。
///
/// 走 root Overlay，可覆盖在普通页面、弹窗、底部面板之上。
/// 替代原先基于 SnackBar 的提示（SnackBar 宽度固定、动画为滑入而非纯淡入淡出）。
void showXianYuToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 1800),
}) {
  _showToast(Overlay.of(context, rootOverlay: true), message,
      duration: duration);
}

/// 用已捕获的 [OverlayState] 展示 toast。
///
/// 适用于 await 之后可能跨 async 间隙使用 BuildContext 的场景：提前拿到
/// OverlayState（不随页面销毁而失效），避免「use context after async gap」。
void showXianYuToastByOverlay(
  OverlayState overlay,
  String message, {
  Duration duration = const Duration(milliseconds: 1800),
}) {
  _showToast(overlay, message, duration: duration);
}

void _showToast(
  OverlayState overlay,
  String message, {
  required Duration duration,
}) {
  // 新消息到来时先移除旧 toast（瞬时替换，不叠加堆积）。
  final previous = _currentToast;
  _currentToast = null;
  if (previous != null && previous.mounted) previous.remove();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _XianYuToast(
      message: message,
      duration: duration,
      onDismissed: () {
        if (identical(_currentToast, entry)) _currentToast = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _currentToast = entry;
  overlay.insert(entry);
}

class _XianYuToast extends StatefulWidget {
  const _XianYuToast({
    required this.message,
    required this.duration,
    required this.onDismissed,
  });

  final String message;

  /// 文本完整停留（不含淡入淡出）的时长。
  final Duration duration;

  final VoidCallback onDismissed;

  @override
  State<_XianYuToast> createState() => _XianYuToastState();
}

class _XianYuToastState extends State<_XianYuToast>
    with SingleTickerProviderStateMixin {
  static const Duration _fade = Duration(milliseconds: 180);

  late final AnimationController _controller;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _fade);
    _fadeIn();
  }

  void _fadeIn() async {
    await _controller.forward();
    if (!mounted) return;
    // 淡入完成后停留 [widget.duration]，再淡出并移除自身。
    _hideTimer = Timer(widget.duration, () {
      if (!mounted) return;
      _controller.reverse().then((_) {
        if (!mounted) return;
        widget.onDismissed();
      });
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // 悬停于底部安全区上方，水平居中，宽度随文本收缩（上限 85% 屏宽）。
    return Positioned(
      width: media.size.width,
      left: 0,
      bottom: media.viewPadding.bottom + 28,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: FadeTransition(
            opacity: _controller,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: 64,
                maxWidth: media.size.width * 0.85,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xE6323232),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}