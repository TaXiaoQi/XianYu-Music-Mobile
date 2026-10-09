import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/application_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../player/player_provider.dart';
import '../theme/theme_icon.dart';
import '../theme/theme_tint.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import '../navigation/routes.dart'
    show appRouter, openPlayer, playerOpenNotifier;
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
  final wallpaper = wallpaperGlassActive(ref);
  // 壁纸模式与悬浮顶栏同轨：液态开即上液态（顶栏液态判断无壁纸排除）
  final liquid =
      (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
          true) &&
          !lowPerf;

  if (liquid) {
    final quality = liquidGlassQualitySetting(ref);
    final glass = BiliPaiGlass(
      radius: radius,
      // chrome 缓存帧：mini 条是 shell 常驻 chrome 条之一，与底栏/悬浮
      // 顶栏同轨。push 二级页（如设置）时条在跑隐藏动画，逐帧 opacity
      // 变化会让液态 shader backdrop 层每帧重采样（我的⇄设置转场 raster
      // 三连卡主源）；缓存帧裁剪无采样，落定后交叉淡回实时渲染
      useChromeFrame: true,
      refract: bilipaiRefractOf(quality),
      chroma: bilipaiChromaOf(quality),
      blurSigma: surfaceBlurSigma(
        base: bilipaiBackdropBlurOf(quality),
        budget: budget,
        type: BlurSurfaceType.bottomBar,
        crispAtRest: true,
      ),
      backgroundColor: themeTint(
        ref,
        'mini.bar',
        bilipaiSurfaceTint(context, ref, quality),
      ),
      specular: bilipaiSpecularOf(quality),
      edgeAmount: bilipaiEdgeOf(quality),
      saturation: bilipaiSaturationOf(quality),
      // 不用 alwaysLive：恒每帧重建 shader backdrop 层在新安卓真机
      // （Impeller）上采样读暗（均匀发灰）；idle 静帧、滚动/拖拽恢复
      // 波动，与底栏/条带垫同构（彼等保留层复用采样正常，互为对照）
      child: child,
    );
    // 不画悬浮投影：投影在 shader backdrop 采样范围内，新安卓真机
    // （Impeller）折射把投影环拉进采样区整条读暗（拖到屏幕顶部依旧黑，
    // 位置无关=自含型采样；旧设备无此现象）；液态底栏/条带垫均无投影
    // 且正常，互为对照
    return liquidGlassShell(context, child: glass, radius: radius);
  }

  final isDark = Theme.of(context).brightness == Brightness.dark;
  // 壁纸模式同步顶栏材质：不实底，恒走组件色块
  final solid = !wallpaper && glassShouldUseSolid(ref, lowPerf: lowPerf);
  final bg = solid
      ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
      : (wallpaper
          ? wallpaperGlassFill(context, ref)
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
      navFloating ? frostedBlurSigma(ref) : navSurfaceBlurSigma(ref);
  final surface = Container(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      // 壁纸模式同步顶栏材质：顶栏无描边
      border: wallpaper ? null : Border.all(color: border),
      // 投影按材质区分：液态分支保留（见 liquid 分支）；毛玻璃/液态降级
      // 材质不画——影子带会落进底栏玻璃采样区被玻璃化成灰黑横带（顶栏
      // 上方无投影所以干净，唯独底栏背锅）；实底（玻璃全关）无 backdrop
      // 采样，保留投影做与页面内容的层级分离
      boxShadow: solid ? navFloatShadows(context, ref) : const [],
    ),
    child: child,
  );
  if (solid) return surface;
  // 静态帧方案：显隐/转场动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
  // （同 glass_appbar 顶栏）
  return RepaintBoundary(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        // 不并入 navGlassKey 共享回读组：新安卓真机（Impeller）组捕获
        // 对紧邻堆叠的成员行为异常（悬浮底栏整条读黑）；独立回读
        // 换取正确性
        child: surface,
      ),
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
    this.degraded = false,
  });

  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final VoidCallback? onPanCancel;

  final bool registerTarget;

  final String? heroTag;

  final Rect Function()? returnTarget;

  /// 磨砂降级：透明度<1 的淡入淡出窗口内产生 saveLayer，ImageFilter.shader
  /// 在其中采样图层自身内容（空）会渲染出黑底；普通 blur 不受 saveLayer
  /// 影响，故该窗口降级磨砂卡，其余时刻（含普通页面转场）保持实时液态
  final bool degraded;

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
      _router = appRouter;
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
      if (playerOpenNotifier.value) {
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
    // 壁纸模式与悬浮顶栏同轨：液态开即上液态（顶栏液态判断无壁纸排除）
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

    // 顶层宿主模式（MaterialApp.builder）下无 Material 祖先，
    // Text 会落入 Flutter 的 _errorTextStyle（红字+黄色双下划线），
    // 显式提供与 Material 环境一致的默认文字样式
    final content = DefaultTextStyle(
      style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
      child: Padding(
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
            icon: themeSlotIcon(ref, 'player.prev',
                fallback: Icons.skip_previous, size: 22),
            iconSize: 22,
            onPressed: () => ref.read(playerProvider.notifier).previous(),
          ),
          IconButton(
            icon: themeSlotIcon(ref, 'player.play',
                fallback: isPlaying ? Icons.pause : Icons.play_arrow,
                size: 26,
                color: scheme.primary),
            iconSize: 26,
            onPressed: () =>
                ref.read(playerProvider.notifier).toggle(origin: 'miniBar'),
          ),
          IconButton(
            icon: themeSlotIcon(ref, 'player.next',
                fallback: Icons.skip_next, size: 22),
            iconSize: 22,
            onPressed: () => ref.read(playerProvider.notifier).next(),
          ),
        ],
      ),
      ),
    );

    // 淡入/还原首帧的采样黑闪由 overlay 层 0.01 保底持续绘制 +
    // BiliPaiGlass 预烘焙图续展兜住，液态面保持实时玻璃不切实底
    final bar = GestureDetector(
      onPanStart: _handlePanStart,
      onPanUpdate: _handlePanUpdate,
      onPanEnd: _handlePanEnd,
      onPanCancel: _handlePanCancel,
      onTap: () {
        final ro = _coverKey.currentContext?.findRenderObject();
        if (ro is RenderBox && ro.hasSize) {
          final from = ro.localToGlobal(Offset.zero) & ro.size;
          unawaited(FlyingCover.instance.launch(
            fromRect: from,
            songPath: current.path,
            networkUrl: current.coverUrl,
            radius: 23,
            // 飞入播放页期间隐藏目的地真封面，落地才露出
            hideTarget: true,
            targetProvider: () =>
                FlyingCover.instance.outboundTargetProvider?.call() ?? from,
          ));
        }
        openPlayer();
      },
      behavior: HitTestBehavior.opaque,
      child: liquid
          ? _liquidSurface(context, content)
          : _frostedSurface(context, content,
              lowPerf: lowPerf, budget: budget),
    );

    if (widget.onPanUpdate == null) {
      if (playerOpenNotifier.value) {
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
          // 不画悬浮投影：黑影子直接垫在 shader backdrop 采样区背后，新
          // 安卓真机（Impeller）把影子读进采样整条均匀发灰（比无投影的
          // 液态顶栏/底栏都黑一点；拖到屏幕顶部依旧黑=影子随条走，位置
          // 无关）；描边由 liquidGlassShell 的 rim 承担，与顶栏/底栏同源
          liquidGlassShell(
            context,
            radius: 999,
            child: LiveLiquidSurface(
              radius: 29,
              refract: bilipaiRefractOf(quality),
              chroma: bilipaiChromaOf(quality),
              blurSigma: bilipaiBackdropBlurOf(quality),
              backgroundColor: themeTint(
                ref,
                'mini.bar',
                bilipaiSurfaceTint(context, ref, quality),
              ),
              specular: bilipaiSpecularOf(quality),
              edgeAmount: bilipaiEdgeOf(quality),
              saturation: bilipaiSaturationOf(quality),
              degraded: widget.degraded,
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
      BlurBudget? budget,
      bool forceSolid = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final wallpaper = wallpaperGlassActive(ref);
    // 壁纸模式同步顶栏材质：不实底，恒走组件色块
    final solid =
        !wallpaper && (forceSolid || glassShouldUseSolid(ref, lowPerf: lowPerf));
    final bg = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (wallpaper
            ? wallpaperGlassFill(context, ref)
            : (isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.52)));
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.40);
    // 壁纸模式同步顶栏材质：顶栏无主题槽位，组件色块不被主题覆盖
    final fill = wallpaper
        ? bg
        : themeTint(
            ref,
            'mini.bar',
            (budget == null || solid || wallpaper)
                ? bg
                : surfaceFillWithBudget(bg, budget));
    final navFloating =
        (ref.watch(settingsProvider.select(
                (s) => s.valueOrNull?.floatingNavBar)) ??
            false) ||
            (ref.watch(settingsProvider.select(
                    (s) => s.valueOrNull?.floatingSearchBar)) ??
                false);
    final sigma =
        navFloating ? frostedBlurSigma(ref) : navSurfaceBlurSigma(ref);
    final surface = Container(
      height: 58,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
        // 壁纸模式同步顶栏材质：顶栏无描边
        border: wallpaper ? null : Border.all(color: border),
        // 投影按材质区分（同主 mini）：毛玻璃/降级材质不画，防灰黑横带；
        // 实底（玻璃全关）无 backdrop 采样，保留投影
        boxShadow: solid ? navFloatShadows(context, ref) : const [],
      ),
      child: content,
    );
    if (solid) return surface;
    // 静态帧方案：显隐/转场动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
    // （同 glass_appbar 顶栏）
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          // 与顶栏/底栏共享一次 backdrop 回读（同 sigma、区域不重叠）
          backdropGroupKey: navGlassKey,
          child: surface,
        ),
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
    this.degraded = false,
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

  /// 磨砂降级（透明度<1 的 saveLayer 窗口内 shader 采样失效 → 黑底）
  final bool degraded;

  final Widget child;

  @override
  State<LiveLiquidSurface> createState() => LiveLiquidSurfaceState();
}

class LiveLiquidSurfaceState extends State<LiveLiquidSurface>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _programFuture;

  static bool _kCapabilityWarned = false;

  AnimationController? _tickC;
  AnimationController get _tick =>
      _tickC ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 8),
        value: 3.0,
      );

  static const _kIdleFreezeMs = 1600;
  Timer? _idleTimer;

  ui.FragmentShader? _shader;
  final GlobalKey _surfaceKey = GlobalKey();

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
    }).catchError((Object e) {
      AppLog.warn('glass', 'bilipai_liquid.frag 加载失败：$e');
    });
    _tick.addListener(_onTick);
    globalIsDragging.addListener(_onDraggingChanged);
    globalScrollTick.addListener(_onScrollTick);
    _nudgeLive();
  }

  @override
  void didUpdateWidget(LiveLiquidSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主每帧重建（长按放大/拖动）时同步重测玻璃几何并刷 uniforms：
    // 折射透镜矩形必须跟随水滴当前位置与尺寸。导航栏水滴的交互不经过
    // globalIsDragging/globalScrollTick，自身 tick 空闲冻结后，这里是
    // 唯一的几何刷新入口——不重测则透镜停在旧位置，折射看起来"消失"
    final shader = _shader;
    if (shader != null) {
      _measureGeometry();
      _writeUniforms(shader);
    }
  }

  @override
  void dispose() {
    globalIsDragging.removeListener(_onDraggingChanged);
    globalScrollTick.removeListener(_onScrollTick);
    _idleTimer?.cancel();
    _tickC?..removeListener(_onTick)..dispose();
    super.dispose();
  }

  void _nudgeLive() {
    if (!mounted) return;
    _tick.repeat();
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: _kIdleFreezeMs), () {
      if (mounted) _tick.stop();
    });
  }

  void _onDraggingChanged() {
    if (globalIsDragging.value) _nudgeLive();
  }

  void _onScrollTick() {
    // 换页滑动（PageView）：mini 条位于路由之上，背后整段内容在滑，
    // 逐帧 live 重建（setState+uniforms+双层 backdrop）是换页卡顿主源
    // 之一——转场口径静默，retained 层由合成器继续采样 backdrop，
    // 折射内容跟随滑动，仅液态波动相位冻结 320ms
    if (globalIsTabSwitching.value) return;
    _nudgeLive();
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
    // degraded：宿主处于透明度<1 的淡入淡出窗口（saveLayer 生效），shader
    // 在其中采样图层自身内容（空）→ 黑底；普通 blur 不受影响，故降级磨砂卡
    if (widget.degraded ||
        shader == null ||
        !ui.ImageFilter.isShaderFilterSupported) {
      // warn 仅限能力位真的缺失：degraded 淡入淡出窗口的降级是预期设计，
      // 此前文案把 degraded 误报成「引擎不支持」，液态实际一直生效
      if (!_kCapabilityWarned &&
          shader != null &&
          !ui.ImageFilter.isShaderFilterSupported) {
        _kCapabilityWarned = true;
        AppLog.warn('glass',
            '液态玻璃降级：isShaderFilterSupported=false（引擎不支持 ImageFilter.shader）');
      }
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
