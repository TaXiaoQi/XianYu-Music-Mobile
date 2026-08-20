import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/settings.dart';
import '../widgets/mini_player_bar.dart';
import 'routes.dart';

/// 浮动底栏占据的底部高度（距底 18 + 栏高 60 + 阴影余量）。
///
/// 底栏是叠在内容之上的 `Positioned`，不参与布局，`SafeArea` 也无法感知。
/// 弹窗、列表等需要避让它的地方统一引用此常量，改动底栏尺寸时只需改这里。
const double kFloatingNavBarInset = 90;

/// 分支根页面需要的底部避让高度。
///
/// - 悬浮式：底栏与播放条都是浮层（顶端到屏幕底部约 165px），页面留出 175px 保证末项完全露出。
/// - 固定式：底栏由 `Scaffold` 收缩内容区，但播放条仍是浮层，
///   页面只需为播放条留白 (82px)。
/// - 侧边栏：导航移到左侧，底部仅剩浮层播放条，页面同样只需留出 82px。
final navBarInsetProvider = Provider<double>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull;
  if (s?.navBarPosition == NavBarPosition.side) return 82;
  final floating = s?.floatingNavBar ?? true;
  return floating ? 175 : 82;
});

/// 最新调优的晶莹水晶物理 Shader 液态玻璃参数。
///
/// 极低底色遮罩 + 适当轻模糊 + 高饱和透光 + 强烈边缘高光与折射，呈现如 iOS 18/26 般水润透亮的液态玻璃。
LiquidGlassSettings liquidGlassSettings(bool isDark) => LiquidGlassSettings(
      glassColor: isDark
          ? const Color.fromARGB(10, 255, 255, 255)
          : const Color.fromARGB(32, 255, 255, 255),
      blur: isDark ? 6.5 : 5.0,
      thickness: 22,
      refractiveIndex: 1.38,
      chromaticAberration: 0.035,
      lightIntensity: isDark ? 1.45 : 1.15,
      ambientStrength: 0.25,
      glowIntensity: 0.85,
      saturation: 1.28,
      shadowElevation: 2.2,
    );

/// 请求隐藏底栏与迷你播放条的页面计数。
///
/// 二级页面（音源管理、扫描文件夹、歌曲列表等）不该被浮层遮挡，
/// 进入时 +1、离开时 -1；大于 0 时 shell 隐藏浮层。
/// 用计数而非布尔，以正确处理多层页面叠加。
final navBarHiddenProvider = StateProvider<int>((ref) => 0);

/// 侧边导航栏是否展开。
///
/// 默认折叠（仅在左上角显示 3 条竖线 logo 按钮），点击展开完整侧边栏。
final sideBarExpandedProvider = StateProvider<bool>((ref) => false);

/// 让当前页面在显示期间隐藏 shell 浮层。
///
/// 用法：在页面 State 中混入本 mixin，无需手动管理计数。
mixin HidesShellChrome<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// 缓存根容器：dispose 时本 State 的 ref 已不可用，
  /// 必须提前持有容器才能可靠地把计数减回去。
  ProviderContainer? _container;

  /// 是否已计入隐藏计数，避免重复增减导致计数漂移。
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    // 延后一帧：build 期间不可修改 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _container = ProviderScope.containerOf(context, listen: false);
      _counted = true;
      _container!.read(navBarHiddenProvider.notifier).state++;
    });
  }

  @override
  void dispose() {
    // 递减必须满足两个约束，缺一不可：
    //
    // 1. 不能同步改：dispose 处于 widget 树销毁流程中，直接改 provider 会触发
    //    "Tried to modify a provider while the widget tree was building"。
    // 2. 不能依赖本 State 的 ref：页面销毁后 ref 已失效，此前用
    //    `notifier.mounted` 判断会恒为假，计数只增不减，
    //    导致返回后底栏再也不出现。
    //
    // 因此用提前缓存的根容器，延后到下一帧执行。
    if (_counted) {
      final container = _container;
      _counted = false;
      if (container != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final notifier = container.read(navBarHiddenProvider.notifier);
          if (notifier.state > 0) notifier.state--;
        });
      }
    }
    super.dispose();
  }
}

/// 主外壳：浮动迷你播放器 + 液态玻璃底栏，叠加在页面内容之上。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  DateTime? _lastBackTime;

  @override
  Widget build(BuildContext context) {
    final index = widget.navigationShell.currentIndex;
    // 只要有页面请求隐藏底栏（说明在二级页面，如音源管理/扫描文件夹/歌曲列表等）
    // 或者 GoRouter 栈深 > 1，就 100% 处于二级页面。
    // 处于二级页面时将 canPop 设为 true，放开系统的 PopScope 拦截，
    // 让 Android 13+ 预测性返回手势（Predictive Back）正常拉动预览；
    // 仅在根 Tab 无法退栈时设为 false，拦截切回主界面或提示双击退出。
    final isSubPage =
        ref.watch(navBarHiddenProvider) > 0 || GoRouter.of(context).canPop();

    return PopScope(
      canPop: isSubPage,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        // 已在 Branch 根页面且不在“主界面”(index != 0)，返回“主界面” Tab
        if (index != 0) {
          widget.navigationShell.goBranch(0);
          return;
        }

        // 3. 如果已经在“主界面” Tab 根节点，提示“再按一次退出应用”
        final now = DateTime.now();
        if (_lastBackTime == null ||
            now.difference(_lastBackTime!) > const Duration(seconds: 2)) {
          _lastBackTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('再按一次退出应用'),
              duration: Duration(seconds: 2),
            ),
          );
          return;
        }

        // 4. 2秒内再次触发系统返回，顺畅退出程序
        SystemNavigator.pop();
      },
      child: _ShellScaffold(
        navigationShell: widget.navigationShell,
        index: index,
      ),
    );
  }
}

/// 外壳骨架：按设置在悬浮式与固定式底栏之间切换。
///
/// - 悬浮式：底栏与播放条为 `Positioned` 浮层，叠在内容之上，
///   页面需自行留出 [kFloatingNavBarInset] 的底部间距。
/// - 固定式：底栏与播放条参与布局（`Scaffold.bottomNavigationBar`），
///   Scaffold 自动收缩内容区，页面无需额外避让。
class _ShellScaffold extends ConsumerWidget {
  const _ShellScaffold({
    required this.navigationShell,
    required this.index,
  });

  final StatefulNavigationShell navigationShell;
  final int index;

  /// 固定的 key：悬浮式与固定式处在 widget 树的不同位置，
  /// 没有它 State 会被丢弃重建，`didUpdateWidget` 也就收不到形态变化。
  static final _jellyKey = GlobalKey<State<_JellySwitch>>();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floating =
        ref.watch(settingsProvider.select((s) => s.valueOrNull?.floatingNavBar)) ??
            true;
    // 二级页面（音源管理、歌曲列表等）不显示底栏与播放条。
    final hidden = ref.watch(navBarHiddenProvider) > 0;

    void select(int i) => navigationShell.goBranch(
          i,
          initialLocation: i == index,
        );

    // 侧边栏模式：导航为左上角悬浮层，主内容全屏显示（不被挤压占位）；
    // 播放条仍以悬浮胶囊浮在内容区底部。
    final isSide = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.navBarPosition)) ==
        NavBarPosition.side;
    if (isSide) {
      final expanded = ref.watch(sideBarExpandedProvider);
      return Scaffold(
        body: Stack(
          children: [
            navigationShell,
            if (!hidden)
              const Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: MiniPlayerBar(),
              ),
            _SideNavRail(
              index: index,
              hidden: hidden,
              expanded: expanded,
              onToggleExpand: () {
                ref.read(sideBarExpandedProvider.notifier).state = !expanded;
              },
              onSelect: select,
            ),
          ],
        ),
      );
    }

    if (floating) {
      // 悬浮式：底栏与播放条同为浮层，一并叠在内容之上。
      return Scaffold(
        body: Stack(
          children: [
            navigationShell,
            _JellySwitch(
              key: _jellyKey,
              mode: true,
              child: _FloatingChrome(
                index: index,
                onSelect: select,
                hidden: hidden,
              ),
            ),
          ],
        ),
      );
    }

    // 固定式：底栏贴底参与布局，播放条仍以悬浮胶囊浮在其上方。
    //
    // 播放条不并入 bottomNavigationBar：那样两者会拼成一整块，
    // 失去悬浮观感。改为放进 Stack，定位在底栏上沿之上。
    return Scaffold(
      body: Stack(
        children: [
          navigationShell,
          if (!hidden)
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: MiniPlayerBar(),
            ),
        ],
      ),
      bottomNavigationBar: _JellySwitch(
        key: _jellyKey,
        mode: false,
        child: _FixedChrome(index: index, hidden: hidden, onSelect: select),
      ),
    );
  }
}

/// 悬浮式浮层：迷你播放条 + 液态玻璃胶囊底栏。
class _FloatingChrome extends StatelessWidget {
  const _FloatingChrome({
    required this.index,
    required this.onSelect,
    required this.hidden,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 14,
              right: 14,
              bottom: 82,
              child: MiniPlayerBar(),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 18,
              child: _LiquidNavBar(index: index, onSelect: onSelect),
            ),
          ],
        ),
      ),
    );
  }
}

/// 固定式底栏：贴底参与布局。
///
/// 播放条不在此处——它以悬浮胶囊形式浮在底栏上方（见 `_ShellScaffold`）。
///
/// 二级页面推入的是分支内部 Navigator（位于 body 内），底栏不会被其覆盖，
/// 因此需主动收起；用 [AnimatedSize] 让高度变化平滑，避免转场跳变。
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

/// 固定式底栏：贴合屏幕底部，含安全区内边距。
class _FixedNavBar extends StatelessWidget {
  const _FixedNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? scheme.surfaceContainer
            : scheme.surface,
        border: Border(
          top: BorderSide(
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              for (var i = 0; i < bottomNavItems.length; i++)
                Expanded(
                  child: _NavTab(
                    item: bottomNavItems[i],
                    selected: i == index,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 包装二级页面，使其显示期间隐藏 shell 浮层。
///
/// 供无状态页面（`ConsumerWidget` / `StatelessWidget`）使用；
/// 有状态页面可直接混入 [HidesShellChrome]。
///
/// 用法：`HideShellChrome(child: Scaffold(...))`
class HideShellChrome extends ConsumerStatefulWidget {
  const HideShellChrome({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<HideShellChrome> createState() => _HideShellChromeState();
}

class _HideShellChromeState extends ConsumerState<HideShellChrome>
    with HidesShellChrome {
  @override
  Widget build(BuildContext context) => widget.child;
}

/// 底栏形态切换的果冻动画。
///
/// 悬浮式与固定式是两套不同的布局，直接替换会显得生硬。
/// 这里在 [mode] 变化时播放一次「缩小 → 回弹」：先快速收缩并淡出，
/// 再以 [Curves.elasticOut] 弹回原尺寸，制造柔软的形变感。
class _JellySwitch extends StatefulWidget {
  const _JellySwitch({
    super.key,
    required this.mode,
    required this.child,
  });

  /// 形态标识，值变化即触发动画。
  final Object mode;
  final Widget child;

  @override
  State<_JellySwitch> createState() => _JellySwitchState();
}

class _JellySwitchState extends State<_JellySwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  /// 缩放曲线：0→0.5 收缩到 0.82，0.5→1 用弹性回到 1。
  late final Animation<double> _scale;

  /// 收缩阶段轻微淡出，回弹时补满，避免形变显得干硬。
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
      value: 1, // 首帧静止在常态，避免启动时无谓动画
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.82)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 32,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.82, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 68,
      ),
    ]).animate(_ctrl);
    _fade = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.55),
        weight: 32,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.55, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 68,
      ),
    ]).animate(_ctrl);
  }

  @override
  void didUpdateWidget(_JellySwitch old) {
    super.didUpdateWidget(old);
    // 仅在形态真正切换时播放，其余重建（如切 tab）不打扰。
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
            // 以底部为支点缩放，贴着屏幕底边形变更自然。
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 悬浮底栏：液态玻璃或毛玻璃胶囊 + 选中态红色 + 圆点指示。
///
/// 液态玻璃走 shader 渲染（折射、动态光照、镜面高光），观感更接近 iOS 26；
/// 关闭后退回 [BackdropFilter] 毛玻璃，开销更低。
class _LiquidNavBar extends ConsumerWidget {
  const _LiquidNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liquid =
        ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            true;

    final tabs = Row(
      children: [
        for (var i = 0; i < bottomNavItems.length; i++)
          Expanded(
            child: _NavTab(
              item: bottomNavItems[i],
              selected: i == index,
              onTap: () => onSelect(i),
            ),
          ),
      ],
    );

    if (liquid) return _liquidGlass(context, tabs);
    return _frostedGlass(tabs);
  }

  /// 液态玻璃：shader 折射 + 高光，胶囊形状。
  Widget _liquidGlass(BuildContext context, Widget tabs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AdaptiveGlass(
      // 胶囊 = 圆角矩形且圆角为高度一半。
      // 不能用 LiquidOval：那是真椭圆，宽高比大时两端会被压成尖角。
      shape: const LiquidRoundedRectangle(borderRadius: 30),
      settings: liquidGlassSettings(isDark),
      child: SizedBox(height: 60, child: tabs),
    );
  }

  /// 毛玻璃：轻量回退方案。
  Widget _frostedGlass(Widget tabs) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 26,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: tabs,
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final BottomNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? const Color(0xFFEC4141)
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(item.icon, size: 22, color: color),
          const SizedBox(height: 3),
          Text(
            item.title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(top: 2),
            width: selected ? 4 : 0,
            height: 4,
            decoration: const BoxDecoration(
              color: Color(0xFFEC4141),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

/// 三条竖线 Logo 图标（音乐感动态竖波纹）。
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

/// 侧边导航栏悬浮面板：支持拖动三条竖线按钮更改悬浮位置，避免遮挡内容。
///
/// 完全采用 [Positioned] 悬浮定位，不挤压或占据主内容画面；
/// 支持手势拖动，微小移动识别为点击切换展开/折叠状态；
/// 支持基于设置（向下/向上展开）与屏幕空间溢出自动反转；
/// 二级页面（[hidden]）时优雅淡出，不阻挡页面返回。
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

  /// 悬浮面板的相对位置（Top 与 Left）
  double? _top;
  double? _left;

  /// 拖动过程中的移动总距离，用于区分点按（Tap）与拖拽（Drag）
  double _dragDistance = 0;

  /// 是否正处于手势拖拽中
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
  }

  void _onPanUpdate(
    DragUpdateDetails details,
    Size screenSize,
    EdgeInsets padding,
  ) {
    _dragDistance += details.delta.distance;
    final currentTop = _top ?? (padding.top + 10.0);
    final currentLeft = _left ?? 10.0;

    final panelW = widget.expanded ? 84.0 : 48.0;

    final minTop = padding.top + 6.0;
    final maxTop = screenSize.height - padding.bottom - 48.0 - 12.0;
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
    // 移动距离极小（< 6 像素）判定为轻触点击
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
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;

    final currentTop = _top ?? (padding.top + 10.0);
    final left = _left ?? 10.0;

    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 获取用户在设置中的首选展开方向与液态玻璃设置
    final preferredDir = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.sideBarExpandDirection)) ??
        SideBarExpandDirection.down;
    final liquid = ref.watch(
            settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
        true;

    // 展开面板预估高度 (用于方向判断)
    const double approxExpandedH = 295.0;

    // 检测向下与向上展开是否能够被屏幕完整包裹
    final bool canFitDown =
        (currentTop + approxExpandedH) <= (screenSize.height - padding.bottom - 8.0);
    final bool canFitUp =
        (currentTop + 48.0 - approxExpandedH) >= (padding.top + 6.0);

    // 智能决策实际展开方向
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
        final panelWidth = lerpDouble(48.0, 84.0, progress)!;

        // 3条竖线 Logo 按钮组件（随 progress 旋转与变色）
        final logoButton = GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: (d) => _onPanUpdate(d, screenSize, padding),
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: panelWidth,
            height: 48,
            child: Center(
              child: Transform.rotate(
                angle: progress * (3.141592653589793 / 2),
                child: _ThreeBarsIcon(
                  color: Color.lerp(
                    scheme.onSurface.withValues(alpha: 0.85),
                    const Color(0xFFEC4141),
                    progress,
                  )!,
                ),
              ),
            ),
          ),
        );

        // 4个 Tab 导航按钮组件（随着 progress 顺畅展开与淡入）
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
          panelWidget = AdaptiveGlass(
            shape: const LiquidRoundedRectangle(borderRadius: 24),
            settings: liquidGlassSettings(isDark),
            child: SizedBox(width: panelWidth, child: panelBody),
          );
        } else {
          panelWidget = ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                width: panelWidth,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.white.withValues(alpha: 0.35),
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
              ),
            ),
          );
        }

        return Positioned(
          left: left,
          top: isUp ? null : currentTop,
          bottom: isUp ? (screenSize.height - currentTop - 48.0) : null,
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

/// 侧边导航栏条目：图标 + 标题竖排，选中态主色胶囊高亮。
class _SideNavTab extends StatelessWidget {
  const _SideNavTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final BottomNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFEC4141);
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? accent
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
                selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(
                item.title,
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
