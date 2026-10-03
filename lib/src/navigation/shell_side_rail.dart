part of 'shell.dart';

class _ThreeBarsIcon extends StatelessWidget {
  const _ThreeBarsIcon({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 18,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3.5),
          Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3.5),
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNavRail extends ConsumerStatefulWidget {
  const _SideNavRail({
    required this.index,
    required this.hidden,
    required this.expanded,
    required this.onToggleExpand,
    required this.onSelect,
  });

  final int index;
  final bool hidden;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final ValueChanged<int> onSelect;

  @override
  ConsumerState<_SideNavRail> createState() => _SideNavRailState();
}

class _SideNavRailState extends ConsumerState<_SideNavRail>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<double> _curvedAnim;

  double? _top;
  double? _left;

  double _dragDistance = 0;

  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: widget.expanded ? 1.0 : 0.0,
    );
    _curvedAnim = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void didUpdateWidget(_SideNavRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) {
      if (widget.expanded) {
        _animCtrl.forward();
      } else {
        _animCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    _dragDistance = 0;
    _isDragging = true;
    setGlobalDragging(true);
  }

  void _onPanUpdate(
    DragUpdateDetails details,
    Size screenSize,
    EdgeInsets padding,
  ) {
    _dragDistance += details.delta.distance;
    final floatingSearchBar =
        ref.read(settingsProvider).valueOrNull?.floatingSearchBar ?? false;
    final topBarBottom =
        floatingSearchBar ? (padding.top + 60.0) : (padding.top + 122.0);
    final currentTop = _top ?? (topBarBottom + 24.0);
    final currentLeft = _left ?? 12.0;

    final panelW = widget.expanded ? 84.0 : 52.0;

    final minTop = topBarBottom + 12.0;
    final maxTop = screenSize.height - padding.bottom - 52.0 - 12.0;
    final minLeft = 8.0;
    final maxLeft = screenSize.width - panelW - 8.0;

    final nextTop = currentTop + details.delta.dy;
    final nextLeft = currentLeft + details.delta.dx;

    setState(() {
      _top = nextTop.clamp(
        minTop,
        maxTop > minTop ? maxTop : minTop,
      );
      _left = nextLeft.clamp(
        minLeft,
        maxLeft > minLeft ? maxLeft : minLeft,
      );
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isDragging) {
      setState(() {
        _isDragging = false;
      });
    }
    setGlobalDragging(false);
    if (_dragDistance < 6) {
      widget.onToggleExpand();
    }
  }

  void _onPanCancel() {
    if (_isDragging) {
      setState(() {
        _isDragging = false;
      });
    }
    setGlobalDragging(false);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;

    final floatingSearchBar = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final topBarBottom =
        floatingSearchBar ? (padding.top + 60.0) : (padding.top + 122.0);
    final safeMinTop = topBarBottom + 12.0;
    final currentTop =
        (_top ?? (topBarBottom + 24.0)).clamp(safeMinTop, double.infinity);
    final left = _left ?? 12.0;

    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final preferredDir = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.sideBarExpandDirection)) ??
        SideBarExpandDirection.down;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(
                settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            true) &&
            !lowPerf;
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.drawerOrSheet));

    const double approxExpandedH = 330.0;

    final bool canFitDown =
        (currentTop + approxExpandedH) <= (screenSize.height - padding.bottom - 8.0);
    final bool canFitUp =
        (currentTop + 52.0 - approxExpandedH) >= (topBarBottom + 12.0);

    SideBarExpandDirection effectiveDir = preferredDir;
    if (preferredDir == SideBarExpandDirection.down) {
      if (!canFitDown &&
          (canFitUp || (currentTop > (screenSize.height / 2)))) {
        effectiveDir = SideBarExpandDirection.up;
      }
    } else {
      if (!canFitUp &&
          (canFitDown || (currentTop <= (screenSize.height / 2)))) {
        effectiveDir = SideBarExpandDirection.down;
      }
    }

    final isUp = effectiveDir == SideBarExpandDirection.up;

    return AnimatedBuilder(
      animation: _curvedAnim,
      builder: (context, child) {
        final progress = _curvedAnim.value;
        final panelWidth = lerpDouble(52.0, 84.0, progress)!;

        final logoButton = GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: (d) => _onPanUpdate(d, screenSize, padding),
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: panelWidth,
            height: 52,
            child: Center(
              child: Transform.rotate(
                angle: progress * (3.141592653589793 / 2),
                child: _ThreeBarsIcon(
                  color: Color.lerp(
                    scheme.onSurface.withValues(alpha: 0.85),
                    scheme.primary,
                    progress,
                  )!,
                ),
              ),
            ),
          ),
        );

        final navItems = [
          for (var i = 0; i < bottomNavItems.length; i++)
            _SideNavTab(
              item: bottomNavItems[i],
              selected: i == widget.index,
              onTap: () => widget.onSelect(i),
            ),
        ];

        final navContent = Opacity(
          opacity: progress.clamp(0.0, 1.0),
          child: IgnorePointer(
            ignoring: progress < 0.2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isUp)
                  Divider(
                    height: 1,
                    indent: 10,
                    endIndent: 10,
                    thickness: 0.5,
                    color: scheme.onSurface.withValues(alpha: 0.1 * progress),
                  ),
                const SizedBox(height: 4),
                ...navItems,
                if (isUp) ...[
                  const SizedBox(height: 4),
                  Divider(
                    height: 1,
                    indent: 10,
                    endIndent: 10,
                    thickness: 0.5,
                    color: scheme.onSurface.withValues(alpha: 0.1 * progress),
                  ),
                ],
              ],
            ),
          ),
        );

        final panelBody = SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: isUp
                ? [
                    if (progress > 0.01)
                      Align(
                        heightFactor: progress,
                        alignment: Alignment.bottomCenter,
                        child: navContent,
                      ),
                    logoButton,
                  ]
                : [
                    logoButton,
                    if (progress > 0.01)
                      Align(
                        heightFactor: progress,
                        alignment: Alignment.topCenter,
                        child: navContent,
                      ),
                  ],
          ),
        );

        Widget panelWidget;
        if (liquid) {
          final quality = liquidGlassQualitySetting(ref);
          panelWidget = BiliPaiGlass(
            radius: 24,
            refract: bilipaiRefractOf(quality),
            chroma: bilipaiChromaOf(quality),
            blurSigma: surfaceBlurSigma(
              base: bilipaiBackdropBlurOf(quality),
              budget: budget,
              type: BlurSurfaceType.drawerOrSheet,
              crispAtRest: true,
            ),
            backgroundColor: bilipaiSurfaceTint(context, ref, quality),
            specular: bilipaiSpecularOf(quality),
            edgeAmount: bilipaiEdgeOf(quality),
            saturation: bilipaiSaturationOf(quality),
            child: SizedBox(width: panelWidth, child: panelBody),
          );
        } else if (lowPerf) {
          panelWidget = Container(
            width: panelWidth,
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xF02A2A2E)
                  : const Color(0xF5FFFFFF),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.45),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.1),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: panelBody,
          );
        } else {
          final panelBg = wallpaperGlassActive(ref)
              ? wallpaperGlassFill(context, ref)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.white.withValues(alpha: 0.35));
          final panelFill = surfaceFillWithBudget(panelBg, budget);
          final panelSigma = wallpaperGlassActive(ref)
              ? wallpaperGlassSigma(context)
              : surfaceBlurSigma(
                  base: 8 * frostedBlurScale(ref),
                  budget: budget,
                  type: BlurSurfaceType.drawerOrSheet,
                );
          final panelBox = Container(
            width: panelWidth,
            decoration: BoxDecoration(
              color: panelFill,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.45),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black
                      .withValues(alpha: isDark ? 0.3 : 0.1),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: panelBody,
          );
          panelWidget = panelSigma <= 0
              ? panelBox
              // 静态帧：动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
              : RepaintBoundary(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                          sigmaX: panelSigma, sigmaY: panelSigma),
                      child: panelBox,
                    ),
                  ),
                );
        }

        final collapsedHintAlpha = (1.0 - progress).clamp(0.0, 1.0);
        if (collapsedHintAlpha > 0.01) {
          panelWidget = Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.45 * collapsedHintAlpha)
                        : Colors.white.withValues(alpha: 0.70 * collapsedHintAlpha),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
              panelWidget,
            ],
          );
        }

        return Positioned(
          left: left,
          top: isUp ? null : currentTop,
          bottom: isUp ? (screenSize.height - currentTop - 52.0) : null,
          child: IgnorePointer(
            ignoring: widget.hidden,
            child: AnimatedOpacity(
              opacity: widget.hidden ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 180),
              child: panelWidget,
            ),
          ),
        );
      },
    );
  }
}

class _SideNavTab extends ConsumerWidget {
  const _SideNavTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final BottomNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final color = selected
        ? primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color:
                selected ? primary.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              themeSlotIcon(ref, item.themeSlot,
                  fallback: item.icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(
                navTitle(context, item),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
