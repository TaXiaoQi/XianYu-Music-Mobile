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
import '../auth/auth_provider.dart';
import '../widgets/glass_settings.dart';
import '../widgets/custom_background.dart';
import '../widgets/landscape_page_fade.dart';
import 'landscape_tab_switcher.dart';
import '../widgets/blur_budget.dart';
import '../widgets/orientation_transition.dart';
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
  '/settings/tools',
  '/settings/advanced',
  '/about',
  '/plugin',
};

final navBarInsetProvider = Provider<double>((ref) {
  final landscape = ref.watch(isLandscapeProvider);
  final s = ref.watch(settingsProvider).valueOrNull;
  if (landscape || s?.navBarPosition == NavBarPosition.side) return 82;
  return 175;
});

final navBarHiddenProvider = StateProvider<int>((ref) => 0);

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
        _isRootPathOf(_router.routerDelegate.currentConfiguration.uri.path);
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

  void _deferLibPaneMount() {
    _libPaneMountable = false;
    _libPaneMountTimer?.cancel();
    _libPaneMountTimer = Timer(const Duration(milliseconds: 400), () {
      _libPaneMountTimer = null;
      if (mounted) setState(() => _libPaneMountable = true);
    });
  }

  bool? _lastChromeHidden;
  Timer? _chromeSettleTimer;

  void _syncChromeGlassSettle(bool hidden) {
    if (_lastChromeHidden == hidden) return;
    final first = _lastChromeHidden == null;
    _lastChromeHidden = hidden;
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

  double? _playerTop;
  double? _playerLeft;

  Offset? _lastSeenShared;

  bool? _lastFloating;
  bool? _lastSide;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final floating = ref.read(
            settingsProvider.select((s) => s.valueOrNull?.floatingNavBar)) ??
        true;
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

  bool _isPlayerDragging = false;

  void _onPlayerPanStart(DragStartDetails details) {
    setState(() {
      _isPlayerDragging = true;
      _playerLeft ??= MiniBarPositionStore.shared?.dx;
      _playerTop ??= MiniBarPositionStore.shared?.dy;
    });
    setGlobalDragging(true);
  }

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

    final barW = landscape ? miniBarW : (screenSize.width - 24.0);
    final minLeft = landscape ? landscapeLeftBound : 6.0;
    final maxLeft = landscape
        ? landscapeRightBound
        : (screenSize.width - barW - 6.0);
    final minTop = _playerMinTop(padding.top, landscape);

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
    setGlobalDragging(false);

    final l = _playerLeft;
    final t = _playerTop;
    if (l != null && t != null) {
      MiniBarPositionStore.shared = Offset(l, t);
      _playerLeft = null;
      _playerTop = null;
    }
  }

  void _onPlayerPanCancel() {
    setState(() {
      _isPlayerDragging = false;
    });
    setGlobalDragging(false);
  }

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
    if (!landscape) _syncChromeGlassSettle(hidden);

    void select(int i) {
      if (i == widget.navigationShell.currentIndex || i == widget.index) return;
      if (searchOpenRaw) closeLandscapeSearch(ref);
      ref.read(landscapeContentPathProvider.notifier).state = null;
      widget.navigationShell.goBranch(
          i, initialLocation: i == widget.navigationShell.currentIndex);
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

    final isPlayerPage =
        GoRouterState.of(context).uri.toString() == '/player';

    final miniBarLow = hiddenCount > 0 || (!_isRootPath && !isPlayerPage);

    final hideShellMiniBar = accountOpen;

    final miniBarW = landscape
        ? math.min(screenSize.width * 0.55, 520.0)
        : (screenSize.width - 24.0);

    final leftCutout = landscape ? padding.left : 0.0;
    final rightCutout = landscape ? padding.right : 0.0;

    late final double defaultLeft;
    var landscapeLeftBound = 6.0;
    var landscapeRightBound = 30.0;
    if (landscape) {
      landscapeLeftBound = math.max(leftCutout, 6.0);
      landscapeRightBound = screenSize.width -
          miniBarW -
          (rightCutout > 0 ? rightCutout + 12 : 16);
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
                : (screenSize.height - 18.0 - 70.0 - 58.0))
            : (screenSize.height - safeBottom - 58.0 - 64.0));

    final batchLift = ref.watch(batchBarLiftProvider);
    final liftedDefaultTop = defaultTop - batchLift;

    final dragMaxTop = () {
      final barH = 58.0;
      if (isSide) return screenSize.height - safeBottom - barH - 12.0 - batchLift;
      if (floating) {
        return hidden
            ? (screenSize.height - padding.bottom - barH - 12.0)
            : (screenSize.height - 18.0 - 70.0 - barH - batchLift);
      }
      return hidden
          ? (screenSize.height - padding.bottom - barH - 12.0)
          : (screenSize.height - safeBottom - 64.0 - barH - batchLift);
    }();

    final shared = MiniBarPositionStore.shared;
    final shellMinLeft = landscape ? landscapeLeftBound : 6.0;
    final shellMaxLeft = landscape
        ? landscapeRightBound
        : (screenSize.width - (screenSize.width - 24.0) - 6.0);
    final actualLeft = (_playerLeft ?? shared?.dx ?? defaultLeft)
        .clamp(shellMinLeft,
            shellMaxLeft > shellMinLeft ? shellMaxLeft : shellMinLeft)
        .toDouble();
    final minTopClamped = _playerMinTop(padding.top, landscape);
    final actualTop = (_playerTop ?? shared?.dy ?? liftedDefaultTop)
        .clamp(
            minTopClamped, math.max(minTopClamped, dragMaxTop.toDouble()))
        .toDouble();

    final adoptedExternal =
        shared != null && shared != _lastSeenShared && !_isPlayerDragging;
    _lastSeenShared = shared;

    final rootBarTop = (isSide
            ? (screenSize.height - safeBottom - 58.0 - 12.0)
            : (floating
                ? (screenSize.height - 18.0 - 70.0 - 58.0)
                : (screenSize.height - safeBottom - 58.0 - 64.0))) -
        batchLift;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(
            child: CustomBackgroundLayer(),
          ),
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

          if (!hideShellMiniBar)
            AnimatedPositioned(
                duration: (_isPlayerDragging || adoptedExternal)
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
                  registerTarget: !(hiddenCount > 0 && !isPlayerPage),
                  heroTag: (hiddenCount > 0 && !isPlayerPage) ? null : 'player-cover',
                  returnTarget: () => Rect.fromLTWH(
                    actualLeft,
                    rootBarTop,
                    46,
                    46,
                  ),
                ),
              ),

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

          if (!landscape)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
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
    final barBox = Container(color: glassFill, child: bar);
    if (solid) {
      return barBox;
    }
    final barSigma = kNavSurfaceBlurSigma;
    return ClipRect(
      child: BackdropFilter(
        filter: cheapBackdropBlur(barSigma),
        child: barBox,
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
  bool _holdSolid = false;
  bool _lastSettling = false;

  @override
  Widget build(BuildContext context) {
    final settling = ref.watch(chromeGlassSettlingProvider);
    if (settling != _lastSettling) {
      final prior = _lastSettling;
      _lastSettling = settling;
      if (prior && !settling) {
        _holdSolid = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_holdSolid) return;
          setState(() => _holdSolid = false);
        });
      }
    }
    final effectiveSettling = settling || _holdSolid;

    final index = widget.index;
    final onSelect = widget.onSelect;
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
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));

    final realLiquid = liquid;
    final dropletQuality = liquidGlassQualitySetting(ref);
    final tabs = _SlidingNavBottom(
      index: index,
      lens: realLiquid,
      lensBoost: bilipaiIndicatorLensBoostOf(dropletQuality),
      edgeBoost: bilipaiIndicatorEdgeBoostOf(dropletQuality),
      dropletChroma: bilipaiIndicatorChromaOf(dropletQuality),
      glassBuilder: liquid
          ? (Widget content) =>
              _liquidGlass(context, ref, content, solid: effectiveSettling)
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
        forceSolid: effectiveSettling,
        keepFilter: effectiveSettling);
  }

  Widget _liquidGlass(BuildContext context, WidgetRef ref, Widget tabs,
      {bool solid = false}) {
    final quality = liquidGlassQualitySetting(ref);
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.bottomBar));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glass = BiliPaiGlass(
      radius: 30,
      refract: bilipaiRefractOf(quality),
      chroma: bilipaiChromaOf(quality),
      blurSigma: surfaceBlurSigma(
        base: bilipaiBackdropBlurOf(quality),
        budget: budget,
        type: BlurSurfaceType.bottomBar,
        crispAtRest: true,
      ),
      backgroundColor: solid
          ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
          : bilipaiSurfaceTint(context, ref, quality),
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
      bool keepFilter = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prefSolid = glassShouldUseSolid(ref, lowPerf: lowPerf);
    final solid = forceSolid || prefSolid;
    final keepFilterAlive = forceSolid && !prefSolid;
    final wallpaper = wallpaperGlassActive(ref);
    final bg = solid
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (wallpaper
            ? wallpaperNavGlassFill(context)
            : (isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.52)));
    final fill =
        (budget == null || solid || wallpaper) ? bg : surfaceFillWithBudget(bg, budget);
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
    if (solid && !keepFilterAlive) return capsule;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: cheapBackdropBlur(sigma),
        child: capsule,
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
                    closeLandscapeSearch(ref);
                    ref.read(landscapeLibraryProvider.notifier).state = j;
                  },
                ),
            ],
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
    _moveC?.dispose();
    _springTickerC?.dispose();
    _pressC?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = bottomNavItems;
    return AnimatedBuilder(
      animation: Listenable.merge([_move, _press]),
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
          k = math.min(k, maxH / dropH);
        }
        final stretchX = _dragging ? _sxPos : 0.0;
        final stretchY = _dragging ? _syPos : 0.0;
        final sx = k * (1 + stretchX);
        final sy = k * (1 + stretchY);

        final d = dropH;
        final bool scaledIndicator = overlayDroplet;
        final dropletOn = _dragging || pressG > 0.005 || dragMf > 0.005;
        Widget indicator;
        if (widget.lens && dropletOn) {
          final band = d * 10.0 / 56.0 * mf * widget.edgeBoost;
          final amount = d * 14.0 / 56.0 * mf * widget.lensBoost;
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
          return Stack(
            clipBehavior: Clip.none,
            children: [
              widget.glassBuilder!(SizedBox(height: maxH, child: gestures)),
              Positioned(
                left: cx - w / 2,
                top: maxH / 2 - h / 2,
                width: w,
                height: h,
                child: IgnorePointer(
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(0, 1, _dragVel.sign * _sxPos * 0.12),
                  child: indicator,
                ),
              ),
              ),
            ],
          );
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

class _NavTab extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
              : ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: cheapBackdropBlur(panelSigma),
                    child: panelBox,
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
