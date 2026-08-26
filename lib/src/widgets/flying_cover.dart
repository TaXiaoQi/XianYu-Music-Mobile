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
/// [context] 必须是列表行（itemBuilder）的 context，其 RenderBox 即行本体；
/// 封面位于行内左上角偏移 (horizontalPad, vPad) 处、边长为 [coverSize]。
/// [centerVertically] 为 true 时忽略 [vPad]，封面在行内垂直居中
/// （ListTile 等 leading 垂直居中的行使用）。
void launchFlyCover(
  BuildContext context, {
  required double coverSize,
  double vPad = 7,
  double horizontalPad = 16,
  bool centerVertically = false,
  String? songPath,
  String? networkUrl,
  String? thumbPath,
  double radius = 6,
}) {
  final ro = context.findRenderObject();
  debugPrint('[fly] findRenderObject => ${ro.runtimeType}');
  if (ro is! RenderBox || !ro.hasSize) return;
  final box = ro;
  final topLeft = box.localToGlobal(Offset.zero);
  final dy = centerVertically ? (box.size.height - coverSize) / 2 : vPad;
  FlyingCover.instance.launch(
    fromRect: Rect.fromLTWH(
      topLeft.dx + horizontalPad,
      topLeft.dy + dy,
      coverSize,
      coverSize,
    ),
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
  Timer? _parkTimer;
  String? _startPath;

  @override
  void initState() {
    super.initState();
    final size = MediaQuery.of(context).size;
    final bottom = MediaQuery.of(context).padding.bottom;
    _toRect = widget.targetProvider?.call() ??
        // 首曲播放时迷你播放栏尚未挂载：用左下角固定坐标兜底。
        Rect.fromLTWH(20, size.height - bottom - 64, 46, 46);
    _p0 = widget.fromRect.topLeft;
    _p2 = _toRect.topLeft;
    final dy = _p2.dy - _p0.dy;
    final lift = math.min(60.0, dy.abs() * 0.25 + 24);
    _mid = Offset.lerp(_p0, _p2, 0.5)! - Offset(0, lift);
    _sx = _toRect.width / widget.fromRect.width;
    _startPath = ref.read(playerProvider).current?.path;

    _flyCtrl = AnimationController(vsync: this, duration: _flyDuration);
    _t = CurvedAnimation(parent: _flyCtrl, curve: Curves.easeInOutCubic);
    _fadeCtrl = AnimationController(vsync: this, duration: _fadeDuration);

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

  /// 缩放：前 50% 放大到 1.12，后 50% 缩到目标比例。
  double _scale(double t) {
    if (t < 0.5) return 1 + 0.12 * (t / 0.5);
    final k = (t - 0.5) / 0.5;
    return 1.12 + (_sx - 1.12) * k;
  }

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
            final opacity = _fading ? (1 - _fadeCtrl.value) : 1.0;
            // 圆角过渡：从列表行圆角渐变到圆形（半径 = 边长一半），到达底栏时
            // 与圆形封面无缝衔接，避免圆角矩形与圆形封面重叠。
            final radius = widget.radius +
                (widget.fromRect.width / 2 - widget.radius) * t;
            return Transform.translate(
              offset: pos,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topLeft,
                child: Opacity(
                  opacity: opacity,
                  child: SizedBox(
                    width: widget.fromRect.width,
                    height: widget.fromRect.height,
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
