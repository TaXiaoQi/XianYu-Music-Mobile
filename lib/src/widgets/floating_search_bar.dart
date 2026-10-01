import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import '../plugin/plugin_provider.dart';
import '../theme/theme_tint.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import 'glass_settings.dart';
import 'page_search_bar.dart';

class FloatingSearchBar extends ConsumerWidget {
  const FloatingSearchBar({
    super.key,
    required this.onTap,
    this.onRecognize,
    this.chromeFrame = false,
  });

  final VoidCallback onTap;

  final VoidCallback? onRecognize;

  // 仅 shell 常驻悬浮顶栏内的搜索条开启 chrome 缓存帧
  final bool chromeFrame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('搜索歌曲、歌手、专辑'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (onRecognize != null &&
                  ref.watch(pluginManagerProvider
                      .select((s) => s.sources.any((p) => p.enabled)))) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRecognize,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.mic_none,
                      size: 17,
                      color: Color(0xFFEC4141),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return FloatingGlassSurface(chromeFrame: chromeFrame, child: content);
  }
}

class FloatingGlassSurface extends ConsumerWidget {
  const FloatingGlassSurface({
    super.key,
    required this.child,
    this.radius = 22,
    this.chromeFrame = false,
  });

  final Widget child;

  final double radius;

  // chrome 缓存帧：仅 shell 常驻 chrome 条开启（见 BiliPaiGlass.useChromeFrame）
  final bool chromeFrame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;

    if (liquid) {
      final quality = liquidGlassQualitySetting(ref);
      final glass = BiliPaiGlass(
        radius: radius,
        useChromeFrame: chromeFrame,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: bilipaiBackdropBlurOf(quality),
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: child,
      );
      return liquidGlassShell(context, child: glass, radius: radius);
    }
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: child,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
    );
  }
}

class BiliPaiPill extends ConsumerWidget {
  const BiliPaiPill({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 20,
    this.alwaysLive = false,
    this.freshBackdrop = false,
    this.chromeFrame = false,
  });

  final Widget child;

  final VoidCallback? onTap;

  final double radius;

  final bool alwaysLive;

  final bool freshBackdrop;

  // chrome 缓存帧：仅 shell 常驻 chrome 条开启（见 BiliPaiGlass.useChromeFrame）
  final bool chromeFrame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );

    if (liquid) {
      final quality = liquidGlassQualitySetting(ref);
      final glass = BiliPaiGlass(
        radius: radius,
        alwaysLive: alwaysLive,
        freshBackdrop: freshBackdrop,
        useChromeFrame: chromeFrame,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: bilipaiBackdropBlurOf(quality),
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: content,
      );
      return liquidGlassShell(context, child: glass, radius: radius);
    }
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: content,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
    );
  }
}

class FloatingSourcePill extends ConsumerWidget {
  const FloatingSourcePill({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
    this.height = 40,
  });

  final String name;

  final bool selected;

  final VoidCallback onTap;

  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final radius = height / 2;
    return BiliPaiPill(
      onTap: onTap,
      radius: radius,
      alwaysLive: true,
      freshBackdrop: true,
      child: Container(
        height: height,
        constraints: BoxConstraints(
          minWidth: height + 12,
        ),
        padding: EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        // sr.pill 的底色画在这层内层 Container 上，不必改公共玻璃原语 BiliPaiPill。
        // 未启用主题时 themeTintOrNull 返回 null，即不上色——观感与接线前一致。
        // 必须带圆角：这一层自身没有圆角，方形底色会从胶囊圆角边缘漏出来。
        decoration: BoxDecoration(
          color: themeTintOrNull(ref, 'sr.pill'),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class BiliPaiIconButton extends StatelessWidget {
  const BiliPaiIconButton({
    super.key,
    this.icon,
    this.iconChild,
    this.onTap,
    this.color,
    this.tooltip,
  });

  final IconData? icon;
  final Widget? iconChild;
  final VoidCallback? onTap;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final iconWidget = SizedBox(
      width: 40,
      height: 40,
      child: IconTheme(
        data: const IconThemeData(size: 20).copyWith(
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: iconChild ??
            Icon(
              icon,
              size: 20,
              color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
    return BiliPaiPill(
      onTap: onTap,
      child: tooltip == null
          ? iconWidget
          : Tooltip(message: tooltip!, child: iconWidget),
    );
  }
}

class FloatingTopBar extends StatelessWidget {
  const FloatingTopBar({
    super.key,
    required this.title,
    required this.onSearchTap,
    this.onRecognize,
    this.actions = const [],
    this.chromeFrame = false,
  });

  final Widget title;

  final VoidCallback onSearchTap;

  final VoidCallback? onRecognize;

  final List<Widget> actions;

  // shell 常驻悬浮顶栏传入 true：转场降级窗口复用 chrome 缓存帧
  final bool chromeFrame;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        BiliPaiPill(
          radius: 20,
          chromeFrame: chromeFrame,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              height: 40,
              child: Align(alignment: Alignment.centerLeft, child: title),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FloatingSearchBar(
            onTap: onSearchTap,
            onRecognize: onRecognize,
            chromeFrame: chromeFrame,
          ),
        ),
        for (final action in actions) ...[
          const SizedBox(width: 10),
          action,
        ],
      ],
    );
  }
}

class FloatingGlassSearchField extends ConsumerWidget {
  const FloatingGlassSearchField({
    super.key,
    required this.controller,
    this.hint,
    this.readOnly = false,
    this.autofocus = false,
    this.isDense = true,
    this.onChanged,
    this.onTap,
    this.onSubmitted,
    this.showClear = false,
    this.onClear,
  });

  final TextEditingController controller;
  final String? hint;
  final bool readOnly;
  final bool autofocus;

  final bool isDense;

  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final ValueChanged<String>? onSubmitted;
  final bool showClear;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingGlassSurface(
      radius: 22,
      child: SizedBox(
        height: 44,
        child: TextField(
          controller: controller,
          readOnly: readOnly,
          autofocus: autofocus,
          textInputAction: TextInputAction.search,
          style: TextStyle(
            fontSize: 14.5,
            color: scheme.onSurface,
          ),
          textAlignVertical: TextAlignVertical.center,
          cursorColor: scheme.primary,
          onChanged: onChanged,
          onTap: onTap,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 14.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            isDense: isDense,
            contentPadding: const EdgeInsets.symmetric(horizontal: 15),
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search, size: 19, color: scheme.onSurfaceVariant),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 40, minHeight: 44),
            suffixIcon: showClear
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 19),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                        width: 32, height: 44),
                    onPressed: onClear,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class FloatingTabPill extends ConsumerWidget {
  const FloatingTabPill({
    super.key,
    required this.child,
    this.height = 48,
    this.controller,
  });

  final Widget child;

  final double height;

  /// 传入时启用底栏同款水滴选择块(位置弹簧+拖拽形变),
  /// child TabBar 自身的指示块转为透明;为 null 时退静态胶囊指示块
  final TabController? controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 单 tab 无需选中指示:水滴与胶囊都省掉,只留标签文字
    // (如未登录时壁纸/主题中心只剩单个本地 tab)
    final tabBar = child is TabBar ? child as TabBar : null;
    final tabCount = controller?.length ?? tabBar?.controller?.length;
    final singleTab = tabCount != null && tabCount <= 1;
    return FloatingGlassSurface(
      radius: height / 2,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          // sr.chips 的底色画在这层内层 Container 上，不改公共玻璃原语。
          // 未启用主题时 themeTintOrNull 返回 null → 不上色，观感与接线前一致。
          // 这一层被外层 Padding(6) 内缩，故圆角取 height/2-6 才与玻璃圆角贴合。
          child: Container(
            decoration: BoxDecoration(
              color: themeTintOrNull(ref, 'sr.chips'),
              borderRadius:
                  BorderRadius.circular((height / 2 - 6).clamp(0.0, 999.0)),
            ),
            child: singleTab
                ? Theme(
                    data: Theme.of(context).copyWith(
                      tabBarTheme: TabBarThemeData(
                        dividerColor: Colors.transparent,
                        // 单 tab 不画任何指示块,透明即可
                        indicator: const BoxDecoration(),
                        // hover/按压高亮一并关掉,避免第二指示块观感
                        overlayColor:
                            const WidgetStatePropertyAll(Colors.transparent),
                        labelPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                    child: child,
                  )
                : controller == null
                ? Theme(
                    data: Theme.of(context).copyWith(
                      tabBarTheme: TabBarThemeData(
                        dividerColor: Colors.transparent,
                        // 选中器与悬浮底栏选择器同口径:胶囊指示块(primary@12%),
                        // 去掉 Material 默认下划线
                        indicator: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        indicatorSize: TabBarIndicatorSize.tab,
                        // hover/按压高亮一并关掉:镜像窗口里鼠标悬停会被当成
                        // 第二颗指示块,且底栏选择器本身无水波纹
                        overlayColor:
                            const WidgetStatePropertyAll(Colors.transparent),
                        // 等分后单 tab 宽度有限,收窄标签内边距,
                        // 避免「自定义壁纸」等长标签被裁
                        labelPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                    child: child,
                  )
                : Stack(
                    children: [
                      // TabBar 在底层;水滴层在最上但 translucent 命中,
                      // 点击仍归 TabBar,横向拖动归水滴(底栏同款拖动换页)
                      Theme(
                        data: Theme.of(context).copyWith(
                          tabBarTheme: TabBarThemeData(
                            dividerColor: Colors.transparent,
                            // 指示块由 _TabDroplet 绘制,TabBar 自身透明
                            indicator: const BoxDecoration(),
                            indicatorSize: TabBarIndicatorSize.tab,
                            // 同上:关掉 hover/按压高亮,避免第二指示块观感
                            overlayColor: const WidgetStatePropertyAll(
                                Colors.transparent),
                            labelPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                        child: child,
                      ),
                      Positioned.fill(
                        child: _TabDroplet(
                          controller: controller!,
                          barHeight: height,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮 tab 胶囊的水滴选择块:观感与弹簧参数均取自底栏 _SlidingNavBottom——
/// 位置由 TabController 动画驱动(点按/TabBarView 滑动均连续跟随),
/// 动画速度驱动横向拉伸+纵向压扁(水滴拖拽形变),静止后弹簧回弹。
/// 位置弹簧 420/25.4(底栏 _move 的 SpringSimulation 同参),
/// 形变弹簧 620/22.9、拉伸 0.40、纵向补偿 0.54(底栏拖拽同参)。
class _TabDroplet extends StatefulWidget {
  const _TabDroplet({required this.controller, required this.barHeight});

  final TabController controller;

  final double barHeight;

  @override
  State<_TabDroplet> createState() => _TabDropletState();
}

class _TabDropletState extends State<_TabDroplet>
    with SingleTickerProviderStateMixin {
  Ticker? _tickerC;
  Ticker get _ticker => _tickerC ??= createTicker(_onTick);
  Duration _lastFrame = Duration.zero;

  // 渲染位置/速度:弹簧追 controller 动画值
  double _pos = 0;
  double _posSpd = 0;
  // 形变量与速度:横向拉伸 _sx,纵向压扁 _sy(负值)
  double _sx = 0, _sxSpd = 0;
  double _sy = 0, _sySpd = 0;
  // controller 动画值与帧间速度差分
  double _animV = 0;
  double _animVel = 0;
  double? _lastAnimT;
  double? _lastAnimV;
  // 距上次 controller 动画回调的帧数(>2 视为停帧,速度清零)
  int _framesSinceAnim = 0;
  // 拖动换页(底栏同款):按下后位置直跟手指,松手吸附最近档并回弹
  bool _dragActive = false;
  double _dragBase = 0;
  double _dragPos = 0;
  double _dragVel = 0;
  int? _lastDragMs;
  double _tabW = 1;

  @override
  void initState() {
    super.initState();
    _animV = widget.controller.animation!.value;
    _pos = _animV;
    widget.controller.animation!.addListener(_onAnim);
  }

  @override
  void didUpdateWidget(covariant _TabDroplet old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.animation!.removeListener(_onAnim);
      _animV = widget.controller.animation!.value;
      _pos = _animV;
      _posSpd = _animVel = 0;
      _lastAnimT = _lastAnimV = null;
      widget.controller.animation!.addListener(_onAnim);
    }
  }

  @override
  void dispose() {
    widget.controller.animation!.removeListener(_onAnim);
    _tickerC?.dispose();
    super.dispose();
  }

  void _onAnim() {
    final v = widget.controller.animation!.value;
    final now = DateTime.now().microsecondsSinceEpoch / 1e6;
    if (_lastAnimT != null && _lastAnimV != null) {
      final dt = (now - _lastAnimT!).clamp(0.001, 0.05);
      _animVel = (v - _lastAnimV!) / dt;
    }
    _lastAnimT = now;
    _lastAnimV = v;
    _animV = v;
    _framesSinceAnim = 0;
    if (!_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    }
  }

  void _onDragStart(DragStartDetails d) {
    if (widget.controller.length < 2) return;
    _dragActive = true;
    _dragBase = widget.controller.index.toDouble();
    _dragPos = _dragBase;
    _dragVel = 0;
    _posSpd = 0;
    _lastDragMs = DateTime.now().millisecondsSinceEpoch;
    if (!_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    }
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragActive || d.primaryDelta == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final dt = ((now - (_lastDragMs ?? now - 16)) / 1000.0).clamp(0.004, 0.05);
    _lastDragMs = now;
    final n = widget.controller.length;
    final next = (_dragPos + d.primaryDelta! / _tabW).clamp(0.0, (n - 1).toDouble());
    _dragVel = _dragVel * 0.6 + ((next - _dragPos) / dt) * 0.4;
    _dragPos = next;
    setState(() {});
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragActive) return;
    _dragActive = false;
    final n = widget.controller.length;
    var target = _dragPos.round();
    // 甩动换页:速度方向上取下一个整档(底栏同款语义)
    if (_dragVel.abs() > 0.5) {
      target = _dragVel > 0 ? _dragPos.ceil() : _dragPos.floor();
    }
    target = target.clamp(0, n - 1);
    _animVel = _dragVel.clamp(-4.0, 4.0);
    _dragVel = 0;
    _lastDragMs = null;
    widget.controller.animateTo(target);
    if (!_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    }
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    final rawDt = (elapsed - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = elapsed;
    final dt = (rawDt <= 0 || rawDt > 0.05) ? 0.016 : rawDt;

    // 动画停帧后速度清零(controller 停止时不再回调,避免拉伸冻结)
    _framesSinceAnim++;
    if (_framesSinceAnim > 2) _animVel = 0;

    final vel = _dragActive ? _dragVel : _animVel;
    if (_dragActive) {
      // 拖拽中位置直跟手指,位置弹簧停用
      _pos = _dragPos;
      _posSpd = 0;
    } else {
      // 位置弹簧:追 controller 动画值(底栏 _move 同参)
      _posSpd += ((_animV - _pos) * 420 - _posSpd * 25.4) * dt;
      _pos += _posSpd * dt;
    }

    // 形变弹簧:速度归一(vn=|vel|/4)→ 横向拉伸 0.40、纵向压扁补偿 0.54,
    // 静止时弹簧回零(底栏拖拽同参)
    const defX = 0.40, compY = 0.54;
    final vn = (vel.abs() / 4.0).clamp(0.0, 1.0);
    _sxSpd += ((vn * defX - _sx) * 620 - _sxSpd * 22.9) * dt;
    _sx += _sxSpd * dt;
    _sySpd += ((-vn * defX * compY - _sy) * 620 - _sySpd * 22.9) * dt;
    _sy += _sySpd * dt;

    final settled = !_dragActive &&
        _animVel == 0 &&
        (_animV - _pos).abs() < 0.002 &&
        _posSpd.abs() < 0.001 &&
        _sx.abs() < 0.002 &&
        _sxSpd.abs() < 0.001 &&
        _sy.abs() < 0.002 &&
        _sySpd.abs() < 0.001;
    if (settled) {
      _pos = _animV;
      _posSpd = _sx = _sxSpd = _sy = _sySpd = 0;
      _ticker.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // translucent:水滴层在最上,命中同时放行底层 TabBar——点击归 TabBar,
    // 横向拖动归水滴(底栏同款拖动换页手势)
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: LayoutBuilder(builder: (context, constraints) {
      final tabCount = widget.controller.length.clamp(1, 999);
      final tabW = constraints.maxWidth / tabCount;
      _tabW = tabW;
      final dropH = (widget.barHeight * 0.8).clamp(28.0, 44.0);
      final sx = 1 + _sx;
      final sy = 1 + _sy;
      return Stack(
        children: [
          Positioned(
            left: _pos * tabW + 4,
            top: (constraints.maxHeight - dropH) / 2,
            width: tabW - 8,
            height: dropH,
            child: IgnorePointer(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(sx, sy, 1)
                  ..setEntry(
                      0, 1, (_dragActive ? _dragVel : _animVel).sign * _sx * 0.15),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(dropH / 2),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      }),
    );
  }
}

class FloatingSearchTopBar extends StatelessWidget {
  const FloatingSearchTopBar({
    super.key,
    required this.field,
    this.onBack,
    this.action,
    this.tabPill,
    this.bottomPill,
  });

  final Widget field;

  final VoidCallback? onBack;

  final Widget? action;

  final Widget? tabPill;

  final Widget? bottomPill;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (onBack != null) ...[
              BiliPaiIconButton(icon: Icons.arrow_back, onTap: onBack),
              const SizedBox(width: 10),
            ],
            Expanded(child: field),
            if (action != null) ...[
              const SizedBox(width: 10),
              action!,
            ],
          ],
        ),
        if (tabPill != null) ...[
          const SizedBox(height: 10),
          tabPill!,
        ],
        if (bottomPill != null) ...[
          const SizedBox(height: 10),
          bottomPill!,
        ],
      ],
    );
  }
}

Widget floatingChromeBar(
  BuildContext context, {
  Widget? leading,
  required Widget title,
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
  TabController? bottomTabController,
}) {
  final statusBar = MediaQuery.paddingOf(context).top;
  final bottomH = bottom?.preferredSize.height ?? 0;
  final lead = leading == null
      ? const <Widget>[]
      : [
          _chromeGlassAction(context, leading),
          const SizedBox(width: 10),
        ];
  Widget? bottomRow;
  if (bottom is PageSearchBarBottom) {
    bottomRow = SizedBox(
      height: bottomH,
      child: Align(
        alignment: Alignment.center,
        child: FloatingSearchBar(
          onTap: bottom.onTap,
          onRecognize: bottom.onRecognize,
        ),
      ),
    );
  } else if (bottom != null) {
    bottomRow = FloatingTabPill(
      height: bottomH,
      controller: bottomTabController,
      child: bottom,
    );
  }
  return RepaintBoundary(
    child: Padding(
      padding: EdgeInsets.fromLTRB(12, statusBar + 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: kToolbarHeight - 8,
            child: Row(
              children: [
                ...lead,
                BiliPaiPill(
                  radius: 20,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(
                      height: 40,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DefaultTextStyle(
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          child: title,
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                for (final a in actions) ...[
                  const SizedBox(width: 10),
                  _chromeGlassAction(context, a),
                ],
              ],
            ),
          ),
          ?bottomRow,
        ],
      ),
    ),
  );
}

Widget _chromeGlassAction(BuildContext context, Widget w) {
  if (w is BackButton) {
    return BiliPaiIconButton(
      icon: Icons.arrow_back,
      onTap: w.onPressed ?? () => Navigator.of(context).maybePop(),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
    );
  }
  if (w is IconButton) {
    final ic = w.icon;
    return BiliPaiIconButton(
      icon: ic is Icon ? ic.icon : null,
      iconChild: ic is Icon ? null : ic,
      color: w.color ?? (ic is Icon ? ic.color : null),
      tooltip: w.tooltip,
      onTap: w.onPressed,
    );
  }
  if (w is SizedBox) return w;
  return BiliPaiPill(
    radius: 20,
    child: IconTheme(
      data: const IconThemeData(size: 20)
          .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      child: w,
    ),
  );
}
