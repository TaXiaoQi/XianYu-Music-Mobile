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