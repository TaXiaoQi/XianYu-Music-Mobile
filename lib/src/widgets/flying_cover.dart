import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import 'cover_image.dart';

/// 全局「飞封面」服务：从歌曲列表被点击行的封面，飞到迷你播放栏封面位置。
///
/// 参考桌面端 useFlyingCover：飞行（平移 + 缩放 + 弧线）→ 悬停（等底栏封面
/// 更新）→ 淡出。用于掩盖点击播放到实际起播之间的延迟，并给出明确的播放反馈。
class FlyingCover {
  FlyingCover._();
  static final FlyingCover instance = FlyingCover._();

  OverlayState? _overlay;
  Rect Function()? _targetProvider;
  int _flyId = 0;

  /// 由 app 根 Overlay 注册（app.dart builder 中调用）。
  void attach(OverlayState overlay) => _overlay = overlay;

  /// 由 MiniPlayerBar 注册其封面位置（每次布局后更新）。
  void registerTarget(Rect Function() provider) => _targetProvider = provider;
  void unregisterTarget() => _targetProvider = null;

  /// 触发飞封面动画。封面从 [fromRect] 飞到迷你播放栏封面位置。
  void launch({
    required Rect fromRect,
    String? songPath,
    String? networkUrl,
    String? thumbPath,
    double radius = 6,
  }) {
    final overlay = _overlay;
    if (overlay == null) return;
    if (fromRect.isEmpty || fromRect.width <= 0 || fromRect.height <= 0) {
      return;
    }
    final id = ++_flyId;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _FlyingCoverOverlay(
        fromRect: fromRect,
        targetProvider: _targetProvider,
        songPath: songPath,
        networkUrl: networkUrl,
        thumbPath: thumbPath,
        radius: radius,
        onDone: () {
          if (id == _flyId) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }

  /// 取消当前飞封面（如切歌/退出播放页）。
  void cancel() => _flyId++;
}

/// 从列表行 context 计算封面位置并触发飞封面。
///
/// [context] 必须是列表行（itemBuilder）的 context，其 RenderBox 即行本体。
/// 优先用 [coverContext]（封面自身 widget 的 context）精确定位起飞点——
/// 直接取封面 RenderBox 的全局矩形，与列表封面像素级一致，杜绝行高/布局差异
/// 导致的起飞偏移。未传 [coverContext] 时回退到遍历行内 RenderBox 树查找
/// `coverSize×coverSize` 的封面（行高高于封面时 vPad 偏移会不准）。
void launchFlyCover(
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
}) {
  Rect? fromRect;
  if (coverContext != null) {
    final ro = coverContext.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      fromRect = ro.localToGlobal(Offset.zero) & ro.size;
    }
  }
  if (fromRect == null) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
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
  FlyingCover.instance.launch(
    fromRect: fromRect,
    songPath: songPath,
    networkUrl: networkUrl,
    thumbPath: thumbPath,
    radius: radius,
  );
}

class _FlyingCoverOverlay extends ConsumerStatefulWidget {
  const _FlyingCoverOverlay({
    required this.fromRect,
    required this.targetProvider,
    required this.songPath,
    required this.networkUrl,
    required this.thumbPath,
    required this.radius,
    required this.onDone,
  });

  final Rect fromRect;
  final Rect Function()? targetProvider;
  final String? songPath;
  final String? networkUrl;
  final String? thumbPath;
  final double radius;
  final VoidCallback onDone;

  @override
  ConsumerState<_FlyingCoverOverlay> createState() =>
      _FlyingCoverOverlayState();
}

class _FlyingCoverOverlayState extends ConsumerState<_FlyingCoverOverlay>
    with TickerProviderStateMixin {
  static const _flyDuration = Duration(milliseconds: 520);
  static const _fadeDuration = Duration(milliseconds: 220);
  static const _parkTimeout = Duration(seconds: 3);

  late final AnimationController _flyCtrl;
  late final Animation<double> _t;
  late final AnimationController _fadeCtrl;
  late final Rect _toRect;
  late final Offset _p0;
  late final Offset _p2;
  late final Offset _mid;
  late final double _sx;
  bool _parking = false;
  bool _fading = false;
  bool _initialized = false;
  Timer? _parkTimer;
  String? _startPath;

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
    _p0 = widget.fromRect.topLeft;
    // 中心缩放（对齐桌面端 transform-origin:center）：终点 topLeft 需补偿中心偏移，
    // 使封面中心落在迷你条封面中心，飞行全程封面以自身中心收拢。
    final centerOffset = Offset(
      widget.fromRect.width * (1 - _sx) / 2,
      widget.fromRect.height * (1 - _sx) / 2,
    );
    _p2 = _toRect.topLeft - centerOffset;
    final dy = _p2.dy - _p0.dy;
    final lift = math.min(60.0, dy.abs() * 0.25 + 24);
    _mid = Offset.lerp(_p0, _p2, 0.5)! - Offset(0, lift);
    _startPath = ref.read(playerProvider).current?.path;

    // 悬停阶段监听底栏封面更新：current 变化即淡出。
    ref.listenManual(playerProvider, (prev, next) {
      if (!_parking || _fading) return;
      if (next.current?.path != _startPath) _fadeOut();
    });

    _flyCtrl.forward().whenComplete(_park);
  }

  @override
  void dispose() {
    _parkTimer?.cancel();
    _flyCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _park() {
    if (!mounted) return;
    setState(() => _parking = true);
    _parkTimer = Timer(_parkTimeout, _fadeOut);
  }

  void _fadeOut() {
    if (_fading || !mounted) return;
    _fading = true;
    _parkTimer?.cancel();
    _fadeCtrl.forward().whenComplete(widget.onDone);
  }

  /// 二次贝塞尔弧线：起点 → 中段抬升点 → 终点。
  Offset _bezier(double t) {
    final u = 1 - t;
    return _p0 * (u * u) + _mid * (2 * u * t) + _p2 * (t * t);
  }

  /// 缩放：全程从源封面尺寸平滑缩到迷你条封面尺寸（与位移同曲线），
  /// 视觉上「大封面缩进播放条」，与播放页 Hero 回程一致。
  double _scale(double t) => 1.0 + (_sx - 1.0) * t;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: Listenable.merge([_flyCtrl, _fadeCtrl]),
          builder: (context, _) {
            final t = _t.value;
            final pos = _bezier(t);
            final scale = _scale(t);
            // 与桌面端一致：飞行中透明度从 1 缓降到 0.92，悬停保持，淡出时归零。
            final opacity = _fading
                ? (0.92 * (1 - _fadeCtrl.value))
                : (1.0 - 0.08 * t);
            // 圆角过渡：从列表行圆角渐变到圆形（半径 = 边长一半），到达底栏时
            // 与圆形封面无缝衔接，避免圆角矩形与圆形封面重叠。
            final radius = widget.radius +
                (widget.fromRect.width / 2 - widget.radius) * t;
            return Transform.translate(
              offset: pos,
              child: Transform.scale(
                // 中心缩放（对齐桌面端 transform-origin:center）：封面绕自身中心
                // 缩放，飞行中始终以列表封面为中心收拢，视觉上「从列表封面起飞」。
                scale: scale,
                alignment: Alignment.center,
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: widget.fromRect.width,
                    height: widget.fromRect.height,
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
                      width: widget.fromRect.width,
                      height: widget.fromRect.height,
                      radius: radius,
                    ),
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
