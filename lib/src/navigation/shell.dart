import 'dart:async';
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
import '../widgets/landscape_page_fade.dart';
import 'landscape_tab_switcher.dart';
import '../widgets/blur_budget.dart';
import '../widgets/app_toast.dart';
import '../notifications/notification_service.dart';
import '../sync/auto_sync.dart';
import '../sync/sync_provider.dart' show syncProvider;
import '../widgets/mini_player_bar.dart';
import '../widgets/page_search_bar.dart';
import '../widgets/bilipai_glass.dart';
import '../../pages/library/library_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/playlist/playlists_page.dart';
import '../widgets/floating_search_bar.dart';
import '../widgets/skin_icon.dart';
import '../widgets/flat_top_bar.dart';
import '../widgets/glass_appbar.dart' show GlassTopBar;
import '../widgets/landscape_top_bar.dart';
import '../../pages/account/account_page.dart';
import '../../pages/download/download_page.dart';
import '../../pages/home/daily_recommend_page.dart';
import '../../pages/home/top_lists_page.dart';
import '../../pages/leaderboard/leaderboard_page.dart';
import '../../pages/search/search_page.dart';
import 'routes.dart';
import '../i18n/i18n.dart';

/// 浮动底栏占据的底部高度（距底 18 + 栏高 60 + 阴影余量）。
///
/// 底栏是叠在内容之上的 `Positioned`，不参与布局，`SafeArea` 也无法感知。
/// 弹窗、列表等需要避让它的地方统一引用此常量，改动底栏尺寸时只需改这里。
const double kFloatingNavBarInset = 90;

/// 横屏固定左缘侧栏宽度（文字侧边栏，参考设置页横屏左栏）。内容区整体右移避让。
/// 拖动分割线时最大划到屏幕中部（对半）；最小可缩到「仅图标」宽
/// （[kLandscapeRailIconWidth]），此时侧栏自动只显示居中的图标、隐藏文字。
const double kLandscapeRailWidth = 176;
/// 拖动分割线的最小宽度：仅图标态（icon + 内边距，容纳单个入口图标）。
const double kLandscapeRailIconWidth = 60;
/// 侧栏宽度低于此值（px）时切换为「仅图标」态：隐藏品牌标题与分区文字、入口只留图标。
const double kLandscapeRailCollapseAt = 120;

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

/// 横屏右侧「内容」容器：首页发现区竖屏二级页（统计榜单/每日推荐/音源榜单）
/// 在横屏下的对应形态（不开二级路由），存对应路由 path，null=未打开。
final landscapeContentPathProvider = StateProvider<String?>((ref) => null);

/// 音乐库四页（本地/收藏/最近/歌单）的共享 GlobalKey：横屏侧边栏容器
/// （_MusicLibraryPane）与对应竖屏路由页用同一 key，翻转瞬间容器/路由在同
/// 一帧卸载与挂载（横→竖：pane 随横屏树退役，路由页同帧挂载 retake），
/// 框架按 key reparent，列表滚动位置/选中索引跨横竖屏保留。
///
/// 重复 key 的两个风险窗口已在壳层处理（见 shell.dart）：
/// 1. 竖屏时 pane 不挂载（LandscapeTabSwitcher 离屏分支 Offstage 常驻，
///    常驻挂载会与竖屏路由页撞 key，路由页被顶掉）；
/// 2. 竖屏音乐库二级页翻进横屏时，pop 反向转场内路由页 element 仍挂于
///    overlay，pane 延迟到转场结束后再挂（_deferLibPaneMount）。
final musicLibraryPageKeys =
    List<GlobalKey>.generate(4, (_) => GlobalKey());

/// 横屏右侧是否有「覆盖面板」打开（账号/下载/歌单详情/搜索/内容容器）。
///
/// 音乐库入口（本地/收藏/最近/歌单）与主 tab 同级：同一个主页内容切换器
/// （LandscapeTabSwitcher，见 build 内 landscapeHome）用同一套 out-in 切换，
/// 不属于覆盖面板。覆盖面板打开期间主页内容的切换动画由面板关闭淡出承担
/// （suppress 硬切），避免「面板淡出 + 下层 out-in」两层动画叠加互闪。
final landscapePaneOpenProvider = Provider<bool>((ref) {
  return ref.watch(landscapeAccountOpenProvider) ||
      ref.watch(landscapeDownloadOpenProvider) ||
      ref.watch(landscapePlaylistOpenProvider) != null ||
      ref.watch(landscapeSearchOpenProvider) ||
      ref.watch(landscapeContentPathProvider) != null;
});

/// 横屏设置 master-detail 当前选中的分类 path（null=默认「账号」）。
///
/// 翻转重定向：进横屏时若停在设置分类二级路由（/settings/:category、/about）
/// 上，先写入目标分类再 pop，揭开下层的 /settings——其横屏 master-detail
/// 直接落在对应分类。设置页（竖屏 master-detail 分类切换）读写同一 provider。
final landscapeSettingsCategoryProvider = StateProvider<String?>((ref) => null);

/// 横屏设置 master-detail 可内嵌的分类 path 白名单（与设置页分组一致），
/// 供翻转重定向校验目标分类，未知 path 不重定向（保持竖屏二级页）。
const Set<String> kLandscapeSettingPaths = <String>{
  '/settings/account',
  '/settings/general',
  '/settings/appearance',
  '/settings/lyrics',
  '/settings/playback',
  '/settings/download',
  '/settings/advanced',
  '/about',
};

/// 分支根页面需要的底部避让高度。
///
/// - 悬浮式：底栏与播放条都是浮层（顶端到屏幕底部约 165px），页面留出 175px 保证末项完全露出。
/// - 固定式：固定底栏经 `extendBody` 让内容延伸穿到其下（毛玻璃透出内容），底栏
///   与播放条同为浮层观感，页面同样留出 175px 保证末项完全露出。
/// - 侧边栏（含横屏自动切换）：导航移到侧边，底部仅剩浮层播放条，页面只需留出 82px。
final navBarInsetProvider = Provider<double>((ref) {
  final landscape = ref.watch(isLandscapeProvider);
  final s = ref.watch(settingsProvider).valueOrNull;
  if (landscape || s?.navBarPosition == NavBarPosition.side) return 82;
  return 175;
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

/// 内嵌作用域：标记子树内的页面为「壳层内嵌面板」，不是真正的二级页面。
///
/// [_MusicLibraryPane]（竖屏音乐库主 tab 与横屏音乐库分支共用，IndexedStack
/// 常驻保活全部子页）、横屏右侧覆盖面板（账号/下载/歌单详情/搜索）都属此类。
/// 这些页面虽然复用二级页组件（内部包了 [HideShellChrome]），但它们由壳层
/// 自己管理显隐，不能参与 navBarHiddenProvider 计数——否则壳层每次 build
/// 都把它们批量挂载，底栏会被误判「处于二级页」而永久隐藏。
class EmbeddedShellScope extends InheritedWidget {
  const EmbeddedShellScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EmbeddedShellScope>() != null;

  @override
  bool updateShouldNotify(EmbeddedShellScope oldWidget) => false;
}

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
      // 内嵌面板（横竖屏音乐库分支/横屏覆盖面板）：由壳层管理显隐，不计数。
      if (!mounted || !hidesChrome) return;
      if (EmbeddedShellScope.of(context)) return;
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

class _ShellScaffoldState extends ConsumerState<_ShellScaffold>
    with WidgetsBindingObserver {
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

  /// 横屏左缘侧栏可拖动宽度（默认取基准值，拖动分割线实时更新）。
  double _railWidth = kLandscapeRailWidth;

  /// 原生旋转事件订阅（旋转一开始推送屏幕方向，提前切横竖屏布局）。
  StreamSubscription<dynamic>? _rotationSub;

  static const _rootPaths = {'/', '/home', '/mine'};

  static bool _isRootPathOf(String path) => _rootPaths.contains(path);

  @override
  void initState() {
    super.initState();
    // 横竖屏翻转重定向依赖 didChangeMetrics（应用级回调）：壳层被不透明二级
    // 路由覆盖时 build 时机不可靠（页面只是「原地横过来」，重定向不触发），
    // observer 与路由形态无关，任何页面上翻转都会回调。
    WidgetsBinding.instance.addObserver(this);
    _router = GoRouter.of(context);
    _isRootPath =
        _isRootPathOf(_router.routerDelegate.currentConfiguration.uri.path);
    _router.routerDelegate.addListener(_onRouteChanged);
    // 订阅原生旋转事件：旋转一开始（onConfigurationChanged）即推送屏幕方向，
    // 立刻切横竖屏布局，尽量第一帧出横屏，缩短系统旋转期间「拉伸竖屏」的停留。
    // 尺寸判定（didChangeMetrics）保留作兜底。
    _rotationSub = const EventChannel('xianyu/rotation/events')
        .receiveBroadcastStream()
        .listen(_onRotationEvent, onError: (_) {});
  }

  /// 接收原生屏幕方向（1 竖 / 2 横），旋转一开始即切横竖屏布局。
  void _onRotationEvent(Object? e) {
    if (!mounted) return;
    final v = e is num ? e.toInt() : null;
    if (v == null) return;
    if (v == 1) {
      ref.read(isLandscapeProvider.notifier).state = false;
    } else if (v == 2) {
      ref.read(isLandscapeProvider.notifier).state = true;
    }
    // 其他值：交给尺寸判定兜底，这里不覆盖。
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
    WidgetsBinding.instance.removeObserver(this);
    _router.routerDelegate.removeListener(_onRouteChanged);
    _libPaneMountTimer?.cancel();
    _chromeSettleTimer?.cancel();
    _rotationSub?.cancel();
    super.dispose();
  }

  /// 功能型全屏页不参与翻转重定向：旋转时应保持任务/界面继续，不能被 pop 掉
  /// （播放页为覆盖式，旋转应保持播放界面不关闭）。
  static const Set<String> _noRotateRedirectPaths = <String>{
    '/player',
    '/scan',
    '/recognize',
    '/tv-login-confirm',
    '/shareBridge',
  };

  /// 取路由栈顶的实际 path（含 context.push 压入的 imperative 路由）。
  ///
  /// [RouteMatchList.uri] 不反映 ImperativeRouteMatch——push 的路由被排除，
  /// 只返回壳层分支路径（如 /home），用它判断栈顶永远不命中二级页，
  /// 必须从 matches.last 解出真实栈顶。
  static String _routerTopPath(RouteMatchList config) {
    final last = config.matches.lastOrNull;
    if (last is ImperativeRouteMatch) return last.matches.uri.path;
    if (last is RouteMatch) return last.matchedLocation;
    if (last is ShellRouteMatch) return last.matchedLocation;
    return config.uri.path;
  }

  /// 翻转前所在的二级页 path：进横屏被重定向时记录，转回竖屏时恢复。
  String? _rotateBackPath;

  /// 上一次 didChangeMetrics 读到的物理朝向（true=横屏），null=尚未收到首帧。
  ///
  /// 翻转重定向以此为准而非 provider 现状：原生旋转通道（_onRotationEvent）在
  /// 旋转一开始就把 isLandscapeProvider 置成新朝向，didChangeMetrics 到达时
  /// state 已匹配会早退、跳过重定向——表现为「横屏音乐库容器回竖屏只到我的页、
  /// 进不了详细页」。物理朝向翻转才做重定向，其余 metrics 触发不重定向。
  bool? _lastPhysicalLandscape;

  /// 是否允许挂载横屏音乐库 pane（_MusicLibraryPane）。
  ///
  /// pane 与竖屏音乐库二级页（/library 等）共享 [musicLibraryPageKeys] 做
  /// 翻转 reparent。竖屏二级页被 pop 时其反向转场（最长 300ms）内 element
  /// 仍挂在 overlay 上，此期间 pane 同 key 挂载会重复——翻转进横屏时暂缓，
  /// 转场结束后（400ms 兜底）再挂载。
  bool _libPaneMountable = true;
  Timer? _libPaneMountTimer;

  void _deferLibPaneMount() {
    _libPaneMountable = false;
    _libPaneMountTimer?.cancel();
    _libPaneMountTimer = Timer(const Duration(milliseconds: 400), () {
      _libPaneMountTimer = null;
      if (mounted) setState(() => _libPaneMountable = true);
    });
  }

  /// 底栏/悬浮顶栏显隐动画窗口（见 [chromeGlassSettlingProvider]）：
  /// hidden 翻转时置 true，动画结束后恢复毛玻璃。仅竖屏驱动——横屏
  /// chrome 无淡入淡出，置 true 会让横屏搜索框等 header 表面无谓闪纯色。
  bool? _lastChromeHidden;
  Timer? _chromeSettleTimer;

  void _syncChromeGlassSettle(bool hidden) {
    if (_lastChromeHidden == hidden) return;
    final first = _lastChromeHidden == null;
    _lastChromeHidden = hidden;
    // 首帧对齐初值，不触发降级窗口。
    if (first) return;
    _chromeSettleTimer?.cancel();
    scheduleMicrotask(() {
      if (!mounted) return;
      ref.read(chromeGlassSettlingProvider.notifier).state = true;
    });
    _chromeSettleTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      ref.read(chromeGlassSettlingProvider.notifier).state = false;
    });
  }

  /// 横竖屏翻转重定向：路由随横竖屏一起切换，两种形态互为对应容器的投影。
  ///
  /// 进横屏：搜索/结果页→右侧搜索容器、设置分类页→master-detail、音乐库/
  /// 下载/账号/歌单详情竖屏页→对应横屏容器（均记录 [_rotateBackPath]）、其余
  /// 内容二级页弹回壳层。功能型全屏页（[_noRotateRedirectPaths]）与
  /// /settings 自身（LandscapeGate 自动切 master-detail）除外。
  ///
  /// 转回竖屏：横屏容器状态全部移交/丢弃，路由成为唯一事实——有记录的恢复
  /// 原二级页；无记录的（横屏内直接点侧边栏进入的容器）映射成对应竖屏二级页
  /// push 上栈，保证返回键可用（否则竖屏没有路由承载该容器，无法返回）。
  ///
  /// 挂在 [WidgetsBindingObserver.didChangeMetrics] 而非壳层 build——壳层被
  /// 不透明二级路由覆盖时，翻转只让页面原地旋转，壳层 build 时机不可靠。
  @override
  void didChangeMetrics() {
    // 同步读平台视图的物理尺寸——不依赖帧时机与 MediaQuery 继承链。壳层被
    // 不透明二级路由（如 /settings）覆盖时不重建，postFrame + MediaQuery 的
    // 读法拿不到新值，isLandscapeProvider 会卡死在旧值（LandscapeGate 永远
    // 渲染翻转前的布局）。didChangeMetrics 本就由视图尺寸变化触发，此处读
    // 到的即最新值。
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null || !mounted) return;
    final size = view.physicalSize / view.devicePixelRatio;
    final landscape = size.width >= size.height * 1.05;
    final noti = ref.read(isLandscapeProvider.notifier);
    if (noti.state != landscape) {
      noti.state = landscape;
    }
    // 物理朝向翻转判定：以上一次 didChangeMetrics 读到的物理朝向为准，而非
    // provider 现状——原生旋转通道(_onRotationEvent)可能已提前把 provider 置成
    // 新朝向，直接按 state 早退会跳过翻转重定向（横屏容器回竖屏只停在主页、
    // 进不了详细页）。真正翻转才跑重定向，键盘/通知栏等 metrics 触发不重定向。
    final flipped =
        _lastPhysicalLandscape != null && _lastPhysicalLandscape != landscape;
    _lastPhysicalLandscape = landscape;
    if (!flipped) return;
    if (!landscape) {
        // 转回竖屏：路由跟着切回竖屏形态，横屏容器状态全部移交/丢弃——竖屏
        // 路由是唯一事实（返回键 pop 即可回主页），下次进横屏再由竖屏路由
        // 映射回对应容器。
        final lib = ref.read(landscapeLibraryProvider);
        final playlist = ref.read(landscapePlaylistOpenProvider);
        final searchOpen = ref.read(landscapeSearchOpenProvider);
        final searchResults = ref.read(landscapeSearchResultsProvider);
        final download = ref.read(landscapeDownloadOpenProvider);
        final account = ref.read(landscapeAccountOpenProvider);
        final content = ref.read(landscapeContentPathProvider);
        void closeAll() {
          ref.read(landscapeLibraryProvider.notifier).state = null;
          ref.read(landscapeSearchOpenProvider.notifier).state = false;
          ref.read(landscapeSearchResultsProvider.notifier).state = false;
          ref.read(landscapeDownloadOpenProvider.notifier).state = false;
          ref.read(landscapeAccountOpenProvider.notifier).state = false;
          ref.read(landscapePlaylistOpenProvider.notifier).state = null;
          ref.read(landscapeContentPathProvider.notifier).state = null;
        }

        final back = _rotateBackPath;
        _rotateBackPath = null;
        closeAll();
        // 记录仅在用户仍停留在横屏重定向形态上时有效：期间手动离开（如设置
        // master-detail 按返回回主页、侧边栏切走）则作废——否则转回竖屏会把
        // 用户推回早已离开的页，形成「每次翻转都被塞回设置」的死循环。
        final top = _routerTopPath(_router.routerDelegate.currentConfiguration);
        final onShell = top == '/' || top == '/home' || top == '/profile';
        final onSettings = top == '/settings';
        if (onSettings && kLandscapeSettingPaths.contains(back)) {
          // 仍在设置横屏 master-detail：恢复最后停留的分类。
          final category = ref.read(landscapeSettingsCategoryProvider);
          context.push(category ?? back!);
        } else if (onShell) {
          // 仍在壳层（被弹回的主页/横屏容器）：按实时容器状态移交竖屏路由。
          if (lib != null) {
            // 横屏内直接点侧边栏进入的音乐库容器 → 对应竖屏页（否则竖屏没有
            // 路由承载，返回键无处可退）。
            const libRoutes = [
              '/library',
              '/favorites',
              '/recent',
              '/playlists',
            ];
            context.push(libRoutes[lib.clamp(0, libRoutes.length - 1)]);
          } else if (searchOpen) {
            context.push(searchResults ? '/search/result' : '/search');
          } else if (content != null) {
            context.push(content);
          } else if (playlist != null) {
            context.push('/playlist/$playlist');
          } else if (download) {
            context.push('/download');
          } else if (account) {
            context.push('/account');
          }
        }
        return;
      }
      final path = _routerTopPath(_router.routerDelegate.currentConfiguration);
      // 音乐库竖屏页 ↔ 横屏侧边栏容器的双向对应（路由随横竖屏一起切换）。
      const libRoutes = ['/library', '/favorites', '/recent', '/playlists'];
      if (path == '/search' || path == '/search/result') {
        // 搜索/结果页：右侧容器打开对应搜索页（会话共用），弹回壳层。
        _rotateBackPath = path;
        ref.read(landscapeSearchOpenProvider.notifier).state = true;
        ref.read(landscapeSearchResultsProvider.notifier).state =
            path == '/search/result';
        while (context.canPop()) {
          context.pop();
        }
      } else if (kLandscapeSettingPaths.contains(path)) {
        // 设置分类二级页（/settings/:category、/settings/account、/about）：
        // 写入目标分类后进入设置的横屏 master-detail。栈里已有 /settings
        // （从设置导航页进入的分类页）时直接 pop 揭开——无路由替换不闪；
        // 从我的页等入口直压的分类页下层没有 /settings，pop 会露进主页横屏
        // 模式，故 go 重整到 [壳层, /settings]。
        _rotateBackPath = path;
        ref.read(landscapeSettingsCategoryProvider.notifier).state = path;
        final hasSettingsBelow = _router
            .routerDelegate.currentConfiguration.matches
            .any((m) => m is RouteMatch && m.matchedLocation == '/settings');
        if (hasSettingsBelow) {
          context.pop();
        } else {
          context.go('/settings');
        }
      } else if (libRoutes.contains(path)) {
        // 音乐库页（本地/收藏/最近/歌单）→ 横屏侧边栏对应容器。
        // pop 的反向转场内路由页 element 仍挂在 overlay，与 pane 共享
        // musicLibraryPageKeys——先暂缓 pane 挂载，转场结束后再挂。
        _rotateBackPath = path;
        _deferLibPaneMount();
        ref.read(landscapeLibraryProvider.notifier).state =
            libRoutes.indexOf(path);
        while (context.canPop()) {
          context.pop();
        }
      } else if (path == '/home/daily' ||
          path == '/home/toplists' ||
          path == '/leaderboard') {
        // 首页发现区内容页（每日推荐/音源榜单/统计榜单）→ 横屏内容容器。
        _rotateBackPath = path;
        ref.read(landscapeContentPathProvider.notifier).state = path;
        while (context.canPop()) {
          context.pop();
        }
      } else if (path == '/download') {
        // 下载页 → 横屏下载面板。
        _rotateBackPath = path;
        ref.read(landscapeDownloadOpenProvider.notifier).state = true;
        while (context.canPop()) {
          context.pop();
        }
      } else if (path == '/account') {
        // 账号页 → 横屏账号面板。
        _rotateBackPath = path;
        ref.read(landscapeAccountOpenProvider.notifier).state = true;
        while (context.canPop()) {
          context.pop();
        }
      } else if (path.startsWith('/playlist/')) {
        // 歌单详情页 → 横屏歌单详情面板。
        _rotateBackPath = path;
        ref.read(landscapePlaylistOpenProvider.notifier).state =
            path.split('/').last;
        while (context.canPop()) {
          context.pop();
        }
      } else if (!_noRotateRedirectPaths.contains(path) && path != '/settings') {
        // 其余内容二级页：统一弹回壳层，进入横屏模式（侧边栏+右侧容器）。
        // 多级压栈（如 设置→分类→反馈）时逐层弹到根，避免露出竖屏中间页。
        _rotateBackPath = path;
        while (context.canPop()) {
          context.pop();
        }
      }
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
    // 通知玻璃表面退回实时背板：拖动把播放条平移到新内容上，静止冻结的
    // 快照还是旧位置抓的背景，不退实时会「液态效果不跟随、还在原地」。
    setGlobalDragging(true);
  }

  /// 播放条拖拽/停靠上界：按当前形态顶栏底部夹紧（竖屏顶栏胶囊高 40 /
  /// 横屏全局顶栏搜索胶囊高 44，均上下各 8、再留 8px 间隙）。
  double _playerMinTop(double paddingTop, bool landscape) =>
      paddingTop + 8.0 + (landscape ? 44.0 : 40.0) + 8.0;

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
    // 左右留白 12 与悬浮底栏/顶栏同列（原 18 偏宽）。
    final barW = landscape ? miniBarW : (screenSize.width - 24.0);
    final minLeft = landscape ? landscapeLeftBound : 6.0;
    final maxLeft = landscape
        ? landscapeRightBound
        : (screenSize.width - barW - 6.0);
    // 拖拽上限：播放条不得进入顶部栏区域（拖拽位置是壳层状态，若在二级页
    // 拖到顶部、回到首页/我的页就会压住顶栏，因此恒按顶栏底部夹紧）。
    final minTop = _playerMinTop(padding.top, landscape);

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
    // 拖动结束：玻璃表面在新位置重新走「静止 → 抓屏冻结」流程。
    setGlobalDragging(false);

    // 完全自由停放：松手后播放条停留在拖到的位置，不再被 60px 磁吸拉回
    // 靠近底栏的停靠位（原先「靠近底栏就会吸过去」即由此造成）。
  }

  void _onPlayerPanCancel() {
    setState(() {
      _isPlayerDragging = false;
    });
    setGlobalDragging(false);
  }

  /// 横屏右侧主 tab 容器：摄像头区域使用时抑制切口内边距。主页内容（导航组+
  /// 音乐库组）的切换动效由 landscapeHome（LandscapeTabSwitcher out-in）负责，
  /// 此处不再叠加。
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

  // 横屏容器（音乐库/下载/歌单详情/搜索/账号）进出场：完整 out-in（旧内容
  // 淡出微上移缩小 → 新内容自下方淡入），关闭面板也播淡出。面板层需常驻挂载
  // （由调用方保证），open=false 时组件内部先淡出再清空。关闭「横屏切换动画」
  // 时保持硬切。
  Widget _landscapeSlide({
    required bool enabled,
    required bool open,
    required Object? trigger,
    required Widget? child,
  }) {
    if (!enabled) {
      return (open && child != null) ? child : const SizedBox.shrink();
    }
    return LandscapePageFade(open: open, trigger: trigger, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    // 使用纯硬件安全区内边距 (padding.bottom)，不受软键盘 viewInsets 干扰
    final padding = MediaQuery.of(context).padding;
    final safeBottom = padding.bottom;

    // 横屏判定：宽 > 高（含大屏/平板）。检测结果回写全局 provider，供各页面
    // 响应横屏布局；值未变化时不写，避免无谓的 provider 通知。
    // 二级页的翻转重定向不在这里做（壳层被二级路由覆盖时 build 时机不可靠），
    // 统一由 _ShellScaffoldState.didChangeMetrics 处理。
    final landscape = screenSize.width >= screenSize.height * 1.05;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final noti = ref.read(isLandscapeProvider.notifier);
      if (noti.state != landscape) {
        noti.state = landscape;
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

    // 横屏内容容器（不开二级路由）：统计榜单/每日推荐/音源榜单的横屏形态。
    final contentPath = landscape
        ? ref.watch(landscapeContentPathProvider)
        : null;

    // 横屏右侧覆盖面板（桌面端同款「整个主页、一个选择」的钻取层）：账号 >
    // 搜索 > 内容容器 > 歌单详情 > 下载。音乐库不在其列——它与主 tab 同级，
    // 走 build 内 landscapeHome 统一内容切换器（同一套 out-in，不再「直接覆盖」）。
    final Widget? landPane;
    final Object? landPaneTrigger;
    // 覆盖面板均为壳层内嵌（自身显隐由壳层管理），一律套 EmbeddedShellScope：
    // 面板内部复用的二级页组件（搜索/下载/歌单详情/账号）不再参与底栏隐藏计数。
    if (accountOpen) {
      landPaneTrigger = 'account';
      landPane = EmbeddedShellScope(
        child: _AccountPane(
          onBack: () =>
              ref.read(landscapeAccountOpenProvider.notifier).state = false,
        ),
      );
    } else if (searchOpen) {
      landPaneTrigger = 'search';
      landPane = EmbeddedShellScope(
        child: _SearchPane(showResults: searchResults),
      );
    } else if (contentPath != null) {
      landPaneTrigger = 'content:$contentPath';
      landPane = EmbeddedShellScope(
        child: _ContentPane(
          path: contentPath,
          onBack: () =>
              ref.read(landscapeContentPathProvider.notifier).state = null,
        ),
      );
    } else if (playlistOpenId != null) {
      landPaneTrigger = 'pl:$playlistOpenId';
      landPane = EmbeddedShellScope(
        child: _PlaylistDetailPane(playlistId: playlistOpenId),
      );
    } else if (downloadOpen) {
      landPaneTrigger = 'download';
      landPane = const EmbeddedShellScope(child: _DownloadPane());
    } else {
      landPaneTrigger = null;
      landPane = null;
    }
    final anyPaneOpen = landPane != null;

    // 音乐库 pane（本地/收藏/最近/歌单）不再让位隐藏全局顶栏：四个容器统一
    // 继承壳层 LandscapeGlobalTopBar（返回/搜索/皮肤/设置），页内顶栏在面板
    // 模式下让位为「全局顶栏下方的内容头」（仅保留 TabBar 与页内操作），
    // 避免悬浮模式下与全局悬浮控件同位叠层。
    const libPaneActive = false;

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

    // 横屏主页统一内容切换器：侧边栏六个入口（导航组 首页/我的 + 音乐库组
    // 本地/收藏/最近/歌单）全部同级——导航组走 children[0] 的分支容器（内部
    // 自带 首页↔我的 out-in），音乐库四项与整个导航容器平级，由外层
    // LandscapeTabSwitcher 用同一套 page-fade out-in 切换。此前音乐库是叠加
    // 在主页上的覆盖面板，「首页→本地」是覆盖淡入、「最近→收藏」才是 out-in，
    // 动画不一致且像直接盖上去。各分支 Offstage 保活，滚动状态跨切换保留。
    // 覆盖面板打开时 suppress 硬切：切换动画由面板关闭淡出承担。
    //
    // 音乐库四 pane 仅横屏挂载：LandscapeTabSwitcher 的离屏分支 Offstage
    // 常驻树中，若竖屏也挂载，pane 的共享 musicLibraryPageKeys 会与竖屏
    // 二级路由页（/library 等，翻转 reparent 用同一 key）重复挂载，路由页
    // 被顶掉——表现为「竖屏切二级页直接消失」。竖屏只保留分支容器。
    // _libPaneMountable：竖屏音乐库二级页翻转进横屏时，pop 反向转场内的
    // 路由页 element 也持同 key，pane 延迟到转场结束后再挂（_deferLibPaneMount）。
    final libPaneMountable = landscape && _libPaneMountable;
    // 主页统一内容切换器包一层 Offstage：横屏钻取面板（账号/搜索/内容/歌单详情/
    // 下载）打开期间把主页内容整体「收走」而不是叠在面板下方。这些面板在壁纸模式
    // 下是半透明表面（无实色底、透出壁纸），若主页仍绘制在下方，会从面板后透出
    // 主页的列表/文字——即用户感知的「穿透」。offstage 后下方只剩根层壁纸，面板
    // 透出的是干净的壁纸；面板切换动画（LandscapePageFade out-in）负责覆盖开合。
    // （音乐库四 pane 本就是同级分支，面板关闭后 parallax 回到对应分支。）
    final Widget landscapeHome = Offstage(
      offstage: anyPaneOpen,
      child: EmbeddedShellScope(
        child: LandscapeTabSwitcher(
          currentIndex:
              libPaneMountable ? (libSel == null ? 0 : 1 + libSel) : 0,
          enabled: landscapeFadeEnabled,
          suppress: anyPaneOpen,
          children: [
            widget.navigationShell,
            if (libPaneMountable) ...[
              const _MusicLibraryPane(index: 0),
              const _MusicLibraryPane(index: 1),
              const _MusicLibraryPane(index: 2),
              const _MusicLibraryPane(index: 3),
            ],
          ],
        ),
      ),
    );

    // 用「当前是否为根路径」而非 canPop 判断是否处于二级页：canPop 在整个返回
    // 过渡动画期间一直为 true（被退路由动画结束才从 _history 移除），会让底栏
    // 动画结束才出现；路径在 pop 开始时即已收缩，可让底栏随一级页露出同步淡入。
    final hiddenCount = ref.watch(navBarHiddenProvider);
    final hidden = hiddenCount > 0 || !_isRootPath;
    // 竖屏底栏/悬浮顶栏显隐动画窗口内强制玻璃表面纯色（防背板采样黑帧）。
    if (!landscape) _syncChromeGlassSettle(hidden);

    void select(int i) {
      // 切主 tab 时关闭横屏覆盖容器（参考桌面端：侧边栏导航即离开当前容器）。
      if (searchOpenRaw) closeLandscapeSearch(ref);
      ref.read(landscapeContentPathProvider.notifier).state = null;
      widget.navigationShell.goBranch(i, initialLocation: i == widget.index);
    }

    // 左缘侧栏分割条：覆盖在侧栏右边界上（hit 区跨边界居中），拖动实时改宽。
    Widget buildRailDivider() => Positioned(
          left: _railWidth - 14,
          top: 0,
          bottom: 0,
          width: 28,
          child: _ShellRailDivider(
            onDragUpdate: (dx) {
              final screenW = MediaQuery.sizeOf(context).width;
              setState(() {
                // 最远划到屏幕中部（对半）；最小可缩到「仅图标」宽。
                _railWidth = (_railWidth + dx)
                    .clamp(kLandscapeRailIconWidth, screenW * 0.5);
              });
            },
          ),
        );

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

    // 迷你条宽度：竖屏占满（两侧各 12，与悬浮底栏/顶栏同列）；横屏保持限宽
    // （55%/520），宽度不变，仅放开拖拽横移边界使其可自由拖动到整个横屏
    // （含越到左侧栏上方）。
    final miniBarW = landscape
        ? math.min(screenSize.width * 0.55, 520.0)
        : (screenSize.width - 24.0);

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
      defaultLeft = 12.0;
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
    // 显示位置按顶栏底部夹紧：历史停靠位（上界收紧前拖到顶部）不残留压栏。
    final actualTop = (_playerTop ?? defaultTop)
        .clamp(_playerMinTop(padding.top, landscape), double.infinity)
        .toDouble();

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

    // resizeToAvoidBottomInset: false — 不让键盘顶起整个壳层内容。
    // 弹窗在 root Navigator 上，DialogKeyboardLift 已负责弹窗自身的键盘避让；
    // 页面级输入（搜索等）在各页面内自行处理。参考 PiliNara 的 ViewInsetsSafeArea
    // 做法：主容器不因键盘缩小，需要避让的页面/弹窗自行消费 viewInsets。
    return Scaffold(
      resizeToAvoidBottomInset: false,
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
              left: landscape ? _railWidth : 0,
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
                                // 覆盖面板打开期间本顶栏隐藏：搜索/下载/歌单详情由
                                // 上层「胶囊顶栏覆盖层」接管，账号/内容容器自带返回
                                // 条——否则壁纸模式下面板透明底盖不住本顶栏（搜索框/
                                // 右侧按钮透出叠在面板标题上）。
                                ? Stack(
                                    children: [
                                      Positioned.fill(
                                        child: _landscapeFadePanel(
                                          useCameraArea: useCameraArea,
                                          padding: padding,
                                          context: context,
                                          child: landscapeHome,
                                        ),
                                      ),
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        child: IgnorePointer(
                                          ignoring:
                                              anyPaneOpen || libPaneActive,
                                          child: Opacity(
                                            opacity: anyPaneOpen ||
                                                    libPaneActive
                                                ? 0
                                                : 1,
                                            child: LandscapeGlobalTopBar(
                                              currentIndex: widget.index,
                                              floating: true,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                // 默认模式：全局顶栏直接显示在容器顶部（普通
                                // IconButton 控件内嵌顶栏条），内容在其下方。
                                // 面板打开期间隐藏但保留占位（Opacity 而非移除，
                                // 避免主页内容上下跳动），理由同上。
                                : Column(
                                    children: [
                                      IgnorePointer(
                                        ignoring:
                                            anyPaneOpen || libPaneActive,
                                        child: Opacity(
                                          opacity:
                                              anyPaneOpen || libPaneActive
                                                  ? 0
                                                  : 1,
                                          child: LandscapeGlobalTopBar(
                                            currentIndex: widget.index,
                                            floating: false,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: _landscapeFadePanel(
                                          useCameraArea: useCameraArea,
                                          padding: padding,
                                          context: context,
                                          child: landscapeHome,
                                        ),
                                      ),
                                    ],
                                  ))
                            : _landscapeFadePanel(
                                useCameraArea: useCameraArea,
                                padding: padding,
                                context: context,
                                child: landscapeHome,
                              ),
                      ),
                      // 横屏右侧覆盖面板层（账号/下载/歌单详情/搜索）：钻取
                      // 层常驻挂载，open/trigger 驱动同一套 out-in，开/关面板
                      // 都播桌面版 page-fade。音乐库不在此层（与主 tab 同级，
                      // 由上方 landscapeHome 切换）；面板打开期间主页内容
                      // suppress 硬切，切换动画由面板关闭淡出承担。
                      if (landscape)
                        Positioned.fill(
                          child: useCameraArea
                              ? MediaQuery(
                                  data: MediaQuery.of(context).copyWith(
                                    padding:
                                        padding.copyWith(left: 0, right: 0),
                                  ),
                                  child: _landscapeSlide(
                                    enabled: landscapeFadeEnabled,
                                    open: anyPaneOpen,
                                    trigger: landPaneTrigger,
                                    child: landPane,
                                  ),
                                )
                              : _landscapeSlide(
                                  enabled: landscapeFadeEnabled,
                                  open: anyPaneOpen,
                                  trigger: landPaneTrigger,
                                  child: landPane,
                                ),
                        ),
                      // 胶囊顶栏覆盖层：任一面板打开时叠加同一根全局顶栏（面板
                      // 铺满全屏，顶栏浮在其上，避免缩短容器截断内嵌迷你条）；
                      // 账号面板与内容容器自带返回条并盖住顶栏区域，不叠加。
                      if (landscape &&
                          anyPaneOpen &&
                          !accountOpen &&
                          contentPath == null)
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
          // 侧栏始终贴边全高：顶部「弦予音乐」logo 与右侧容器全局顶栏对齐，
          // 不随「悬浮搜索框」开关下移（避免 logo 错位），右侧可拖动分割线常驻。
          if (landscape)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _railWidth,
              child: _LandscapeRail(
                index: widget.index,
                onSelect: select,
                railWidth: _railWidth,
                floating: false,
              ),
            ),

          // 左缘侧栏右侧的可拖动分割条：静置为细分隔线，拖动实时调整侧栏宽度。
          if (landscape) buildRailDivider(),

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
                // 左右 12：对齐 BiliPai dock 比例（≈3.5% 屏宽），18 偏宽。
                left: 12,
                right: 12,
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
                        child:
                            _LiquidNavBar(index: widget.index, onSelect: select),
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
              // 与悬浮底栏同列：左右 12。
              left: 12,
              right: 12,
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
                    // 竖屏「我的」页顶栏标题用「个人中心」（底部导航栏仍是「我的」）。
                    title: widget.index == 1
                        ? Text(
                            tr('个人中心'),
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
                          iconChild: const SkinIcon(),
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

          // 固定顶部栏（竖屏非悬浮模式，首页/我的页共用同一实例，与悬浮顶栏
          // 同位上提至壳层）：毛玻璃表面（BackdropFilter）常驻，首页↔我的 tab
          // 切换时实例不卸载重建，仅标题/动作随分支切换；搜索框扩展区也是同一
          // 实例。二级页 hidden 时随底栏一同淡出（显隐动画窗口内强制纯色防
          // BackdropFilter 黑帧，见 chromeGlassSettlingProvider）。
          if (!landscape && !floatingSearchBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                opacity: (widget.index == 0 || widget.index == 1) && !hidden
                    ? 1.0
                    : 0.0,
                child: IgnorePointer(
                  ignoring: hidden,
                  child: GlassTopBar(
                    titleSpacing: widget.index == 0 ? 18 : null,
                    forceSolid: ref.watch(chromeGlassSettlingProvider),
                    title: widget.index == 1
                        ? Text(tr('个人中心'))
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
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                    actions: [
                      if (widget.index == 0) ...[
                        IconButton(
                          icon: const SkinIcon(),
                          tooltip: tr('皮肤'),
                          onPressed: () => context.push('/wallpaper'),
                        ),
                        const SizedBox(width: 16),
                      ] else ...[
                        IconButton(
                          icon: const Icon(Icons.settings_outlined),
                          tooltip: tr('设置'),
                          onPressed: () => context.push('/settings'),
                        ),
                        // 与首页「皮肤」按钮保持一致的右侧留白，避免首页↔我的
                        // 切换时右上角按钮位置左右跳变（对齐到皮肤位）。
                        const SizedBox(width: 16),
                      ],
                    ],
                    bottom: PageSearchBarBottom(
                      onTap: () => context.push('/search'),
                      onRecognize: () => context.push('/recognize'),
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
              child: _FixedChrome(
                  index: widget.index, hidden: hidden, onSelect: select),
            )
          : null,
      // 固定底栏走入 bottomNavigationBar 槽位时，默认 Scaffold 会把 body 高度收缩
      // 到底栏上方，导致内容永远到不了底栏后面——固定底栏的毛玻璃只能模糊一片空白
      // 背景，观感像「不透出的遮挡」。extendBody 让 body（整页内容）延伸到固定底栏
      // 之下去，滚动内容得以穿过底栏、被其毛玻璃透出（与顶栏/悬浮 dock 一致）。
      extendBody: !isSide && !floating,
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

    // 固定底栏内容（与材质设置无关，共用布局）。选择指示器与悬浮底栏一致，
    // 统一为 BiliPai 紧凑圆形水滴，不再用铺满整格的全宽胶囊。
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
    // 显隐动画窗口内（二级页进出）强制纯色：BackdropFilter 在透明度动画层
    // 内背板采样会渲染成黑帧（「返回一级时玻璃黑一下再加载」）。
    final solid = glassShouldUseSolid(ref, lowPerf: lowPerf) ||
        ref.watch(chromeGlassSettlingProvider);
    final wallpaper = wallpaperGlassActive(ref);
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
    final fill = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (wallpaper
            ? wallpaperNavGlassFill(context)
            : (isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.52)));
    final glassFill =
        (solid || wallpaper) ? fill : surfaceFillWithBudget(fill, budget);
    // 固定底栏顶部不再画横向分隔线（玻璃态的分隔条 / 实色态的 border）：
    // 迷你播放条停靠时正好落在底栏顶边，画线会在播放条底缘形成一条可见
    // 接缝，视觉上就像"播放条贴不住底栏、中间有空"。去掉后二者无缝贴合。
    final barBox = Container(color: glassFill, child: bar);
    if (solid) {
      return barBox;
    }
    // 伪毛玻璃：半透明白/暗 + 高斯模糊（安卓原生磨砂质感），壁纸时更透。
    // 固定底栏模糊度恒定最深，不跟随「毛玻璃强度」档位、不随预算缩放
    // （见 kNavSurfaceBlurSigma）——顶/底栏观感两态一致，壁纸模式同。
    final barSigma = kNavSurfaceBlurSigma;
    return ClipRect(
      child: BackdropFilter(
        filter: cheapBackdropBlur(barSigma),
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
    // 显隐动画窗口内（二级页进出）强制纯色铺底：BackdropFilter/液态 shader
    // 在透明度/缩放动画层内背板采样会渲染成黑帧（「玻璃黑一下再加载」）。
    final settling = ref.watch(chromeGlassSettlingProvider);

    // 指示器随玻璃档位分流：液态玻璃（全档真液态 shader）→ BiliPai 折射
    // 透镜水滴；毛玻璃/纯色 → 主题色淡红大胶囊（铺满整格）。
    // 水平留 10px：滑动指示条与最左/最右 tab 让开，避免顶到玻璃圆角边界。
    final realLiquid = liquid;
    // 玻璃外壳由 _SlidingNavBottom 自组装（水滴画在玻璃之上不被裁剪，
    // 按住胀大可鼓出底栏边缘）；显隐动画窗口内退纯色毛玻璃，水滴回嵌内部。
    final tabs = _SlidingNavBottom(
      index: index,
      lens: realLiquid,
      glassBuilder: liquid && !settling
          ? (Widget content) => _liquidGlass(context, ref, content)
          : null,
      onSelect: (i) {
        triggerHaptic(haptic);
        onSelect(i);
      },
    );

    if (liquid) {
      // 液态玻璃全档走真 shader（BiliPai 三档配方：低=CLEAR 零模糊，
      // 中=BALANCED 4dp，高=FROSTED 24dp），不再用伪液态毛玻璃充数。
      // 显隐动画窗口内不跑液态 shader（背板采样黑帧），退回纯色毛玻璃。
      if (settling) {
        return _frostedGlass(context, ref, tabs,
            lowPerf: lowPerf, budget: budget, forceSolid: true);
      }
      return tabs;
    }
    return _frostedGlass(context, ref, tabs,
        lowPerf: lowPerf, budget: budget, forceSolid: settling);
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
      // BiliPai 三档配方：中档=CLEAR 零模糊（水晶玻璃，「液态感」核心），
      // 高档=BALANCED 4dp 轻模糊。
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
      child: tabs,
    );
  }

  /// 伪毛玻璃：液态玻璃关闭时的默认样式。
  ///
  /// 规则：标准半透明磨砂（跟随毛玻璃开关）；低性能 → 高不透明度纯色。
  Widget _frostedGlass(BuildContext context, WidgetRef ref, Widget tabs,
      {bool lowPerf = false, BlurBudget? budget, bool forceSolid = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final solid =
        forceSolid || glassShouldUseSolid(ref, lowPerf: lowPerf);
    final wallpaper = wallpaperGlassActive(ref);
    final bg = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (wallpaper
            // 壁纸模式下底栏保持极淡磨砂（wallpaperNavGlassFill），与固定底栏/
            // 顶栏一致，避免全透明让悬浮 dock 在壁纸下滑走时「直接不可见」。
            ? wallpaperNavGlassFill(context)
            : (isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.52)));
    final fill =
        (budget == null || solid || wallpaper) ? bg : surfaceFillWithBudget(bg, budget);
    // 底栏（悬浮液态 dock）模糊度同样恒定最深，壁纸/常规一致（kNavSurfaceBlurSigma）。
    final sigma = kNavSurfaceBlurSigma;
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
    if (solid) return capsule;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        // 降采样模糊 filter，按 (sigma, downscale) 全局缓存复用。
        filter: cheapBackdropBlur(sigma),
        child: capsule,
      ),
    );
  }
}

/// 左缘侧栏分割条：覆盖在侧栏右边界，静置为一条细分隔线，拖动实时回调更新宽度。
///
/// hit 命中区可跨边界一段，避免手指落在边界正中间难以点中。
class _ShellRailDivider extends StatelessWidget {
  const _ShellRailDivider({required this.onDragUpdate});

  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDragUpdate(d.delta.dx),
      child: Center(
        child: Container(
          width: 3,
          height: 56,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// 横屏固定左缘侧栏：玻璃竖条 + 顶部三线 logo + 4 个主 Tab 竖排。
///
/// 横屏时取代底部/悬浮底栏，贴合屏幕左缘（内容区已右移避让）。
/// 选中态用淡红色胶囊 + 主题色图标/文字，竖排布局充分利用横屏高度。
class _LandscapeRail extends ConsumerWidget {
  const _LandscapeRail({
    required this.index,
    required this.onSelect,
    required this.railWidth,
    required this.floating,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final double railWidth;

  /// 悬浮顶部栏模式：侧栏以玻璃胶囊卡悬浮（不贴边全高、不画分隔线）。
  final bool floating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 窄宽（用户把分割线拖到图标态）时隐藏品牌/分区/文字，仅居中显示图标。
    final collapsed = railWidth < kLandscapeRailCollapseAt;

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

    final content = Column(
      children: [
        SizedBox(height: floating ? 14 : 20),
        // 顶部品牌标题（横屏时首页顶栏的「弦予音乐」标题移来这里，取代原三条竖线图标）。
        // 图标态下隐藏，仅保留顶部留白。
        if (!collapsed)
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
            padding: EdgeInsets.only(top: 6, bottom: floating ? 8 : 12),
            children: [
              if (!collapsed) label(tr('导航')),
              for (var i = 0; i < primary.length; i++)
                _railItem(
                  context,
                  icon: primary[i].icon,
                  title: navTitle(context, primary[i]),
                  collapsed: collapsed,
                  selected: libSel == null && i == index,
                  onTap: () {
                    ref.read(landscapeLibraryProvider.notifier).state = null;
                    onSelect(i);
                  },
                ),
              if (!collapsed) label(tr('音乐库')),
              for (var j = 0; j < library.length; j++)
                _railItem(
                  context,
                  icon: library[j].$2,
                  title: library[j].$1,
                  collapsed: collapsed,
                  selected: libSel == j,
                  onTap: () {
                    // 切换音乐库入口时关闭横屏搜索容器（不遮挡新容器）。
                    closeLandscapeSearch(ref);
                    ref.read(landscapeLibraryProvider.notifier).state = j;
                  },
                ),
            ],
          ),
        ),
      ],
    );

    // 悬浮顶部栏模式：侧边栏用玻璃容器包裹成悬浮胶囊卡（与竖屏悬浮底栏同一
    // 套悬浮容器思路，玻璃口径同 FloatingGlassSurface：液态/伪液态/毛玻璃/低
    // 性能纯色），不再贴边全高、不画分隔线。
    if (floating) {
      return FloatingGlassSurface(radius: 18, child: content);
    }

    return SafeArea(
      right: false,
      child: SizedBox(
        width: railWidth,
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
          child: content,
        ),
      ),
    );
  }

  /// 横屏侧栏单个入口（图标 + 文字，选中淡红胶囊）。图标态（[collapsed]）只居中图标。
  Widget _railItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
    bool collapsed = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: collapsed ? 0 : 8,
        vertical: 2,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: collapsed ? 0 : 10,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment:
                collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              if (!collapsed) ...[
                const SizedBox(width: 9),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 横屏「音乐库」页面：按序号展示 本地/收藏/最近/歌单 中对应的一页，
/// 与主 tab 同级（主页统一内容切换器 landscapeHome 的一个分支），铺满右侧
/// 容器（迷你条等按全屏底定位），顶栏由壳层基座统一提供，与首页/我的同一根
/// 顶栏。四页实例常驻（外层 Offstage 保活），切换不重建、保留各页状态。
class _MusicLibraryPane extends StatelessWidget {
  const _MusicLibraryPane({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    // 每个 pane 只持有自己对应的一页：四页共享 musicLibraryPageKeys 与竖屏
    // 路由页做翻转 reparent，若像旧结构那样每个 pane 内嵌完整 IndexedStack
    // （含全部四页），横屏四 pane 常驻挂载会让每个 key 同时存在 4 份，
    // GlobalKey 归属错乱（表现为「切收藏显示歌单」）。页间切换/保活由外层
    // LandscapeTabSwitcher 的 Offstage 分支承担。
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: KeyedSubtree(
        key: musicLibraryPageKeys[index],
        child: switch (index) {
          0 => const LibraryPage(),
          1 => const FavoritesPage(),
          2 => const RecentPage(),
          _ => const PlaylistsPage(),
        },
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

/// 横屏右侧「内容」容器：首页发现区竖屏二级页（统计榜单/每日推荐/音源榜单）
/// 的横屏形态，不开二级路由。自带 FlatTopBar 返回条（同账号面板盖住全局顶栏
/// 区域，故全局顶栏覆盖层排除本容器），页面用 embedded 形态（无自绘顶栏、
/// 无自带迷你条——外壳迷你条照常显示）。
class _ContentPane extends StatelessWidget {
  const _ContentPane({required this.path, required this.onBack});

  final String path;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final page = switch (path) {
      '/home/daily' => const DailyRecommendPage(embedded: true),
      '/home/toplists' => const TopListsPage(embedded: true),
      '/leaderboard' => const LeaderboardPage(embedded: true),
      _ => const SizedBox.shrink(),
    };
    final title = switch (path) {
      '/home/daily' => tr('每日推荐'),
      '/home/toplists' => tr('音源榜单'),
      '/leaderboard' => tr('听歌排行榜'),
      _ => '',
    };
    return Column(
      children: [
        FlatTopBar(
          title: title,
          leading: BackButton(onPressed: onBack),
        ),
        Expanded(child: page),
      ],
    );
  }
}


/// 底栏滑动指示器：BiliPai 水滴样式。
///
/// 切换时水滴从旧 tab 飞向新 tab（260ms easeOutCubic）：
/// - 飞行中按速度拉伸（BiliPai `resolveBottomBarIndicatorLayerTransform`：
///   v = items/s ÷ 10，scaleX = 1/(1−v·0.75)、scaleY = 1−v·0.5，clamp ±0.18），
///   起步最快拉得最长、到站前收拢；
/// - 落点回弹（`resolveBottomBarSettleReboundTransform`：前 20% 压扁
///   scaleX −3.5% / scaleY +2.8%，之后阻尼正弦波 scaleX +8.5% 摆动 260ms）；
/// - 水滴经过的图标按覆盖度放大（coverage = 1−|i−pos|，最高 1.2×）。
class _SlidingNavBottom extends StatefulWidget {
  const _SlidingNavBottom({
    required this.index,
    required this.onSelect,
    this.lens = false,
    this.glassBuilder,
  });

  final int index;
  final ValueChanged<int> onSelect;

  /// 真液态玻璃时用 BiliPai 折射透镜水滴；否则用主题色大胶囊选中指示器
  /// （铺满整格的淡红底，与固定底栏观感一致）。
  final bool lens;

  /// 真液态时由状态内部组装玻璃外壳：水滴画在玻璃**之上**（外层 Stack 兄弟
  /// 节点），不被玻璃的 clipPath 裁剪——按住胀大可以超出底栏边缘（BiliPai
  /// dock 同款：56dp 水滴胀到 73dp，鼓出 64dp 栏外仍可见）。
  /// null = 旧结构：整个 widget（含水滴）嵌进外部玻璃/纯色容器内（毛玻璃
  /// 回退、显隐动画窗口纯色态）。
  final Widget Function(Widget content)? glassBuilder;

  @override
  State<_SlidingNavBottom> createState() => _SlidingNavBottomState();
}

class _SlidingNavBottomState extends State<_SlidingNavBottom>
    with TickerProviderStateMixin {
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final AnimationController _rebound = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );

  /// 水滴起止位置（tab 索引，double 支持中途改向时从当前视觉位置续飞）。
  double _from = 0;
  double _to = 0;

  // —— 按住拖动（BiliPai drag-to-switch）——
  bool _dragging = false;
  double _dragPos = 0;
  double _dragVel = 0; // tabs/s（带符号）
  Duration? _lastDragTime;

  @override
  void initState() {
    super.initState();
    _from = _to = widget.index.toDouble();
    _move.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _from = _to;
        if (mounted) _rebound.forward(from: 0);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _SlidingNavBottom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      // 中途改向：从当前视觉位置出发，避免跳变。
      _from = _dragging ? _dragPos : _currentPosition;
      _to = widget.index.toDouble();
      _rebound.stop();
      _move.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _move.dispose();
    _rebound.dispose();
    _press.dispose();
    super.dispose();
  }

  double get _currentPosition =>
      _from + (_to - _from) * Curves.easeOutCubic.transform(_move.value);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final items = bottomNavItems;
    // 三个控制器任一走帧都要重绘（水滴飞行/落点回弹/按住放大）。
    return AnimatedBuilder(
      animation: Listenable.merge([_move, _rebound, _press]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
        // 玻璃外壳自组装（overlay 水滴）时高度自定 70（BiliPai dock 高）；
        // 嵌入外部容器时由容器给高度（固定 70）。
        final overlayDroplet = widget.lens && widget.glassBuilder != null;
        final maxW = constraints.maxWidth;
        final maxH = overlayDroplet
            ? 70.0
            : (constraints.maxHeight.isFinite ? constraints.maxHeight : 70.0);
        final tabW = (maxW - 20) / items.length;
        // 透镜水滴静止直径 0.8×栏高（BiliPai 56/64 同比例），完整罩住
        // 图标+文字。按住再胀 ~30%——水滴画在玻璃外层（overlay），胀出
        // 底栏边缘也可见，不再被玻璃 clip 吃掉放大效果。
        final dropH = (maxH * 0.8).clamp(54.0, 60.0);
        final pos = _dragging ? _dragPos : _currentPosition;

        // —— 飞行速度形变（水滴拉伸）——
        // 点击飞行用 easeOutCubic 导数 3(1−t)²（起步最快、到站归零）；
        // 拖动用指针实时速度。
        final tMove = _move.value;
        final delta = (_to - _from).abs();
        final speed = _dragging
            ? _dragVel
            : delta * 3 * math.pow(1 - tMove, 2) / 0.26;
        final vClamp =
            (speed.isFinite ? speed.abs() : 0.0).clamp(0.0, 1.8) / 10;
        double sx = 1 / (1 - vClamp * 0.75);
        double sy = 1 - vClamp * 0.5;

        // 按住放大：拖动中或指针按下（尚未过拖动 slop）都生效——纯按住
        // 也要有 BiliPai/RwaS 的水滴胀大反馈。静止直径 0.8 栏高，按住
        // 高度 +30%（胀出栏缘）、横向再鼓 24%，肉眼可辨；折射量同步长满
        // （pressG），水滴「活」起来。
        final pressG = Curves.easeOut.transform(_press.value);
        if (_dragging || pressG > 0) {
          sx *= 1 + 0.24 * pressG;
          sy *= 1 + 0.30 * pressG;
        }
        if (!overlayDroplet) {
          // 嵌入玻璃内部时按住胀大被玻璃裁剪，上限钳到栏高防硬切边。
          sy = math.min(sy, maxH / dropH);
        }
        if (!_dragging && _move.isCompleted) {
          // —— 落点回弹（仅在到站后播放）——
          final rp = _rebound.value;
          if (rp < 1) {
            double rx;
            double ry;
            if (rp <= 0.20) {
              final e = Curves.easeOut.transform(rp / 0.20);
              rx = 1 - 0.035 * e;
              ry = 1 + 0.028 * e;
            } else {
              final rel = (rp - 0.20) / 0.80;
              final damping = (1 - rel) * math.exp(-3.2 * rel);
              final wave = damping * math.sin(math.pi * rel);
              rx = 1 + 0.085 * wave;
              ry = 1 + 0.075 * wave;
            }
            sx *= rx;
            sy *= ry;
          }
        }

        // 真液态：圆形折射透镜水滴，参数按 BiliPai 指示器透镜等比缩放
        //（MIUIX 上游：56dp 水滴 = 10dp 折射带 + 14dp 最大位移）。
        // 折射量完全由按压进度驱动（Halcyon：H=10dp·p / A=14dp·p）——
        // 静止 p=0 纯 passthrough（BiliPai 同款），水滴只余极淡底色；
        // 按住/拖动 p→1 折射满档，图标被连贯地「熔」进边缘。不能加静止
        // 保底：半强度位移会让图标原图和折射副本错开成两层重影。
        // depthEffect=1 让中心内容也「鼓起」，水滴压到内容上立刻有
        // 放大镜观感。
        // 非液态：铺满整格的主题色淡红大胶囊（恢复通用选中指示样式）。
        final d = dropH;
        final bool scaledIndicator = overlayDroplet; // 尺寸已含形变，无需 Transform
        Widget indicator;
        if (widget.lens) {
          final pressS = pressG;
          final band = d * 10.0 / 56.0 * pressS;
          final amount = d * 14.0 / 56.0 * pressS;
          indicator = BiliPaiGlass(
            // overlay 模式尺寸含 sx/sy 形变，半径取缩放后短边的一半。
            radius: scaledIndicator ? d * sy / 2 : d / 2,
            refract: amount,
            chroma: 0.5,
            // Halcyon 水滴是纯折射透镜（无模糊）：图标/文字被扭过来时保持
            // 清晰，只靠底色+扫光提供存在感。
            blurSigma: 0,
            // BiliPai/Halcyon 静止水滴近乎全透（无染色无高光，progress=0 时
            // 纯 passthrough）：这里只留极淡底色+弱扫光，否则水滴叠在壳体
            // 染色上变成灰色实心球，失去「清水透镜」观感。
            backgroundColor: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.02),
            specular: 0.12,
            edgeAmount: band,
            saturation: 1.5,
            depthEffect: 1.0,
            child: const SizedBox.expand(),
          );
        } else {
          indicator = DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .primary
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(d / 2),
            ),
            child: const SizedBox.expand(),
          );
        }

        // 水滴=圆形；主题色胶囊=铺满整格（左右各让 4px）。
        final indicatorW = widget.lens ? d : (tabW - 8);

        final tabRow = Center(
          child: Padding(
            // 与指示器同一坐标系（左右各让 10px）：让每个 Expanded 恰好分到
            // tabW，tab 中心 = 10+(i+0.5)·tabW，与水滴中心严格重合（Row 全宽
            // 时 Expanded 分到 maxW/n，会错位）。
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavTab(
                      item: items[i],
                      selected: i == widget.index,
                      // 水滴覆盖度：经过的图标放大，选中项常驻 1.2×
                      //（仅透镜水滴模式，胶囊模式图标不缩放）。
                      iconScale: widget.lens
                          ? 1 +
                              0.2 *
                                  (1 - (i - pos).abs()).clamp(0.0, 1.0)
                          : 1.0,
                      onTap: () => widget.onSelect(i),
                    ),
                  ),
              ],
            ),
          ),
        );

        final gestures = Listener(
          // 指针按下：水滴立刻滑向手指并胀大（不等拖动 slop，BiliPai/RwaS
          // 按住预览）；抬起/取消回缩。松手后的选中由 InkWell onTap 或
          // 拖动结算接管。仅透镜水滴模式生效，主题色胶囊走经典点按行为。
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
                // tab 内容在前（画在底层）：水滴（BackdropFilter）必须画在
                // 图标/文字之上，其 backdrop 才包含 tab 内容——Halcyon 同款
                // （combinedBackdrop 录制 tab 层），水滴压过去时图标/文字
                // 本身被扭向水滴中心；若水滴在下，折射的只是空的栏背景。
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
                        transform: Matrix4.diagonal3Values(sx, sy, 1),
                        child: indicator,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );

        if (overlayDroplet) {
          // 水滴画在玻璃之上（外层 Stack 兄弟节点，clipBehavior: none）：
          // 不被玻璃 clipPath 裁剪，按住胀大可鼓出底栏边缘；BackdropFilter
          // 的背板 = 玻璃+tab 内容（鼓出栏外的部分还能折射页面背景）。
          final w = indicatorW * sx;
          final h = dropH * sy;
          final cx = 10 + pos * tabW + tabW / 2;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              widget.glassBuilder!(SizedBox(height: maxH, child: gestures)),
              Positioned(
                left: cx - w / 2,
                top: maxH / 2 - h / 2,
                width: w,
                height: h,
                child: IgnorePointer(child: indicator),
              ),
            ],
          );
        }
        return gestures;
        },
      ),
    );
  }

  /// 指针按下/抬起驱动水滴放大（不等拖动 slop，纯按住也有反馈）。
  /// 拖动中抬起由 [_commitDragTarget] 统一收尾，此处跳过避免二次 reverse。
  void _setPressed(bool down) {
    if (down) {
      _press.forward(from: 0);
    } else if (!_dragging) {
      _press.reverse();
    }
  }

  /// 按住预览：水滴滑向手指位置并胀大（飞行中不打断，点按仍走原有
  /// 飞行动画衔接）。松手未拖动时由 onTap 选中，水滴已在目标 tab。
  void _onPointerDown(PointerDownEvent e, double tabW, int count) {
    _setPressed(true);
    if (_dragging || _move.isAnimating) return;
    final target =
        ((e.localPosition.dx - 10) / tabW - 0.5).clamp(0.0, count - 1.0);
    if ((target - _currentPosition).abs() > 0.02) {
      _from = _currentPosition;
      _to = target;
      _move.forward(from: 0);
    }
  }

  /// 指针被系统取消（未触发 onTap 也未走拖动结算）：回缩并滑回选中 tab，
  /// 防止水滴停在按住预览的位置。
  void _onPressCancel() {
    if (_dragging) return;
    _press.reverse();
    if (!_move.isAnimating && (_currentPosition - widget.index).abs() > 0.02) {
      _from = _currentPosition;
      _to = widget.index.toDouble();
      _move.forward(from: 0);
    }
  }

  void _onDragStart(DragStartDetails d, double tabW, int count) {
    _dragging = true;
    _dragVel = 0;
    _lastDragTime = d.sourceTimeStamp;
    // 水滴中心跟随手指：pos = (x − 10 − tabW/2) / tabW。
    _dragPos = ((d.localPosition.dx - 10) / tabW - 0.5)
        .clamp(0.0, count - 1.0);
    _move.stop();
    _from = _to = _currentPosition;
    _rebound.stop();
    _press.forward(from: 0);
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails d, double tabW, int count) {
    final prev = _dragPos;
    _dragPos = ((d.localPosition.dx - 10) / tabW - 0.5)
        .clamp(0.0, count - 1.0);
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
    // 按速度投影（BiliPai 手势甩动同款）：位置 + 速度×提前量，吸附最近 tab。
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
    _from = _dragPos;
    _to = target;
    _move.forward(from: 0);
    final idx = target.round();
    if (idx != widget.index) {
      widget.onSelect(idx);
    } else {
      setState(() {});
    }
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
    this.iconScale = 1.0,
  });

  final BottomNavItem item;
  final bool selected;
  final VoidCallback onTap;
  final double iconScale;

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
            Transform.scale(
              scale: iconScale,
              child: Icon(item.icon, size: 22, color: color),
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
    setGlobalDragging(true);
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
    setGlobalDragging(false);
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
    setGlobalDragging(false);
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
          // BiliPai 液态玻璃面板（全档真 shader）：与底栏/迷你播放条同一套观感。
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
            backgroundColor: bilipaiGlassTint(isDark, quality),
            specular: bilipaiSpecularOf(quality),
            edgeAmount: bilipaiEdgeOf(quality),
            saturation: bilipaiSaturationOf(quality),
            child: SizedBox(width: panelWidth, child: panelBody),
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
          // 降采样模糊（cheapBackdropBlur）：模糊工作量降为 1/16，
          // 运动期保持玻璃恒定（RwaS 口径），sigma 按预算档位缩放。
          // 壁纸模式 sigma=0、fill=全透明：不铺模糊直接透出壁纸。
          panelWidget = panelSigma <= 0
              ? panelBox
              : ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: cheapBackdropBlur(panelSigma),
                    child: panelBox,
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

