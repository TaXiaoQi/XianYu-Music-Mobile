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

  /// 播放页大封面锚点（FlyingCoverAnchor 挂载）：
  /// 播放条 → 播放页的飞行封面用它的实时矩形作目标
  Rect Function()? outboundTargetProvider;

  /// 目标封面圆角（FlyingCoverAnchor 挂载）：传统播放页大封面为圆形
  /// 唱片，飞行副本目标圆角 = 起点宽度/2；沉浸式封面为全宽直角图，
  /// 锚点上报 0，飞行副本落成直角与真封面形状对齐。
  double? outboundTargetRadius;

  /// true = 目标端真封面在飞行期间隐藏（飞行副本是唯一封面），
  /// 落地瞬间恢复显示，副本 0.92→0 淡出正好叠回真封面。
  /// 沉浸式封面的「真封面」是页面背景层（不可藏），锚点声明
  /// hideOnFly=false 后飞行期间背景保持可见，副本落地淡出融入。
  final ValueNotifier<bool> targetHidden = ValueNotifier<bool>(false);

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
    Rect? Function()? targetProvider,
    bool hideTarget = false,
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
      // 旧飞行被打断，目标端真封面恢复显示
      targetHidden.value = false;
    }
    if (hideTarget) targetHidden.value = true;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _FlyingCoverOverlay(
        fromRect: fromRect,
        targetProvider: targetProvider ?? _targetProvider,
        songPath: songPath,
        networkUrl: networkUrl,
        thumbPath: thumbPath,
        radius: radius,
        targetRadius: outboundTargetRadius,
        onLanded: () {
          if (id == _flyId) {
            // 落地：真封面恢复显示，副本随后淡出叠回
            targetHidden.value = false;
            if (!completer.isCompleted) completer.complete(true);
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
    targetHidden.value = false;
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

/// 播放页封面锚点：把播放页大封面的实时矩形注册为
/// [FlyingCover.outboundTargetProvider]，供播放条 → 播放页的
/// 飞行封面取目标（播放条在 Navigator 之外，Hero 无法配对）。
///
/// [rectOverride]：沉浸式封面等「真封面是整块背景」的布局无法直接把
/// 锚点 child 当作飞行目标（整块矩形非方形、中心落在渐变区），传一个
/// 返回全局矩形的闭包作为飞行目标（沉浸式取上半屏顶部全宽正方形）。
/// [hideOnFly]=false：飞行期间不隐藏 child——沉浸式封面的 child 就是
/// 页面背景层，藏掉会让上半屏在飞行期间空白。
/// [targetRadius]：上报目标圆角（沉浸式全宽直角 = 0）。
class FlyingCoverAnchor extends StatefulWidget {
  const FlyingCoverAnchor({
    super.key,
    required this.child,
    this.rectOverride,
    this.hideOnFly = true,
    this.targetRadius,
  });

  final Widget child;
  final Rect Function()? rectOverride;
  final bool hideOnFly;
  final double? targetRadius;

  @override
  State<FlyingCoverAnchor> createState() => _FlyingCoverAnchorState();
}

class _FlyingCoverAnchorState extends State<FlyingCoverAnchor> {
  late final Rect Function() _provider = _computeProviderRect;

  Rect _computeProviderRect() {
    final over = widget.rectOverride;
    if (over != null) {
      final r = over();
      if (!r.isEmpty) return r;
    }
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return Rect.zero;
  }

  @override
  void initState() {
    super.initState();
    FlyingCover.instance.outboundTargetProvider = _provider;
    FlyingCover.instance.outboundTargetRadius = widget.targetRadius;
  }

  @override
  void dispose() {
    if (identical(FlyingCover.instance.outboundTargetProvider, _provider)) {
      FlyingCover.instance.outboundTargetProvider = null;
      FlyingCover.instance.outboundTargetRadius = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.hideOnFly) return widget.child;
    return ValueListenableBuilder<bool>(
      valueListenable: FlyingCover.instance.targetHidden,
      builder: (context, hidden, _) => Opacity(
        // 飞行副本在途时隐藏真封面（Opacity 不影响布局，矩形追踪照常）
        opacity: hidden ? 0.0 : 1.0,
        child: widget.child,
      ),
    );
  }
}

class _FlyingCoverOverlay extends StatefulWidget {
  const _FlyingCoverOverlay({
    required this.fromRect,
    required this.targetProvider,
    required this.songPath,
    required this.networkUrl,
    required this.thumbPath,
    required this.radius,
    required this.targetRadius,
    required this.onLanded,
    required this.onDone,
  });

  final Rect fromRect;
  final Rect? Function()? targetProvider;
  final String? songPath;
  final String? networkUrl;
  final String? thumbPath;
  final double radius;

  /// 目标端封面圆角：null = 旧行为（圆形唱片，起点宽度/2）；
  /// 沉浸式锚点上报 0（全宽直角图）。
  final double? targetRadius;
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

    // 飞行副本解码宽度按目的地大封面计算，并与真封面一样走 highQuality
    // 全图：与播放页同文件同解码宽度 → FileImage 缓存命中同一条目，飞行
    // 全程清晰且落地无二次解码跳变。传统播放页竖屏 coverSize = 屏宽×0.68；
    // 沉浸式封面目标为全宽矩形，按锚点实时矩形宽度取值（未就绪回落屏宽）。
    final t0 = widget.targetProvider?.call();
    final targetW = (t0 != null && !t0.isEmpty && t0.width > 0)
        ? t0.width
        : size.shortestSide * 0.68;
    _cacheWidth = (targetW * MediaQuery.of(context).devicePixelRatio)
        .round()
        .clamp(1, 1600);

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
    // 目标圆角：锚点上报值优先（沉浸式全宽直角 = 0）；无上报按旧行为
    // 走圆形唱片（起点宽度/2）。
    final targetRadius =
        widget.targetRadius ?? widget.fromRect.width / 2;
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
                    highQuality: true,
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
