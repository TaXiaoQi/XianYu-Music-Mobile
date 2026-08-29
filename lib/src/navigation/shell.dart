import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_logger.dart';
import '../core/app_colors.dart';
import '../core/haptics.dart';
import '../core/settings.dart';
import '../auth/auth_provider.dart';
import '../widgets/glass_settings.dart';
import '../widgets/custom_background.dart';
import '../widgets/blur_budget.dart';
import '../widgets/app_toast.dart';
import '../notifications/notification_service.dart';
import '../sync/auto_sync.dart';
import '../sync/sync_provider.dart' show syncProvider;
import '../widgets/mini_player_bar.dart';
import '../widgets/bilipai_glass.dart';
import '../../pages/library/library_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/playlist/playlists_page.dart';
import '../widgets/floating_search_bar.dart';
import '../widgets/glass_appbar.dart' show GlassTopBar;
import '../widgets/landscape_top_bar.dart';
import '../../pages/account/account_page.dart';
import '../../pages/download/download_page.dart';
import '../../pages/search/search_page.dart';
import 'routes.dart';
import '../i18n/i18n.dart';

/// 浮动底栏占据的底部高度（距底 18 + 栏高 60 + 阴影余量）。
///
/// 底栏是叠在内容之上的 `Positioned`，不参与布局，`SafeArea` 也无法感知。
/// 弹窗、列表等需要避让它的地方统一引用此常量，改动底栏尺寸时只需改这里。
const double kFloatingNavBarInset = 90;

/// 横屏固定左缘侧栏宽度（文字侧边栏，参考设置页横屏左栏）。内容区整体右移避让。
const double kLandscapeRailWidth = 176;

/// 全局横屏感知：由 AppShell 的 MediaQuery 检测写入，供各页面响应横屏布局。
///
/// 横屏时导航自动切换为侧边形态、无底部栏，页面底部只需为准占播放条留白，
/// 侧边栏浮层不参与布局，故左缘由需要避让的页面自行判断。
final isLandscapeProvider = StateProvider<bool>((ref) => false);

/// 横屏侧边栏「音乐库」当前选中的入口（0本地/1收藏/2最近/3歌单），null 表示
/// 未选中（右侧显示主 tab）。选中后右侧直接内嵌对应页面，不进入二级路由，
/// 参考设置页横屏的 master-detail。
final landscapeLibraryProvider = StateProvider<int?>((ref) => null);

/// 横屏「我的」页账号与安全是否以右侧容器内嵌面板打开（不开二级路由）。
final landscapeAccountOpenProvider = StateProvider<bool>((ref) => false);

/// 横屏「我的」页歌曲下载是否以右侧容器内嵌面板打开（不开二级路由）。
final landscapeDownloadOpenProvider = StateProvider<bool>((ref) => false);

/// 横屏选中的歌单 id：右侧容器内嵌歌单详情（不开二级路由），null=未打开。
final landscapePlaylistOpenProvider = StateProvider<String?>((ref) => null);

/// 分支根页面需要的底部避让高度。
///
/// - 悬浮式：底栏与播放条都是浮层（顶端到屏幕底部约 165px），页面留出 175px 保证末项完全露出。
/// - 固定式：底栏由 `Scaffold` 收缩内容区，但播放条仍是浮层，
///   页面只需为播放条留白 (82px)。
/// - 侧边栏（含横屏自动切换）：导航移到侧边，底部仅剩浮层播放条，页面只需留出 82px。
final navBarInsetProvider = Provider<double>((ref) {
  final landscape = ref.watch(isLandscapeProvider);
  final s = ref.watch(settingsProvider).valueOrNull;
  if (landscape || s?.navBarPosition == NavBarPosition.side) return 82;
  final floating = s?.floatingNavBar ?? true;
  return floating ? 175 : 82;
});

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

  /// 是否真正计入隐藏计数。横屏内嵌容器模式（embedded）覆盖为 false：
  /// 迷你播放条由壳层常驻承接，页面自身不再隐藏 shell 浮层。
  bool get hidesChrome => true;

  @override
  void initState() {
    super.initState();
    // 延后一帧：build 期间不可修改 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !hidesChrome) return;
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

  // 记录上一次底栏形态，用于检测「浮/固定/侧栏」切换：用户手动停靠的播放条
  // 位置是按旧底栏几何锁定的，切到新底栏后可能压在底栏上（如贴住固定底栏后
  // 切悬浮，条会被卡进悬浮底栏），形态变化时应回落默认停靠位重新贴合。
  bool? _lastFloating;
  bool? _lastSide;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final floating = ref.read(
            settingsProvider.select((s) => s.valueOrNull?.floatingNavBar)) ??
        true;
    // 形态检测并入横屏：竖屏↔横屏切换同样会改变底栏几何，需重置迷你条停靠位。
    final screen = MediaQuery.maybeOf(context);
    final landscape = screen == null ||
        screen.size.width >= screen.size.height * 1.05;
    final side = landscape ||
        (ref.read(settingsProvider
                .select((s) => s.valueOrNull?.navBarPosition)) ==
            NavBarPosition.side);
    if ((_lastFloating != null && _lastFloating != floating) ||
        (_lastSide != null && _lastSide != side)) {
      _playerTop = null;
      _playerLeft = null;
    }
    _lastFloating = floating;
    _lastSide = side;

    // 横屏沉浸式全屏：一并隐藏系统状态栏与导航条，让界面满铺并越过摄像头挖孔区；
    // 仅在地面方向变化时切换，避免反复设置系统 UI。
    if (_lastImmersive != landscape) {
      _lastImmersive = landscape;
      _applyLandscapeImmersive(landscape);
      // 横屏不切回流：进入/退出横屏都留在当前页，不强制切回首页 tab。
    }
  }

  /// 横屏进入沉浸式全屏（无系统栏），竖屏还原显示状态栏/导航栏。
  Future<void> _applyLandscapeImmersive(bool landscape) async {
    try {
      if (landscape) {
        await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.immersiveSticky);
      } else {
        // 还原系统栏：Android 12+ 为 edge-to-edge（透明状态栏），低版本强制显示系统栏。
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
    } catch (_) {
      // 忽略：部分 ROM/仿真器可能不支持指定 UI 模式。
    }
  }

  /// 最近一次是否已应用沉浸式全屏，避免方向未变时反复设置系统 UI。
  bool _lastImmersive = false;

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
    double maxTop,
    double miniBarW,
    double landscapeLeftBound,
    double landscapeRightBound,
    bool landscape,
  ) {
    final currentLeft = _playerLeft ?? defaultLeft;
    final currentTop = _playerTop ?? defaultTop;

    // 拖拽边界：横屏按真实迷你条宽度在 leftBound..rightBound 间自由左右拖动；
    // 竖屏为贴底长条，沿用旧行为（横移基本锁死、只纵向停靠）。
    final barW = landscape ? miniBarW : (screenSize.width - 36.0);
    final minLeft = landscape ? landscapeLeftBound : 6.0;
    final maxLeft = landscape
        ? landscapeRightBound
        : (screenSize.width - barW - 6.0);
    final minTop = padding.top + 6.0;

    // 拖拽下限由调用方按底栏几何（悬浮 18+70 / 固定 safeBottom+64 / 二级页无底栏）
    // 算好传入，确保常规底部栏下播放条也能拖到真正贴住底栏顶。

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

  /// 横屏右侧主 tab 容器：摄像头区域使用时抑制切口内边距。主 tab 切换的
  /// 淡出淡入动效由分支容器（PageSwitchTabView 横屏 out-in）负责，此处不再叠加。
  Widget _landscapeFadePanel({
    required bool useCameraArea,
    required EdgeInsets padding,
    required BuildContext context,
    required Widget child,
  }) {
    // 摄像头区域使用时抑制切口内边距：壳内各页面 SafeArea 不再为挖孔留安全区。
    return useCameraArea
        ? MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: padding.copyWith(left: 0, right: 0),
            ),
            child: child,
          )
        : child;
  }

  /// 音乐库面板的固定 trigger：面板内部是 IndexedStack（四页常驻挂载），
  /// 切换条目是瞬时的、无需转场。若把 libSel 当 trigger，每次切条目都会重播
  /// 一次 opacity 0→1 的淡入，而这是叠在主分支之上的覆盖层，淡入期间整层半透明，
  /// 底下的导航分支页会透出来——即「横屏音乐库里切换时闪一下导航页」。
  /// 用常量让淡入只在面板首次打开时播放一次。
  static const _kLibraryPaneTrigger = 'library-pane';

  // 横屏容器（音乐库/下载/歌单详情）切入切换：从下往上轻微滑动 + 淡进淡出，
  // 类似桌面端切换效果。关闭「横屏切换动画」时保持硬切。
  Widget _landscapeSlide({
    required bool enabled,
    required Object? trigger,
    required Widget child,
  }) {
    if (!enabled) return child;
    return _LandscapeSlideFade(trigger: trigger, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    // 使用纯硬件安全区内边距 (padding.bottom)，不受软键盘 viewInsets 干扰
    final padding = MediaQuery.of(context).padding;
    final safeBottom = padding.bottom;

    // 横屏判定：宽 > 高（含大屏/平板）。检测结果回写全局 provider，供各页面
    // 响应横屏布局；值未变化时不写，避免无谓的 provider 通知。
    final landscape = screenSize.width >= screenSize.height * 1.05;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final noti = ref.read(isLandscapeProvider.notifier);
      if (noti.state != landscape) {
        final wasLandscape = noti.state;
        noti.state = landscape;
        // 进入横屏且停在搜索二级路由上：关掉二级路由，改为在右侧容器打开
        // 搜索对应页面（/search=默认页，/search/result=结果页，会话共用）。
        // 注意不能用 GoRouterState.of(context)——壳层拿到的是自己分支的路由
        // 状态（如 /home），/search、/search/result 压在其之上，须读路由器
        // 实时栈顶。
        if (landscape && !wasLandscape) {
          final path = GoRouter.of(context)
              .routerDelegate
              .currentConfiguration
              .uri
              .path;
          if (path == '/search' || path == '/search/result') {
            ref.read(landscapeSearchOpenProvider.notifier).state = true;
            ref.read(landscapeSearchResultsProvider.notifier).state =
                path == '/search/result';
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/home');
            }
          }
        }
      }
    });

    final floating =
        ref.watch(settingsProvider.select((s) => s.valueOrNull?.floatingNavBar)) ??
            true;

    // 横屏侧边栏「音乐库」当前选中的入口（null=显示主 tab）。
    final libSel = ref.watch(landscapeLibraryProvider);

    // 横屏「我的」页账号与安全内嵌面板是否打开（不开二级路由）。
    final accountOpen = landscape && ref.watch(landscapeAccountOpenProvider);

    // 横屏「我的」页歌曲下载内嵌面板是否打开（不开二级路由）。
    final downloadOpen = landscape && ref.watch(landscapeDownloadOpenProvider);

    // 横屏选中的歌单详情内嵌面板（不开二级路由），null=未打开。
    final playlistOpenId = landscape
        ? ref.watch(landscapePlaylistOpenProvider)
        : null;

    // 横屏搜索容器（不开二级路由）：true=搜索默认页，显示结果页看 results。
    final searchOpenRaw = ref.watch(landscapeSearchOpenProvider);
    final searchResults = ref.watch(landscapeSearchResultsProvider);
    final searchOpen = landscape && searchOpenRaw;

    // 悬浮搜索框开关：开启后首页/我的页共用同一个实例（提至壳层，不随 tab
    // 重建，避免液态玻璃 shader 反复初始化渲染）。
    final floatingSearchBar =
        ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.floatingSearchBar ?? false));

    // 横屏使用摄像头区域：开启时壳内各页面不再为摄像头挖孔保留安全区，
    // 内容可铺满到短边摄像头（迷你条避让仍用原始 padding，不受影响）。
    final useCameraArea = landscape &&
        ref.watch(
            settingsProvider.select(
                (s) => s.valueOrNull?.landscapeCameraArea ?? true));

    // 横屏下首页/我的等主 tab 在右侧容器切换时的淡进淡出动效（独立于竖屏切换动画）。
    final landscapeFadeEnabled = landscape &&
        ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.landscapeTransitionEnabled ?? true));

    // 用「当前是否为根路径」而非 canPop 判断是否处于二级页：canPop 在整个返回
    // 过渡动画期间一直为 true（被退路由动画结束才从 _history 移除），会让底栏
    // 动画结束才出现；路径在 pop 开始时即已收缩，可让底栏随一级页露出同步淡入。
    final hiddenCount = ref.watch(navBarHiddenProvider);
    final hidden = hiddenCount > 0 || !_isRootPath;

    void select(int i) {
      // 切主 tab 时关闭横屏搜索容器（参考桌面端：侧边栏导航即离开搜索页）。
      if (searchOpenRaw) closeLandscapeSearch(ref);
      widget.navigationShell.goBranch(i, initialLocation: i == widget.index);
    }

    // 横屏自动切换为侧边导航（复用「侧边栏模式」布局几何，隐藏底部栏）。
    // 前提：横屏前必须先有被测量的 MediaQuery——本 State 作为壳层必然已完成首帧。
    final isSide = landscape ||
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.navBarPosition)) ==
            NavBarPosition.side);

    // 侧边栏模式下的展开状态（横屏走固定左缘侧栏 [_LandscapeRail]，不使用此展开态）。
    final expanded = ref.watch(sideBarExpandedProvider);

    // 检测当前路由：全屏歌曲详情页 /player 时不隐藏迷你条（见下），
    // 其余二级页由 hidden 统一处理。
    final isPlayerPage =
        GoRouterState.of(context).uri.toString() == '/player';

    // 迷你条位置档位：播放页打开时保持进入前的位置（供 Hero 飞行取源/落点，
    // 否则位置变化会打断「底栏封面飞播放页」的飞行）；其余情况沿用 hidden 下沉。
    final miniBarLow = hiddenCount > 0 || (!_isRootPath && !isPlayerPage);

    // 统一播放条：横屏音乐库面板（本地/收藏/最近/歌单）以及下载/歌单详情
    // 容器统一由外壳条承载并常驻整屏（与全局顶栏同步）；账号面板仍按原逻辑隐藏外壳条。
    final hideShellMiniBar = accountOpen;

    // 迷你条宽度：竖屏占满（两侧各 18）；横屏保持限宽（55%/520），宽度不变，
    // 仅放开拖拽横移边界使其可自由拖动到整个横屏（含越到左侧栏上方）。
    final miniBarW = landscape
        ? math.min(screenSize.width * 0.55, 520.0)
        : (screenSize.width - 36.0);

    // 挖孔屏避让：横屏沉浸时 `padding.left/right` 含摄像头切口，迷你条停靠须避开，
    // 否则右缘探进挖孔会导致「底栏被摄像头遮住、显示不全」。
    final leftCutout = landscape ? padding.left : 0.0;
    final rightCutout = landscape ? padding.right : 0.0;

    // 默认定位坐标（不受软键盘影响，始终保持在底部稳定避让区）
    late final double defaultLeft;
    // 横屏可自由拖拽的左右边界：播放条占满整屏宽，仅避开左右挖孔。
    // 竖屏为贴底长条，只做纵向停靠，横移基本不放开（沿用旧行为）。
    var landscapeLeftBound = 6.0;
    var landscapeRightBound = 30.0;
    if (landscape) {
      landscapeLeftBound = math.max(leftCutout, 6.0);
      landscapeRightBound = screenSize.width -
          miniBarW -
          (rightCutout > 0 ? rightCutout + 12 : 16);
      // 横屏默认起始位置居中；若居中位越出可拖拽边界则夹紧到边界内（防退化越界）。
      defaultLeft = landscapeRightBound > landscapeLeftBound
          ? ((screenSize.width - miniBarW) / 2.0)
              .clamp(landscapeLeftBound, landscapeRightBound)
          : landscapeLeftBound;
    } else {
      defaultLeft = 18.0;
    }
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

    // 播放条拖拽下限：与 defaultTop 停靠位一致，按底栏几何分支。
    // 原来只按悬浮底栏参数(18 间隙+70 高)算，常规(固定式)底部栏下因缺计算
    // safeBottom+64 导致播放条拖到底也与底栏贴近不了，这里按类型精确避让。
    final dragMaxTop = () {
      final barH = 58.0;
      if (isSide) return screenSize.height - safeBottom - barH - 12.0;
      if (floating) {
        return hidden
            ? (screenSize.height - padding.bottom - barH - 12.0)
            : (screenSize.height - 18.0 - 70.0 - barH);
      }
      return hidden
          ? (screenSize.height - padding.bottom - barH - 12.0)
          : (screenSize.height - safeBottom - 64.0 - barH);
    }();

    return Scaffold(
      body: Stack(
        children: [
          // 壳底「固定背景层」：始终不随内容平移，供透明页面透出根层壁纸/底色。
          // （壁纸由 CustomBackgroundLayer 铺设；无壁纸时透出主题底色。
          // 第二个 Positioned.fill 作保底底色。）
          const Positioned.fill(
            child: CustomBackgroundLayer(),
          ),
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
          // 横屏时左缘固定侧栏占位，内容整体右移避让；二级页（hidden）侧栏淡出，
          // 内容不偏移以享受全宽。播放页是推入 root navigator 的独立路由，不受此影响。
          // 滚动检测由 app.dart 根层 ScrollOffsetCapture 统一捕获，波浪扭曲已内聚到
          // 迷你播放条/悬浮底栏的 BiliPaiGlass 自身负责液态玻璃渲染，
          // 无需再整页包裹 LiquidWave 离屏捕获。
          Padding(
            // 横屏：左缘固定侧栏占位，内容右移避让；开关开启时不再为右侧
            // 摄像头挖孔预留安全区（所有页面使用摄像头区域）。
            padding: EdgeInsets.only(
              // 横屏侧栏常驻：二级页（本地/收藏/最近/歌单）打开时也在左侧保留侧栏，
              // 便于在音乐库入口间直接切换（参考桌面版侧边栏）。
              left: landscape ? kLandscapeRailWidth : 0,
              right: (landscape && !useCameraArea) ? padding.right : 0,
            ),
            child: Stack(
                    children: [
                      // 主 tab 内容（首页/我的）：横屏下先接全局顶栏（全局继承，
                      // 各页不再渲染自身顶栏），下方为当前页内容（切换动效在
                      // 分支容器内，桌面版 page-fade 同款 out-in）。
                      Positioned.fill(
                        child: landscape
                            ? (floatingSearchBar
                                // 悬浮模式：内容铺满右侧容器，横屏全局顶栏独立悬浮
                                // 在其上方（控件独立显示），滚动内容从其下穿过。
                                ? Stack(
                                    children: [
                                      Positioned.fill(
                                        child: _landscapeFadePanel(
                                          useCameraArea: useCameraArea,
                                          padding: padding,
                                          context: context,
                                          child: widget.navigationShell,
                                        ),
                                      ),
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        child: LandscapeGlobalTopBar(
                                          currentIndex: widget.index,
                                          floating: true,
                                        ),
                                      ),
                                    ],
                                  )
                                // 默认模式：全局顶栏直接显示在容器顶部（普通
                                // IconButton 控件内嵌顶栏条），内容在其下方。
                                : Column(
                                    children: [
                                      LandscapeGlobalTopBar(
                                        currentIndex: widget.index,
                                        floating: false,
                                      ),
                                      Expanded(
                                        child: _landscapeFadePanel(
                                          useCameraArea: useCameraArea,
                                          padding: padding,
                                          context: context,
                                          child: widget.navigationShell,
                                        ),
                                      ),
                                    ],
                                  ))
                            : _landscapeFadePanel(
                                useCameraArea: useCameraArea,
                                padding: padding,
                                context: context,
                                child: widget.navigationShell,
                              ),
                      ),
                      // 横屏且侧边栏选中音乐库入口时，右侧直接内嵌对应页面：
                      // 不进入二级路由，navigationShell 保持挂载以保留主 tab 状态。
                      if (landscape && libSel != null)
                        Positioned.fill(
                          child: useCameraArea
                                  ? MediaQuery(
                                      data: MediaQuery.of(context).copyWith(
                                        padding: padding.copyWith(left: 0, right: 0),
                                      ),
                                      child: _landscapeSlide(
                                        enabled: landscapeFadeEnabled,
                                        trigger: _kLibraryPaneTrigger,
                                        child: _MusicLibraryPane(index: libSel),
                                      ),
                                    )
                                  : _landscapeSlide(
                                      enabled: landscapeFadeEnabled,
                                      trigger: _kLibraryPaneTrigger,
                                      child: _MusicLibraryPane(index: libSel),
                                    ),
                              ),
                      // 胶囊顶栏覆盖层：音乐库面板打开时叠加同一根全局顶栏
                      // （面板保持全屏铺满，顶栏浮在其上，避免缩短容器截断内嵌迷你条）。
                      if (landscape && libSel != null)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: LandscapeGlobalTopBar(
                            currentIndex: widget.index,
                            floating: floatingSearchBar,
                          ),
                        ),
                      // 横屏「我的」账号与安全：右侧容器内嵌账号页，不开二级路由，
                      // 盖住容器（含全局顶栏），返回后回到我的页。
                      if (accountOpen)
                        Positioned.fill(
                          child: useCameraArea
                              ? MediaQuery(
                                  data: MediaQuery.of(context).copyWith(
                                    padding: padding.copyWith(left: 0, right: 0),
                                  ),
                                  child: _AccountPane(
                                    onBack: () => ref
                                        .read(landscapeAccountOpenProvider.notifier)
                                        .state = false,
                                  ),
                                )
                              : _AccountPane(
                                  onBack: () => ref
                                      .read(landscapeAccountOpenProvider.notifier)
                                      .state = false,
                                ),
                        ),
                      // 横屏「我的」下载管理：右侧容器内嵌下载页，不开二级路由。
                      if (downloadOpen)
                        Positioned.fill(
                          child: useCameraArea
                              ? MediaQuery(
                                  data: MediaQuery.of(context).copyWith(
                                    padding: padding.copyWith(left: 0, right: 0),
                                  ),
                                  child: _landscapeSlide(
                                    enabled: landscapeFadeEnabled,
                                    trigger: downloadOpen,
                                    child: const _DownloadPane(),
                                  ),
                                )
                              : _landscapeSlide(
                                  enabled: landscapeFadeEnabled,
                                  trigger: downloadOpen,
                                  child: const _DownloadPane(),
                                ),
                        ),
                      // 横屏选中的歌单详情：右侧容器内嵌歌单详情，不开二级路由。
                      if (playlistOpenId != null)
                        Positioned.fill(
                          child: useCameraArea
                              ? MediaQuery(
                                  data: MediaQuery.of(context).copyWith(
                                    padding: padding.copyWith(left: 0, right: 0),
                                  ),
                                  child: _landscapeSlide(
                                    enabled: landscapeFadeEnabled,
                                    trigger: playlistOpenId,
                                    child: _PlaylistDetailPane(playlistId: playlistOpenId),
                                  ),
                                )
                              : _landscapeSlide(
                                  enabled: landscapeFadeEnabled,
                                  trigger: playlistOpenId,
                                  child: _PlaylistDetailPane(playlistId: playlistOpenId),
                                ),
                        ),
                      // 横屏搜索容器：右侧容器内嵌搜索默认页（历史+热搜）/
                      // 结果页，不开二级路由（原 /search、/search/result 为
                      // 竖屏二级路由，横屏改走容器）。参考桌面端「顶栏即搜索
                      // 输入」：输入框由全局顶栏承接，提交后在容器内显示结果。
                      // 渲染顺序在歌单详情之后（最上层覆盖），回退链最先闭合。
                      if (searchOpen)
                        Positioned.fill(
                          child: useCameraArea
                              ? MediaQuery(
                                  data: MediaQuery.of(context).copyWith(
                                    padding: padding.copyWith(left: 0, right: 0),
                                  ),
                                  child: _landscapeSlide(
                                    enabled: landscapeFadeEnabled,
                                    trigger: searchOpen,
                                    child: _SearchPane(showResults: searchResults),
                                  ),
                                )
                              : _landscapeSlide(
                                  enabled: landscapeFadeEnabled,
                                  trigger: searchOpen,
                                  child: _SearchPane(showResults: searchResults),
                                ),
                        ),
                      // 下载/歌单详情容器与全局顶栏同步：不盖住顶栏，顶栏在其上
                      // 浮层显示（搜索框左侧带回退按钮），由顶栏返回闭合容器。
                      if (downloadOpen)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: LandscapeGlobalTopBar(
                            currentIndex: widget.index,
                            floating: floatingSearchBar,
                          ),
                        ),
                      if (playlistOpenId != null)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: LandscapeGlobalTopBar(
                            currentIndex: widget.index,
                            floating: floatingSearchBar,
                          ),
                        ),
                      // 搜索容器打开时顶栏浮层显示搜索输入框（顶栏即搜索输入）。
                      if (searchOpen)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: LandscapeGlobalTopBar(
                            currentIndex: widget.index,
                            floating: floatingSearchBar,
                          ),
                        ),
                    ],
                  ),
                ),

          // 横屏固定左缘侧栏（取代底部栏/悬浮底栏）。参考桌面版侧边栏常驻：
          // 二级页（本地/收藏/最近/歌单）打开时仍在左展示，便于在音乐库入口间切换。
          // 播放页是覆盖全屏的独立 root 路由，侧栏在下层不可见，无需处理。
          if (landscape)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: kLandscapeRailWidth,
              child: _LandscapeRail(
                index: widget.index,
                onSelect: select,
              ),
            ),

          // 迷你播放条：支持全界面常驻、手势防穿透拖拽与 60px 区域磁吸吸附回弹；
          // 二级页面进出时带有平滑上浮/下沉动画。播放页打开时【不移除】——移除会让
          // Hero 在 push 后下一帧收集源封面时找不到迷你条，导致「打开无飞行、只有
          // 返回有飞行」；播放页为不透明路由会盖住迷你条，留在树中无副作用。
          if (!hideShellMiniBar)
            AnimatedPositioned(
                duration: _isPlayerDragging
                    ? Duration.zero
                    : const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                left: actualLeft,
                top: actualTop,
                width: miniBarW,
                child: MiniPlayerBar(
                  onPanStart: _onPlayerPanStart,
                  onPanUpdate: (d) => _onPlayerPanUpdate(
                      d,
                      screenSize,
                      padding,
                      defaultLeft,
                      defaultTop,
                      dragMaxTop,
                      miniBarW,
                      landscapeLeftBound,
                      landscapeRightBound,
                      landscape),
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

          // 侧边栏悬浮层（竖屏「侧边栏模式」用）
          if (isSide && !landscape)
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

          // 悬浮顶部栏（竖屏首页/我的页共用同一实例）：标题玻璃胶囊 + 搜索胶囊
          // （长度自适应）+ 右侧玻璃小按钮（首页=皮肤、我的=设置），直接悬浮在
          // 状态栏下方，取代页面自带的标题行；二级页/其它 tab 淡出并禁用交互。
          // 横屏不渲染——横屏有带搜索框的全局顶栏。
          if (!landscape)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 18,
              right: 18,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                opacity: (floatingSearchBar &&
                        (widget.index == 0 || widget.index == 1) &&
                        !hidden)
                    ? 1.0
                    : 0.0,
                child: IgnorePointer(
                  ignoring: !(floatingSearchBar &&
                      (widget.index == 0 || widget.index == 1) &&
                      !hidden),
                  child: FloatingTopBar(
                    title: widget.index == 1
                        ? Text(
                            tr('我的'),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          )
                        : Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: tr('弦予')),
                                TextSpan(
                                  text: tr('音乐'),
                                  style: const TextStyle(
                                    color: Color(0xFFEC4141),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                    onSearchTap: () => context.push('/search'),
                    // 首页/我的页共用同一搜索框样式（带听歌识曲话筒入口）。
                    onRecognize: () => context.push('/recognize'),
                    actions: [
                      if (widget.index == 0)
                        BiliPaiIconButton(
                          icon: Icons.checkroom,
                          tooltip: tr('皮肤'),
                          onTap: () => context.push('/wallpaper'),
                        )
                      else
                        BiliPaiIconButton(
                          icon: Icons.settings_outlined,
                          tooltip: tr('设置'),
                          onTap: () => context.push('/settings'),
                        ),
                    ],
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
              child: _FixedChrome(
                  index: widget.index, hidden: hidden, onSelect: select),
            )
          : null,
        ); // 关闭 Scaffold，结束 return 语句
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

    // 固定底栏内容（与材质设置无关，共用布局）。
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

    // 液态玻璃仅属于悬浮底栏；固定底栏保持下方常规圆角样式，不走 shader。
    // 伪毛玻璃（液态/未开 默认）：半透明 + BackdropFilter 高斯模糊；
    // 低性能模式或关闭「毛玻璃」→ 高不透明度纯色回退（无模糊）。
    final solid =
        glassShouldUseSolid(ref, lowPerf: lowPerf);
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
    final fill = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.52));
    final glassFill =
        solid ? fill : surfaceFillWithBudget(fill, budget);
    // 固定底栏顶部不再画横向分隔线（玻璃态的分隔条 / 实色态的 border）：
    // 迷你播放条停靠时正好落在底栏顶边，画线会在播放条底缘形成一条可见
    // 接缝，视觉上就像"播放条贴不住底栏、中间有空"。去掉后二者无缝贴合。
    final barBox = Container(color: glassFill, child: bar);
    if (solid) {
      return barBox;
    }
    // 伪毛玻璃：半透明白/暗 + 高斯模糊（安卓原生磨砂质感），壁纸时更透。
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: surfaceBlurSigma(
              base: 14, budget: budget, type: BlurSurfaceType.bottomBar),
          sigmaY: surfaceBlurSigma(
              base: 14, budget: budget, type: BlurSurfaceType.bottomBar),
        ),
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
    // 全局 blur 预算：滚动/转场时悬浮底栏玻璃降级。
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));

    // 水平留 10px：滑动指示条与最左/最右 tab 让开，避免顶到玻璃圆角边界。
    final tabs = _SlidingNavBottom(
      index: index,
      onSelect: (i) {
        triggerHaptic(haptic);
        onSelect(i);
      },
    );

    if (liquid) {
      // 液态玻璃低档：不跑 shader，用伪液态毛玻璃伪造（透明底 + 淡模糊）。
      if (liquidUseFrosted(ref)) {
        return pseudoLiquidSurface(
          context: context,
          ref: ref,
          radius: 999,
          child: SizedBox(height: 70, child: tabs),
          lowPerf: lowPerf,
          surfaceType: BlurSurfaceType.bottomBar,
          budget: budget,
        );
      }
      return _liquidGlass(context, ref, tabs);
    }
    return _frostedGlass(context, ref, tabs,
        lowPerf: lowPerf, budget: budget);
  }

  /// BiliPai 化液态玻璃：实时背景采样 + 滚动波浪扭曲 + 色差 + 轻量模糊，胶囊形状。
  Widget _liquidGlass(BuildContext context, WidgetRef ref, Widget tabs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final quality = liquidGlassQualitySetting(ref);
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
    return BiliPaiGlass(
      radius: 30,
      refract: bilipaiRefractOf(quality),
      chroma: bilipaiChromaOf(quality),
      blurSigma: surfaceBlurSigma(
        base: 6,
        budget: budget,
        type: BlurSurfaceType.bottomBar,
      ),
      backgroundColor: bilipaiGlassTint(isDark),
      specular: bilipaiSpecularOf(quality),
      edgeAmount: bilipaiEdgeOf(quality),
      saturation: bilipaiSaturationOf(quality),
      child: SizedBox(height: 70, child: tabs),
    );
  }

  /// 伪毛玻璃：液态玻璃关闭时的默认样式。
  ///
  /// 规则：标准半透明磨砂（跟随毛玻璃开关）；低性能 → 高不透明度纯色。
  Widget _frostedGlass(BuildContext context, WidgetRef ref, Widget tabs,
      {bool lowPerf = false, BlurBudget? budget}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final solid =
        glassShouldUseSolid(ref, lowPerf: lowPerf);
    final bg = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.52));
    final fill = (budget == null || solid) ? bg : surfaceFillWithBudget(bg, budget);
    final sigma = budget == null
        ? 14.0
        : surfaceBlurSigma(
            base: 14,
            budget: budget,
            type: BlurSurfaceType.bottomBar,
          );
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.40);
    final capsule = Container(
      height: 70,
      decoration: BoxDecoration(
        color: fill,
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
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: capsule,
      ),
    );
  }
}

/// 横屏固定左缘侧栏：玻璃竖条 + 顶部三线 logo + 4 个主 Tab 竖排。
///
/// 横屏时取代底部/悬浮底栏，贴合屏幕左缘（内容区已右移避让）。
/// 选中态用淡红色胶囊 + 主题色图标/文字，竖排布局充分利用横屏高度。
class _LandscapeRail extends ConsumerWidget {
  const _LandscapeRail({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    // 主导航 = 主 tab（首页/我的）；音乐库 = 从「我的」抽出的入口，直接内嵌右侧显示。
    final primary = bottomNavItems;
    final library = [
      (tr('本地音乐'), Icons.library_music_outlined),
      (tr('我的收藏'), Icons.favorite_outline),
      (tr('最近播放'), Icons.history_outlined),
      (tr('我的歌单'), Icons.queue_music_outlined),
    ];
    final libSel = ref.watch(landscapeLibraryProvider);

    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 0, 4),
          child: Text(
            t,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
              letterSpacing: 0.5,
            ),
          ),
        );

    final rail = SafeArea(
      right: false,
      child: SizedBox(
        width: kLandscapeRailWidth,
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 与设置页侧边栏一致：不单独绘制底色（继承外壳默认背景），
            // 仅保留右侧一条细分隔线。
            border: Border(
              right: BorderSide(
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 20),
              // 顶部品牌标题（横屏时首页顶栏的「弦予音乐」标题移来这里，取代原三条竖线图标）。
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                    children: [
                      TextSpan(text: tr('弦予')),
                      TextSpan(
                        text: tr('音乐'),
                        style: const TextStyle(
                          color: Color(0xFFEC4141),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 主导航 = 主 tab（首页/我的）；音乐库 = 从「我的」抽出的二级入口。
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 6, bottom: 12),
                  children: [
                    label(tr('导航')),
                    for (var i = 0; i < primary.length; i++)
                      _railItem(
                        context,
                        icon: primary[i].icon,
                        title: navTitle(context, primary[i]),
                        selected: libSel == null && i == index,
                        onTap: () {
                          ref.read(landscapeLibraryProvider.notifier).state =
                              null;
                          onSelect(i);
                        },
                      ),
                    label(tr('音乐库')),
                    for (var j = 0; j < library.length; j++)
                      _railItem(
                        context,
                        icon: library[j].$2,
                        title: library[j].$1,
                        selected: libSel == j,
                        onTap: () {
                          // 切换音乐库入口时关闭横屏搜索容器（不遮挡新容器）。
                          closeLandscapeSearch(ref);
                          ref.read(landscapeLibraryProvider.notifier).state =
                              j;
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return rail;
  }

  /// 横屏侧栏单个入口（图标 + 文字，选中淡红胶囊）。
  Widget _railItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
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

/// 横屏右侧「音乐库」内嵌面板：按 [landscapeLibraryProvider] 的序号
/// 用 [IndexedStack] 展示 本地/收藏/最近/歌单，切换不重建、保留各页状态。
/// 面板保持铺满右侧容器（迷你条等按全屏底定位），胶囊顶栏由壳层作为
/// 覆盖层叠在其顶部，统一与首页/我的同一根顶栏。
class _MusicLibraryPane extends StatelessWidget {
  const _MusicLibraryPane({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: IndexedStack(
        index: index,
        children: const [
          LibraryPage(),
          FavoritesPage(),
          RecentPage(),
          PlaylistsPage(),
        ],
      ),
    );
  }
}

/// 横屏「我的」账号与安全：右侧容器内嵌账号页，不开二级路由。
/// 复用 [AccountPage.embedded]，自带「账号与安全」顶栏 + 返回闭合面板。
class _AccountPane extends StatelessWidget {
  const _AccountPane({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return AccountPage(embedded: true, onBack: onBack);
  }
}

/// 横屏「我的」下载管理：右侧容器内嵌下载页，不开二级路由。
/// 复用 [DownloadPage.embedded]，顶栏由全局横屏顶栏承接并隐藏自身顶栏。
class _DownloadPane extends StatelessWidget {
  const _DownloadPane();

  @override
  Widget build(BuildContext context) {
    return const DownloadPage(embedded: true);
  }
}

/// 横屏选中的歌单详情：右侧容器内嵌歌单详情页，不开二级路由。
/// 复用 [PlaylistDetailPage.embedded]，顶栏由全局横屏顶栏承接并隐藏自身顶栏。
class _PlaylistDetailPane extends StatelessWidget {
  const _PlaylistDetailPane({required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    return PlaylistDetailPage(playlistId: playlistId, embedded: true);
  }
}

/// 横屏搜索容器：右侧容器内嵌搜索默认页（历史+热搜）或结果页，不开二级路由。
/// 输入框由全局横屏顶栏承接（搜索胶囊点击打开本容器），提交后切到结果页。
class _SearchPane extends ConsumerWidget {
  const _SearchPane({required this.showResults});

  /// true=搜索结果页（SearchResultPage.embedded），false=搜索默认页。
  final bool showResults;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 悬浮顶部栏模式下应用悬浮观感：内容铺满全高，滚动时从悬浮玻璃控件
    // 下方穿过（与首页/我的页一致）；默认模式保持静态避让顶栏高度。
    final floatingBar = ref.watch(settingsProvider
        .select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    if (!showResults) {
      // 页面底色用 appScaffoldBackground（与其他容器一致）。注意不能用
      // Theme.scaffoldBackgroundColor——全局主题为透明（底色由根层渲染），
      // 透明容器会直接透出下方主 tab 内容。
      if (floatingBar) {
        return ColoredBox(
          color: appScaffoldBackground(context, ref),
          child: SearchIdleView(
            onSearch: (q) => submitLandscapeSearch(ref, q),
            // 初始内容位于悬浮控件下方，滚动时穿透到其背后。
            topPadding: GlassTopBar.height(context),
          ),
        );
      }
      // 内容下移避让全局顶栏（顶栏以浮层形式盖在容器上方）。
      return ColoredBox(
        color: appScaffoldBackground(context, ref),
        child: Padding(
          padding: EdgeInsets.only(top: GlassTopBar.height(context)),
          child:
              SearchIdleView(onSearch: (q) => submitLandscapeSearch(ref, q)),
        ),
      );
    }
    return const SearchResultPage(embedded: true);
  }
}


/// 底部栏共享选中指示器：红色胶囊随所选 tab 横向滑动。
///
/// 原实现是每个 tab 内部各自原地淡入选中背景，切「首页/我的」时没有滑动感；
/// 这里把指示条提升到底栏层，切换 tab 时用 [AnimatedPositioned] 平滑滑到目标格。
class _SlidingNavBottom extends StatelessWidget {
  const _SlidingNavBottom({
    required this.index,
    required this.onSelect,
  });

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final items = bottomNavItems;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final tabW = (maxW - 20) / items.length;
        final indH = (maxH * 0.6).clamp(40.0, 50.0);
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: 10 + index * tabW,
              top: (maxH - indH) / 2,
              bottom: (maxH - indH) / 2,
              width: tabW,
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
            Center(
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _NavTab(
                        item: items[i],
                        selected: i == index,
                        onTap: () => onSelect(i),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
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
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
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
    // 全局 blur 预算：滚动/转场时侧栏面板玻璃降级（drawerOrSheet 档）。
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.drawerOrSheet));

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
          if (liquidUseFrosted(ref)) {
            // 液态玻璃低档：伪液态毛玻璃面板（透明底 + 淡模糊），不跑 shader。
            panelWidget = pseudoLiquidSurface(
              context: context,
              ref: ref,
              radius: 24,
              child: SizedBox(width: panelWidth, child: panelBody),
              lowPerf: lowPerf,
              surfaceType: BlurSurfaceType.drawerOrSheet,
              budget: budget,
            );
          } else {
            // BiliPai 液态玻璃面板：与底栏/迷你播放条同一套 shader 观感。
            final quality = liquidGlassQualitySetting(ref);
            panelWidget = BiliPaiGlass(
              radius: 24,
              refract: bilipaiRefractOf(quality),
              chroma: bilipaiChromaOf(quality),
              blurSigma: surfaceBlurSigma(
                base: 8,
                budget: budget,
                type: BlurSurfaceType.drawerOrSheet,
              ),
              backgroundColor: bilipaiGlassTint(isDark),
              specular: bilipaiSpecularOf(quality),
              edgeAmount: bilipaiEdgeOf(quality),
              saturation: bilipaiSaturationOf(quality),
              child: SizedBox(width: panelWidth, child: panelBody),
            );
          }
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
          final panelBg = isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.white.withValues(alpha: 0.35);
          final panelFill = surfaceFillWithBudget(panelBg, budget);
          panelWidget = ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: surfaceBlurSigma(
                  base: 8 * frostedBlurScale(ref),
                  budget: budget,
                  type: BlurSurfaceType.drawerOrSheet,
                ),
                sigmaY: surfaceBlurSigma(
                  base: 8 * frostedBlurScale(ref),
                  budget: budget,
                  type: BlurSurfaceType.drawerOrSheet,
                ),
              ),
              child: Container(
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

/// 横屏容器切入过渡：对齐桌面版 page-fade —— 自下方 8px、scale 0.996 微上移
/// 淡入（0.22s，cubic-bezier(0.16, 1, 0.3, 1)）。每次 [trigger] 变化（或首次
/// 挂载）时重放一次过渡；关闭横屏切换动画时由壳层直接返回 child，不经此组件。
class _LandscapeSlideFade extends StatefulWidget {
  const _LandscapeSlideFade({required this.trigger, required this.child});
  // 桌面版 page-fade 同款参数。
  static const _duration = Duration(milliseconds: 220);
  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);

  final Object? trigger;
  final Widget child;

  @override
  State<_LandscapeSlideFade> createState() => _LandscapeSlideFadeState();
}

class _LandscapeSlideFadeState extends State<_LandscapeSlideFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: _LandscapeSlideFade._duration,
    );
    final curve = CurvedAnimation(
      parent: _c,
      curve: _LandscapeSlideFade._ease,
    );
    _fade = curve;
    // 与桌面版 enter-from 一致：translateY(8px) + scale(0.996) → 原位。
    _slide = Tween<Offset>(
      begin: const Offset(0, 8),
      end: Offset.zero,
    ).animate(curve);
    _scale = Tween<double>(begin: 0.996, end: 1).animate(curve);
    _c.forward();
  }

  @override
  void didUpdateWidget(_LandscapeSlideFade old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        return Transform.translate(
          offset: _slide.value,
          child: Transform.scale(
            scale: _scale.value,
            child: Opacity(opacity: _fade.value, child: child),
          ),
        );
      },
    );
  }
}
