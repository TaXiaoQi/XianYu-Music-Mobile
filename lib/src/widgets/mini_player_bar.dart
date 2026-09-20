import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../player/player_provider.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import 'cover_hero.dart';
import 'cover_image.dart';
import 'flying_cover.dart';
import 'predictive_cover_return.dart';
import 'glass_settings.dart';
import 'liquid_wave.dart';

final batchBarLiftProvider = StateProvider<double>((ref) => 0.0);

Widget playbarGlassSurface(
  BuildContext context,
  WidgetRef ref, {
  required Widget child,
  double radius = 999,
}) {
  final lowPerf = ref.watch(
    settingsProvider.select(
        (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
  );
  final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
  final liquid =
      (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
          true) &&
          !lowPerf;

  if (liquid) {
    final quality = liquidGlassQualitySetting(ref);
    final glass = BiliPaiGlass(
      radius: radius,
      refract: bilipaiRefractOf(quality),
      chroma: bilipaiChromaOf(quality),
      blurSigma: surfaceBlurSigma(
        base: bilipaiBackdropBlurOf(quality),
        budget: budget,
        type: BlurSurfaceType.bottomBar,
        crispAtRest: true,
      ),
      backgroundColor: bilipaiSurfaceTint(context, ref, quality),
      specular: bilipaiSpecularOf(quality),
      edgeAmount: bilipaiEdgeOf(quality),
      saturation: bilipaiSaturationOf(quality),
      alwaysLive: true,
      child: child,
    );
    return liquidGlassShell(context, child: glass, radius: radius);
  }

  final isDark = Theme.of(context).brightness == Brightness.dark;
  final solid = glassShouldUseSolid(ref, lowPerf: lowPerf);
  final wallpaper = wallpaperGlassActive(ref);
  final bg = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
      : (wallpaper
          ? wallpaperNavGlassFill(context)
          : (isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.white.withValues(alpha: 0.52)));
  final fill =
      (solid || wallpaper) ? bg : surfaceFillWithBudget(bg, budget);
  final border = isDark
      ? Colors.white.withValues(alpha: 0.12)
      : Colors.white.withValues(alpha: 0.40);
  final navFloating =
      (ref.watch(settingsProvider.select(
              (s) => s.valueOrNull?.floatingNavBar)) ??
          false) ||
          (ref.watch(settingsProvider.select(
                  (s) => s.valueOrNull?.floatingSearchBar)) ??
              false);
  final sigma =
      navFloating ? frostedBlurSigma(ref) : kNavSurfaceBlurSigma;
  final surface = Container(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: border),
      boxShadow: navFloatShadows(context, ref),
    ),
    child: child,
  );
  if (solid) return surface;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: surface,
    ),
  );
}

class MiniBarPositionStore {
  MiniBarPositionStore._();

  static Offset? shared;
}

class MiniPlayerBar extends ConsumerStatefulWidget {
  const MiniPlayerBar({
    super.key,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onPanCancel,
    this.registerTarget = true,
    this.heroTag = 'player-cover',
    this.returnTarget,
  });

  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final VoidCallback? onPanCancel;

  final bool registerTarget;

  final String? heroTag;

  final Rect Function()? returnTarget;

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  String? _lastSpinPath;

  final GlobalKey _coverKey = GlobalKey();

  Rect _coverRect = Rect.zero;
  Rect Function()? _targetProvider;

  Rect Function()? _returnSourceProvider;
  Rect Function()? _returnTargetProvider;

  Offset? _pos;

  GoRouter? _router;

  bool get _isLandscape =>
      MediaQuery.of(context).size.width >=
      MediaQuery.of(context).size.height * 1.05;

  double get _barWidth {
    final w = MediaQuery.of(context).size.width;
    return _isLandscape ? math.min(w * 0.55, 520.0) : w - 36.0;
  }

  double get _defaultLeft {
    final w = MediaQuery.of(context).size.width;
    if (!_isLandscape) return 18.0;
    final barW = _barWidth;
    return ((w - barW) / 2.0).clamp(6.0, math.max(6.0, w - barW - 6.0));
  }

  double get _defaultTop {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final batchLift = ref.read(batchBarLiftProvider);
    return size.height - padding.bottom - 58.0 - 12.0 - batchLift;
  }

  bool? _lastLandscape;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.onPanUpdate == null && _router == null) {
      _router = GoRouter.of(context);
      _router!.routerDelegate.addListener(_onRouteChanged);
    }
    if (widget.onPanUpdate == null && _lastLandscape == null) {
      final shared = MiniBarPositionStore.shared;
      if (shared != null) {
        _pos = _clampToPageGeometry(shared);
      }
    }
    final landscape = _isLandscape;
    if (_lastLandscape != null && _lastLandscape != landscape) {
      _pos = null;
      MiniBarPositionStore.shared = null;
    }
    _lastLandscape = landscape;
  }

  Offset _clampToPageGeometry(Offset p) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final barW = _barWidth;
    const barH = 58.0;
    const minLeft = 6.0;
    final maxLeft = size.width - barW - 6.0;
    final minTop = padding.top + 6.0;
    const bottomInset = 12.0;
    final batchLift = ref.read(batchBarLiftProvider);
    final maxTop = size.height - padding.bottom - barH - bottomInset - batchLift;
    return Offset(
      p.dx.clamp(minLeft, maxLeft > minLeft ? maxLeft : minLeft),
      p.dy.clamp(minTop, maxTop > minTop ? maxTop : minTop),
    );
  }

  void _onRouteChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    if (ref.read(playerProvider).isPlaying) _spin.repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    _router?.routerDelegate.removeListener(_onRouteChanged);
    final p = _targetProvider;
    if (p != null) FlyingCover.instance.unregisterTarget(p);
    final rs = _returnSourceProvider;
    if (rs != null) PredictiveCoverReturn.instance.unregisterSource(rs);
    final rt = _returnTargetProvider;
    if (rt != null) PredictiveCoverReturn.instance.unregisterTarget(rt);
    if (widget.returnTarget != null) {
      PredictiveCoverReturn.instance.unregisterTarget(widget.returnTarget!);
    }
    super.dispose();
  }

  void _syncSpin({
    required bool isPlaying,
    required bool resolving,
    required String path,
  }) {
    if (path != _lastSpinPath) {
      _spin.stop();
      _spin.value = 0;
      _lastSpinPath = path;
      if (isPlaying && !resolving) _spin.repeat();
      return;
    }
    if (isPlaying && !resolving && !_spin.isAnimating) {
      _spin.repeat();
    } else if ((!isPlaying || resolving) && _spin.isAnimating) {
      _spin.stop();
    }
  }

  void _updateCoverTarget() {
    final ctx = _coverKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    _coverRect = box.localToGlobal(Offset.zero) & box.size;

    final fp = _targetProvider;
    if (widget.registerTarget) {
      final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
      if (!isCurrent) {
        if (fp != null) {
          FlyingCover.instance.unregisterTarget(fp);
          _targetProvider = null;
        }
      } else {
        _targetProvider ??= () {
          final c = _coverKey.currentContext;
          final b = c?.findRenderObject() as RenderBox?;
          if (b == null || !b.hasSize || !b.attached) return _coverRect;
          return b.localToGlobal(Offset.zero) & b.size;
        };
        FlyingCover.instance.registerTarget(_targetProvider!);
      }
    } else if (fp != null) {
      FlyingCover.instance.unregisterTarget(fp);
      _targetProvider = null;
    }

    _syncReturnRegistration();
  }

  void _syncReturnRegistration() {
    final internal = widget.onPanUpdate == null;
    if (internal) {
      final onPlayer =
          GoRouter.of(context).routerDelegate.currentConfiguration.uri.path ==
              '/player';
      if (onPlayer) {
        final s = _returnSourceProvider;
        if (s != null) {
          PredictiveCoverReturn.instance.unregisterSource(s);
          _returnSourceProvider = null;
        }
        return;
      }
      final provider = _returnSourceProvider ??= () => _coverRect;
      final c = ref.read(playerProvider).current;
      PredictiveCoverReturn.instance.registerSource(
        songPath: c?.path,
        networkUrl: c?.coverUrl,
        rectProvider: provider,
      );
    } else {
      final provider = widget.returnTarget ?? (_returnTargetProvider ??= () => _coverRect);
      PredictiveCoverReturn.instance.registerTarget(provider);
    }
  }

  void _defaultPanUpdate(DragUpdateDetails d) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final barW = _barWidth;
    const barH = 58.0;
    const minLeft = 6.0;
    final maxLeft = size.width - barW - 6.0;
    final minTop = padding.top + 6.0;
    const bottomInset = 12.0;
    final batchLift = ref.read(batchBarLiftProvider);
    final maxTop = size.height -
        padding.bottom -
        barH -
        bottomInset -
        batchLift;
    final current = _pos ?? Offset(_defaultLeft, _defaultTop);
    setState(() {
      _pos = Offset(
        (current.dx + d.delta.dx).clamp(minLeft, maxLeft),
        (current.dy + d.delta.dy).clamp(minTop, maxTop),
      );
    });
  }

  void _defaultPanEnd(DragEndDetails d) {
    final current = _pos ?? Offset(_defaultLeft, _defaultTop);
    final defaultPos = Offset(_defaultLeft, _defaultTop);
    if ((current - defaultPos).distance < 60.0) {
      setState(() => _pos = null);
    }
    MiniBarPositionStore.shared = _pos;
  }

  void _handlePanStart(DragStartDetails d) {
    setGlobalDragging(true);
    widget.onPanStart?.call(d);
  }

  void _handlePanUpdate(DragUpdateDetails d) {
    if (widget.onPanUpdate != null) {
      widget.onPanUpdate!(d);
    } else {
      _defaultPanUpdate(d);
    }
  }

  void _handlePanEnd(DragEndDetails d) {
    releaseGlobalDragging();
    if (widget.onPanEnd != null) {
      widget.onPanEnd!(d);
    } else {
      _defaultPanEnd(d);
    }
  }

  void _handlePanCancel() {
    releaseGlobalDragging();
    widget.onPanCancel?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(playerProvider.select((s) => (
          current: s.current,
          playing: s.isPlaying,
          duration: s.duration,
          resolving: s.resolving,
        )));
    ref.watch(batchBarLiftProvider);
    final current = p.current;
    if (current == null) return const SizedBox.shrink();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateCoverTarget();
    });

    _syncSpin(isPlaying: p.playing, resolving: p.resolving, path: current.path);

    final scheme = Theme.of(context).colorScheme;
    final isPlaying = p.playing;

    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            true) &&
            !lowPerf;
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));

    final cover = _RotatingDisc(
      key: _coverKey,
      current: current,
      duration: p.duration,
      spin: _spin,
    );
    final coverWidget = (widget.heroTag == null)
        ? cover
        : Hero(
            tag: widget.heroTag!,
            flightShuttleBuilder: (ctx, animation, direction, fromCtx, toCtx) {
              return PlayerCoverShuttle(
                animation: animation,
                songPath: current.path,
                networkUrl: current.coverUrl,
                fromRadius: 23,
                toRadius: 28,
                borderColor: Colors.white.withValues(alpha: 0.18),
                shadow: BoxShadow(
                  color: Theme.of(ctx)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.28),
                  blurRadius: 36,
                  spreadRadius: 2,
                ),
              );
            },
            child: cover,
          );

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
      child: Row(
        children: [
          coverWidget,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  current.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  current.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous),
            iconSize: 22,
            onPressed: () => ref.read(playerProvider.notifier).previous(),
          ),
          IconButton(
            icon: Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              color: scheme.primary,
            ),
            iconSize: 26,
            onPressed: () => ref.read(playerProvider.notifier).toggle(),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next),
            iconSize: 22,
            onPressed: () => ref.read(playerProvider.notifier).next(),
          ),
        ],
      ),
    );

    final bar = GestureDetector(
      onPanStart: _handlePanStart,
      onPanUpdate: _handlePanUpdate,
      onPanEnd: _handlePanEnd,
      onPanCancel: _handlePanCancel,
      onTap: () => context.push('/player'),
      behavior: HitTestBehavior.opaque,
      child: liquid
          ? _liquidSurface(context, content)
          : _frostedSurface(context, content,
              lowPerf: lowPerf, budget: budget),
    );

    if (widget.onPanUpdate == null) {
      final isPlayerPage = GoRouter.of(context)
              .routerDelegate
              .currentConfiguration
              .uri
              .path ==
          '/player';
      if (isPlayerPage) {
        final p = _targetProvider;
        if (p != null) {
          FlyingCover.instance.unregisterTarget(p);
          _targetProvider = null;
        }
        return const SizedBox.shrink();
      }
      return Stack(
        children: [
          AnimatedPositioned(
            duration: (_pos == null)
                ? const Duration(milliseconds: 320)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            left: _pos?.dx ?? _defaultLeft,
            top: _pos?.dy ?? _defaultTop,
            width: _barWidth,
            child: bar,
          ),
        ],
      );
    }

    return bar;
  }

  Widget _liquidSurface(BuildContext context, Widget content) {
    final quality = liquidGlassQualitySetting(ref);
    return SizedBox(
      height: 58,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Impeller 的 BackdropFilter backdrop 快照按层 bounds 裁剪缓存，
          // 失效条件是「backdrop 内容变化」。拖拽移层时页面静止，快照不
          // 失效，玻璃折射便冻结在旧位置。此点位于玻璃 z 序之下、随拖拽
          // 移动，每帧改写 backdrop 内容强制重采样，实现拖拽实时折射。
          ValueListenableBuilder<bool>(
            valueListenable: globalIsDragging,
            builder: (context, dragging, _) => dragging
                ? const Positioned(
                    left: 2,
                    top: 2,
                    width: 1,
                    height: 1,
                    child: ColoredBox(color: Color(0x02000000)),
                  )
                : const SizedBox.shrink(),
          ),
          liquidGlassShell(
            context,
            radius: 999,
            child: LiveLiquidSurface(
              radius: 29,
              refract: bilipaiRefractOf(quality),
              chroma: bilipaiChromaOf(quality),
              blurSigma: bilipaiBackdropBlurOf(quality),
              backgroundColor: bilipaiSurfaceTint(context, ref, quality),
              specular: bilipaiSpecularOf(quality),
              edgeAmount: bilipaiEdgeOf(quality),
              saturation: bilipaiSaturationOf(quality),
              child: content,
            ),
          ),
        ],
      ),
    );
  }

  Widget _frostedSurface(BuildContext context,
      Widget content, {
      bool lowPerf = false,
      BlurBudget? budget}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final solid =
        glassShouldUseSolid(ref, lowPerf: lowPerf);
    final wallpaper = wallpaperGlassActive(ref);
    final bg = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (wallpaper
            ? wallpaperNavGlassFill(context)
            : (isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.52)));
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.40);
    final fill = (budget == null || solid || wallpaper) ? bg : surfaceFillWithBudget(bg, budget);
    final navFloating =
        (ref.watch(settingsProvider.select(
                (s) => s.valueOrNull?.floatingNavBar)) ??
            false) ||
            (ref.watch(settingsProvider.select(
                    (s) => s.valueOrNull?.floatingSearchBar)) ??
                false);
    final sigma =
        navFloating ? frostedBlurSigma(ref) : kNavSurfaceBlurSigma;
    final surface = Container(
      height: 58,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
        boxShadow: navFloatShadows(context, ref),
      ),
      child: content,
    );
    if (solid) return surface;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: surface,
      ),
    );
  }
}

class _RotatingDisc extends ConsumerWidget {
  const _RotatingDisc({
    super.key,
    required this.current,
    required this.duration,
    required this.spin,
  });

  final QueueItem current;
  final double duration;
  final AnimationController spin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playerProvider.select((s) => s.position));
    final progress = duration <= 0
        ? 0.0
        : (position / duration).clamp(0.0, 1.0);

    return RepaintBoundary(
      child: SizedBox(
      width: 46,
      height: 46,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress,
          color: Theme.of(context).colorScheme.primary,
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: AnimatedBuilder(
              animation: spin,
              builder: (context, _) => Transform.rotate(
                angle: spin.value * 2 * math.pi,
                child: CoverImage(
                  songPath: current.path,
                  networkUrl: current.coverUrl,
                  width: 40,
                  height: 40,
                  radius: 0,
                  icon: Icons.music_note,
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

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - stroke / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withValues(alpha: 0.12);
    canvas.drawCircle(center, radius, track);
    if (progress > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        arc,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

class LiveLiquidSurface extends StatefulWidget {
  const LiveLiquidSurface({
    super.key,
    required this.radius,
    required this.refract,
    required this.chroma,
    required this.blurSigma,
    required this.backgroundColor,
    required this.specular,
    required this.edgeAmount,
    required this.saturation,
    this.depthEffect = 0.0,
    required this.child,
  });

  final double radius;
  final double refract;
  final double chroma;
  final double blurSigma;
  final Color backgroundColor;
  final double specular;
  final double edgeAmount;
  final double saturation;

  final double depthEffect;

  final Widget child;

  @override
  State<LiveLiquidSurface> createState() => LiveLiquidSurfaceState();
}

class LiveLiquidSurfaceState extends State<LiveLiquidSurface>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _programFuture;

  AnimationController? _tickC;
  AnimationController get _tick =>
      _tickC ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 8),
        value: 3.0,
      );

  // 激进省电：静止即冻结。只有拖动/滚动/转场等瞬时活动才跑 8s 循环重绘，
  // 让折射实时跟手；活动停止 _kIdleFreezeMs 后停 tick，冻结最后一帧省 GPU。
  static const _kIdleFreezeMs = 1600;
  Timer? _idleTimer;

  ui.FragmentShader? _shader;
  final GlobalKey _surfaceKey = GlobalKey();

  bool _frozen = false;

  double _glassDx = 0;
  double _glassDy = 0;
  double _glassW = 1;
  double _glassH = 1;

  @override
  void initState() {
    super.initState();
    _programFuture ??=
        ui.FragmentProgram.fromAsset('assets/shaders/bilipai_liquid.frag');
    _programFuture!.then((p) {
      if (!mounted) return;
      _shader = p.fragmentShader();
      _writeUniforms(_shader!);
      setState(() {});
    });
    _tick.addListener(_onTick);
    _frozen = globalIsTransitioning.value;
    if (_frozen) _tick.stop();
    globalIsTransitioning.addListener(_onTransitionChanged);
    globalIsDragging.addListener(_onDraggingChanged);
    globalScrollTick.addListener(_onScrollTick);
    // 挂载首帧即渲染一次实时玻璃（几何/uniforms 已就绪），避免静止态
    // 一直停在 blur 降级面；此后才进入「静止冻结、活动激活」。
    if (!_frozen) _nudgeLive();
  }

  @override
  void dispose() {
    globalIsTransitioning.removeListener(_onTransitionChanged);
    globalIsDragging.removeListener(_onDraggingChanged);
    globalScrollTick.removeListener(_onScrollTick);
    _idleTimer?.cancel();
    _tickC?..removeListener(_onTick)..dispose();
    super.dispose();
  }

  /// 舒适光：切到静止，正是此刻。外部发生一次「折射应实时跟手」的活动
  /// （拖动/滚动/转场收尾），唤起 tick 并重置冻结计时。
  void _nudgeLive() {
    if (!mounted) return;
    if (!_frozen) _tick.repeat();
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: _kIdleFreezeMs), () {
      if (mounted && !_frozen) _tick.stop();
    });
  }

  void _onDraggingChanged() {
    if (globalIsDragging.value) _nudgeLive();
  }

  void _onScrollTick() => _nudgeLive();

  void _onTransitionChanged() {
    if (!mounted) return;
    final active = globalIsTransitioning.value;
    if (active == _frozen) return;
    setState(() => _frozen = active);
    if (active) {
      _idleTimer?.cancel();
      _tick.stop();
    } else {
      _nudgeLive();
    }
  }

  void _onTick() {
    if (!mounted) return;
    _measureGeometry();
    final shader = _shader;
    if (shader != null) _writeUniforms(shader);
    setState(() {});
  }

  void _measureGeometry() {
    final ro = _surfaceKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final global = ro.localToGlobal(Offset.zero);
    _glassDx = global.dx * dpr;
    _glassDy = global.dy * dpr;
    _glassW = math.max(1.0, ro.size.width * dpr);
    _glassH = math.max(1.0, ro.size.height * dpr);
  }

  void _writeUniforms(ui.FragmentShader shader) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final view = View.of(context);
    final bg = widget.backgroundColor;
    final a = bg.a;
    final minSide = math.min(_glassW, _glassH) / dpr;
    shader
      ..setFloat(0, view.physicalSize.width)
      ..setFloat(1, view.physicalSize.height)
      ..setFloat(2, globalScrollOffset.value)
      ..setFloat(3, math.min(widget.refract, minSide * 0.375) * dpr)
      ..setFloat(4, widget.chroma)
      ..setFloat(5, 1.5 * dpr)
      ..setFloat(6, bg.r * a)
      ..setFloat(7, bg.g * a)
      ..setFloat(8, bg.b * a)
      ..setFloat(9, a)
      ..setFloat(10, widget.specular)
      ..setFloat(11, widget.radius * dpr)
      ..setFloat(12, _glassDx)
      ..setFloat(13, _glassDy)
      ..setFloat(14, _glassW)
      ..setFloat(15, _glassH)
      ..setFloat(16, math.min(widget.edgeAmount, minSide * 0.42) * dpr)
      ..setFloat(17, widget.saturation)
      ..setFloat(18, widget.depthEffect)
      ..setFloat(19, _tick.value * 8.0);
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (_frozen || shader == null || !ui.ImageFilter.isShaderFilterSupported) {
      // 转场/降级期用同款 blur + 液态底色的毛玻璃过渡，避免
      // 「实心色块 ↔ 液态玻璃」来回硬切产生闪跳。
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
              sigmaX: widget.blurSigma, sigmaY: widget.blurSigma),
          child: ColoredBox(
            color: widget.backgroundColor,
            child: widget.child,
          ),
        ),
      );
    }
    return ClipRRect(
      key: _surfaceKey,
      borderRadius: BorderRadius.circular(widget.radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                  sigmaX: widget.blurSigma, sigmaY: widget.blurSigma),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.shader(shader),
              child: const SizedBox.expand(),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}
