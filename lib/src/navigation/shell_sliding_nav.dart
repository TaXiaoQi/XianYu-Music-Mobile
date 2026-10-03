part of 'shell.dart';

/// 顶层水滴快照：_SlidingNavBottom 每帧写入，NavDropletOverlay 消费渲染
class NavDropletSnapshot {
  const NavDropletSnapshot({
    required this.rect,
    required this.shear,
    required this.liquid,
    required this.radius,
    required this.refract,
    required this.band,
    required this.chroma,
    required this.depth,
    required this.press,
    required this.isDark,
  });

  /// 水滴屏幕坐标矩形（帧末实测，含底栏显隐动画变换）
  final Rect rect;

  /// 拖拽水平剪切（果冻拉伸的斜切分量）
  final double shear;

  /// true=液态水滴（按住/滑动中），false=静息浅色胶囊
  final bool liquid;
  final double radius;
  final double refract;
  final double band;
  final double chroma;

  /// 凸透镜深度（∝mf，长按渐强；驱动 shader 全表面放大+边带径向）
  final double depth;
  final double press;
  final bool isDark;
}

final ValueNotifier<NavDropletSnapshot?> navDropletSnapshot =
    ValueNotifier(null);

/// 顶层水滴 overlay 宿主：挂在 app.dart builder Stack 中 mini 播放条之上。
/// 底栏指示水滴独立于底栏树渲染——长按放大可鼓出栏缘、覆盖并折射上方
/// 内容（对齐 B 站参考效果），不再被顶层播放条盖住上缘。
class NavDropletOverlay extends ConsumerStatefulWidget {
  const NavDropletOverlay({super.key});

  @override
  ConsumerState<NavDropletOverlay> createState() => _NavDropletOverlayState();
}

class _NavDropletOverlayState extends ConsumerState<NavDropletOverlay> {
  @override
  void initState() {
    super.initState();
    navDropletSnapshot.addListener(_onSnapshot);
  }

  @override
  void dispose() {
    navDropletSnapshot.removeListener(_onSnapshot);
    super.dispose();
  }

  void _onSnapshot() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = navDropletSnapshot.value;
    // 底栏 hidden = navBarHidden 计数 >0 || 非 root 路径（设置等页面走
    // 后者且会 postFrame 重写快照，仅靠清快照拦不住残影），overlay 显隐
    // 条件必须与 _ShellScaffold 的 hidden 完全一致
    final chromeHidden = ref.watch(navBarHiddenProvider) > 0 ||
        !ref.watch(navOnRootPathProvider);
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          // 液态 shader 0.01 保温防重显黑闪；毛玻璃归零停绘防淡入闪白
          opacity: chromeHidden ? glassHiddenOpacityFloor(ref) : 1.0,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // chromeHidden 时不渲染快照：快照是逐帧写入的「活性数据」，
              // 底栏隐藏后不再更新，残留旧几何会被全亮画成灰圆残影
              //（Impeller 下 0.01 兜底绘制也会以异常 alpha 泄漏）
              if (!chromeHidden && s != null)
                Positioned.fromRect(
                  rect: s.rect,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..setEntry(0, 1, s.shear),
                    child: s.liquid
                        ? ClipOval(
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                LiveLiquidSurface(
                                  radius: s.radius,
                                  refract: s.refract,
                                  chroma: s.chroma,
                                  blurSigma: 0,
                                  backgroundColor: Colors.transparent,
                                  specular: 0.12,
                                  edgeAmount: s.band,
                                  saturation: 1.4,
                                  depthEffect: s.depth,
                                  child: const SizedBox.expand(),
                                ),
                                CustomPaint(
                                  painter:
                                      _DropletEdgePainter(s.press, s.isDark),
                                ),
                              ],
                            ),
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              color: s.isDark
                                  ? Colors.white.withValues(alpha: 0.10)
                                  : Colors.black.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(
                                  s.rect.shortestSide / 2),
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlidingNavBottom extends StatefulWidget {
  const _SlidingNavBottom({
    required this.index,
    required this.onSelect,
    this.lens = false,
    this.glassBuilder,
    this.lensBoost = 1.0,
    this.edgeBoost = 1.0,
    this.dropletChroma = 0.5,
  });

  final int index;
  final ValueChanged<int> onSelect;

  final bool lens;

  final double lensBoost;
  final double edgeBoost;
  final double dropletChroma;

  final Widget Function(Widget content)? glassBuilder;

  @override
  State<_SlidingNavBottom> createState() => _SlidingNavBottomState();
}

class _SlidingNavBottomState extends State<_SlidingNavBottom>
    with TickerProviderStateMixin {
  AnimationController? _pressC;
  AnimationController get _press => _pressC ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );

  AnimationController? _moveC;
  AnimationController get _move => _moveC ??= AnimationController(vsync: this);

  Ticker? _springTickerC;
  Ticker get _springTicker => _springTickerC ??= createTicker(_onSpringTick);
  Duration _springLast = Duration.zero;

  void _ensureTicker() {
    if (!_springTicker.isActive) {
      _springLast = Duration.zero;
      _springTicker.start();
    }
  }

  void _onSpringTick(Duration elapsed) {
    final rawDt = (elapsed - _springLast).inMicroseconds / 1e6;
    _springLast = elapsed;
    final dt = (rawDt < 0 || rawDt > 0.05) ? 0.016 : rawDt;

    final vn = _dragging ? (_dragVel.abs() / 4.0).clamp(0.0, 1.0) : 0.0;
    const defX = 0.40, compY = 0.54;
    final tX = _dragging ? vn * defX : 0.0;
    final tY = _dragging ? -vn * defX * compY : 0.0;
    const sStiff = 620.0, sDamp = 22.9;
    _sxSpd += ((tX - _sxPos) * sStiff - _sxSpd * sDamp) * dt;
    _sxPos += _sxSpd * dt;
    _sySpd += ((tY - _syPos) * sStiff - _sySpd * sDamp) * dt;
    _syPos += _sySpd * dt;

    final settled = !_dragging &&
        _sxSpd.abs() < 0.001 && _sxPos.abs() < 0.002 &&
        _sySpd.abs() < 0.001 && _syPos.abs() < 0.002;
    if (settled) {
      _sxPos = _sxSpd = _syPos = _sySpd = 0;
      _springTicker.stop();
    }
    if (mounted) setState(() {});
  }

  bool _dragging = false;
  double _dragPos = 0;
  double _dragVel = 0;
  double _sxPos = 0, _sxSpd = 0;
  double _syPos = 0, _sySpd = 0;
  Duration? _lastDragTime;

  /// 底栏玻璃胶囊定位键：顶层水滴快照在帧末用它实测栏的屏幕位置
  final GlobalKey _barKey = GlobalKey();

  /// 本页被覆盖路由的转场动画。壳层视差平移（_SmoothFadeForwards 的
  /// -25% 平移）由它驱动：转场每帧 tick 重建底栏 → _syncSnapshot 帧末
  /// 量到实时几何 → 顶层水滴全程跟随，不会把转场中间几何烙进快照。
  /// 没有它，pop 首帧 rebuild 时几何尚未变化（与冻结值相同）→ 追帧链
  /// 不续 → 转场全程盲区，快照停在错误位置，直到下一次交互才飞回。
  Animation<double>? _coverAnim;

  void _onCoverAnimStatus(AnimationStatus status) {
    // 转场落定/退场后强制同步一次：视差已停但栏显隐 scale 动画可能
    // 未结束，补一帧让快照收敛到真实静息几何（防终点残偏）
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final anim = ModalRoute.of(context)?.secondaryAnimation;
    if (!identical(anim, _coverAnim)) {
      _coverAnim?.removeStatusListener(_onCoverAnimStatus);
      _coverAnim = anim;
      anim?.addStatusListener(_onCoverAnimStatus);
    }
  }

  @override
  void initState() {
    super.initState();
    _move.value = widget.index.toDouble();
  }

  @override
  void didUpdateWidget(covariant _SlidingNavBottom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index && !_dragging) {
      _move.animateWith(
        SpringSimulation(
          const SpringDescription(
              mass: 1, stiffness: 420, damping: 25.4),
          _move.value,
          widget.index.toDouble(),
          0,
        ),
      );
    }
  }

  @override
  void dispose() {
    // 底栏卸载（横屏侧栏/固定底栏切换等）时清顶层水滴快照，防残影
    navDropletSnapshot.value = null;
    _coverAnim?.removeStatusListener(_onCoverAnimStatus);
    _moveC?.dispose();
    _springTickerC?.dispose();
    _pressC?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = bottomNavItems;
    return AnimatedBuilder(
      // _coverAnim（被覆盖路由转场）参与驱动：转场期间每帧重建并实测
      // 栏几何，快照水滴跟随壳层视差全程移动，不再冻结在转场中间值
      animation: Listenable.merge([_move, _press, _coverAnim]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
        final overlayDroplet = widget.lens && widget.glassBuilder != null;
        final maxW = constraints.maxWidth;
        final maxH = overlayDroplet
            ? 70.0
            : (constraints.maxHeight.isFinite ? constraints.maxHeight : 70.0);
        final tabW = (maxW - 20) / items.length;
        final dropH = (maxH * 0.8).clamp(54.0, 60.0);
        final pos = _dragging ? _dragPos : _move.value;

        final velPx = _dragging ? _dragVel.abs() * tabW : 0.0;
        final dragMf = _dragging
            ? math.max(0.18, (velPx / 2600).clamp(0.0, 1.0))
            : (velPx > 45
                ? ((velPx - 45) / 1400).clamp(0.0, 1.0)
                : 0.0);
        final pressG = Curves.easeOut.transform(_press.value);
        final mf = math.max(pressG, dragMf);

        if (_dragging && !_springTicker.isActive) _ensureTicker();

        double k = 1 + dragMf * 0.22 + pressG * 0.55;
        if (!overlayDroplet) {
          // 树内水滴（玻璃引擎降级路径）嵌入玻璃内部，按住胀大被玻璃裁剪，
          // 上限钳到栏高防硬切边。overlay 顶层水滴不钳——它画在 mini 播放条
          // 之上，鼓出栏缘覆盖折射上方内容正是设计意图。
          k = math.min(k, maxH / dropH);
        }
        final stretchX = _dragging ? _sxPos : 0.0;
        final stretchY = _dragging ? _syPos : 0.0;
        // 红色胶囊（非液态）样式：滑动选择时长度收一点，松手回到原长。
        // 用 _press 驱动，收和放都是 150ms 平滑过渡，不会在松手瞬间硬跳；
        // 横向也不再跟着 k 变长，否则快速拖动时反而比静止时更长。
        final squeeze = widget.lens ? 1.0 : 1 - pressG * 0.15;
        final sx = widget.lens
            ? k * (1 + stretchX)
            : (1 + stretchX) * squeeze;
        final sy = k * (1 + stretchY);

        final d = dropH;
        final bool scaledIndicator = overlayDroplet;
        final dropletOn = _dragging || pressG > 0.005 || dragMf > 0.005;
        Widget indicator;
        if (widget.lens && dropletOn) {
          final band = d * 16.0 / 56.0 * mf * widget.edgeBoost;
          final amount = d * 18.0 / 56.0 * mf * widget.lensBoost;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final press = pressG.clamp(0.0, 1.0);
          indicator = ClipOval(
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LiveLiquidSurface(
                  radius: scaledIndicator ? d * sy / 2 : d / 2,
                  refract: amount,
                  chroma: widget.dropletChroma,
                  blurSigma: 0,
                  backgroundColor: Colors.transparent,
                  specular: 0.12,
                  edgeAmount: band,
                  saturation: 1.4,
                  depthEffect: 1.2,
                  child: const SizedBox.expand(),
                ),
                CustomPaint(
                  painter: _DropletEdgePainter(press, isDark),
                ),
              ],
            ),
          );
        } else {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          indicator = DecoratedBox(
            decoration: BoxDecoration(
              color: widget.lens
                  ? (isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.black.withValues(alpha: 0.10))
                  : Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(d / 2),
            ),
            child: const SizedBox.expand(),
          );
        }

        final indicatorW = widget.lens ? d : (tabW - 8);

        final tabRow = Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavTab(
                      item: items[i],
                      selected: i == widget.index,
                      iconScale: widget.lens
                          ? 1 +
                              0.2 *
                                  (1 - (i - pos).abs()).clamp(0.0, 1.0)
                          : 1.0,
                      onTap: () => widget.onSelect(i),
                      suppressSplash: widget.lens,
                    ),
                  ),
              ],
            ),
          ),
        );

        final gestures = Listener(
          onPointerDown:
              widget.lens ? (e) => _onPointerDown(e, tabW, items.length) : null,
          onPointerUp: widget.lens ? (_) => _setPressed(false) : null,
          onPointerCancel:
              widget.lens ? (_) => _onPressCancel() : null,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (d) => _onDragStart(d, tabW, items.length),
            onHorizontalDragUpdate: (d) => _onDragUpdate(d, tabW, items.length),
            onHorizontalDragEnd: (d) => _onDragEnd(d, tabW, items.length - 1),
            onHorizontalDragCancel: () => _onDragCancel(items.length - 1),
            child: Stack(
              children: [
                tabRow,
                if (!overlayDroplet)
                  Positioned(
                    left: 10 + pos * tabW + (tabW - indicatorW) / 2,
                    top: (maxH - dropH) / 2,
                    bottom: (maxH - dropH) / 2,
                    width: indicatorW,
                    child: IgnorePointer(
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.diagonal3Values(sx, sy, 1)
                          ..setEntry(0, 1, _dragVel.sign * _sxPos * 0.15),
                        child: indicator,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );

        if (overlayDroplet) {
          final w = indicatorW * sx;
          final h = dropH * sy;
          final cx = 10 + pos * tabW + tabW / 2;
          // 顶层水滴快照：水滴不再渲染在底栏树内，而是逐帧把几何/参数写进
          // navDropletSnapshot，由 app.dart 顶层 NavDropletOverlay（位于
          // mini 播放条之上）绘制——水滴独立于底栏边界，长按放大可鼓出
          // 栏缘、覆盖并折射上方内容，不再被顶层播放条盖住上缘。
          // rect 在帧末实测（此时布局已定，localToGlobal 含显隐动画变换）。
          final isDark = Theme.of(context).brightness == Brightness.dark;
          _syncSnapshot(
            cx: cx,
            w: w,
            h: h,
            maxH: maxH,
            liquid: dropletOn,
            radius: d * sy / 2,
            refract: d * 18.0 / 56.0 * mf * widget.lensBoost,
            band: d * 16.0 / 56.0 * mf * widget.edgeBoost,
            chroma: widget.dropletChroma,
            shear: _dragVel.sign * _sxPos * 0.12,
            depth: 1.2 * mf,
            press: pressG.clamp(0.0, 1.0),
            isDark: isDark,
          );
          return widget.glassBuilder!(
              SizedBox(key: _barKey, height: maxH, child: gestures));
        }
        if (navDropletSnapshot.value != null) {
          // 降级为树内水滴（玻璃引擎不可用）时清掉顶层快照，避免残影
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) navDropletSnapshot.value = null;
          });
        }
        return gestures;
        },
      ),
    );
  }

  void _setPressed(bool down) {
    if (down) {
      _press.forward(from: 0);
    } else if (!_dragging) {
      _press.reverse();
    }
  }

  /// 顶层水滴快照同步：帧末实测底栏几何写快照；rect 未稳定时逐帧重写
  /// 直至收敛。仅靠 build 触发的单次写入会把显隐动画起步帧的几何烙进
  /// 快照（AnimatedScale 0.92→1.0 的 paint 变换参与 localToGlobal）——
  /// 静息态不再 rebuild，动画结束后顶层水滴停在错位处，直到下一次交互
  /// 逐帧跳回（二级页返回时指示器「乱飞」的根因）
  void _syncSnapshot({
    required double cx,
    required double w,
    required double h,
    required double maxH,
    required bool liquid,
    required double radius,
    required double refract,
    required double band,
    required double chroma,
    required double shear,
    required double depth,
    required double press,
    required bool isDark,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final b = _barKey.currentContext?.findRenderObject() as RenderBox?;
      if (b == null || !b.attached || !b.hasSize) return;
      // 逻辑中心点过同一 paint 变换（显隐动画 scale 参与矩阵），
      // 避免未缩放逻辑 cx 与缩放后 origin 混算产生错位
      final topLeft = b.localToGlobal(Offset(cx - w / 2, maxH / 2 - h / 2));
      final rect = topLeft & Size(w, h);
      final prev = navDropletSnapshot.value;
      final rectStable = prev != null && prev.rect == rect;
      // 交互中 press/refract 等随 rebuild 逐帧渐变，有变必须写快照；
      // rect 稳定（且无 rebuild 驱动）后循环自然终止，静息零开销
      final changed = prev == null ||
          prev.rect != rect ||
          prev.liquid != liquid ||
          prev.press != press ||
          prev.radius != radius ||
          prev.refract != refract ||
          prev.band != band ||
          prev.depth != depth ||
          prev.shear != shear;
      if (changed) {
        navDropletSnapshot.value = NavDropletSnapshot(
          rect: rect,
          shear: shear,
          liquid: liquid,
          radius: radius,
          refract: refract,
          band: band,
          chroma: chroma,
          depth: depth,
          press: press,
          isDark: isDark,
        );
      }
      if (!rectStable) {
        // 几何仍在过渡（显隐动画/布局变化）：下一帧继续同步
        _syncSnapshot(
          cx: cx,
          w: w,
          h: h,
          maxH: maxH,
          liquid: liquid,
          radius: radius,
          refract: refract,
          band: band,
          chroma: chroma,
          shear: shear,
          depth: depth,
          press: press,
          isDark: isDark,
        );
      }
    });
  }

  void _onPointerDown(PointerDownEvent e, double tabW, int count) {
    _setPressed(true);
  }

  void _onPressCancel() {
    if (_dragging) return;
    _press.reverse();
    _move.stop();
    _move.value = widget.index.toDouble();
  }

  void _onDragStart(DragStartDetails d, double tabW, int count) {
    _dragging = true;
    _dragVel = 0;
    _lastDragTime = d.sourceTimeStamp;
    _dragPos = ((d.localPosition.dx - 10) / tabW - 0.5)
        .clamp(0.0, count - 1.0);
    _move.stop();
    _move.value = _dragPos;
    _press.forward(from: 0);
    _ensureTicker();
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails d, double tabW, int count) {
    final prev = _dragPos;
    _dragPos = ((d.localPosition.dx - 10) / tabW - 0.5)
        .clamp(0.0, count - 1.0);
    _move.stop();
    _move.value = _dragPos;
    final ts = d.sourceTimeStamp;
    final prevTs = _lastDragTime;
    _lastDragTime = ts;
    if (ts != null && prevTs != null) {
      final dt = (ts - prevTs).inMicroseconds / 1e6;
      if (dt > 0.004) _dragVel = (_dragPos - prev) / dt;
    }
    setState(() {});
  }

  void _onDragEnd(DragEndDetails d, double tabW, int maxIndex) {
    final vTab = d.velocity.pixelsPerSecond.dx / tabW;
    final projected = (_dragPos + vTab * 0.12).clamp(0.0, maxIndex.toDouble());
    _commitDragTarget(
        projected.roundToDouble().clamp(0.0, maxIndex.toDouble()));
  }

  void _onDragCancel(int maxIndex) {
    _commitDragTarget(widget.index.toDouble());
  }

  void _commitDragTarget(double target) {
    _dragging = false;
    _press.reverse();
    _move.animateWith(
      SpringSimulation(
        const SpringDescription(
            mass: 1, stiffness: 420, damping: 25.4),
        _move.value,
        target,
        _dragVel,
      ),
    );
    final idx = target.round();
    if (idx != widget.index) {
      widget.onSelect(idx);
    } else {
      setState(() {});
    }
  }
}

class _NavTab extends ConsumerWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
    this.iconScale = 1.0,
    this.suppressSplash = false,
  });

  final BottomNavItem item;
  final bool selected;
  final VoidCallback onTap;
  final double iconScale;

  final bool suppressSplash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final color = selected
        ? primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    final tab = Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.scale(
            scale: iconScale,
            child: themeSlotIcon(ref, item.themeSlot,
                fallback: item.icon, size: 22, color: color),
          ),
          const SizedBox(height: 3),
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
    );
    if (suppressSplash) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: tab,
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: tab,
    );
  }
}


class _DropletEdgePainter extends CustomPainter {
  const _DropletEdgePainter(this.progress, this.isDark);

  final double progress;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0) return;
    final center = (Offset.zero & size).center;
    final rx = size.width / 2;
    final ry = size.height / 2;
    if (rx <= 0 || ry <= 0) return;

    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(rx, ry) * 0.03
      ..color = Colors.white.withValues(alpha: 0.14 * p);
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.96,
        height: size.height * 0.96,
      ),
      edge,
    );
  }

  @override
  bool shouldRepaint(_DropletEdgePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.isDark != isDark;
}

