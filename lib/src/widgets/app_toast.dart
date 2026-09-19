import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _currentToast;

void showXianYuToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 1800),
}) {
  _showToast(Overlay.of(context, rootOverlay: true), message,
      duration: duration);
}

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

/// 进度型常驻 toast（对齐桌面端 showProgressToast）：
/// update 逐项刷新文本与进度（progress 传 null 走不确定态），
/// complete/fail 显示最终文案后自动关闭，close 立即关闭。
class XianYuProgressToastHandle {
  XianYuProgressToastHandle._();

  final ValueNotifier<String> _text = ValueNotifier('');
  final ValueNotifier<double?> _progress = ValueNotifier(null);
  final ValueNotifier<bool> _done = ValueNotifier(false);
  OverlayEntry? _entry;
  bool _finished = false;
  Timer? _removeTimer;

  void update(String text, {double? progress}) {
    if (_finished) return;
    _text.value = text;
    if (progress != null) _progress.value = progress.clamp(0.0, 1.0);
  }

  void complete(String text) => _finish(text);

  void fail(String text) => _finish(text);

  void close() {
    if (_finished) return;
    _finished = true;
    _done.value = true;
    _remove();
  }

  void _finish(String text) {
    if (_finished) return;
    _finished = true;
    _text.value = text;
    _done.value = true;
    _removeTimer = Timer(const Duration(milliseconds: 2400), _remove);
  }

  void _remove() {
    _removeTimer?.cancel();
    _removeTimer = null;
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

XianYuProgressToastHandle showXianYuProgressToast(
  BuildContext context,
  String message,
) {
  final handle = XianYuProgressToastHandle._().._text.value = message;
  final entry = OverlayEntry(
    builder: (ctx) => _XianYuProgressToast(handle: handle),
  );
  handle._entry = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
  return handle;
}

class _XianYuProgressToast extends StatelessWidget {
  const _XianYuProgressToast({required this.handle});

  final XianYuProgressToastHandle handle;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      width: media.size.width,
      left: 0,
      bottom: media.viewPadding.bottom + 28,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: BoxConstraints(maxWidth: media.size.width * 0.85),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xE6323232),
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: handle._text,
                  builder: (context, text, _) => Text(
                    text,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      height: 1.3,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: handle._done,
                  builder: (context, done, _) {
                    if (done) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: ValueListenableBuilder<double?>(
                        valueListenable: handle._progress,
                        builder: (context, progress, _) {
                          final value = progress;
                          if (value == null) {
                            return const LinearProgressIndicator(
                              minHeight: 3,
                              borderRadius:
                                  BorderRadius.all(Radius.circular(1.5)),
                            );
                          }
                          return ClipRRect(
                            borderRadius:
                                const BorderRadius.all(Radius.circular(1.5)),
                            child: LinearProgressIndicator(
                              value: value,
                              minHeight: 3,
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _XianYuToast extends StatefulWidget {
  const _XianYuToast({
    required this.message,
    required this.duration,
    required this.onDismissed,
  });

  final String message;

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
                    decoration: TextDecoration.none,
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