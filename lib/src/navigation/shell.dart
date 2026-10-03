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
import '../widgets/custom_background.dart' show PageWallpaperScope;
import '../../pages/library/library_page.dart';
import '../../pages/library/library_folder_page.dart';
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
import 'dart:async';

part 'shell_mini_bar.dart';
part 'shell_back.dart';
part 'shell_landscape.dart';
part 'shell_bottom_bar.dart';
part 'shell_sliding_nav.dart';
part 'shell_side_rail.dart';

const double kFloatingNavBarInset = 90;

const double kLandscapeRailWidth = 176;
const double kLandscapeRailIconWidth = 60;
const double kLandscapeRailCollapseAt = 120;

final isLandscapeProvider = StateProvider<bool>((ref) => false);

final landscapeLibraryProvider = StateProvider<int?>((ref) => null);

final landscapeLibrarySearchActiveProvider = StateProvider<bool>(
  (ref) => false,
);

final landscapeLibraryQueryProvider = StateProvider<String>((ref) => '');

final landscapeLibrarySearchCtrlProvider = Provider<TextEditingController>((
  ref,
) {
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

final musicLibraryPageKeys = List<GlobalKey>.generate(5, (_) => GlobalKey());

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
          (_) => stale.image.dispose(),
        );
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

}

class _ShellScaffold extends ConsumerStatefulWidget {
  const _ShellScaffold({required this.navigationShell, required this.index});

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

  /// 悬浮 chrome（底栏/悬浮顶栏）完全隐藏后整树卸载。Impeller 下
  /// Opacity(0.01) 常绘子树的 alpha 泄漏——内容以约 10% 亮度透出，二级页上
  /// 残留底栏与选中圆形（与 mini 播放条幽灵 bar 同源，那里已用整树卸载修掉）
  bool _chromeGone = false;

  /// 重挂载恢复帧：隐式动画（AnimatedOpacity/AnimatedScale）首建不播动画，
  /// 挂回首帧若目标值已是 1.0/1.0 会硬切，需先以隐藏目标渲染一帧
  bool _chromeRecovering = false;

  /// 恢复窗口：停绘后挂回的首帧 backdrop 采样未就绪，降级磨砂防黑闪
  bool _chromeFading = false;

  bool? _lastChromeHidden;
  Timer? _chromeGoneTimer;
  Timer? _chromeFadeTimer;

  static const _rootPaths = {'/', '/home', '/mine'};

  static bool _isRootPathOf(String path) => _rootPaths.contains(path);

  /// hidden 变化时调度悬浮 chrome 的整树卸载/挂回：淡出动画（240ms）结束后
  /// 停绘，恢复时先挂回并按隐藏目标渲染一帧再翻回真实目标，保住淡入/缩放
  /// 隐式动画。与 mini 播放条 _syncBarGone 同构。
  void _syncChromeHidden() {
    if (!mounted) return;
    _syncChromeGone(
      ref.read(navBarHiddenProvider) > 0 || !ref.read(navOnRootPathProvider),
    );
  }

  void _syncChromeGone(bool hidden) {
    if (_lastChromeHidden == hidden) return;
    _lastChromeHidden = hidden;
    if (hidden) {
      _chromeGoneTimer?.cancel();
      _chromeGoneTimer = Timer(const Duration(milliseconds: 320), () {
        if (mounted) setState(() => _chromeGone = true);
      });
      // 缓存帧里含旧底栏与圆形：隐藏后它不再刷新，留着会被其它
      // useChromeFrame 玻璃面裁出残影——立即失效（宁缺勿错）
      final stale = chromeGlassFrame.value;
      if (stale != null) {
        chromeGlassFrame.value = null;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => stale.image.dispose(),
        );
      }
    } else {
      _chromeGoneTimer?.cancel();
      if (_chromeGone) {
        _chromeGone = false;
        _chromeRecovering = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _chromeRecovering = false);
        });
        _chromeFadeTimer?.cancel();
        _chromeFading = true;
        _chromeFadeTimer = Timer(const Duration(milliseconds: 280), () {
          if (mounted) setState(() => _chromeFading = false);
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _router = GoRouter.of(context);
    _isRootPath = _isRootPathOf(
      _routerTopPath(_router.routerDelegate.currentConfiguration),
    );
    ref.read(navOnRootPathProvider.notifier).state = _isRootPath;
    _router.routerDelegate.addListener(_onRouteChanged);
    // 悬浮 chrome 显隐驱动整树卸载/挂回：hidden = 计数 >0 || 非 root 路径，
    // 两路都要监听（二级页靠后者隐藏，计数不增）
    ref.listenManual(navBarHiddenProvider, (_, _) => _syncChromeHidden());
    ref.listenManual(navOnRootPathProvider, (_, _) => _syncChromeHidden());
    // 冷启动直接落在二级页时上面两个监听都不会触发，先同步一次
    _syncChromeGone(ref.read(navBarHiddenProvider) > 0 || !_isRootPath);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _rotationSub = const EventChannel(
        'xianyu/rotation/events',
      ).receiveBroadcastStream().listen(_onRotationEvent, onError: (_) {});
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
    _chromeGoneTimer?.cancel();
    _chromeFadeTimer?.cancel();
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
            '/library/folders',
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
    const libRoutes = [
      '/library',
      '/favorites',
      '/recent',
      '/playlists',
      '/library/folders',
    ];
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
          .routerDelegate
          .currentConfiguration
          .matches
          .any((m) => m is RouteMatch && m.matchedLocation == '/settings');
      if (hasSettingsBelow) {
        context.pop();
      } else {
        context.go('/settings');
      }
    } else if (libRoutes.contains(path)) {
      _rotateBackPath = path;
      _deferLibPaneMount();
      ref.read(landscapeLibraryProvider.notifier).state = libRoutes.indexOf(
        path,
      );
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
      ref.read(landscapePlaylistOpenProvider.notifier).state = path
          .split('/')
          .last;
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
    final landscape =
        screen == null || screen.size.width >= screen.size.height * 1.05;

    if (_lastImmersive != landscape) {
      _lastImmersive = landscape;
      _applyLandscapeImmersive(landscape);
    }
  }

  bool _lastImmersive = false;

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
        ref.watch(
          settingsProvider.select((s) => s.valueOrNull?.floatingNavBar),
        ) ??
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

    final floatingSearchBar = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false),
    );

    final useCameraArea =
        landscape &&
        ref.watch(
          settingsProvider.select(
            (s) => s.valueOrNull?.landscapeCameraArea ?? true,
          ),
        );

    final landscapeFadeEnabled =
        landscape &&
        ref.watch(
          settingsProvider.select(
            (s) => s.valueOrNull?.landscapeTransitionEnabled ?? true,
          ),
        );

    final libPaneMountable = landscape && _libPaneMountable;
    final Widget landscapeHome = Offstage(
      offstage: anyPaneOpen,
      child: EmbeddedShellScope(
        child: LandscapeTabSwitcher(
          currentIndex: libPaneMountable
              ? (libSel == null ? 0 : 1 + libSel)
              : 0,
          enabled: landscapeFadeEnabled,
          suppress: anyPaneOpen,
          children: [
            widget.navigationShell,
            if (libPaneMountable) ...[
              const _MusicLibraryPane(index: 0),
              const _MusicLibraryPane(index: 1),
              const _MusicLibraryPane(index: 2),
              const _MusicLibraryPane(index: 3),
              const _MusicLibraryPane(index: 4),
            ],
          ],
        ),
      ),
    );

    final hiddenCount = ref.watch(navBarHiddenProvider);
    final hidden = hiddenCount > 0 || !_isRootPath;

    // chrome 缓存帧抓取门控：竖屏悬浮 chrome（底栏/悬浮顶栏）可见且为
    // 液态材质时才允许抓帧，保证缓存帧里的 chrome 区域是有效液态输出
    chromeGlassFrameActive.value =
        !landscape &&
        !hidden &&
        (ref.watch(
              settingsProvider.select((s) => s.valueOrNull?.liquidGlass),
            ) ??
            true) &&
        !ref.watch(
          settingsProvider.select(
            (s) => performancePriority(s.valueOrNull ?? const AppSettings()),
          ),
        );

    void select(int i) {
      if (i == widget.navigationShell.currentIndex || i == widget.index) return;
      if (searchOpenRaw) closeLandscapeSearch(ref);
      ref.read(landscapeContentPathProvider.notifier).state = null;
      widget.navigationShell.goBranch(
        i,
        initialLocation: i == widget.navigationShell.currentIndex,
      );
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
              icon: themeSlotWidget(
                ref,
                'entry.wallpaper',
                fallback: const SkinIcon(),
              ),
              tooltip: tr('皮肤'),
              onPressed: () => context.push('/wallpaper'),
            ),
            const SizedBox(width: 16),
          ] else ...[
            IconButton(
              icon: themeSlotIcon(
                ref,
                'mine.settings',
                fallback: Icons.settings_outlined,
              ),
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
            _railWidth = (_railWidth + dx).clamp(
              leftSafe + kLandscapeRailIconWidth,
              screenW * 0.5,
            );
          });
        },
      ),
    );

    final isSide =
        landscape ||
        (ref.watch(
              settingsProvider.select((s) => s.valueOrNull?.navBarPosition),
            ) ==
            NavBarPosition.side);

    final expanded = ref.watch(sideBarExpandedProvider);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
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
                                        ignoring: anyPaneOpen || libPaneActive,
                                        child: Opacity(
                                          opacity: anyPaneOpen || libPaneActive
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
                                      ignoring: anyPaneOpen || libPaneActive,
                                      child: Opacity(
                                        opacity: anyPaneOpen || libPaneActive
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
                                padding: padding.copyWith(left: 0, right: 0),
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
                opacity: (hidden || _chromeRecovering)
                    ? glassHiddenOpacityFloor(ref)
                    : 1.0,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  scale: (hidden || _chromeRecovering) ? 0.92 : 1.0,
                  child: IgnorePointer(
                    ignoring: hidden || _chromeRecovering,
                    // 淡出结束后整树卸载：Impeller 下 0.01 常绘子树的
                    // alpha 泄漏会让底栏与选中圆形残留在二级页上
                    child: _chromeGone
                        ? const SizedBox.shrink()
                        : _JellySwitch(
                            key: _jellyKey,
                            mode: true,
                            child: _LiquidNavBar(
                              index: widget.index,
                              onSelect: select,
                              degraded: _chromeFading || _chromeRecovering,
                            ),
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
                opacity:
                    (floatingSearchBar &&
                        (widget.index == 0 || widget.index == 1) &&
                        !hidden &&
                        !_chromeRecovering)
                    ? 1.0
                    : glassHiddenOpacityFloor(ref),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  // 与悬浮底栏同款缩小退让（0.92），退场不再只是淡出
                  scale:
                      (floatingSearchBar &&
                          (widget.index == 0 || widget.index == 1) &&
                          !hidden &&
                          !_chromeRecovering)
                      ? 1.0
                      : 0.92,
                  child: IgnorePointer(
                    ignoring:
                        !(floatingSearchBar &&
                            (widget.index == 0 || widget.index == 1) &&
                            !hidden &&
                            !_chromeRecovering),
                    child: _chromeGone
                        ? const SizedBox.shrink()
                        : FloatingTopBar(
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
                                  iconChild: themeSlotWidget(
                                    ref,
                                    'entry.wallpaper',
                                    fallback: const SkinIcon(),
                                  ),
                                  tooltip: tr('皮肤'),
                                  onTap: () => context.push('/wallpaper'),
                                )
                              else
                                BiliPaiIconButton(
                                  iconChild: themeSlotWidget(
                                    ref,
                                    'mine.settings',
                                    fallback: const Icon(
                                      Icons.settings_outlined,
                                    ),
                                  ),
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
                index: widget.index,
                hidden: hidden,
                onSelect: select,
              ),
            )
          : null,
      extendBody: !isSide && !floating,
    );
  }
}
