import 'dart:ui';

import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/app_logger.dart';
import '../core/app_colors.dart';
import '../core/haptics.dart';
import '../core/settings.dart';
import '../auth/auth_provider.dart';
import '../widgets/glass_settings.dart';
import '../widgets/app_toast.dart';
import '../notifications/notification_service.dart';
import '../sync/auto_sync.dart';
import '../sync/sync_provider.dart' show syncProvider;
import '../widgets/mini_player_bar.dart';
import 'routes.dart';
import '../i18n/i18n.dart';

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
      glassColor:
          // 提升底色不透明度：暗色从 alpha 10(≈0.04) 提到 80(≈0.31)、
          // 亮色从 130(≈0.51) 提到 175(≈0.69)，让液态底栏/侧栏不透明到能
          // 托起折射高光、透出模糊层次；亮色避免过高压暗底色（老问题）。
          isDark
          ? const Color.fromARGB(80, 255, 255, 255)
          : const Color.fromARGB(175, 255, 255, 255),
      blur: isDark ? 9.0 : 7.0,
      thickness: 22,
      refractiveIndex: 1.38,
      chromaticAberration: 0.035,
      lightIntensity: isDark ? 1.45 : 1.15,
      ambientStrength: 0.25,
      glowIntensity: 1.1,
      saturation: 1.28,
      shadow: const [],
      // ambientRim/edgeAbsorption 仅 premium(高)档消费：全周边亮环 + 边缘雕刻暗带。
      ambientRim: 0.5,
      edgeAbsorption: 0.12,
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
      AppLogger.instance.log('shell', '进入二级页面 ${widget.runtimeType}');
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
      AppLogger.instance.log('shell', '离开二级页面 ${widget.runtimeType}');
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

  bool _notificationsChecked = false;

  @override
  void initState() {
    super.initState();
    // 启动自动同步调度器（每分钟 tick，到点才同步）。
    ref.read(autoSyncProvider).start();
    // 启动时若已登录则触发首次全量一致性同步（仅首次，本地有数据且与云端冲突才弹窗）。
    // 显式登录/注册场景由 account_page 触发，此处覆盖重开应用自动登录的既有用户。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(authProvider).user != null) {
        ref.read(syncProvider.notifier).syncOnLoginSuccess(context);
      }
    });
    // 首帧后检查公告/反馈完成通知，避免与启动动画冲突。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_notificationsChecked) return;
      _notificationsChecked = true;
      ref
          .read(notificationServiceProvider)
          .checkOnStartup(context)
          .catchError((_) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.navigationShell.currentIndex;
    final hiddenCount = ref.watch(navBarHiddenProvider);
    // 只要有页面请求隐藏底栏（说明在二级页面，如音源管理/扫描文件夹/歌曲列表等）
    // 或者 GoRouter 栈深 > 1，就 100% 处于二级页面。
    final isSubPage = hiddenCount > 0 || GoRouter.of(context).canPop();

    // 动态 canPop（预测返回友好）：
    //
    // - 二级页面（go_router 子路由 / push 到 root navigator 的页面，root 栈深 > 1）
    //   isSubPage=true → canPop=true，系统把手势交给 Flutter，由
    //   PredictiveBackPageTransitionsBuilder 自绘过渡，预测返回显示真实内容预览；
    // - 真正根节点 isSubPage=false → canPop=false，回到下方式手动分发
    //   （切 tab / 再按一次退出等）。
    //
    // 关键前提：二级页面必须压在 ROOT navigator 上（routes.dart 已如此），
    // 使 GoRouter.canPop() 如实反映"root 栈里有可弹的真实页面"；若仍压在
    // 分支内部 Navigator，canPop 会失真并触发「返回直接回桌面」的历史 bug。
    return Listener(
      behavior: HitTestBehavior.translucent,
      // 鼠标/外接设备的侧键「返回」（PiliNara BackDetector 同款语义），
      // 走与系统返回一致的分发，保证桌面扩展屏/外接鼠标下体验一致。
      onPointerDown: (PointerDownEvent e) {
        if (e.buttons == kBackMouseButton) _handleBack();
      },
      child: PopScope(
        canPop: isSubPage,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _handleBack();
        },
        child: _ShellScaffold(
          navigationShell: widget.navigationShell,
          index: index,
        ),
      ),
    );
  }

  /// 根节点返回分发：二级页弹栈 → 切回主界面 Tab → 双击退出。
  /// 同时被系统返回与鼠标侧键触发，避免两处重复实现。
  void _handleBack() {
    final router = GoRouter.of(context);
    AppLogger.instance.log('back',
        'onBack tab=${widget.navigationShell.currentIndex} routerCanPop=${router.canPop()}');

    // 1. 二级页面（go_router 子路由或直接 push 到 root navigator 的
    //    页面都在 root 栈上，router.canPop 均为 true）：弹栈返回。
    if (router.canPop()) {
      AppLogger.instance.log('back', '手动 pop 二级页面');
      router.pop();
      return;
    }

    // 2. 已在 Branch 根页面且不在“主界面”(index != 0)，返回“主界面” Tab
    if (widget.navigationShell.currentIndex != 0) {
      AppLogger.instance.log('back', '切回主界面 tab');
      widget.navigationShell.goBranch(0);
      return;
    }

    // 3. 如果已经在“主界面” Tab 根节点，提示“再按一次退出应用”
    final now = DateTime.now();
    if (_lastBackTime == null ||
        now.difference(_lastBackTime!) > const Duration(seconds: 2)) {
      _lastBackTime = now;
      AppLogger.instance.log('back', '提示再按一次退出');
      showXianYuToast(context, tr('再按一次退出应用'),
        duration: const Duration(seconds: 2));
      return;
    }

    // 4. 2秒内再次触发系统返回，顺畅退出程序
    AppLogger.instance.log('back', 'SystemNavigator.pop 退出应用');
    SystemNavigator.pop();
  }
}

/// 外壳骨架：按设置在悬浮式与固定式底栏之间切换。
///
/// - 悬浮式：底栏与播放条为 `Positioned` 浮层，叠在内容之上，
///   页面需自行留出 [kFloatingNavBarInset] 的底部间距。
/// - 固定式：底栏与播放条参与布局（`Scaffold.bottomNavigationBar`），
///   Scaffold 自动收缩内容区，页面无需额外避让。
class _ShellScaffold extends ConsumerStatefulWidget {
  const _ShellScaffold({
    required this.navigationShell,
    required this.index,
  });

  final StatefulNavigationShell navigationShell;
  final int index;

  @override
  ConsumerState<_ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends ConsumerState<_ShellScaffold> {
  static final _jellyKey = GlobalKey<State<_JellySwitch>>();

  late final GoRouter _router;

  /// 当前是否处于「根级 Tab 路径」。
  ///
  /// 与 [GoRouter.canPop] 刻意解耦：`canPop` 读的是根 Navigator 的 `_history`，
  /// 被退出的路由在整段反向过渡动画期间都还留在 `_history` 里（要到动画结束才
  /// 移除、页面 dispose），因此返回途中 `canPop` 恒为 true，导致底栏在整个过渡
  /// 中一直隐藏、动画结束才淡入，出现「先看到一级页、再看到底栏」。
  ///
  /// 而 GoRouter 的 `currentConfiguration` 在 pop 一开始的 `didPop` 就会同步收缩
  /// 路由匹配（见 delegate 的 `_completeRouteMatch` → `notifyListeners`），用它判断
  /// 路径能立刻在「一级页开始露出」的同一帧把底栏解开。这样无论用
  /// PredictBackPageTransitionsBuilder（预测返回）还是 ZoomPageTransitionsBuilder
  /// （关闭预测返回），返回过渡期间底栏都能随页面露出一起出现。
  bool _isRootPath = true;

  static const _rootPaths = {'/', '/home', '/mine'};

  static bool _isRootPathOf(String path) => _rootPaths.contains(path);

  @override
  void initState() {
    super.initState();
    _router = GoRouter.of(context);
    _isRootPath =
        _isRootPathOf(_router.routerDelegate.currentConfiguration.uri.path);
    _router.routerDelegate.addListener(_onRouteChanged);
  }

  /// 路由匹配变化（push/pop）时跟手更新是否处于根路径，并顺带清掉漂移的
  /// 「隐藏底栏」计数，让底栏/播放条随返回过渡一起淡入，而不是等二级页
  /// dispose（返回过渡结束后）再触发。
  void _onRouteChanged() {
    if (!mounted) return;
    final rootNow =
        _isRootPathOf(_router.routerDelegate.currentConfiguration.uri.path);
    if (rootNow != _isRootPath) {
      setState(() => _isRootPath = rootNow);
    }
    if (rootNow) {
      final notifier = ref.read(navBarHiddenProvider.notifier);
      if (notifier.state > 0) notifier.state = 0;
    }
  }

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  /// 迷你播放条拖拽的绝对位置 (Top & Left)
  double? _playerTop;
  double? _playerLeft;

  bool _isPlayerDragging = false;

  void _onPlayerPanStart(DragStartDetails details) {
    setState(() {
      _isPlayerDragging = true;
    });
  }

  void _onPlayerPanUpdate(
    DragUpdateDetails details,
    Size screenSize,
    EdgeInsets padding,
    double defaultLeft,
    double defaultTop,
    bool hasBottomBar,
  ) {
    final currentLeft = _playerLeft ?? defaultLeft;
    final currentTop = _playerTop ?? defaultTop;

    // 实际宽度（与悬浮底栏一致的 18px 双侧边距），拖拽边界按真实尺寸夹取。
    final barW = screenSize.width - 36.0;
    const barH = 58.0;

    final minLeft = 6.0;
    final maxLeft = screenSize.width - barW - 6.0;
    final minTop = padding.top + 6.0;

    // 拖拽下限：
    // - 有悬浮底栏(根页)时：播放条底边可拖到与底栏顶(screenSize.height-18-70)
    //   贴合，基于底栏几何精确避让，不依赖手势区 height。
    // - 无底栏(二级页)：向下限到屏幕底上方 12px。
    final maxTop = hasBottomBar
        ? (screenSize.height - 18.0 - 70.0 - barH)
        : (screenSize.height - padding.bottom - barH - 12.0);

    setState(() {
      _playerLeft = (currentLeft + details.delta.dx).clamp(
        minLeft,
        maxLeft > minLeft ? maxLeft : minLeft,
      );
      _playerTop = (currentTop + details.delta.dy).clamp(
        minTop,
        maxTop > minTop ? maxTop : minTop,
      );
    });
  }

  void _onPlayerPanEnd(
    DragEndDetails details,
    double defaultLeft,
    double defaultTop,
  ) {
    setState(() {
      _isPlayerDragging = false;
    });

    // 完全自由停放：松手后播放条停留在拖到的位置，不再被 60px 磁吸拉回
    // 靠近底栏的停靠位（原先「靠近底栏就会吸过去」即由此造成）。
  }

  void _onPlayerPanCancel() {
    setState(() {
      _isPlayerDragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    // 使用纯硬件安全区内边距 (padding.bottom)，不受软键盘 viewInsets 干扰
    final padding = MediaQuery.of(context).padding;
    final safeBottom = padding.bottom;

    final floating =
        ref.watch(settingsProvider.select((s) => s.valueOrNull?.floatingNavBar)) ??
            true;

    // 用「当前是否为根路径」而非 canPop 判断是否处于二级页：canPop 在整个返回
    // 过渡动画期间一直为 true（被退路由动画结束才从 _history 移除），会让底栏
    // 动画结束才出现；路径在 pop 开始时即已收缩，可让底栏随一级页露出同步淡入。
    final hiddenCount = ref.watch(navBarHiddenProvider);
    final hidden = hiddenCount > 0 || !_isRootPath;

    void select(int i) => widget.navigationShell.goBranch(
          i,
          initialLocation: i == widget.index,
        );

    final isSide = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.navBarPosition)) ==
        NavBarPosition.side;

    final expanded = ref.watch(sideBarExpandedProvider);

    // 检测当前路由：全屏歌曲详情页 /player 时不隐藏迷你条（见下），
    // 其余二级页由 hidden 统一处理。
    final isPlayerPage =
        GoRouterState.of(context).uri.toString() == '/player';

    // 迷你条位置档位：播放页打开时保持进入前的位置（供 Hero 飞行取源/落点，
    // 否则位置变化会打断「底栏封面飞播放页」的飞行）；其余情况沿用 hidden 下沉。
    final miniBarLow = hiddenCount > 0 || (!_isRootPath && !isPlayerPage);

    // 默认定位坐标（不受软键盘影响，始终保持在底部稳定避让区）
    final defaultLeft = 18.0;
    final defaultTop = isSide
        ? (screenSize.height - safeBottom - 58.0 - 12.0)
        : (floating
            ? (miniBarLow
                ? (screenSize.height - safeBottom - 58.0 - 18.0)
                // 根页停靠：播放条底边与悬浮底栏顶(screenSize.height-18-70)贴合，
                // 消除二者之间的缝隙。
                : (screenSize.height - 18.0 - 70.0 - 58.0))
            // 固定式：播放条底边与固定底栏顶(screenSize.height-safeBottom-64)贴合。
            : (screenSize.height - safeBottom - 58.0 - 64.0));

    final actualLeft = _playerLeft ?? defaultLeft;
    final actualTop = _playerTop ?? defaultTop;

    // 根页停靠位顶部：预测返回回拨的落点（页面条在二级页位于低位 -18，shell 条
    // 回到根页停在 -82/-70/-12，直接取隐藏位产生的飞行只有几像素不可见）。用
    // 根页停靠顶计算目标，才能复现「页面条封面飞回根页 shell 条」的可见飞行。
    final rootBarTop = isSide
        ? (screenSize.height - safeBottom - 58.0 - 12.0)
        : (floating
            ? (screenSize.height - 18.0 - 70.0 - 58.0)
            : (screenSize.height - safeBottom - 58.0 - 64.0));

    return Scaffold(
      body: Stack(
        children: [
          widget.navigationShell,

          // 迷你播放条：支持全界面常驻、手势防穿透拖拽与 60px 区域磁吸吸附回弹；
          // 二级页面进出时带有平滑上浮/下沉动画。播放页打开时【不移除】——移除会让
          // Hero 在 push 后下一帧收集源封面时找不到迷你条，导致「打开无飞行、只有
          // 返回有飞行」；播放页为不透明路由会盖住迷你条，留在树中无副作用。
          AnimatedPositioned(
            duration: _isPlayerDragging
                ? Duration.zero
                : const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            left: actualLeft,
            top: actualTop,
            width: screenSize.width - 36.0,
            child: MiniPlayerBar(
              onPanStart: _onPlayerPanStart,
              onPanUpdate: (d) => _onPlayerPanUpdate(d, screenSize, padding,
                  defaultLeft, defaultTop, !isSide && !hidden),
              onPanEnd: (d) =>
                  _onPlayerPanEnd(d, defaultLeft, defaultTop),
              onPanCancel: _onPlayerPanCancel,
              // 二级页面（非播放页）时 shell 播放条被 root navigator 覆盖不可见，
              // 不注册飞封面目标，避免与页面自己的播放条竞争目标位置。
              registerTarget: !(hiddenCount > 0 && !isPlayerPage),
              // Hero 源：根页面与播放页时由 shell 播放条承担；二级页面（非播放页）
              // 时去掉 Hero，由页面内嵌播放条承担（Hero 源必须在栈顶页面子树中）。
              heroTag: (hiddenCount > 0 && !isPlayerPage) ? null : 'player-cover',
              // 预测返回回拨落点：用根页停靠位（见上 rootBarTop），使二级页返回时
              // 封面飞行可见地归位到 shell 条。
              returnTarget: () => Rect.fromLTWH(
                actualLeft,
                rootBarTop,
                46,
                46,
              ),
            ),
          ),

          // 侧边栏悬浮层
          if (isSide)
            _SideNavRail(
              index: widget.index,
              hidden: hidden,
              expanded: expanded,
              onToggleExpand: () {
                ref.read(sideBarExpandedProvider.notifier).state = !expanded;
              },
              onSelect: select,
            ),

          // 悬浮底栏（仅在 4 个主 Tab 根页面展示，二级页面 hidden 时优雅淡出缩小隐去）
          if (!isSide && floating)
            Positioned(
              left: 18,
              right: 18,
              bottom: 18,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                opacity: hidden ? 0.0 : 1.0,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  scale: hidden ? 0.92 : 1.0,
                  child: IgnorePointer(
                    ignoring: hidden,
                    child: _JellySwitch(
                      key: _jellyKey,
                      mode: true,
                      child: _LiquidNavBar(index: widget.index, onSelect: select),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: (!isSide && !floating)
          ? _JellySwitch(
              key: _jellyKey,
              mode: false,
              child:
                  _FixedChrome(index: widget.index, hidden: hidden, onSelect: select),
            )
          : null,
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
class _FixedNavBar extends ConsumerWidget {
  const _FixedNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 性能模式：一次性关闭常驻玻璃/液态玻璃，回退到高不透明度纯色（更实底色补偿模糊缺失）。
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    // 固定底栏不使用液态玻璃 shader：液态玻璃只属于悬浮底栏（floating==true）。
    // _FixedNavBar 仅在 floating==false 时被渲染，固定底栏保持其常规圆角样式即可。
    final haptic = hapticStrengthFromInt(
      ref.watch(settingsProvider.select((s) => s.valueOrNull?.hapticStrength)),
    );
    final wallpaper = ref.watch(wallpaperActiveProvider);

    // 固定底栏内容（与材质设置无关，共用布局）。
    final bar = SafeArea(
      top: false,
      child: SizedBox(
        height: 64,
        // 与悬浮底栏一致：左右留边，避免最外侧 tab 的选中色块贴屏幕边缘。
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              for (var i = 0; i < bottomNavItems.length; i++)
                Expanded(
                  child: _NavTab(
                    item: bottomNavItems[i],
                    selected: i == index,
                    onTap: () {
                      triggerHaptic(haptic);
                      onSelect(i);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    // 液态玻璃仅属于悬浮底栏；固定底栏保持下方常规圆角样式，不走 shader。
    // 伪毛玻璃（液态/未开 默认）：半透明 + BackdropFilter 高斯模糊；
    // 低性能模式或关闭「毛玻璃」→ 高不透明度纯色回退（无模糊）。
    final solid =
        glassShouldUseSolid(ref, lowPerf: lowPerf, wallpaper: wallpaper);
    final fill = wallpaper
        ? glassControlFill
        : (solid
            ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
            : (isDark
                ? const Color(0xCC222222)
                : const Color(0xD9F7F7F9)));
    // 固定底栏顶部不再画横向分隔线（玻璃态的分隔条 / 实色态的 border）：
    // 迷你播放条停靠时正好落在底栏顶边，画线会在播放条底缘形成一条可见
    // 接缝，视觉上就像"播放条贴不住底栏、中间有空"。去掉后二者无缝贴合。
    final barBox = Container(color: fill, child: bar);
    if (solid) {
      return barBox;
    }
    // 伪毛玻璃：半透明白/暗 + 高斯模糊（安卓原生磨砂质感），壁纸时更透。
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: barBox,
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
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            true) &&
            !lowPerf;
    final haptic = hapticStrengthFromInt(
      ref.watch(settingsProvider.select((s) => s.valueOrNull?.hapticStrength)),
    );

    // 水平留 10px：选中色块占满整个 Expanded 宽度，不加内边距的话
    // 最左/最右 tab 的色块会顶到胶囊两端，被玻璃圆角边界裁切。
    final tabs = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          for (var i = 0; i < bottomNavItems.length; i++)
            Expanded(
              child: _NavTab(
                item: bottomNavItems[i],
                selected: i == index,
                onTap: () {
                  triggerHaptic(haptic);
                  onSelect(i);
                },
              ),
            ),
        ],
      ),
    );

    if (liquid) return _liquidGlass(context, ref, tabs);
    return _frostedGlass(context, ref, tabs, lowPerf: lowPerf);
  }

  /// 液态玻璃：shader 折射 + 高光，胶囊形状。
  Widget _liquidGlass(BuildContext context, WidgetRef ref, Widget tabs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return glassBorder(
      context: context,
      radius: 30,
      child: AdaptiveGlass(
        // 胶囊 = 圆角矩形且圆角为高度一半。
        // 不能用 LiquidOval：那是真椭圆，宽高比大时两端会被压成尖角。
        shape: const LiquidRoundedRectangle(borderRadius: 30),
        settings: liquidGlassSettings(isDark),
        // 渲染档位走设置：低=minimal / 中=standard 均衡（默认）/ 高=premium 真折射。
        quality: liquidGlassQualityFromRef(ref),
        child: SizedBox(height: 70, child: tabs),
      ),
    );
  }

  /// 伪毛玻璃：液态玻璃关闭时的默认样式。
  ///
  /// 规则：开启壁纸 → 半透明玻璃 + 高斯模糊（透出壁纸，与设置组件/播放条一致）；
  /// 低性能模式（或关闭壁纸）→ 标准半透明磨砂；低性能 → 高不透明度纯色。
  Widget _frostedGlass(BuildContext context, WidgetRef ref, Widget tabs,
      {bool lowPerf = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final wallpaper = ref.watch(wallpaperActiveProvider);
    final solid =
        glassShouldUseSolid(ref, lowPerf: lowPerf, wallpaper: wallpaper);
    final bg = wallpaper
        ? glassControlFill
        : (solid
            ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
            : (isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.52)));
    final border = wallpaper
        ? glassControlBorder
        : (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.40));
    final capsule = Container(
      height: 70,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.18),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: tabs,
    );
    if (solid) return capsule;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: capsule,
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
    final primary = scheme.primary;
    final color = selected
        ? primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        // 纵向 padding 恒定：选中/未选中高度一致，图标+文字整体
        // 由 Row 垂直居中（栏高 60 > 内容 47，切换不跳动）。
        padding: EdgeInsets.symmetric(
          horizontal: selected ? 14 : 4,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(item.icon, size: 22, color: color),
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
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(
                settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            true) &&
            !lowPerf;

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
                    scheme.primary,
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
          panelWidget = glassBorder(
            context: context,
            radius: 24,
            child: AdaptiveGlass(
              shape: const LiquidRoundedRectangle(borderRadius: 24),
              settings: liquidGlassSettings(isDark),
              quality: liquidGlassQualityFromRef(ref),
              child: SizedBox(width: panelWidth, child: panelBody),
            ),
          );
        } else if (lowPerf) {
          // 性能模式：更高不透明度纯色补偿模糊缺失，省去 BackdropFilter。
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
          panelWidget = ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
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
              Icon(item.icon, size: 22, color: color),
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
