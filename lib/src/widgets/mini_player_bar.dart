import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/application_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings.dart';
import '../player/player_provider.dart';
import '../theme/theme_icon.dart';
import '../theme/theme_store.dart' show themeLibraryProvider;
import '../theme/theme_tint.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import '../navigation/routes.dart'
    show appRouter, openPlayer, playerOpenNotifier;
import 'cover_hero.dart';
import 'cover_image.dart';
import 'flying_cover.dart';
import 'predictive_cover_return.dart';
import 'play_pause_icon.dart';
import 'press_scale.dart';
import 'glass_settings.dart';
import 'liquid_wave.dart';

final batchBarLiftProvider = StateProvider<double>((ref) => 0.0);

/// 播放槽是否配置了自定义主题图（配置了就走平滑切换，未配置走形变）
bool _hasCustomPlayIcon(WidgetRef ref) =>
    ref.watch(themeLibraryProvider).themeIcon('player.play') != null;

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
  final budget = watchBlurBudget(ref, BlurSurfaceType.bottomBar);
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

/// mini 播放条拖放位置存储：横竖屏各自记忆并持久化（SharedPreferences），
/// 重启保留；「位置固定」开启后按当前方向恢复记忆位置并锁死
class MiniBarPositionStore {
  MiniBarPositionStore._();

  static Offset? _portrait;
  static Offset? _landscape;
  static Future<void>? _hydration;
  static const _kPortrait = 'miniBarPosPortrait';
  static const _kLandscape = 'miniBarPosLandscape';

  /// 首次访问时从磁盘水合（幂等）
  static Future<void> hydrate() {
    return _hydration ??= () async {
      final prefs = await SharedPreferences.getInstance();
      _portrait = _parse(prefs.getString(_kPortrait));
      _landscape = _parse(prefs.getString(_kLandscape));
    }();
  }

  static Offset? get(bool landscape) => landscape ? _landscape : _portrait;

  static void set(bool landscape, Offset? pos) {
    if (landscape) {
      _landscape = pos;
    } else {
      _portrait = pos;
    }
    unawaited(_write(landscape ? _kLandscape : _kPortrait, pos));
  }

  static Future<void> _write(String key, Offset? pos) async {
    final prefs = await SharedPreferences.getInstance();
    if (pos == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(
          key, '${pos.dx.toStringAsFixed(1)},${pos.dy.toStringAsFixed(1)}');
    }
  }

  static Offset? _parse(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final dx = double.tryParse(parts[0]);
    final dy = double.tryParse(parts[1]);
    if (dx == null || dy == null) return null;
    return Offset(dx, dy);
  }
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
    this.degraded = false,
  });

  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final VoidCallback? onPanCancel;

  final bool registerTarget;

  final String? heroTag;

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

  /// 位置固定（外观设置「mini播放条」分组）：开启后不可拖拽、固定在该
  /// 方向记忆的拖放位置（无记忆则默认位）。仅宿主 mini 条生效；播放页
  /// 内嵌条（onPanUpdate 外接）有自己的拖拽展开语义，不受此开关约束
  bool get _posLocked {
    if (widget.onPanUpdate != null) return false;
    final s = ref.read(settingsProvider).valueOrNull;
    return (_isLandscape
            ? (s?.miniBarLockLandscape ?? false)
            : (s?.miniBarLockPortrait ?? false));
  }

  /// 横屏播放条档位高度：0 小 / 1 标准 / 2 大 / 3 更大；竖屏恒为标准
  static const List<double> _barHeights = [46.0, 58.0, 72.0, 88.0];

  double get _barH {
    final v = ref.read(settingsProvider).valueOrNull?.landscapeBarSize ?? 1;
    return _isLandscape ? _barHeights[v.clamp(0, 3)] : 58.0;
  }

  double get _barWidth {
    final w = MediaQuery.of(context).size.width;
    if (!_isLandscape) return w - 36.0;
    // 档位宽度倍率比高度略陡：换档横向长度变化更可感
    final v = ref.read(settingsProvider).valueOrNull?.landscapeBarSize ?? 1;
    const widthFactors = [0.85, 1.0, 1.28, 1.62];
    final scaled = math.min(w * 0.55, 520.0) * widthFactors[v.clamp(0, 3)];
    return math.min(scaled, w - 12.0);
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
    return size.height - padding.bottom - _barH - 12.0 - batchLift;
  }

  bool? _lastLandscape;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.onPanUpdate == null && _router == null) {
      _router = appRouter;
      _router!.routerDelegate.addListener(_onRouteChanged);
    }
    final landscape = _isLandscape;
    if (_lastLandscape == null) {
      // 首次进入：异步水合磁盘记忆位并恢复；锁定时由 build 走锁定位置路径
      unawaited(MiniBarPositionStore.hydrate().then((_) {
        if (!mounted) return;
        setState(() {
          final p = MiniBarPositionStore.get(_isLandscape);
          if (p != null && !_posLocked) {
            _pos = _clampToPageGeometry(p);
          }
        });
      }));
    } else if (_lastLandscape != landscape) {
      // 方向切换：横竖屏位置独立，恢复另一方向各自的记忆位置
      final p = MiniBarPositionStore.get(landscape);
      _pos = (p == null || _posLocked) ? null : _clampToPageGeometry(p);
    }
    _lastLandscape = landscape;
  }

  Offset _clampToPageGeometry(Offset p) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final barW = _barWidth;
    final barH = _barH;
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
    // 返回目标（PredictiveCoverReturn.targetRect）由 MiniPlayerOverlay 宿主
    // 常驻注册（跟手拖拽位置）：条子树在播放页打开期间会被整树卸载
    // （_barGone），注册挂在子树里会在手势飞回时全部清空、落进左下兜底
    final internal = widget.onPanUpdate == null;
    if (!internal) return;
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
  }

  void _defaultPanUpdate(DragUpdateDetails d) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final barW = _barWidth;
    final barH = _barH;
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
    // 记忆（含持久化）当前方向拖放位；贴近默认位时记 null 回默认
    MiniBarPositionStore.set(_isLandscape, _pos);
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
    final budget = watchBlurBudget(ref, BlurSurfaceType.bottomBar);

    // 横屏播放条档位（竖屏恒标准）：watch 触发换档重建，几何回调经 _barH 读取
    final barSize = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.landscapeBarSize ?? 1),
    );
    // 位置固定开关：watch 触发即时上锁/解锁重建（上锁时条动画弹回默认位）
    final posLocked = ref.watch(settingsProvider.select((s) {
      final v = s.valueOrNull;
      return _isLandscape
          ? (v?.miniBarLockLandscape ?? false)
          : (v?.miniBarLockPortrait ?? false);
    })) &&
        widget.onPanUpdate == null;
    final barH = _isLandscape ? _barHeights[barSize.clamp(0, 3)] : 58.0;
    final k = barH / 58.0;
    final coverSize = barH - 12.0;

    final cover = _RotatingDisc(
      key: _coverKey,
      current: current,
      duration: p.duration,
      spin: _spin,
      size: coverSize,
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
                fromRadius: coverSize / 2,
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
                  style: TextStyle(
                    fontSize: 14 * k,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  current.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11 * k,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          PressableScale(
            pressScale: 0.88,
            child: IconButton(
              icon: themeSlotIcon(ref, 'player.prev',
                  fallback: Icons.skip_previous, size: 22 * k),
              iconSize: 22 * k,
              // 档位条高可低至 46：放宽默认 48 最小约束防溢出
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: 44 * k,
                minHeight: coverSize,
              ),
              onPressed: () => ref.read(playerProvider.notifier).previous(),
            ),
          ),
          PressableScale(
            pressScale: 0.88,
            child: IconButton(
              // 播放/暂停切换：无自定义主题图走形变过渡；有自定义图
              // 无法形变，退回缩小淡入的平滑切换
              icon: _hasCustomPlayIcon(ref)
                  ? AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutBack,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(scale: animation, child: child),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(isPlaying),
                        child: themeSlotIcon(ref, 'player.play',
                            fallback: isPlaying ? Icons.pause : Icons.play_arrow,
                            size: 26 * k,
                            color: scheme.primary),
                      ),
                    )
                  : PlayPauseMorphIcon(
                      playing: isPlaying,
                      size: 26 * k,
                      color: scheme.primary,
                    ),
              iconSize: 26 * k,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: 44 * k,
                minHeight: coverSize,
              ),
              onPressed: () =>
                  ref.read(playerProvider.notifier).toggle(origin: 'miniBar'),
            ),
          ),
          PressableScale(
            pressScale: 0.88,
            child: IconButton(
              icon: themeSlotIcon(ref, 'player.next',
                  fallback: Icons.skip_next, size: 22 * k),
              iconSize: 22 * k,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: 44 * k,
                minHeight: coverSize,
              ),
              onPressed: () => ref.read(playerProvider.notifier).next(),
            ),
          ),
        ],
      ),
      ),
    );

    // 淡入/还原首帧的采样黑闪由 overlay 层 0.01 保底持续绘制 +
    // BiliPaiGlass 预烘焙图续展兜住，液态面保持实时玻璃不切实底
    final bar = PressableScale(
      pressScale: 0.92,
      child: GestureDetector(
        // 位置固定：不挂 pan 手势，条恒在默认位置（点击进播放页不受影响）
        onPanStart: posLocked ? null : _handlePanStart,
        onPanUpdate: posLocked ? null : _handlePanUpdate,
        onPanEnd: posLocked ? null : _handlePanEnd,
        onPanCancel: posLocked ? null : _handlePanCancel,
        onTap: () {
          final ro = _coverKey.currentContext?.findRenderObject();
          if (ro is RenderBox && ro.hasSize) {
            final from = ro.localToGlobal(Offset.zero) & ro.size;
            unawaited(FlyingCover.instance.launch(
              fromRect: from,
              songPath: current.path,
              networkUrl: current.coverUrl,
              // 网盘条目无 URL 封面：预探/兜底命中的内嵌封面
              // 本地路径作为飞行源，否则飞行副本只能用占位块
              thumbPath: current.coverPath,
              radius: coverSize / 2,
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
      ),
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
      // 锁定＝固定在该方向记忆的拖放位置（无记忆则默认位）；解锁恢复
      // 可拖拽，拖放位置实时记忆并持久化
      final lockedPos = posLocked
          ? _clampToPageGeometry(MiniBarPositionStore.get(_isLandscape) ??
              Offset(_defaultLeft, _defaultTop))
          : Offset(_defaultLeft, _defaultTop);
      return Stack(
        children: [
          AnimatedPositioned(
            duration: (posLocked || _pos == null)
                ? const Duration(milliseconds: 320)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            left: posLocked ? lockedPos.dx : (_pos?.dx ?? _defaultLeft),
            top: posLocked ? lockedPos.dy : (_pos?.dy ?? _defaultTop),
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
      height: _barH,
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
              radius: _barH / 2,
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
      height: _barH,
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
    this.size = 46.0,
  });

  final QueueItem current;
  final double duration;
  final AnimationController spin;

  /// 外径（含进度环）；内封面 = size - 2×环距
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playerProvider.select((s) => s.position));
    final progress = duration <= 0
        ? 0.0
        : (position / duration).clamp(0.0, 1.0);
    final inset = 3.0 * size / 46.0;

    return RepaintBoundary(
      child: SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress,
          color: Theme.of(context).colorScheme.primary,
          stroke: inset,
        ),
        child: Padding(
          padding: EdgeInsets.all(inset),
          child: ClipOval(
            // RenderObject 级旋转：每帧只更新 transform 矩阵，不重建
            // CoverImage 子树（AnimatedBuilder 每帧重建会让 CachedNetworkImage
            // 等 image 组件跟着跑 build，低端机 UI 线程吃紧导致旋转掉帧）
            child: RotationTransition(
              turns: spin,
              child: CoverImage(
                songPath: current.path,
                networkUrl: current.coverUrl,
                width: size - inset * 2,
                height: size - inset * 2,
                radius: 0,
                icon: Icons.music_note,
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
  const _RingPainter({
    required this.progress,
    required this.color,
    this.stroke = 3.0,
  });
  final double progress;
  final Color color;

  /// 环宽随碟面外径等比缩放（标准档 46 时为 3）
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = this.stroke;
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
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.stroke != stroke;
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
    // 水滴透镜（底栏顶层水滴专用）：droplet=true 时 shader 走水滴分支
    //（全表面放大 + 边带折射 + 7 谱色散 + 图标纹理合成，即 BiliPai
    // LiquidIndicator 采样 combinedBackdrop 的完整公式）。mini 播放条等
    // 其余实例保持默认关闭
    this.droplet = false,
    this.dropletDepth = 0.0,
    this.dropletBand = 0.0,
    this.dropletRefract = 0.0,
    this.dropletChroma = 0.0,
    this.dropletGapBand = 0.0,
    // 水滴面 tint 动态反色（BiliPai 空闲水滴面同构）：shader 按水滴圆心
    // 处实时折射内容亮度选 tint——亮背景黑 10%、暗背景白 10%，修复
    // 纯色白底上白 tint 水滴隐形。仅 droplet 实例有意义
    this.tintInvert = false,
    this.barTop = 0.0,
    this.barBottom = 0.0,
    this.iconImage,
    this.iconOrigin = Offset.zero,
    this.iconSize = Size.zero,
    // 页面原始内容捕获纹理（采样器 2）：app 内容 RepaintBoundary
    // toImageSync 产物，BiliPai materialBackdrop 等价物。null 时绑占位图
    //（uPageOn=0，shader 退回玻璃面分支）
    this.pageImage,
    this.pageOrigin = Offset.zero,
    this.pageSize = Size.zero,
    // 屏幕坐标玻璃矩形直传（逻辑 px，与 Positioned.fromRect 同源）：提供
    // 时 _measureGeometry 直接采用，跳过 localToGlobal 实测。顶层水滴
    // overlay 专用——快照 rect 是帧末 postFrame 写入、overlay 下一帧以
    // Positioned.fromRect 裁剪；而 build 期 localToGlobal 测到的是上一帧
    // layout 的位置（本帧 layout 尚未执行），快速甩页时透镜 SDF 落后裁剪
    // 1 帧位移（≈30-60px），裁剪内未覆盖区漏出壳层玻璃兜底面 = 白色月牙
    // 残影（真机截图确认）。直传同一 rect 使 SDF 与裁剪逐帧严格同源
    this.screenRect,
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

  /// 水滴透镜开关：true 时透镜圆心/半径由 _measureGeometry 实测的面几何
  /// 推导（surface 即水滴包围圆），无需外部传几何
  final bool droplet;

  /// 水滴面 tint 动态反色开关（shader 槽 35，见 bilipai_liquid.frag）
  final bool tintInvert;

  /// 栏顶全局 y（逻辑 px，水滴实例槽 36）：>0 时按压镜面把落入栏条带
  /// 的采样替换为干净玻璃色，栏顶以上保持透出（BiliPai combinedBackdrop
  /// 等效观感）
  final double barTop;

  /// 栏底全局 y（逻辑 px，水滴实例槽 42）：与 [barTop] 成对——独立透镜
  /// 「完整区域画面」归属判据（barC 落在栏上下缘之间=栏面，缘外=缩栏
  /// 露出的上下原始内容）
  final double barBottom;

  /// 水滴全表面放大深度（0..1，随按压 mf 渐强）
  final double dropletDepth;

  /// 水滴边带厚度（逻辑像素）
  final double dropletBand;

  /// 水滴边带折射量（逻辑像素）
  final double dropletRefract;

  /// 水滴色差强度
  final double dropletChroma;

  /// 色散外溢带（逻辑像素，BiliPai chromaticEdgeBand）：水滴超出栏缘的
  /// 溢出量，彩虹只画上下缘外溢月牙带；0=无色散
  final double dropletGapBand;

  /// 栏内容捕获纹理（tabRow 图标+文字的 toImage 产物）；null 时绑占位图
  final ui.Image? iconImage;

  /// 栏内容纹理左上角（逻辑屏幕坐标，与 localToGlobal 同系）
  final Offset iconOrigin;

  /// 屏幕坐标玻璃矩形直传（逻辑 px）：非 null 时几何不再实测，见构造
  /// 函数注释（顶层水滴 SDF 与裁剪同源防快帧月牙残影）
  final Rect? screenRect;

  /// 栏内容纹理尺寸（逻辑）
  final Size iconSize;

  /// 页面原始内容捕获纹理（BiliPai materialBackdrop 等价物）；null 时绑
  /// 占位图，shader uPageOn=0 走玻璃面分支
  final ui.Image? pageImage;

  /// 页面纹理左上角（逻辑屏幕坐标，与 localToGlobal 同系）
  final Offset pageOrigin;

  /// 页面纹理尺寸（逻辑）
  final Size pageSize;

  final Widget child;

  @override
  State<LiveLiquidSurface> createState() => LiveLiquidSurfaceState();
}

class LiveLiquidSurfaceState extends State<LiveLiquidSurface>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _programFuture;

  static bool _kCapabilityWarned = false;
  // 水滴透镜诊断日志节流（每次冷启前 4 帧，供 adb 联调核对 uniform 值）
  static int _kDropletDiagCount = 0;

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
      // 引擎 ValidateImageFilter 要求索引 ≥1 的采样器在创建
      // ImageFilter.shader 前已绑定：本路径无图标纹理，绑 1×1 占位图兜底
      //（uIconOn=0 时 shader 不采样它）。占位图缺失则保持 _shader=null
      // 走磨砂降级分支，避免抛 "missing a sampler uniform"
      final placeholder = iconSamplerPlaceholder;
      if (placeholder == null) {
        AppLog.warn('glass', '液态玻璃降级：占位采样图未就绪');
        return;
      }
      _shader = p.fragmentShader();
      _shader!.setImageSampler(1, placeholder);
      // 采样器 2（页面原始内容纹理）同样必须预绑占位图：shader 声明了
      // uPageTex，ValidateImageFilter 要求索引 ≥1 的采样器全部非 null
      _shader!.setImageSampler(2, placeholder);
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
    // 直传几何（顶层水滴）：与宿主 Positioned.fromRect 用同一 rect，
    // build 期即可得本帧正确值——不依赖 RenderObject 的上一帧 layout
    // 位置（快速移动时落后 1 帧 = 白月牙残影根因，见构造函数注释）
    final sr = widget.screenRect;
    if (sr != null) {
      final dpr = View.of(context).devicePixelRatio;
      _glassDx = sr.left * dpr;
      _glassDy = sr.top * dpr;
      _glassW = math.max(1.0, sr.width * dpr);
      _glassH = math.max(1.0, sr.height * dpr);
      return;
    }
    final ro = _surfaceKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
    // 真实视图 dpr（与液态垫 backing 同款修正）：MediaQuery 的 dpr 会被
    // UI 缩放覆盖，采样原点必须信 view dpr——否则折射透镜全局错位，
    // 且偏移量随玻璃尺寸/位置变化（iOS 26 水滴歪移实测）
    final dpr = View.of(context).devicePixelRatio;
    final global = ro.localToGlobal(Offset.zero);
    _glassDx = global.dx * dpr;
    _glassDy = global.dy * dpr;
    _glassW = math.max(1.0, ro.size.width * dpr);
    _glassH = math.max(1.0, ro.size.height * dpr);
  }

  void _writeUniforms(ui.FragmentShader shader) {
    final dpr = View.of(context).devicePixelRatio;
    final view = View.of(context);
    final bg = widget.backgroundColor;
    final a = bg.a;
    final minSide = math.min(_glassW, _glassH) / dpr;
    // 胶囊/超大半径钳到半短边再传 shader（与 bilipai_glass.backing 同款）：
    // 原值 999 会让 SDF 零线远在玻璃外，折射带整圈失效
    final effRadius = math.min(widget.radius, minSide / 2);
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
      ..setFloat(11, effRadius * dpr)
      ..setFloat(12, _glassDx)
      ..setFloat(13, _glassDy)
      ..setFloat(14, _glassW)
      ..setFloat(15, _glassH)
      ..setFloat(16, math.min(widget.edgeAmount, minSide * 0.42) * dpr)
      ..setFloat(17, widget.saturation)
      ..setFloat(18, widget.depthEffect)
      ..setFloat(19, _tick.value * 8.0)
      // 超椭圆指数：与 shader SDF/Dart squircle 裁剪同源（胶囊/圆形 n=2，
      // 非胶囊恒 2.2，标定见 squircle.dart）
      ..setFloat(
        20,
        effRadius >= minSide / 2 - 0.5 ? 2.0 : 2.2,
      );
    if (widget.droplet) {
      // 水滴透镜（槽 21-27）：圆心/半径由实测面几何推导——surface 即水滴
      // 包围圆（Transform 剪切时 localToGlobal 已含变换，透镜跟随可见圆）
      // 坐标系与 backing 一致：屏幕物理像素 = 逻辑 × 真实视图 dpr
      final dpr = View.of(context).devicePixelRatio;
      final hasIcon =
          widget.iconImage != null && widget.iconSize.width > 0;
      if (_kDropletDiagCount < 4) {
        _kDropletDiagCount++;
        AppLog.warn(
          'glass',
          '[XYDropletDiag] center=(${_glassDx + _glassW / 2},'
          '${_glassDy + _glassH / 2}) halfW=${_glassW / 2} '
          'r=${math.min(_glassW, _glassH) / 2} depth=${widget.dropletDepth} '
          'band=${widget.dropletBand * dpr} '
          'refract=${widget.dropletRefract * dpr} '
          'chroma=${widget.dropletChroma} '
          'gap=${widget.dropletGapBand * dpr} icon=$hasIcon '
          'iconSize=${widget.iconSize} origin=${widget.iconOrigin}',
        );
      }
      shader
        ..setFloat(21, _glassDx + _glassW / 2)
        ..setFloat(22, _glassDy + _glassH / 2)
        // 胶囊水滴：纵向半径取短边一半，横向半长 = 宽一半（BiliPai
        // LiquidIndicator stadium 同构；两者相等时 shader 退化圆）
        ..setFloat(23, math.min(_glassW, _glassH) / 2)
        ..setFloat(34, _glassW / 2)
        ..setFloat(24, widget.dropletDepth)
        ..setFloat(25, widget.dropletBand * dpr)
        ..setFloat(26, widget.dropletRefract * dpr)
        ..setFloat(27, widget.dropletChroma)
        // 色散外溢带（槽 33）：逻辑 × 真实视图 dpr，与 band/refract 同规
        ..setFloat(33, widget.dropletGapBand * dpr)
        // 栏内容捕获纹理（槽 28-32，采样器 1）：BiliPai tabsBackdrop 等价
        ..setFloat(28, hasIcon ? 1.0 : 0.0)
        ..setFloat(29, widget.iconOrigin.dx * dpr)
        ..setFloat(30, widget.iconOrigin.dy * dpr)
        ..setFloat(31, widget.iconSize.width * dpr)
        ..setFloat(32, widget.iconSize.height * dpr)
        // tint 动态反色开关（槽 35）：BiliPai Shadow/Highlight 空闲
        // 水滴面同构，亮背景黑 10%/暗背景白 10%
        ..setFloat(35, widget.tintInvert ? 1.0 : 0.0)
        // 栏顶全局 y（槽 36，物理 px = 逻辑 × dpr，与槽 21-22 同空间）：
        // 按压透镜「虚拟合成栈」的栏带判据——采样坐标 y 落在栏上下缘
        // 之间读栏面（玻璃面+图标一起弯折），缘外读缩栏露出的原始页面
        ..setFloat(36, widget.barTop * dpr)
        ..setFloat(42, widget.barBottom * dpr);
      // 页面原始内容捕获纹理（槽 37-41，采样器 2）：BiliPai
      // materialBackdrop 等价物，按压透镜折射原始页面内容
      final hasPage = widget.pageImage != null && widget.pageSize.width > 0;
      shader
        ..setFloat(37, hasPage ? 1.0 : 0.0)
        ..setFloat(38, widget.pageOrigin.dx * dpr)
        ..setFloat(39, widget.pageOrigin.dy * dpr)
        ..setFloat(40, widget.pageSize.width * dpr)
        ..setFloat(41, widget.pageSize.height * dpr);
      // 采样器 1/2 每帧绑定：真实纹理 ?? 1×1 占位图（引擎
      // ValidateImageFilter 要求索引 ≥1 采样器非 null）
      final iconTex = widget.iconImage;
      if (iconTex != null) {
        shader.setImageSampler(1, iconTex);
      } else {
        final placeholder = iconSamplerPlaceholder;
        if (placeholder != null) shader.setImageSampler(1, placeholder);
      }
      final pageTex = widget.pageImage;
      if (pageTex != null) {
        shader.setImageSampler(2, pageTex);
      } else {
        final placeholder = iconSamplerPlaceholder;
        if (placeholder != null) shader.setImageSampler(2, placeholder);
      }
    } else {
      // 非水滴实例（mini 播放条壳路径）：显式归零，防 didUpdateWidget
      // 切换透镜开关后残留旧透镜几何
      for (var i = 21; i <= 42; i++) {
        shader.setFloat(i, 0.0);
      }
    }
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
