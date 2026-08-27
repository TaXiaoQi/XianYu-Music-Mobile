import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cover_image.dart';

/// 全局「飞封面」服务：从歌曲列表被点击行的封面，飞到迷你播放栏封面位置。
///
/// 参考桌面端 useFlyingCover：飞行（平移 + 缩放 + 弧线）→ 落地（触发播放，
/// 播放条封面随之更新）→ 淡出嵌入。用于掩盖点击播放到实际起播之间的延迟，
/// 并给出明确的播放反馈。
class FlyingCover {
  FlyingCover._();
  static final FlyingCover instance = FlyingCover._();

  OverlayState? _overlay;
  final List<Rect Function()> _targets = [];
  int _flyId = 0;
  OverlayEntry? _currentEntry;
  Completer<bool>? _currentCompleter;

  /// 当前生效的目标位置：取最后注册的活跃实例。
  ///
  /// 根页面由 shell 播放条注册；二级页面被 root navigator 覆盖 shell 后，
  /// 由页面自己的播放条注册（shell 播放条在二级页面不注册，见 MiniPlayerBar
  /// 的 [MiniPlayerBar.registerTarget]）。多实例并存时以最后注册者为准。
  Rect Function()? get _targetProvider =>
      _targets.isEmpty ? null : _targets.last;

  /// 由 app 根 Overlay 注册（app.dart builder 中调用）。
  void attach(OverlayState overlay) => _overlay = overlay;

  /// 由 MiniPlayerBar 注册其封面位置（每次布局后更新）。
  /// 同一实例重复注册会移到末尾（视为最新），避免累积重复项。
  void registerTarget(Rect Function() provider) {
    _targets.remove(provider);
    _targets.add(provider);
  }

  /// 注销指定实例的目标位置；仅移除该实例，不影响其他实例。
  void unregisterTarget(Rect Function() provider) {
    _targets.remove(provider);
  }

  /// 当前生效的迷你条封面目标矩形；无注册实例时返回 null。
  ///
  /// 供预测返回的封面回拨（PredictiveCoverReturnView）复用同一目标位。
  Rect? get targetRect {
    final provider = _targetProvider;
    return provider?.call();
  }

  /// 触发飞封面动画。返回的 Future 在封面落地时完成：
  /// - `true`：封面正常落地，可继续播放；
  /// - `false`：被更新的飞封面取代，不应再播放（新封面落地后自行触发播放）。
  /// 无法启动（无 Overlay / 起点无效）时直接返回 `true`，不阻塞播放。
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
    // 取代上一张飞封面：完成其 Future（false，不再触发播放）并移除其 OverlayEntry。
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

  /// 取消当前飞封面（如切歌/退出播放页）。
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

/// 从列表行 context 计算封面位置并触发飞封面。
///
/// [context] 必须是列表行（itemBuilder）的 context，其 RenderBox 即行本体。
/// 优先用 [coverContext]（封面自身 widget 的 context）精确定位起飞点——
/// 直接取封面 RenderBox 的全局矩形，与列表封面像素级一致，杜绝行高/布局差异
/// 导致的起飞偏移。未传 [coverContext] 时回退到遍历行内 RenderBox 树查找
/// `coverSize×coverSize` 的封面（行高高于封面时 vPad 偏移会不准）。
///
/// 返回的 Future 语义与 [FlyingCover.launch] 一致：`true` 表示封面已落地，
/// 可继续播放；`false` 表示被更新的飞封面取代，不应再播放。
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

    // 找行内实际封面 RenderBox（coverSize×coverSize），确保飞封面起点与列表封面
    // 完全一致。行高高于封面时（如标题换行）vPad 偏移会不准，导致封面从错误位置起飞。
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
  late final Rect _toRect;

  /// 起点中心位置（封面中心坐标）。
  late final Offset _p0;

  /// 终点中心位置（迷你条封面中心坐标）。
  late final Offset _p2;

  /// 弧线控制点（中段最高点）。
  late final Offset _ctrl;

  /// 目标缩放比例（终点尺寸 / 起点尺寸）。
  late final double _sx;

  /// 固定解码宽度：按起点封面尺寸 × 屏幕密度锁定，飞行中宽度逐帧变化时
  /// 不重解码，避免封面模糊/时隐时现。
  late final int _cacheWidth;

  bool _fading = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _flyCtrl = AnimationController(vsync: this, duration: _flyDuration);
    // 与桌面端 useFlyingCover 的 cubic-bezier(0.4, 0.0, 0.2, 1) 一致：
    // 起速快、收尾缓，飞行更有「甩出去再落定」的动感。
    _t = CurvedAnimation(parent: _flyCtrl, curve: Curves.fastOutSlowIn);
    _fadeCtrl = AnimationController(vsync: this, duration: _fadeDuration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    // MediaQuery 只能在 didChangeDependencies/build 中访问，initState 里取会抛
    // dependOnInheritedWidgetOfExactType 异常。
    final size = MediaQuery.of(context).size;
    final bottom = MediaQuery.of(context).padding.bottom;
    _toRect = widget.targetProvider?.call() ??
        // 首曲播放时迷你播放栏尚未挂载：用左下角固定坐标兜底。
        Rect.fromLTWH(20, size.height - bottom - 64, 46, 46);

    _sx = _toRect.width / widget.fromRect.width;
    _cacheWidth =
        (widget.fromRect.width * MediaQuery.of(context).devicePixelRatio)
            .round();

    // 用封面中心点作为位移基准（对齐桌面端 transform-origin: center）。
    // 飞行中封面始终绕自身中心缩放，起点/终点的 topLeft 需补偿中心偏移。
    _p0 = widget.fromRect.center;
    _p2 = _toRect.center;

    // 弧线控制点：中段 50% 处向上抬升，营造「飞」的弧线感。
    // 对齐桌面端：midY = dy * 0.5 - min(60, abs(dy) * 0.25 + 24)
    final dy = _p2.dy - _p0.dy;
    final lift = math.min(60.0, dy.abs() * 0.25 + 24);
    _ctrl = Offset.lerp(_p0, _p2, 0.5)! - Offset(0, lift);

    _flyCtrl.forward().whenComplete(_landed);
  }

  @override
  void dispose() {
    _flyCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  /// 封面落地：通知播放（onLanded 触发 onPlay，播放条封面随之更新），
  /// 随即淡出嵌入播放条，不再悬停等待。
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

  /// 二次贝塞尔弧线：起点 → 控制点 → 终点。
  /// 返回封面中心点坐标。
  Offset _bezier(double t) {
    final u = 1 - t;
    return _p0 * (u * u) + _ctrl * (2 * u * t) + _p2 * (t * t);
  }

  /// 缩放：全程从源封面尺寸平滑缩到迷你条封面尺寸（与位移同曲线），
  /// 视觉上「大封面缩进播放条」，与播放页 Hero 回程一致。
  double _scale(double t) => 1.0 + (_sx - 1.0) * t;

  /// 圆角过渡：从列表行圆角线性渐变到圆形（半径 = 边长一半），
  /// 与全程线性缩放同步，收拢进播放条时与圆形封面无缝衔接。
  double _radius(double t) {
    final targetRadius = widget.fromRect.width / 2;
    return widget.radius + (targetRadius - widget.radius) * t;
  }

  @override
  Widget build(BuildContext context) {
    // 用 Positioned(left/top) 而非 Positioned.fill：fill 会给子级屏幕大小的
    // 紧约束，Container(width: w, height: h) 会被强制撑满全屏，导致飞封面
    // 以整个列表大小出现（曾表现为超大封面超过屏幕宽度）。
    return Positioned(
      left: 0,
      top: 0,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: Listenable.merge([_flyCtrl, _fadeCtrl]),
          builder: (context, _) {
            final t = _t.value;
            final center = _bezier(t);
            final scale = _scale(t);
            final w = widget.fromRect.width * scale;
            final h = widget.fromRect.height * scale;
            // 从中心位置反推 topLeft，使封面中心恰好落在贝塞尔曲线上
            final topLeft = center - Offset(w / 2, h / 2);

            // 与桌面端一致：飞行中透明度从 1 缓降到 0.92，淡出时归零。
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
                      // 与桌面端 useFlyingCover 同款投影：0 6px 20px rgba(0,0,0,0.25)。
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
