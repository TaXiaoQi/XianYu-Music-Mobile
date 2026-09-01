import 'dart:math' as math;
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

/// 批量操作栏当前在底部占用的高度（px）——即批量菜单作为「底栏」托起播放条所需
/// 上移的量。批量操作栏挂载时按自身实测高度写入，卸载（批量模式退出）时归零。
/// 壳层迷你播放条与页面内嵌播放条统一读取该值，在批量模式下把自身抬高到批量栏
/// 之上（模拟「底栏托起播放条」，避免批量菜单被播放条挡住）。
final batchBarLiftProvider = StateProvider<double>((ref) => 0.0);

/// 播放条 / 批量操作栏等底部悬浮胶囊共用的玻璃表面（材质完全同步）：
///
/// - 液态玻璃开启（且非低性能）→ 走 BiliPai 液态 shader；
/// - 液态玻璃关闭 → 退毛玻璃，模糊度跟随「顶栏/底栏悬浮」口径（与播放条一致）。
///
/// 底部悬浮胶囊（迷你播放条、批量操作栏）共用同一入口，避免各自实现玻璃导致
/// 观感漂移（模糊量 / 液态配方不相统一）。
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final quality = liquidGlassQualitySetting(ref);
    return BiliPaiGlass(
      radius: radius,
      refract: bilipaiRefractOf(quality),
      chroma: bilipaiChromaOf(quality),
      blurSigma: surfaceBlurSigma(
        base: bilipaiBackdropBlurOf(quality),
        budget: budget,
        type: BlurSurfaceType.bottomBar,
        crispAtRest: true,
      ),
      backgroundColor: bilipaiGlassTint(isDark, quality),
      specular: bilipaiSpecularOf(quality),
      edgeAmount: bilipaiEdgeOf(quality),
      saturation: bilipaiSaturationOf(quality),
      // 常驻实时背板：播放条可拖拽、批量栏贴底，统一保持实时采样，观感一致。
      alwaysLive: true,
      child: child,
    );
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
  // 模糊度与播放条完全一致：顶栏/底栏切悬浮时跟随悬浮口径（毛玻璃档位缩放），
  // 否则恒定最深（kNavSurfaceBlurSigma=16，与固定顶栏/底栏一致）。
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

/// 迷你播放条：旋转封面 + 环形进度 + 上一首/播放/下一首，支持手势拖拽与防透传点击。
///
/// 拖拽为内建默认行为：未传 [onPanUpdate] 等回调时自动启用「全图拖动 + 磁吸
/// 回弹」，因此页面内嵌的播放条（二级页面）与 shell 播放条（根页面）行为一致。
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

  /// 是否注册为「飞封面」目标位置。
  ///
  /// shell 播放条在二级页面（被 root navigator 覆盖不可见）时传 false，
  /// 避免与页面自己的播放条竞争目标位置；根页面与播放页（Hero 源）传 true。
  final bool registerTarget;

  /// 封面 Hero 标签。
  ///
  /// 默认 'player-cover'：页面内嵌播放条承担「当前路由子树」的播放页转场 Hero
  /// （Hero 源必须在栈顶页面子树中，shell 播放条在 AppShell 底层不在扫描范围）。
  /// shell 播放条在二级页面（非播放页）时传 null 避免与页面播放条同标签冲突；
  /// 根页面与播放页时传 'player-cover' 作为 Hero 源。
  final String? heroTag;

  /// 预测返回回拨的「目标」覆盖矩形。
  ///
  /// 仅 shell 播放条传入：指向它回到根页后的停靠位置。shell 条在二级页面处于
  /// 隐藏低位，直接取当前布局矩形作目标会让回拨飞行几乎不可见（只差几像素）。
  /// 用根页停靠位（比页面条高 ~70px）才能复现普通返回里页面条 → shell 条的可见飞行。
  final Rect Function()? returnTarget;

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  /// 当前旋转封面对应的歌曲 path；切歌（含手动/自动/播放结束）时据此归零重转。
  String? _lastSpinPath;

  /// 封面定位锚点：供「飞封面」动画计算目标位置。
  final GlobalKey _coverKey = GlobalKey();

  /// 本实例注册到 FlyingCover 的目标闭包（引用可变 [Rect]，布局更新无需重注册）。
  Rect _coverRect = Rect.zero;
  Rect Function()? _targetProvider;

  /// 预测返回回拨的源/目标闭包（同为可变 [Rect] 的惰性引用）。
  /// 页面内嵌播放条注册为「源」，shell 播放条注册为「目标」。
  Rect Function()? _returnSourceProvider;
  Rect Function()? _returnTargetProvider;

  /// 内建拖拽位置（绝对坐标，null = 默认位置）。
  ///
  /// 页面内嵌播放条用 [Positioned] 定位自身，拖动直接改 left/top 触发重新布局，
  /// hit test 天然跟随，避免 Transform.translate 视觉位移与命中区域错位。
  Offset? _pos;

  /// 路由监听：页面内嵌播放条在播放页打开时隐藏（避免与 shell 播放条 Hero 冲突）。
  GoRouter? _router;

  bool get _isLandscape =>
      MediaQuery.of(context).size.width >=
      MediaQuery.of(context).size.height * 1.05;

  /// 横屏复用外壳播放条的封顶宽度（min(55%屏宽, 520)）并底部居中；
  /// 竖屏保持原「占满两侧各 18」的全宽。
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
    // 批量模式下被批量操作栏（作底栏）托起：上移批量栏高度，避免被挡住。
    final batchLift = ref.read(batchBarLiftProvider);
    return size.height - padding.bottom - 58.0 - 12.0 - batchLift;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 仅内建定位模式（页面播放条）需要监听路由；shell 播放条由 shell 管理。
    if (widget.onPanUpdate == null && _router == null) {
      _router = GoRouter.of(context);
      _router!.routerDelegate.addListener(_onRouteChanged);
    }
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

  /// 同步封面旋转：
  /// - 切歌（path 变化，含手动/自动/播放结束跳下一首）→ 归零后，若真正在播且
  ///   未缓冲则从头转；
  /// - 暂停或在线解析/缓冲中（resolving）→ 停住不动；
  /// - 真正在播 → 旋转。
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

  /// 布局完成后把封面全局位置用于两套注册：
  /// - FlyingCover 目标（列表封面起飞落点）仅在 [MiniPlayerBar.registerTarget] 时注册；
  /// - 预测返回回拨源（页面内嵌条）/目标（shell 条）按定位模式自动注册。
  void _updateCoverTarget() {
    final ctx = _coverKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    _coverRect = box.localToGlobal(Offset.zero) & box.size;
    // Positioned 定位变化会触发重新布局，localToGlobal 自动跟随，无需手动叠加偏移。

    final fp = _targetProvider;
    if (widget.registerTarget) {
      _targetProvider ??= () => _coverRect;
      FlyingCover.instance.registerTarget(_targetProvider!);
    } else if (fp != null) {
      FlyingCover.instance.unregisterTarget(fp);
      _targetProvider = null;
    }

    _syncReturnRegistration();
  }

  /// 按定位模式维护预测返回的源/目标注册：
  /// - 内部定位（页面内嵌条 `onPanUpdate == null`）→ 注册为「源」；
  /// - 外部定位（shell 条）→ 注册为「目标」，二级页面仍存活可作回拨落点。
  void _syncReturnRegistration() {
    final internal = widget.onPanUpdate == null;
    if (internal) {
      final onPlayer =
          GoRouter.of(context).routerDelegate.currentConfiguration.uri.path ==
              '/player';
      // 播放页打开时页面条隐藏，勿再充当回拨源；否则预测返回会从错误位置起飞。
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

  /// 内建拖拽更新：以默认位置（left / bottom:12+安全区）为基准，用绝对坐标计算边界。
  void _defaultPanUpdate(DragUpdateDetails d) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final barW = _barWidth;
    const barH = 58.0;
    const minLeft = 6.0;
    final maxLeft = size.width - barW - 6.0;
    final minTop = padding.top + 6.0;
    // 页面内嵌播放条仅出现在二级页面（无底栏），可拖到更底部。
    // 批量模式下其下方被批量操作栏占据，拖拽下限同步上移批量栏高度。
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
    // 距默认位置 < 60px 自动磁吸回弹。
    final current = _pos ?? Offset(_defaultLeft, _defaultTop);
    final defaultPos = Offset(_defaultLeft, _defaultTop);
    if ((current - defaultPos).distance < 60.0) {
      setState(() => _pos = null);
    }
  }

  void _handlePanStart(DragStartDetails d) {
    // 拖动开始即视为浮层在动：让 BiliPaiGlass 退回实时背板，避免移盖到别处时
    // 仍 blit 旧位置的冻结背板（玻璃「没加载」）。
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
    setGlobalDragging(false);
    if (widget.onPanEnd != null) {
      widget.onPanEnd!(d);
    } else {
      _defaultPanEnd(d);
    }
  }

  void _handlePanCancel() {
    setGlobalDragging(false);
    widget.onPanCancel?.call();
  }

  @override
  Widget build(BuildContext context) {
    // 仅订阅进度环之外的字段；position 交给 _RotatingDisc 内部订阅，
    // 避免随播放进度每帧重建整根播放条。
    final p = ref.watch(playerProvider.select((s) => (
          current: s.current,
          playing: s.isPlaying,
          duration: s.duration,
          resolving: s.resolving,
        )));
    // 订阅批量操作栏占位：批量模式进入/退出时重定位播放条（托起/回落）。
    ref.watch(batchBarLiftProvider);
    final current = p.current;
    if (current == null) return const SizedBox.shrink();

    // 布局完成后更新飞封面目标位置（封面尺寸/位置随主题与底栏变化）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateCoverTarget();
    });

    // 封面旋转由 build 驱动（播放条已 watch current/playing/resolving，任何切歌、
    // 缓冲状态变化必触发 rebound）：真正在播且未缓冲才转，其余停住，切歌归零。
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
    // 全局 blur 预算：滚动/转场时迷你条玻璃降级（sigma 缩放 + 铺底补偿）。
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));

    final cover = _RotatingDisc(
      key: _coverKey,
      current: current,
      duration: p.duration,
      spin: _spin,
    );
    // 当前路由子树内只存在一个带 Hero 的播放条：根页面由 shell 播放条承担，
    // 二级页面由页面内嵌播放条承担（shell 在二级页面传 heroTag:null 让位）。
    // 播放页打开时页面播放条隐藏，避免与 shell 播放条同标签 Hero 冲突。
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

    // 内建定位模式（页面内嵌播放条，未传 onPanUpdate）：自己返回 Stack + Positioned，
    // 拖动直接改 left/top 触发重新布局，hit test 与视觉位置天然一致。
    if (widget.onPanUpdate == null) {
      // 播放页打开时隐藏页面播放条：避免与 shell 播放条（Hero 源）同标签冲突，
      // 同时注销飞封面目标（此时由 shell 播放条接管）。
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
          // 批量模式托起/回落用 AnimatedPositioned 平滑过渡（默认停靠位变化时
          // 带 320ms 缓动）；用户拖拽时归零时长，位置实时跟手。
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

    // 外部定位模式（shell 播放条）：被外层 AnimatedPositioned 包裹定位。
    return bar;
  }

  /// BiliPai 化液态玻璃表面：与底栏同一套参数，保证两者观感一致。
  Widget _liquidSurface(BuildContext context, Widget content) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final quality = liquidGlassQualitySetting(ref);
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
    return BiliPaiGlass(
      radius: 29,
      refract: bilipaiRefractOf(quality),
      chroma: bilipaiChromaOf(quality),
      blurSigma: surfaceBlurSigma(
        base: bilipaiBackdropBlurOf(quality),
        budget: budget,
        type: BlurSurfaceType.bottomBar,
        crispAtRest: true,
      ),
      backgroundColor: bilipaiGlassTint(isDark, quality),
      specular: bilipaiSpecularOf(quality),
      edgeAmount: bilipaiEdgeOf(quality),
      saturation: bilipaiSaturationOf(quality),
      // 播放条可拖拽/平移盖到不同内容上，不能容忍「静止冻结背板」在拖动时
      // 错位（旧位置的液态折射固化在原地、新位置没有折射）。开启常驻实时：
      // 关闭抓屏冻结，背板始终实时采样跟随，涟漪常转提供拖动时的液态观感。
      alwaysLive: true,
      child: SizedBox(height: 58, child: content),
    );
  }

  /// 伪毛玻璃表面：液态玻璃关闭时使用。
  /// 透明 + 高斯模糊；低性能模式 → 高不透明度纯色回退（无模糊）。
  /// [budget] 传入时按全局 blur 预算缩放 sigma、铺底透明度补偿。
  Widget _frostedSurface(BuildContext context,
      Widget content, {
      bool lowPerf = false,
      BlurBudget? budget}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 标准磨砂（跟随毛玻璃开关）；关闭毛玻璃/低性能 → 纯色。
    final solid =
        glassShouldUseSolid(ref, lowPerf: lowPerf);
    final wallpaper = wallpaperGlassActive(ref);
    // 壁纸模式：迷你播放条同底栏口径保持磨砂模糊（wallpaperNavGlassFill +
    // 最深固定模糊 kNavSurfaceBlurSigma），不透明化——仅彻底关闭毛玻璃/低性能
    // 时回退纯色。
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
    // 顶栏/底栏切悬浮时，播放条跟随「悬浮」口径（毛玻璃档位缩放：跟悬浮顶栏
    // 胶囊一致）；否则保持恒定最深（kNavSurfaceBlurSigma=16，跟固定顶栏/底栏
    // 一致）。保证播放条始终与当前顶栏/底栏形态的模糊量对得上。
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
        // 播放条是贴底的细长圆角窄条，cheapBackdropBlur 的 1/4 降采样再放大
        // 采样网格与物理像素不对齐，会产生约 1~2px 水平相位偏移（观感"往右歪、
        // 和背底没对上"）。与顶栏一致改用全分辨率高斯，按原始像素精确对齐背板；
        // 播放条仅一条窄带，全分辨率成本可控。
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: surface,
      ),
    );
  }
}

/// 旋转封面 + 环形进度。独立订阅 position，使播放进度只重建本组件。
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

    // 旋转封面独立成 RepaintBoundary：封面每帧旋转只重绘这一小块图层，
    // 不再 touch 到整页大边界触发全页重绘，避免播放时列表滚动双重掉帧。
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
