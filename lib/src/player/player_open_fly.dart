import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/cover_image.dart';
import 'player_provider.dart';

/// 打开播放详情页时顶层「飞封面」控制器的 Riverpod 入口。
final playerOpenFlyProvider =
    ChangeNotifierProvider<PlayerOpenFlyController>(
  (_) => PlayerOpenFlyController.instance,
);

/// 顶层「飞封面」控制器：打开播放详情页时，把播放条封面从其在屏幕上的实际位置
/// 起飞、沿弧线飞入详情页大封面圆心。
///
/// 根因：详情页是不透明(opaque)路由从底部上滑覆盖，页面一出现就盖住左下角播放条，
/// 导致 Hero(同标签)在「打开」时起飞源封面瞬间被盖住、几乎看不到飞行过程；
/// 而「关闭」时播放条随页面收回露出，返回飞行反而完整 → 开/关不对称。
/// 这里改用 app 根 Overlay 的顶层图层承载封面飞行：起飞点=播放条封面全局矩形，
/// 落点=详情页大封面全局矩形(逐帧采样，与页面上滑转场同步收敛)。因该图层挂在
/// 所有页面之上、永不被详情页覆盖，所以能完整看到「从播放条飞入」的全过程。
class PlayerOpenFlyController extends ChangeNotifier {
  PlayerOpenFlyController._();
  static final PlayerOpenFlyController instance = PlayerOpenFlyController._();

  OverlayState? _overlay;
  Rect Function()? _destProvider;
  OverlayEntry? _entry;
  bool _coverVisible = true;

  /// 详情页大封面是否可见。飞入期间为 false，由顶层飞封面接管视觉；
  /// 落地后再恢复，保证与关闭对称。
  bool get coverVisible => _coverVisible;

  /// 由 app 根 Overlay 注册（app.dart builder 中调用，与 FlyingCover 同点挂载）。
  void attach(OverlayState overlay) => _overlay = overlay;

  /// 详情页大封面在布局后注册其全局矩形（供飞入落点精算）；离开播放页时清空。
  void registerDest(Rect Function() provider) => _destProvider = provider;

  void clearDest() => _destProvider = null;

  void setCoverVisible(bool visible) {
    if (_coverVisible == visible) return;
    _coverVisible = visible;
    notifyListeners();
  }

  /// 触发打开飞封面：起飞=播放条封面 rect，落点=详情页大封面 rect。
  /// 无法启动（无 Overlay / rect 无效 / 已有飞入）时静默返回，详情页照常打开。
  void open({required Rect fromRect, required QueueItem current}) {
    final overlay = _overlay;
    if (overlay == null || _entry != null) return;
    if (fromRect.isEmpty ||
        fromRect.width <= 0 ||
        fromRect.height <= 0) {
      return;
    }
    setCoverVisible(false);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _OpenFlyCover(
        fromRect: fromRect,
        songPath: current.path,
        networkUrl: current.coverUrl,
        getDest: () {
          final rect = _destProvider?.call();
          return (rect == null || rect.isEmpty) ? null : rect;
        },
        onReveal: () => setCoverVisible(true),
        onLand: () {
          if (_entry != entry) return;
          entry.remove();
          if (_entry == entry) _entry = null;
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

/// 由播放详情页包裹大封面，把封面 GlobalKey 的全局矩形注册给飞封面落点。
/// 仅在当前页面（当前布局）起作用；切换布局/离开时自动换绑。
class OpenFlyDest extends StatefulWidget {
  const OpenFlyDest({super.key, required this.child});

  final Widget child;

  @override
  State<OpenFlyDest> createState() => _OpenFlyDestState();
}

class _OpenFlyDestState extends State<OpenFlyDest> {
  final GlobalKey _key = GlobalKey();
  Rect Function()? _provider;

  @override
  void initState() {
    super.initState();
    // 首个骨架页也要注册（飞封面可能在首帧就开始采样）。等首次布局后才有 rect，
    // 采样函数本身对 Rect.zero/未布局做防御。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _register();
    });
  }

  void _register() {
    PlayerOpenFlyController.instance.registerDest(
      _provider ??= () {
        final ctx = _key.currentContext;
        final ro = ctx?.findRenderObject();
        if (ro is RenderBox && ro.hasSize) {
          return ro.localToGlobal(Offset.zero) & ro.size;
        }
        return Rect.zero;
      },
    );
  }

  @override
  void dispose() {
    PlayerOpenFlyController.instance.clearDest();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

/// 顶层飞封面图层：封面从播放条位置起飞，沿弧线飞到详情页大封面圆心并缩放到位。
class _OpenFlyCover extends StatefulWidget {
  const _OpenFlyCover({
    required this.fromRect,
    required this.songPath,
    required this.networkUrl,
    required this.getDest,
    required this.onReveal,
    required this.onLand,
  });

  final Rect fromRect;
  final String songPath;
  final String? networkUrl;

  /// 详情页大封面全局矩形采样（布局后返回有效值；落地前已收敛到圆心/尺寸）。
  final Rect? Function() getDest;

  /// 主飞行到位（已落到大封面圆心与尺寸一致）时回调 → 恢复大封面可见，开始淡入。
  final VoidCallback onReveal;

  /// 淡出完成、移除 OverlayEntry 时回调。
  final VoidCallback onLand;

  @override
  State<_OpenFlyCover> createState() => _OpenFlyCoverState();
}

class _OpenFlyCoverState extends State<_OpenFlyCover>
    with TickerProviderStateMixin {
  static const Duration _flyDuration = Duration(milliseconds: 500);
  static const Duration _fadeDuration = Duration(milliseconds: 130);

  late final AnimationController _flyCtrl;
  late final Animation<double> _t;
  late final AnimationController _fadeCtrl;

  Offset _from = Offset.zero;
  Rect _dest = Rect.zero;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _from = widget.fromRect.center;
    _flyCtrl = AnimationController(vsync: this, duration: _flyDuration);
    _t = CurvedAnimation(parent: _flyCtrl, curve: Curves.easeOutCubic);
    _fadeCtrl =
        AnimationController(vsync: this, duration: _fadeDuration);
    _flyCtrl.addListener(_sample);
    _flyCtrl.forward().whenComplete(_revealAndFade);
  }

  @override
  void dispose() {
    _flyCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  /// 每帧采样目标矩形：详情页随上滑转场逐步收敛，最终等于大封面的圆心与尺寸，
  /// 保证飞行终点与大封面完全重合（无缝淡入）。
  void _sample() {
    final dest = widget.getDest();
    if (dest != null && dest.width > 0 && dest.height > 0) {
      _dest = dest;
    }
    if (mounted) setState(() {});
  }

  void _revealAndFade() {
    if (!mounted) return;
    if (!_revealed) {
      _revealed = true;
      widget.onReveal(); // 大封面开始淡入，与封面淡出交叉
    }
    _fadeCtrl.forward().whenComplete(_finish);
  }

  void _finish() {
    if (mounted) widget.onLand();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t.value;
    // 圆心沿二次贝塞尔弧线：起点 → 控制点 → 目标圆心（随采样更新，收敛到最终圆心）。
    final target = _dstCenter(t);
    final p0 = _from;
    final p2 = target;
    final dy = p2.dy - p0.dy;
    final lift = math.min(60.0, dy.abs() * 0.25 + 24);
    final ctrl = Offset.lerp(p0, p2, 0.5)! - Offset(0, lift);
    final u = 1 - t;
    final center = p0 * (u * u) + ctrl * (2 * u * t) + p2 * (t * t);

    // 尺寸：从播放条封面缩放到当前采样到的大封面尺寸（采样有滞后，最终帧即目标尺寸）。
    final dW = _dest.width > 0 ? _dest.width : widget.fromRect.width;
    final dH = _dest.height > 0 ? _dest.height : widget.fromRect.height;
    final w = widget.fromRect.width + (dW - widget.fromRect.width) * t;
    final h = widget.fromRect.height + (dH - widget.fromRect.height) * t;
    final topLeft = center - Offset(w / 2, h / 2);

    // 圆角：从圆形(半径=边长一半)过渡到大封面圆角。
    final radius =
        23.0 + ((math.min(w, h) / 2) - 23.0) * t;

    // 飞行主体透明度稳定在 1，落地后与详情页大封面交叉淡入而淡出。
    final opacity = _revealed ? (1 - _fadeCtrl.value) : 1.0;

    return Positioned(
      left: 0,
      top: 0,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: Listenable.merge([_flyCtrl, _fadeCtrl]),
          builder: (context, _) {
            return Transform.translate(
              offset: topLeft,
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 36,
                        offset: Offset(0, 18),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: _FlyCoverImage(
                      songPath: widget.songPath,
                      networkUrl: widget.networkUrl,
                      width: w,
                      height: h,
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

  /// 目标圆心：用最新采样的大封面圆心。若尚未拿到有效矩形，退化为屏幕中心兜底，
  /// 避免首帧飞到 (0,0)。
  Offset _dstCenter(double t) {
    if (_dest.width > 0 && _dest.height > 0) return _dest.center;
    final size = MediaQuery.of(context).size;
    return Offset(size.width / 2, size.height * 0.42);
  }
}

/// 飞行封面图：直接用盖封面的封面组件，避免硬编码取图逻辑。
class _FlyCoverImage extends StatelessWidget {
  const _FlyCoverImage({
    required this.songPath,
    required this.networkUrl,
    required this.width,
    required this.height,
  });

  final String songPath;
  final String? networkUrl;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    // 复用 CoverImage：本地封面经 Rust 缩略图、在线封面带缓存，与播放页一致。
    return CoverImage(
      songPath: songPath,
      networkUrl: networkUrl,
      width: width,
      height: height,
      radius: 0,
      icon: Icons.music_note,
    );
  }
}