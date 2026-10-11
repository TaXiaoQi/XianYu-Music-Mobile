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

  /// 目标端整块矩形形变：沉浸式真封面是整块背景（全宽非方形），锚点
  /// 声明 rectMorph 后飞行副本全程形变为目标矩形（宽高独立插值），
  /// 落地即与真封面同位同形，淡出完成嵌入；同时落地段淡出放缓到
  /// 300ms 与真封面淡入同步，阴影随贴合退场。
  bool outboundRectMorph = false;

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
    double? targetRadius,
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
        // targetRadius 为发射时快照（出向飞行中锚点可能 dispose，实例值
        // 会被复位，快照保底）；targetRadiusOverride 为调用方显式指定
        // （返回飞行落到迷你条圆形），两者在副本内按优先级解析
        targetRadius: outboundTargetRadius,
        targetRadiusOverride: targetRadius,
        rectMorph: outboundRectMorph,
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
/// [rectMorph]：飞行副本全程宽高独立形变到锚点整块矩形（沉浸式背景
/// 「真封面是非方形整块图」），落地即与真封面同位同形，淡出嵌入。
class FlyingCoverAnchor extends StatefulWidget {
  const FlyingCoverAnchor({
    super.key,
    required this.child,
    this.rectOverride,
    this.hideOnFly = true,
    this.targetRadius,
    this.rectMorph = false,
  });

  final Widget child;
  final Rect Function()? rectOverride;
  final bool hideOnFly;
  final double? targetRadius;
  final bool rectMorph;

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
    FlyingCover.instance.outboundRectMorph = widget.rectMorph;
  }

  @override
  void dispose() {
    if (identical(FlyingCover.instance.outboundTargetProvider, _provider)) {
      FlyingCover.instance.outboundTargetProvider = null;
      FlyingCover.instance.outboundTargetRadius = null;
      FlyingCover.instance.outboundRectMorph = false;
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
    required this.targetRadiusOverride,
    required this.rectMorph,
    required this.onLanded,
    required this.onDone,
  });

  final Rect fromRect;
  final Rect? Function()? targetProvider;
  final String? songPath;
  final String? networkUrl;
  final String? thumbPath;
  final double radius;

  /// 目标端封面圆角：发射时的锚点上报快照（沉浸式全宽直角 = 0）；
  /// null = 旧行为（圆形唱片，起点宽度/2）。
  final double? targetRadius;

  /// 调用方显式指定的目标圆角，优先于 [targetRadius] 与锚点实时值
  /// （返回飞行落到迷你条圆形封面时使用）。
  final double? targetRadiusOverride;

  /// 整块矩形形变：副本全程宽高独立插值到目标矩形（沉浸式背景
  /// 「真封面比方形大」），落地即贴合真封面，淡出即嵌入；同时落地
  /// 淡出放缓到 300ms 与真封面淡入同步。false = 旧行为方形插值。
  final bool rectMorph;
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

  /// 目标圆角解析：调用方显式指定 > 锚点实时上报（入向首飞锚点晚于
  /// 副本挂载，实时值补首飞快照缺失）> 发射快照 > 起点宽度/2（圆形
  /// 唱片旧行为）
  double get _effectiveTargetRadius {
    final over = widget.targetRadiusOverride;
    if (over != null) return over;
    final live = FlyingCover.instance.outboundTargetRadius;
    return live ?? widget.targetRadius ?? widget.fromRect.width / 2;
  }

  /// 整块矩形形变解析：锚点实时值与发射快照任一为真即生效
  bool get _effectiveRectMorph =>
      FlyingCover.instance.outboundRectMorph || widget.rectMorph;

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
    // 嵌入段时长在起飞时按锚点实时声明决定（见 _fadeOut）
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

    // 飞行副本解码宽度与真封面/预取预热统一（CoverImage.fullCoverDecodePx），
    // 与播放页同文件同解码宽度 → ImageCache 命中同一条目，飞行首帧即高清、
    // 落地无二次解码跳变。旧逻辑按目标矩形宽计算，与预热条目分键不命中，
    // 飞行前段只能显示缩略图占位（观感为模糊封面）。
    _cacheWidth = CoverImage.fullCoverDecodePx();

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
    // 整块矩形嵌入段放缓到 300ms，与真封面淡入同步（easeOut 前快后缓）
    _fadeCtrl.duration =
        _effectiveRectMorph ? const Duration(milliseconds: 300) : _fadeDuration;
    _fadeCtrl.forward().whenComplete(widget.onDone);
  }

  double _radius(double t) {
    // 目标圆角：见 _effectiveTargetRadius 的解析顺序
    final targetRadius = _effectiveTargetRadius;
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
            // 宽高独立插值：方形源到整块矩形目标（沉浸式背景）全程
            // 形变贴合，t=1 时副本与真封面同位同形，落地纯淡出嵌入
            final w = widget.fromRect.width +
                (toRect.width - widget.fromRect.width) * t;
            final h = widget.fromRect.height +
                (toRect.height - widget.fromRect.height) * t;
            final topLeft = center - Offset(w / 2, h / 2);

            // 飞行途中保持不透明：Opacity<1 会逐帧对整块区域 saveLayer，
            // 沉浸式全屏形变时是主要掉帧源；淡出只在落地嵌入段发生
            final opacity = _fading ? 0.92 * (1 - _fadeCtrl.value) : 1.0;

            final radius = _radius(t);
            // 阴影只在有形时绘制（alpha≈0 跳过）；飞向整块背景（沉浸式）
            // 目标端无卡片阴影，全程不绘全屏模糊阴影，避免大矩形逐帧高斯
            final shadowAlpha = _effectiveRectMorph
                ? (toRect.height >= widget.fromRect.height ? 0.0 : 0.25 * t)
                : 0.25;

            return Transform.translate(
              offset: topLeft,
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: shadowAlpha > 0.005
                        ? [
                            BoxShadow(
                              color:
                                  Colors.black.withValues(alpha: shadowAlpha),
                              blurRadius: 20,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : null,
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
