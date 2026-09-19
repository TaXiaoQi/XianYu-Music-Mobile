import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cover_image.dart';

class FlyingCover {
  FlyingCover._();
  static final FlyingCover instance = FlyingCover._();

  OverlayState? _overlay;
  final List<Rect Function()> _targets = [];
  int _flyId = 0;
  OverlayEntry? _currentEntry;
  Completer<bool>? _currentCompleter;

  Rect Function()? get _targetProvider =>
      _targets.isEmpty ? null : _targets.last;

  void attach(OverlayState overlay) => _overlay = overlay;

  void registerTarget(Rect Function() provider) {
    _targets.remove(provider);
    _targets.add(provider);
  }

  void unregisterTarget(Rect Function() provider) {
    _targets.remove(provider);
  }

  Rect? get targetRect {
    final provider = _targetProvider;
    return provider?.call();
  }

  Future<bool> waitTargetReady({
    Duration timeout = const Duration(milliseconds: 600),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final r = targetRect;
      if (r != null && !r.isEmpty && r.width > 0 && r.height > 0) {
        return true;
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    return targetRect != null;
  }

  Future<bool> launch({
    required Rect fromRect,
    String? songPath,
    String? networkUrl,
    String? thumbPath,
    double radius = 6,
  }) {
    final overlay = _overlay;
    if (overlay == null) return Future.value(true);
    if (fromRect.isEmpty || fromRect.width <= 0 || fromRect.height <= 0) {
      return Future.value(true);
    }
    final id = ++_flyId;
    final completer = Completer<bool>();
    final prevEntry = _currentEntry;
    final prevCompleter = _currentCompleter;
    if (prevEntry != null) {
      if (prevCompleter != null && !prevCompleter.isCompleted) {
        prevCompleter.complete(false);
      }
      prevEntry.remove();
    }
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _FlyingCoverOverlay(
        fromRect: fromRect,
        targetProvider: _targetProvider,
        songPath: songPath,
        networkUrl: networkUrl,
        thumbPath: thumbPath,
        radius: radius,
        onLanded: () {
          if (id == _flyId && !completer.isCompleted) {
            completer.complete(true);
          }
        },
        onDone: () {
          if (id == _flyId) {
            entry.remove();
            if (_currentEntry == entry) _currentEntry = null;
            if (!completer.isCompleted) completer.complete(true);
          }
        },
      ),
    );
    _currentEntry = entry;
    _currentCompleter = completer;
    overlay.insert(entry);
    return completer.future;
  }

  void cancel() {
    _flyId++;
    final entry = _currentEntry;
    final completer = _currentCompleter;
    _currentEntry = null;
    _currentCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    entry?.remove();
  }
}

Future<bool> launchFlyCover(
  BuildContext context, {
  required double coverSize,
  double vPad = 7,
  double horizontalPad = 16,
  bool centerVertically = false,
  BuildContext? coverContext,
  String? songPath,
  String? networkUrl,
  String? thumbPath,
  double radius = 6,
}) async {
  Rect? fromRect;
  if (coverContext != null) {
    final ro = coverContext.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      fromRect = ro.localToGlobal(Offset.zero) & ro.size;
    }
  }
  if (fromRect == null) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return true;
    final box = ro;

    Rect? coverRect;
    void walk(RenderObject node) {
      if (coverRect != null) return;
      if (node is RenderBox && node.hasSize) {
        final s = node.size;
        if ((s.width - coverSize).abs() < 0.5 &&
            (s.height - coverSize).abs() < 0.5) {
          coverRect = node.localToGlobal(Offset.zero) & s;
          return;
        }
      }
      node.visitChildren(walk);
    }
    walk(box);

    final topLeft = box.localToGlobal(Offset.zero);
    fromRect = coverRect ??
        Rect.fromLTWH(
          topLeft.dx + horizontalPad,
          topLeft.dy +
              (centerVertically ? (box.size.height - coverSize) / 2 : vPad),
          coverSize,
          coverSize,
        );
  }
  return FlyingCover.instance.launch(
    fromRect: fromRect,
    songPath: songPath,
    networkUrl: networkUrl,
    thumbPath: thumbPath,
    radius: radius,
  );
}

class _FlyingCoverOverlay extends StatefulWidget {
  const _FlyingCoverOverlay({
    required this.fromRect,
    required this.targetProvider,
    required this.songPath,
    required this.networkUrl,
    required this.thumbPath,
    required this.radius,
    required this.onLanded,
    required this.onDone,
  });

  final Rect fromRect;
  final Rect Function()? targetProvider;
  final String? songPath;
  final String? networkUrl;
  final String? thumbPath;
  final double radius;
  final VoidCallback onLanded;
  final VoidCallback onDone;

  @override
  State<_FlyingCoverOverlay> createState() => _FlyingCoverOverlayState();
}

class _FlyingCoverOverlayState extends State<_FlyingCoverOverlay>
    with TickerProviderStateMixin {
  static const _flyDuration = Duration(milliseconds: 520);
  static const _fadeDuration = Duration(milliseconds: 220);

  late final AnimationController _flyCtrl;
  late final Animation<double> _t;
  late final AnimationController _fadeCtrl;

  late final Rect _fallbackRect;

  late final Offset _p0;

  late final int _cacheWidth;

  bool _fading = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _flyCtrl = AnimationController(vsync: this, duration: _flyDuration);
    _t = CurvedAnimation(parent: _flyCtrl, curve: Curves.fastOutSlowIn);
    _fadeCtrl = AnimationController(vsync: this, duration: _fadeDuration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final size = MediaQuery.of(context).size;
    final bottom = MediaQuery.of(context).padding.bottom;
    _fallbackRect = Rect.fromLTWH(20, size.height - bottom - 64, 46, 46);

    _cacheWidth =
        (widget.fromRect.width * MediaQuery.of(context).devicePixelRatio)
            .round();

    _p0 = widget.fromRect.center;

    _flyCtrl.forward().whenComplete(_landed);
  }

  @override
  void dispose() {
    _flyCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _landed() {
    if (!mounted) return;
    widget.onLanded();
    _fadeOut();
  }

  void _fadeOut() {
    if (_fading || !mounted) return;
    _fading = true;
    _fadeCtrl.forward().whenComplete(widget.onDone);
  }

  double _radius(double t) {
    final targetRadius = widget.fromRect.width / 2;
    return widget.radius + (targetRadius - widget.radius) * t;
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: Listenable.merge([_flyCtrl, _fadeCtrl]),
          builder: (context, _) {
            final t = _t.value;
            final toRect = widget.targetProvider?.call() ?? _fallbackRect;
            final toCenter = toRect.center;
            final dy = toCenter.dy - _p0.dy;
            final lift = math.min(60.0, dy.abs() * 0.25 + 24);
            final ctrl = Offset.lerp(_p0, toCenter, 0.5)! - Offset(0, lift);
            final u = 1 - t;
            final center =
                _p0 * (u * u) + ctrl * (2 * u * t) + toCenter * (t * t);
            final sx = toRect.width / widget.fromRect.width;
            final scale = 1.0 + (sx - 1.0) * t;
            final w = widget.fromRect.width * scale;
            final h = widget.fromRect.height * scale;
            final topLeft = center - Offset(w / 2, h / 2);

            final opacity = _fading
                ? (0.92 * (1 - _fadeCtrl.value))
                : (1.0 - 0.08 * t);

            final radius = _radius(t);

            return Transform.translate(
              offset: topLeft,
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: CoverImage(
                    songPath: widget.songPath ?? '',
                    networkUrl: widget.networkUrl,
                    thumbPath: widget.thumbPath,
                    width: w,
                    height: h,
                    radius: radius,
                    cacheWidth: _cacheWidth,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
