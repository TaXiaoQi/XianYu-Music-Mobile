import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cover_image.dart';
import 'flying_cover.dart';

class PredictiveCoverReturn {
  PredictiveCoverReturn._();
  static final PredictiveCoverReturn instance = PredictiveCoverReturn._();

  final ValueNotifier<bool> returning = ValueNotifier<bool>(false);

  _ReturnSource? _source;
  Rect Function()? _targetProvider;

  void registerSource({
    String? songPath,
    String? networkUrl,
    String? thumbPath,
    required Rect Function() rectProvider,
  }) {
    final s = _source ??= _ReturnSource();
    s.rectProvider = rectProvider;
    s.songPath = songPath;
    s.networkUrl = networkUrl;
    s.thumbPath = thumbPath;
  }

  void updateSource({String? songPath, String? networkUrl, String? thumbPath}) {
    final s = _source;
    if (s == null) return;
    s.songPath = songPath;
    s.networkUrl = networkUrl;
    s.thumbPath = thumbPath;
  }

  void unregisterSource(Rect Function() provider) {
    final s = _source;
    if (s != null && identical(s.rectProvider, provider)) {
      _source = null;
    }
  }

  Rect get sourceRect => _source?.rectProvider?.call() ?? Rect.zero;

  (String?, String?, String?) get coverSource {
    final s = _source;
    return (s?.songPath, s?.networkUrl, s?.thumbPath);
  }

  void registerTarget(Rect Function() provider) {
    _targetProvider = provider;
  }

  void unregisterTarget(Rect Function() provider) {
    if (identical(_targetProvider, provider)) {
      _targetProvider = null;
    }
  }

  Rect? get targetRect => _targetProvider?.call();
}

class _ReturnSource {
  String? songPath;
  String? networkUrl;
  String? thumbPath;
  Rect Function()? rectProvider;
}

class CoverReturnSource extends StatefulWidget {
  const CoverReturnSource({
    super.key,
    required this.child,
    this.songPath,
    this.networkUrl,
    this.thumbPath,
  });

  final Widget child;
  final String? songPath;
  final String? networkUrl;
  final String? thumbPath;

  @override
  State<CoverReturnSource> createState() => _CoverReturnSourceState();
}

class _CoverReturnSourceState extends State<CoverReturnSource> {
  final GlobalKey _key = GlobalKey();
  bool _registered = false;
  // ignore: prefer_function_declarations_over_variables
  late final Rect Function() _provider = () {
    final ctx = _key.currentContext;
    if (ctx == null || !ctx.mounted) return Rect.zero;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return Rect.zero;
    try {
      return ro.localToGlobal(Offset.zero) & ro.size;
    } catch (_) {
      return Rect.zero;
    }
  };

  void _sync() {
    if (!_registered) {
      _registered = true;
      PredictiveCoverReturn.instance.registerSource(
        songPath: widget.songPath,
        networkUrl: widget.networkUrl,
        thumbPath: widget.thumbPath,
        rectProvider: _provider,
      );
    } else {
      PredictiveCoverReturn.instance.updateSource(
        songPath: widget.songPath,
        networkUrl: widget.networkUrl,
        thumbPath: widget.thumbPath,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant CoverReturnSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    PredictiveCoverReturn.instance.unregisterSource(_provider);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: ValueListenableBuilder<bool>(
        valueListenable: PredictiveCoverReturn.instance.returning,
        builder: (context, returning, _) => Opacity(
          opacity: returning ? 0.0 : 1.0,
          child: widget.child,
        ),
      ),
    );
  }
}

class PredictiveCoverReturnView extends StatefulWidget {
  const PredictiveCoverReturnView({
    super.key,
    required this.animation,
  });

  final Animation<double> animation;

  @override
  State<PredictiveCoverReturnView> createState() =>
      _PredictiveCoverReturnViewState();
}

class _PredictiveCoverReturnViewState extends State<PredictiveCoverReturnView> {
  OverlayEntry? _entry;

  Rect? _anchoredSource;

  Rect _effectiveSource() {
    final anchored = _anchoredSource;
    if (anchored != null) return anchored;
    final src = PredictiveCoverReturn.instance.sourceRect;
    if (!src.isEmpty) _anchoredSource = src;
    return src;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entry == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _entry != null) return;
        final entry = OverlayEntry(builder: (ctx) => _buildCover(ctx));
        _entry = entry;
        PredictiveCoverReturn.instance.returning.value = true;
        Overlay.of(context, rootOverlay: true).insert(entry);
      });
    }
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    _anchoredSource = null;
    PredictiveCoverReturn.instance.returning.value = false;
    super.dispose();
  }

  Rect _target(BuildContext context) {
    return FlyingCover.instance.targetRect ??
        PredictiveCoverReturn.instance.targetRect ??
        Rect.fromLTWH(
          20,
          MediaQuery.of(context).size.height -
              MediaQuery.of(context).padding.bottom -
              64,
          46,
          46,
        );
  }

  Widget _buildCover(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: widget.animation,
          builder: (context, _) {
            final src = _effectiveSource();
            if (src.isEmpty) return const SizedBox.shrink();
            final (songPath, networkUrl, thumbPath) =
                PredictiveCoverReturn.instance.coverSource;
            final target = _target(context);

            final p0 = src.center;
            final p2 = target.center;
            final s0 = src.width;
            final s1 = target.width;
            final srcRadius = math.min(32.0, s0 * 0.08);
            final dstRadius = s1 / 2;

            final raw = (1 - widget.animation.value).clamp(0.0, 1.0);
            const startProgress = 1 / 3;
            final t = raw <= startProgress
                ? 0.0
                : (raw - startProgress) / (1 - startProgress);
            final center = Offset.lerp(p0, p2, t)!;
            final w = s0 + (s1 - s0) * t;
            final h = w;
            final radius = srcRadius + (dstRadius - srcRadius) * t;
            final topLeft = center - Offset(w / 2, h / 2);
            double opacity = 1.0;
            if (t > 0.94) opacity = 1 - (t - 0.94) / 0.06;
            opacity = opacity.clamp(0.0, 1.0);

            return Positioned(
              left: topLeft.dx,
              top: topLeft.dy,
              width: w,
              height: h,
              child: IgnorePointer(
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
                      songPath: songPath ?? '',
                      networkUrl: networkUrl,
                      thumbPath: thumbPath,
                      width: w,
                      height: h,
                      radius: radius,
                      highQuality: true,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}