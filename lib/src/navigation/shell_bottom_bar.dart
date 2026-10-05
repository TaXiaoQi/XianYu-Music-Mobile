part of 'shell.dart';

class _FixedChrome extends StatelessWidget {
  const _FixedChrome({
    required this.index,
    required this.onSelect,
    required this.hidden,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: hidden
          ? const SizedBox(width: double.infinity, height: 0)
          : _FixedNavBar(index: index, onSelect: onSelect),
    );
  }
}

/// 固定底栏表面填充（_FixedNavBar 与系统导航栏三键涂色共用同一份色值）。
/// 返回 (fill, solid)：solid=true 时 fill 全不透明，无需磨砂。
(Color fill, bool solid) fixedNavBarSurfaceFill(
    BuildContext context, WidgetRef ref) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final lowPerf = ref.watch(
    settingsProvider.select(
      (s) => performancePriority(s.valueOrNull ?? const AppSettings()),
    ),
  );
  final wallpaper = wallpaperGlassActive(ref);
  // 壁纸模式同步顶栏材质：不实底，恒走组件色块+导航面档位模糊
  final solid = !wallpaper && glassShouldUseSolid(ref, lowPerf: lowPerf);
  final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
  // 实底兜底与顶栏/scaffold 同色全不透明，避免停靠栏透出页面内容
  final fill = solid
      ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
      : (wallpaper
            ? wallpaperGlassFill(context, ref)
            : (isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : Colors.white.withValues(alpha: 0.52)));
  // 壁纸模式同步顶栏材质：顶栏无主题槽位，组件色块不被主题覆盖
  final glassFill = wallpaper
      ? fill
      : themeTint(
          ref,
          'nav.bar',
          (solid || wallpaper) ? fill : surfaceFillWithBudget(fill, budget),
        );
  return (glassFill, solid);
}

class _FixedNavBar extends ConsumerWidget {
  const _FixedNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haptic = hapticStrengthFromInt(
      ref.watch(settingsProvider.select((s) => s.valueOrNull?.hapticStrength)),
    );

    final bar = SafeArea(
      top: false,
      child: SizedBox(
        height: 64,
        child: _SlidingNavBottom(
          index: index,
          onSelect: (i) {
            triggerHaptic(haptic);
            onSelect(i);
          },
        ),
      ),
    );

    final (glassFill, solid) = fixedNavBarSurfaceFill(context, ref);
    final barBox = Container(color: glassFill, child: bar);
    if (solid) {
      return barBox;
    }
    final barSigma = navSurfaceBlurSigma(ref);
    // 滚动不降载：矩阵降采样链在 live backdrop 上渲染异常（滚动中模糊
    // 失效读作变透明），恒用与静置一致的普通 blur；与顶栏/播放条共享
    // 一次 backdrop 回读（同 sigma、区域不重叠）
    // 静态帧：显隐/转场动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
    return RepaintBoundary(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: barSigma, sigmaY: barSigma),
          backdropGroupKey: navGlassKey,
          child: barBox,
        ),
      ),
    );
  }
}

class _JellySwitch extends StatefulWidget {
  const _JellySwitch({super.key, required this.mode, required this.child});

  final Object mode;
  final Widget child;

  @override
  State<_JellySwitch> createState() => _JellySwitchState();
}

class _JellySwitchState extends State<_JellySwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  late final Animation<double> _scale;

  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
      value: 1,
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.82,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 32,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.82,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 68,
      ),
    ]).animate(_ctrl);
    _fade = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.55), weight: 32),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.55,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 68,
      ),
    ]).animate(_ctrl);
  }

  @override
  void didUpdateWidget(_JellySwitch old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Opacity(
          opacity: _fade.value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: _scale.value,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _LiquidNavBar extends ConsumerStatefulWidget {
  const _LiquidNavBar({
    required this.index,
    required this.onSelect,
    this.degraded = false,
  });

  final int index;
  final ValueChanged<int> onSelect;

  /// 停绘后挂回/恢复窗口：backdrop 尚未就绪，走磨砂兜底防首帧 shader 采样黑闪
  final bool degraded;

  @override
  ConsumerState<_LiquidNavBar> createState() => _LiquidNavBarState();
}

class _LiquidNavBarState extends ConsumerState<_LiquidNavBar> {
  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    final onSelect = widget.onSelect;
    // 底栏隐藏（播放页/黑名单页等）时清顶层水滴快照：顶层 overlay 不随
    // 底栏 opacity 淡出，不清会留残影。离开 root 路径（设置等页不增
    // navBarHidden 计数，靠 !onRoot 隐藏）同样清——底栏隐藏期间不再
    // rebuild，build 内的兜底清理不会执行，必须在事件点直接清
    ref.listen(navBarHiddenProvider, (_, hidden) {
      if (hidden > 0 && navDropletSnapshot.value != null) {
        navDropletSnapshot.value = null;
      }
    });
    ref.listen(navOnRootPathProvider, (_, onRoot) {
      if (!onRoot && navDropletSnapshot.value != null) {
        navDropletSnapshot.value = null;
      }
    });
    final lowPerf = ref.watch(
      settingsProvider.select(
        (s) => performancePriority(s.valueOrNull ?? const AppSettings()),
      ),
    );
    // 液态开关与引擎能力分开算:用户开了液态但引擎不支持 shader 时,
    // BiliPaiGlass 自身会降级(blur+淡底),裸分支观感接近透明(用户读作透底),
    // 但 lens 水滴的按住放大折射(LiveLiquidSurface 伪折射)是好的,必须保留。
    // → 引擎支持才走裸分支;降级场景走 _frostedGlass(degradedLiquid:
    //    磨砂级胶囊底+标准 blur,禁实底兜底),折射水滴原样保留。
    final liquidGlassOn =
        (ref.watch(
              settingsProvider.select((s) => s.valueOrNull?.liquidGlass),
            ) ??
            true) &&
        !lowPerf;
    // 壁纸模式与悬浮顶栏同轨：液态开即上液态（顶栏液态判断无壁纸排除）；
    // lens 水滴是交互折射效果，与栏面材质无关，保留
    final liquid =
        liquidGlassOn &&
        !widget.degraded &&
        ImageFilter.isShaderFilterSupported;
    final haptic = hapticStrengthFromInt(
      ref.watch(settingsProvider.select((s) => s.valueOrNull?.hapticStrength)),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));

    final realLiquid = liquidGlassOn;
    final dropletQuality = liquidGlassQualitySetting(ref);
    final tabs = _SlidingNavBottom(
      index: index,
      lens: realLiquid,
      lensBoost: bilipaiIndicatorLensBoostOf(dropletQuality),
      edgeBoost: bilipaiIndicatorEdgeBoostOf(dropletQuality),
      dropletChroma: bilipaiIndicatorChromaOf(dropletQuality),
      glassBuilder: liquid
          ? (Widget content) => _liquidGlass(context, ref, content)
          : null,
      onSelect: (i) {
        triggerHaptic(haptic);
        onSelect(i);
      },
    );

    if (liquid) {
      return tabs;
    }
    return _frostedGlass(
      context,
      ref,
      tabs,
      lowPerf: lowPerf,
      budget: budget,
      degradedLiquid: liquidGlassOn,
    );
  }

  Widget _liquidGlass(BuildContext context, WidgetRef ref, Widget tabs) {
    final quality = liquidGlassQualitySetting(ref);
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
    final glass = BiliPaiGlass(
      radius: 30,
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
        'nav.bar',
        bilipaiSurfaceTint(context, ref, quality),
      ),
      specular: bilipaiSpecularOf(quality),
      edgeAmount: bilipaiEdgeOf(quality),
      saturation: bilipaiSaturationOf(quality),
      child: tabs,
    );
    return liquidGlassShell(context, child: glass, radius: 30);
  }

  Widget _frostedGlass(
    BuildContext context,
    WidgetRef ref,
    Widget tabs, {
    bool lowPerf = false,
    BlurBudget? budget,
    bool forceSolid = false,
    bool degradedLiquid = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prefSolid = glassShouldUseSolid(ref, lowPerf: lowPerf);
    final effBudget =
        budget ?? ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar))!;
    final wallpaper = wallpaperGlassActive(ref);
    // 液态降级:用户开了液态但引擎不支持 shader,胶囊走磨砂玻璃观感
    // (半透+标准 blur),禁实底兜底——否则实底挡住页面,水滴折射不可见。
    // 壁纸模式同步顶栏材质：不实底，恒走组件色块
    final solid = !wallpaper && (forceSolid || prefSolid) && !degradedLiquid;
    final keepFilterAlive = forceSolid && !prefSolid;
    final bg = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (wallpaper
              ? wallpaperGlassFill(context, ref)
              : (isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.white.withValues(alpha: 0.52)));
    // 壁纸模式同步顶栏材质：顶栏无主题槽位，组件色块不被主题覆盖
    final fill = wallpaper
        ? bg
        : themeTint(
            ref,
            'nav.bar',
            (budget == null || solid || wallpaper)
                ? bg
                : surfaceFillWithBudget(bg, budget),
          );
    final sigma = degradedLiquid && !wallpaper
        ? surfaceBlurSigma(
            // 液态降级胶囊用液态档 blur(磨砂观感,而非导航面弱模糊)
            base: bilipaiBackdropBlurOf(liquidGlassQualitySetting(ref)),
            budget: effBudget,
            type: BlurSurfaceType.bottomBar,
            crispAtRest: true,
          )
        // 壁纸模式同步顶栏材质：导航面档位模糊
        : navSurfaceBlurSigma(ref);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.40);
    final capsule = Container(
      height: 70,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
        boxShadow: navFloatShadows(context, ref),
      ),
      child: tabs,
    );
    if (solid && !keepFilterAlive) return capsule;
    // 静态帧方案：显隐/转场动画帧父级递归重绘会让 BackdropFilter 在
    // Opacity saveLayer 内重建采样层闪黑；RepaintBoundary 复用旧玻璃
    // layer 不重采样，raster 期实时模糊不受影响（同 glass_appbar 顶栏）
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          // 液态降档胶囊用液态档 sigma，不并入导航面共享回读组
          backdropGroupKey: degradedLiquid && !wallpaper ? null : navGlassKey,
          child: capsule,
        ),
      ),
    );
  }
}
