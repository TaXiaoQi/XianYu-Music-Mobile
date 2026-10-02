import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_logger.dart';
import '../core/app_colors.dart';
import '../core/haptics.dart';
import '../core/settings.dart';
import '../theme/theme_icon.dart';
import '../theme/theme_tint.dart';
import '../auth/auth_provider.dart';
import '../widgets/glass_settings.dart';
import '../widgets/landscape_page_fade.dart';
import 'landscape_tab_switcher.dart';
import '../widgets/blur_budget.dart';
import '../widgets/orientation_transition.dart';
import '../widgets/app_toast.dart';
import '../notifications/notification_service.dart';
import '../sync/auto_sync.dart';
import '../sync/sync_provider.dart' show syncProvider;
import '../widgets/mini_player_bar.dart' show LiveLiquidSurface;
import '../widgets/page_search_bar.dart';
import '../widgets/bilipai_glass.dart';
import '../widgets/chrome_glass_frame.dart';
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
import '../../pages/leaderboard/leaderboard_prefetch.dart';
import '../../pages/search/search_page.dart';
import 'routes.dart';
import '../i18n/i18n.dart';

const double kFloatingNavBarInset = 90;

const double kLandscapeRailWidth = 176;
const double kLandscapeRailIconWidth = 60;
const double kLandscapeRailCollapseAt = 120;

final isLandscapeProvider = StateProvider<bool>((ref) => false);

final landscapeLibraryProvider = StateProvider<int?>((ref) => null);

final landscapeLibrarySearchActiveProvider =
    StateProvider<bool>((ref) => false);

final landscapeLibraryQueryProvider = StateProvider<String>((ref) => '');

final landscapeLibrarySearchCtrlProvider =
    Provider<TextEditingController>((ref) {
  final ctrl = TextEditingController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

final landscapeLibrarySearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode();
  ref.onDispose(node.dispose);
  return node;
});

final landscapeAccountOpenProvider = StateProvider<bool>((ref) => false);

final landscapeDownloadOpenProvider = StateProvider<bool>((ref) => false);

final landscapePlaylistOpenProvider = StateProvider<String?>((ref) => null);

final landscapeContentPathProvider = StateProvider<String?>((ref) => null);

final musicLibraryPageKeys =
    List<GlobalKey>.generate(4, (_) => GlobalKey());

final landscapePaneOpenProvider = Provider<bool>((ref) {
  return ref.watch(landscapeAccountOpenProvider) ||
      ref.watch(landscapeDownloadOpenProvider) ||
      ref.watch(landscapePlaylistOpenProvider) != null ||
      ref.watch(landscapeSearchOpenProvider) ||
      ref.watch(landscapeContentPathProvider) != null;
});

final landscapeSettingsCategoryProvider = StateProvider<String?>((ref) => null);

const Set<String> kLandscapeSettingPaths = <String>{
  '/settings/account',
  '/settings/general',
  '/settings/appearance',
  '/settings/lyrics',
  '/settings/playback',
  '/settings/download',
  '/settings/watch',
  '/settings/dlna',
  '/settings/tools',
  '/settings/advanced',
  '/about',
  '/plugin',
};

final navBarInsetProvider = Provider<double>((ref) {
  final landscape = ref.watch(isLandscapeProvider);
  final s = ref.watch(settingsProvider).valueOrNull;
  if (landscape || s?.navBarPosition == NavBarPosition.side) return 82;
  // 悬浮底栏是覆盖式，页面需多留白避让；固定底栏占位在布局内，只需留 mini 播放条。
  return (s?.floatingNavBar ?? false) ? 175 : 82;
});

final navBarHiddenProvider = StateProvider<int>((ref) => 0);

/// 当前是否处于根路径（'/'、'/home'、'/mine'）：底栏 hidden = 计数 >0 ||
/// 非 root 路径，设置等未混 HidesShellChrome 的二级页面靠后者隐藏；
/// 顶层 NavDropletOverlay 据此对齐底栏显隐
final navOnRootPathProvider = StateProvider<bool>((ref) => true);

/// mini 播放条页面黑名单计数：混入 HideMiniBar 的页面（设置、搜索等）
/// 持有期间 >0，全局播放条在该页面落定后隐藏、离开后恢复
final miniBarHiddenProvider = StateProvider<int>((ref) => 0);

final sideBarExpandedProvider = StateProvider<bool>((ref) => false);

class EmbeddedShellScope extends InheritedWidget {
  const EmbeddedShellScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EmbeddedShellScope>() != null;

  @override
  bool updateShouldNotify(EmbeddedShellScope oldWidget) => false;
}

mixin HidesShellChrome<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  ProviderContainer? _container;

  bool _counted = false;

  bool get hidesChrome => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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

/// 页面级 mini 播放条黑名单：混入的页面（设置、搜索等）持有期间
/// miniBarHiddenProvider >0，全局播放条在该页面落定后隐藏、离开后恢复；
/// 转场期间不生效（条不受切换动画影响，落定后才淡出/淡入）
mixin HideMiniBar<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  ProviderContainer? _miniBarContainer;

  bool _miniBarCounted = false;

  /// 本页被上层路由覆盖（push 了详情/子页）时是否继续压住播放条。
  /// 默认 true 维持整树隐藏（设置体系等依赖父级计数连坐）；
  /// 音源榜单等"详情页应恢复播放条"的页面覆写为 false。
  bool get hideMiniBarWhenCovered => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (EmbeddedShellScope.of(context)) return;
      _miniBarContainer = ProviderScope.containerOf(context, listen: false);
      _miniBarCounted = true;
      _miniBarContainer!.read(miniBarHiddenProvider.notifier).state++;
      if (hideMiniBarWhenCovered) return;
      // 监听被覆盖状态：覆盖层落定（secondaryAnimation completed）释放
      // 计数让播放条回归，覆盖层 pop 回来（dismissed）后重新压住
      final coverAnim = ModalRoute.of(context)?.secondaryAnimation;
      coverAnim?.addStatusListener(_onCoverStatusChanged);
      // 极端情况：页面创建时已被覆盖（如状态恢复），直接释放
      if (coverAnim?.status == AnimationStatus.completed) _releaseCount();
    });
  }

  void _onCoverStatusChanged(AnimationStatus status) {
    if (hideMiniBarWhenCovered) return;
    if (status == AnimationStatus.completed) {
      // 覆盖层落定：本页不可见，释放计数（已释放时幂等）
      _releaseCount();
    } else if (status == AnimationStatus.dismissed) {
      // 覆盖层离开、本页重新可见：重新压住
      if (_miniBarCounted || !mounted) return;
      _miniBarContainer?.read(miniBarHiddenProvider.notifier).state++;
      _miniBarCounted = true;
    }
    // forward/reverse 为转场途中，保持前一状态不动
  }

  void _releaseCount() {
    if (!_miniBarCounted) return;
    _miniBarCounted = false;
    final container = _miniBarContainer;
    if (container != null) {
      final notifier = container.read(miniBarHiddenProvider.notifier);
      if (notifier.state > 0) notifier.state--;
    }
  }

  @override
  void dispose() {
    if (_miniBarCounted) {
      final container = _miniBarContainer;
      _miniBarCounted = false;
      if (container != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final notifier = container.read(miniBarHiddenProvider.notifier);
          if (notifier.state > 0) notifier.state--;
        });
      }
    }
    super.dispose();
  }
}

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
    ref.read(autoSyncProvider).start();
    // 启动即静默预热排行榜：进个人中心点统计卡时直接命中缓存，
    // 不再先闪一屏空骨架（预热失败/未完成时页面行为与以前一致）
    unawaited(prefetchLeaderboard(ref));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(authProvider).user != null) {
        ref.read(syncProvider.notifier).syncOnLoginSuccess(context);
      }
    });
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
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 页签切换（首页⇄我的）不走路由转场，转场 false 沿的抓帧触发不到；
    // 而底栏/顶栏的透底内容已换页，必须刷新 chrome 缓存帧——否则在新
    // 页签推入二级页时，转场裁剪出的是旧页签的透底
    if (widget.navigationShell.currentIndex !=
        oldWidget.navigationShell.currentIndex) {
      // 旧页签的缓存帧立即失效：补抓完成前 chrome 面拿到的帧为 null，
      // 转场裁剪/adopt 落到毛玻璃兜底——宁缺勿错，绝不裁出上个页签的透底
      final stale = chromeGlassFrame.value;
      chromeGlassFrame.value = null;
      if (stale != null) {
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => stale.image.dispose());
      }
      schedule(const Duration(milliseconds: 300));
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.navigationShell.currentIndex;
    final hiddenCount = ref.watch(navBarHiddenProvider);
    final isSubPage = hiddenCount > 0 || GoRouter.of(context).canPop();

    return Listener(
      behavior: HitTestBehavior.translucent,
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

  void _handleBack() {
    final router = GoRouter.of(context);
    AppLogger.instance.log('back',
        'onBack tab=${widget.navigationShell.currentIndex} routerCanPop=${router.canPop()}');

    if (router.canPop()) {
      AppLogger.instance.log('back', '手动 pop 二级页面');
      router.pop();
      return;
    }

    if (widget.navigationShell.currentIndex != 0) {
      AppLogger.instance.log('back', '切回主界面 tab');
      widget.navigationShell.goBranch(0);
      return;
    }

    final now = DateTime.now();
    if (_lastBackTime == null ||
        now.difference(_lastBackTime!) > const Duration(seconds: 2)) {
      _lastBackTime = now;
      AppLogger.instance.log('back', '提示再按一次退出');
      showXianYuToast(context, tr('再按一次退出应用'),
        duration: const Duration(seconds: 2));
      return;
    }

    AppLogger.instance.log('back', 'SystemNavigator.pop 退出应用');
    SystemNavigator.pop();
  }
}

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

  bool _isRootPath = true;

  double _railWidth = kLandscapeRailWidth;

  StreamSubscription<dynamic>? _rotationSub;

  static const _rootPaths = {'/', '/home', '/mine'};

  static bool _isRootPathOf(String path) => _rootPaths.contains(path);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _router = GoRouter.of(context);
    _isRootPath =
        _isRootPathOf(_routerTopPath(_router.routerDelegate.currentConfiguration));
    ref.read(navOnRootPathProvider.notifier).state = _isRootPath;
    _router.routerDelegate.addListener(_onRouteChanged);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _rotationSub = const EventChannel('xianyu/rotation/events')
          .receiveBroadcastStream()
          .listen(_onRotationEvent, onError: (_) {});
    }
  }

  void _onRotationEvent(Object? e) {
    if (!mounted) return;
    final v = e is num ? e.toInt() : null;
    if (v == null) return;
    if (v == 1) {
      ref.read(isLandscapeProvider.notifier).state = false;
    } else if (v == 2) {
      ref.read(isLandscapeProvider.notifier).state = true;
    }
  }

  void _onRouteChanged() {
    if (!mounted) return;
    // 不能用 currentConfiguration.uri.path：push 二级页（ImperativeRouteMatch）
    // 后 uri.path 仍停留在 shell 分支的路径（/home 或 /mine），不会变成
    // /settings——根因是它只反映 shell 分支 location。取 matches.last 的
    // 实际位置（_routerTopPath），与底栏/横屏逻辑的判定保持同源
    final top = _routerTopPath(_router.routerDelegate.currentConfiguration);
    final rootNow = _isRootPathOf(top);
    if (rootNow != _isRootPath) {
      setState(() => _isRootPath = rootNow);
      ref.read(navOnRootPathProvider.notifier).state = rootNow;
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
    _rotationSub?.cancel();
    super.dispose();
  }

  static const Set<String> _noRotateRedirectPaths = <String>{
    '/player',
    '/scan',
    '/recognize',
    '/tv-login-confirm',
    '/shareBridge',
  };

  static String _routerTopPath(RouteMatchList config) {
    final last = config.matches.lastOrNull;
    if (last is ImperativeRouteMatch) return last.matches.uri.path;
    if (last is RouteMatch) return last.matchedLocation;
    if (last is ShellRouteMatch) return last.matchedLocation;
    return config.uri.path;
  }

  String? _rotateBackPath;

  bool? _lastPhysicalLandscape;

  bool _libPaneMountable = true;
  Timer? _libPaneMountTimer;

  // 转场中顶栏复用的旧 widget 实例（identical → 子树跳过 rebuild 保帧）
  Widget? _topBarCache;

  void _deferLibPaneMount() {
    _libPaneMountable = false;
    _libPaneMountTimer?.cancel();
    _libPaneMountTimer = Timer(const Duration(milliseconds: 400), () {
      _libPaneMountTimer = null;
      if (mounted) setState(() => _libPaneMountable = true);
    });
  }

  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null || !mounted) return;
    final size = view.physicalSize / view.devicePixelRatio;
    final landscape = size.width >= size.height * 1.05;
    final noti = ref.read(isLandscapeProvider.notifier);
    if (noti.state != landscape) {
      noti.state = landscape;
    }
    final flipped =
        _lastPhysicalLandscape != null && _lastPhysicalLandscape != landscape;
    _lastPhysicalLandscape = landscape;
    if (!flipped) return;
    if (!landscape) {
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
        final top = _routerTopPath(_router.routerDelegate.currentConfiguration);
        final onShell = _isRootPathOf(top);
        final onSettings = top == '/settings';
        if (onSettings && kLandscapeSettingPaths.contains(back)) {
          final category = ref.read(landscapeSettingsCategoryProvider);
          context.push(category ?? back!);
        } else if (onShell) {
          if (lib != null) {
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
      const libRoutes = ['/library', '/favorites', '/recent', '/playlists'];
      if (path == '/search' || path == '/search/result') {
        _rotateBackPath = path;
        ref.read(landscapeSearchOpenProvider.notifier).state = true;
        ref.read(landscapeSearchResultsProvider.notifier).state =
            path == '/search/result';
        while (context.canPop()) {
          context.pop();
        }
      } else if (kLandscapeSettingPaths.contains(path)) {
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
        _rotateBackPath = path;
        ref.read(landscapeContentPathProvider.notifier).state = path;
        while (context.canPop()) {
          context.pop();
        }
      } else if (path == '/download') {
        _rotateBackPath = path;
        ref.read(landscapeDownloadOpenProvider.notifier).state = true;
        while (context.canPop()) {
          context.pop();
        }
      } else if (path == '/account') {
        _rotateBackPath = path;
        ref.read(landscapeAccountOpenProvider.notifier).state = true;
        while (context.canPop()) {
          context.pop();
        }
      } else if (path.startsWith('/playlist/')) {
        _rotateBackPath = path;
        ref.read(landscapePlaylistOpenProvider.notifier).state =
            path.split('/').last;
        while (context.canPop()) {
          context.pop();
        }
      } else if (!_noRotateRedirectPaths.contains(path) && path != '/settings') {
        _rotateBackPath = path;
        while (context.canPop()) {
          context.pop();
        }
      }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final screen = MediaQuery.maybeOf(context);
    final landscape = screen == null ||
        screen.size.width >= screen.size.height * 1.05;

    if (_lastImmersive != landscape) {
      _lastImmersive = landscape;
      _applyLandscapeImmersive(landscape);
    }
  }

  Future<void> _applyLandscapeImmersive(bool landscape) async {
    try {
      if (landscape) {
        await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
        );
      }
    } catch (_) {
    }
  }

  bool _lastImmersive = false;

  Widget _landscapeFadePanel({
    required bool useCameraArea,
    required EdgeInsets padding,
    required BuildContext context,
    required Widget child,
  }) {
    return useCameraArea
        ? MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: padding.copyWith(left: 0, right: 0),
            ),
            child: child,
          )
        : child;
  }

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
    final padding = MediaQuery.of(context).padding;
    final safeBottom = padding.bottom;

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

    final libSel = ref.watch(landscapeLibraryProvider);

    final accountOpen = landscape && ref.watch(landscapeAccountOpenProvider);

    final downloadOpen = landscape && ref.watch(landscapeDownloadOpenProvider);

    final playlistOpenId = landscape
        ? ref.watch(landscapePlaylistOpenProvider)
        : null;

    final searchOpenRaw = ref.watch(landscapeSearchOpenProvider);
    final searchResults = ref.watch(landscapeSearchResultsProvider);
    final searchOpen = landscape && searchOpenRaw;

    final contentPath = landscape
        ? ref.watch(landscapeContentPathProvider)
        : null;

    final Widget? landPane;
    final Object? landPaneTrigger;
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

    const libPaneActive = false;

    final floatingSearchBar =
        ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.floatingSearchBar ?? false));

    final useCameraArea = landscape &&
        ref.watch(
            settingsProvider.select(
                (s) => s.valueOrNull?.landscapeCameraArea ?? true));

    final landscapeFadeEnabled = landscape &&
        ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.landscapeTransitionEnabled ?? true));

    final libPaneMountable = landscape && _libPaneMountable;
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

    final hiddenCount = ref.watch(navBarHiddenProvider);
    final hidden = hiddenCount > 0 || !_isRootPath;

    // chrome 缓存帧抓取门控：竖屏悬浮 chrome（底栏/悬浮顶栏）可见且为
    // 液态材质时才允许抓帧，保证缓存帧里的 chrome 区域是有效液态输出
    chromeGlassFrameActive.value = !landscape &&
        !hidden &&
        (ref.watch(settingsProvider.select(
                (s) => s.valueOrNull?.liquidGlass)) ??
            true) &&
        !ref.watch(settingsProvider.select(
            (s) => performancePriority(s.valueOrNull ?? const AppSettings())));

    void select(int i) {
      if (i == widget.navigationShell.currentIndex || i == widget.index) return;
      if (searchOpenRaw) closeLandscapeSearch(ref);
      ref.read(landscapeContentPathProvider.notifier).state = null;
      widget.navigationShell.goBranch(
          i, initialLocation: i == widget.navigationShell.currentIndex);
    }

    // 转场中沿用上次构建的顶栏实例（identical → Element 跳过子树 rebuild）：
    // 标题/按钮变化会连带毛玻璃 BackdropFilter 重新采样 backdrop 层，
    // 转场中该层不稳定即闪黑；锁定后落定才更新标题
    final Widget topBar;
    if (globalIsTransitioning.value && _topBarCache != null) {
      topBar = _topBarCache!;
    } else {
      topBar = _topBarCache = GlassTopBar(
        titleSpacing: widget.index == 0 ? 18 : null,
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
              icon: themeSlotWidget(ref, 'entry.wallpaper',
                  fallback: const SkinIcon()),
              tooltip: tr('皮肤'),
              onPressed: () => context.push('/wallpaper'),
            ),
            const SizedBox(width: 16),
          ] else ...[
            IconButton(
              icon: themeSlotIcon(ref, 'mine.settings',
                  fallback: Icons.settings_outlined),
              tooltip: tr('设置'),
              onPressed: () => context.push('/settings'),
            ),
            const SizedBox(width: 16),
          ],
        ],
        bottom: PageSearchBarBottom(
          onTap: () => context.push('/search'),
          onRecognize: () => context.push('/recognize'),
        ),
      );
    }

    Widget buildRailDivider() => Positioned(
          left: _railWidth - 14,
          top: 0,
          bottom: 0,
          width: 28,
          child: _ShellRailDivider(
            onDragUpdate: (dx) {
              final screenW = MediaQuery.sizeOf(context).width;
              final leftSafe = padding.left;
              setState(() {
                _railWidth = (_railWidth + dx)
                    .clamp(leftSafe + kLandscapeRailIconWidth, screenW * 0.5);
              });
            },
          ),
        );

    final isSide = landscape ||
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.navBarPosition)) ==
            NavBarPosition.side);

    final expanded = ref.watch(sideBarExpandedProvider);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
          ValueListenableBuilder<double>(
            valueListenable: orientationContentFade,
            builder: (context, fade, child) =>
                Opacity(opacity: fade, child: child),
            child: Padding(
            padding: EdgeInsets.only(
              left: landscape ? _railWidth : 0,
              right: (landscape && !useCameraArea) ? padding.right : 0,
            ),
            child: Stack(
                    children: [
                      Positioned.fill(
                        child: landscape
                            ? (floatingSearchBar
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
          ),

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

          if (landscape) buildRailDivider(),

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

          if (!isSide && floating)
            Positioned(
                left: 12,
                right: 12,
                bottom: 18 + safeBottom,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  // 液态 shader 最低 0.01 保温（整树停绘后重显首帧采样
                  // 黑闪）；毛玻璃普通 blur 归零停绘，淡入首绘发生在极低
                  // alpha（不可见），防 saveLayer 内首帧重采样闪白
                  opacity: hidden ? glassHiddenOpacityFloor(ref) : 1.0,
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

          if (!landscape)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 12,
              right: 12,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                // 液态 shader 0.01 保温防重显黑闪；毛玻璃归零停绘，
                // 淡入首绘在极低 alpha 下防 saveLayer 内重采样闪白
                opacity: (floatingSearchBar &&
                        (widget.index == 0 || widget.index == 1) &&
                        !hidden)
                    ? 1.0
                    : glassHiddenOpacityFloor(ref),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  // 与悬浮底栏同款缩小退让（0.92），退场不再只是淡出
                  scale: (floatingSearchBar &&
                          (widget.index == 0 || widget.index == 1) &&
                          !hidden)
                      ? 1.0
                      : 0.92,
                  child: IgnorePointer(
                    ignoring: !(floatingSearchBar &&
                        (widget.index == 0 || widget.index == 1) &&
                        !hidden),
                    child: FloatingTopBar(
                      chromeFrame: true,
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
                      onRecognize: () => context.push('/recognize'),
                      actions: [
                        if (widget.index == 0)
                          BiliPaiIconButton(
                            iconChild: themeSlotWidget(ref, 'entry.wallpaper',
                                fallback: const SkinIcon()),
                            tooltip: tr('皮肤'),
                            onTap: () => context.push('/wallpaper'),
                          )
                        else
                          BiliPaiIconButton(
                            iconChild: themeSlotWidget(ref, 'mine.settings',
                                fallback: const Icon(Icons.settings_outlined)),
                            tooltip: tr('设置'),
                            onTap: () => context.push('/settings'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

    if (!landscape && !floatingSearchBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                // 顶栏恒为毛玻璃 BackdropFilter（无 shader 层）：归零停绘，
                // 淡入首绘在极低 alpha 下防 saveLayer 内重采样闪白
                opacity: (widget.index == 0 || widget.index == 1) && !hidden
                    ? 1.0
                    : 0.0,
                child: IgnorePointer(ignoring: hidden, child: topBar),
              ),
            ),
          const OrientationTransitionOverlay(),
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
      extendBody: !isSide && !floating,
        );
  }
}

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

class _FixedNavBar extends ConsumerWidget {
  const _FixedNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
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
            (solid || wallpaper) ? fill : surfaceFillWithBudget(fill, budget));
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

class _JellySwitch extends StatefulWidget {
  const _JellySwitch({
    super.key,
    required this.mode,
    required this.child,
  });

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
  const _LiquidNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

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
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    // 液态开关与引擎能力分开算:用户开了液态但引擎不支持 shader 时,
    // BiliPaiGlass 自身会降级(blur+淡底),裸分支观感接近透明(用户读作透底),
    // 但 lens 水滴的按住放大折射(LiveLiquidSurface 伪折射)是好的,必须保留。
    // → 引擎支持才走裸分支;降级场景走 _frostedGlass(degradedLiquid:
    //    磨砂级胶囊底+标准 blur,禁实底兜底),折射水滴原样保留。
    final liquidGlassOn =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
                true) &&
            !lowPerf;
    // 壁纸模式同步顶栏材质：栏面不上液态，走组件色块+导航面档位模糊；
    // lens 水滴是交互折射效果，与栏面材质无关，保留
    final wallpaper = wallpaperGlassActive(ref);
    final liquid = liquidGlassOn &&
        !wallpaper &&
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
    return _frostedGlass(context, ref, tabs,
        lowPerf: lowPerf,
        budget: budget,
        degradedLiquid: liquidGlassOn);
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

  Widget _frostedGlass(BuildContext context, WidgetRef ref, Widget tabs,
      {bool lowPerf = false,
      BlurBudget? budget,
      bool forceSolid = false,
      bool degradedLiquid = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prefSolid = glassShouldUseSolid(ref, lowPerf: lowPerf);
    final effBudget = budget ?? ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar))!;
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
                : surfaceFillWithBudget(bg, budget));
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
          backdropGroupKey:
              degradedLiquid && !wallpaper ? null : navGlassKey,
          child: capsule,
        ),
      ),
    );
  }
}

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

  final bool floating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = railWidth < kLandscapeRailCollapseAt;

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
        if (!collapsed)
          Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 主题提供品牌图时才出现；未启用主题时是零尺寸，观感不变。
              themeSlotWidget(
                ref,
                'landscape.logo',
                size: 22,
                fallback: const SizedBox.shrink(),
              ),
              Text.rich(
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
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(top: 6, bottom: floating ? 8 : 12),
            children: [
              if (!collapsed) label(tr('导航')),
              for (var i = 0; i < primary.length; i++)
                _railItem(
                  context,
                  ref,
                  icon: primary[i].icon,
                  themeSlot: primary[i].themeSlot,
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
                  ref,
                  icon: library[j].$2,
                  title: library[j].$1,
                  collapsed: collapsed,
                  selected: libSel == j,
                  onTap: () {
                    closeLandscapeSearch(ref);
                    ref.read(landscapeLibraryProvider.notifier).state = j;
                  },
                ),
            ],
          ),
        ),
        const Spacer(),
        // 主题提供侧栏贴纸时才出现；未启用主题时零尺寸，观感不变。
        if (!collapsed)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: themeSlotSticker(
                ref,
                'ls-sidebar.bottom',
                width: (railWidth - 24).clamp(24.0, 240.0),
              ),
            ),
          ),
      ],
    );

    if (floating) {
      return FloatingGlassSurface(radius: 18, child: content);
    }

    return SafeArea(
      right: false,
      child: SizedBox(
        width: railWidth,
        child: DecoratedBox(
          decoration: BoxDecoration(
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

  Widget _railItem(
    BuildContext context,
    WidgetRef ref, {
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
    bool collapsed = false,
    String? themeSlot,
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
              themeSlotIcon(ref, themeSlot,
                  fallback: icon, size: 20, color: color),
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

class _MusicLibraryPane extends StatelessWidget {
  const _MusicLibraryPane({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
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

class _AccountPane extends StatelessWidget {
  const _AccountPane({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return AccountPage(embedded: true, onBack: onBack);
  }
}

class _DownloadPane extends StatelessWidget {
  const _DownloadPane();

  @override
  Widget build(BuildContext context) {
    return const DownloadPage(embedded: true);
  }
}

class _PlaylistDetailPane extends StatelessWidget {
  const _PlaylistDetailPane({required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    return PlaylistDetailPage(playlistId: playlistId, embedded: true);
  }
}

class _SearchPane extends ConsumerWidget {
  const _SearchPane({required this.showResults});

  final bool showResults;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floatingBar = ref.watch(settingsProvider
        .select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    if (!showResults) {
      if (floatingBar) {
        return ColoredBox(
          color: appScaffoldBackground(context, ref),
          child: SearchIdleView(
            onSearch: (q) => submitLandscapeSearch(ref, q),
            topPadding: GlassTopBar.height(context),
          ),
        );
      }
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

