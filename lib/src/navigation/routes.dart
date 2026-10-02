import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../core/application_logger.dart';
import '../auth/auth_provider.dart';
import '../widgets/predictive_back_transitions.dart';
import '../widgets/flying_cover.dart';
import '../widgets/predictive_cover_return.dart';
import '../widgets/predictive_back_tab_switch.dart';
import '../widgets/blur_budget.dart';
import '../widgets/custom_background.dart';
import '../widgets/route_static_snapshot.dart';
import '../../l10n/gen/app_localizations.dart';

import '../../pages/home/home_page.dart';
import '../../pages/home/daily_recommend_page.dart';
import '../../pages/home/top_lists_page.dart';
import '../../pages/home/online_detail_page.dart';
import '../../pages/library/library_page.dart';
import '../../pages/library/library_folder_page.dart';
import '../../pages/library/song_list_page.dart';
import '../../pages/mine/mine_page.dart';
import '../../pages/effects/effects_page.dart';
import '../../pages/search/search_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/settings/settings_category_page.dart';
import '../../pages/settings/account_settings_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/account/account_page.dart';
import '../../pages/feedback/feedback_page.dart';
import '../../pages/about/about_page.dart';
import '../../pages/leaderboard/leaderboard_page.dart';
import '../../pages/plugin/plugin_page.dart';
import '../../pages/playlist/playlists_page.dart';
import '../../pages/playlist/playlist_import_page.dart';
import '../../pages/download/download_page.dart';
import '../../pages/settings/batch_rename_page.dart';
import '../../pages/remote/remote_library_page.dart';
import '../../pages/tools/qmc_decrypt_page.dart';
import '../../pages/tools/audio_convert_page.dart';
import '../../pages/tools/audio_trim_page.dart';
import '../../pages/wallpaper/wallpaper_center_page.dart';
import '../../pages/theme/theme_center_page.dart';
import '../../pages/recognize/recognize_page.dart';
import '../../pages/scan/scan_page.dart';
import '../../pages/scan/tv_login_confirm_page.dart';
import '../../pages/deeplink/song_share_bridge.dart';
import '../../pages/debug/debug_page.dart';
import 'shell.dart';
import '../i18n/i18n.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

/// 播放页开合状态（五级模型第二级：顶层播放 Navigator）。
/// 播放页不经过 go_router（appRouter），独立在播放条之上，
/// 转场时物理盖过播放条；本通知供条显隐/深链接/投屏判断。
final playerOpenNotifier = ValueNotifier<bool>(false);

final playerNavigatorKey = GlobalKey<NavigatorState>();

/// 打开播放页（顶层 Navigator，物理盖过播放条）。
/// 替代原 appRouter.push('/player')：入口只翻转通知，
/// 真正插页由 PlayerNavigatorHost 的监听器完成——
/// 不持有从未挂载的孤儿 GlobalKey（那会让 openPlayer 静默失效）。
void openPlayer() {
  if (playerOpenNotifier.value) return;
  playerOpenNotifier.value = true;
}

/// 关闭播放页（走 Navigator.pop：转场 + 返程封面飞行照常触发）。
void closePlayer() {
  if (!playerOpenNotifier.value) return;
  playerNavigatorKey.currentState?.maybePop();
}

/// 播放页独立 Navigator 宿主：挂在 MaterialApp.builder 的 Stack 中，
/// 层级在 MiniPlayerOverlay（播放条）之上、飞行封面 Overlay 之下。
class PlayerNavigatorHost extends ConsumerStatefulWidget {
  const PlayerNavigatorHost({super.key});

  @override
  ConsumerState<PlayerNavigatorHost> createState() =>
      _PlayerNavigatorHostState();
}

class _PlayerNavigatorHostState extends ConsumerState<PlayerNavigatorHost>
    with WidgetsBindingObserver {
  bool _pageOpen = false;

  /// 开合单一同步点：任何入口翻转 playerOpenNotifier 后，
  /// 在这里统一插页/拔页（含构建期触发的帧末推迟保护）。
  void _onPlayerOpenChanged() {
    final open = playerOpenNotifier.value;
    if (!mounted || open == _pageOpen) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && playerOpenNotifier.value != _pageOpen) {
          setState(() => _pageOpen = playerOpenNotifier.value);
        }
      });
      return;
    }
    setState(() => _pageOpen = open);
  }

  void _syncClosed() {
    if (!_pageOpen) return;
    playerOpenNotifier.value = false; // 统一经监听器回调拔页
  }

  // 新版引擎把 Android back 映射为 escape KeyDown：
  // 用全局键盘监听（焦点无关），播放页内任何组件抢焦点都不影响拦截
  bool _onKey(KeyEvent event) {
    if (_pageOpen &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      playerNavigatorKey.currentState?.maybePop();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    PredictiveBackOffFallback.instance.ensureRegistered();
    _pageOpen = playerOpenNotifier.value; // 通知早于挂载时的兜底对齐
    playerOpenNotifier.addListener(_onPlayerOpenChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    playerOpenNotifier.removeListener(_onPlayerOpenChanged);
    super.dispose();
  }

  // Android 系统返回兜底：播放页不在 go_router 栈上，
  // go_router.popRoute() 返回 false 后会轮到本 observer 关闭播放页
  @override
  Future<bool> didPopRoute() async {
    if (_pageOpen) {
      playerNavigatorKey.currentState?.maybePop();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final predictiveBack = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.enablePredictiveBack)) ??
        true;
    return Navigator(
      key: playerNavigatorKey,
      // pages API 不允许空列表：常驻一个透明待机页兜底，
      // 播放页在其上插入/拔出（拔出后回到透明待机态）
      pages: [
        const _PlayerIdlePage(),
        if (_pageOpen)
          _PlayerCoverPage(
            key: const ValueKey('player-page'),
            predictiveBack: predictiveBack,
            builder: (_) => const PlayerPage(),
          ),
      ],
      onDidRemovePage: (page) {
        // 播放页被移除（pop 完成）：同步开合状态，条按返回节奏淡入
        if (page.key == const ValueKey('player-page')) {
          _syncClosed();
        }
      },
    );
  }
}

/// 播放 Navigator 的常驻待机页：满足 pages API 非空要求。
/// 故意不用 PageRouteBuilder——ModalRoute 的 barrier 会吸走其下
/// 所有触摸；裸 Route 无 barrier，纯透明占位不拦截任何事件。
class _PlayerIdlePage extends Page<void> {
  const _PlayerIdlePage();

  @override
  Route<void> createRoute(BuildContext context) =>
      _PlayerIdleRoute(settings: this);
}

class _PlayerIdleRoute extends Route<void> {
  _PlayerIdleRoute({super.settings});

  final OverlayEntry _entry =
      OverlayEntry(builder: (_) => const SizedBox.shrink());

  @override
  List<OverlayEntry> get overlayEntries => <OverlayEntry>[_entry];
}

/// 预测返回手势的兜底认领者。
///
/// 引擎只在有认领者时才派发 commit：各路由 detector 因预测关闭、根部
/// （无可弹路由）或任何 popGestureEnabled=false 而 decline 时，若无人
/// 认领，commit 不进 Dart，系统按默认行为直接 finish 退出应用。
/// 这里无条件兜底认领（observer 逆序遍历中 detector 先被问，认领时
/// 轮不到这里），commit 时按经典返回处理（播放页优先，其余走 go_router
/// 栈：pop 二级页 / 切回主 tab / 再按一次退出）。
class PredictiveBackOffFallback with WidgetsBindingObserver {
  PredictiveBackOffFallback._();

  static final PredictiveBackOffFallback instance =
      PredictiveBackOffFallback._();

  static bool _registered = false;

  void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    WidgetsBinding.instance.addObserver(instance);
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 按键返回走经典链路（escape KeyDown / popRoute），不认领
    if (backEvent.isButtonEvent) return false;
    // 兜底认领：observer 逆序遍历中，各路由的 detector（注册更晚）先被问，
    // detector 认领（预测开且该页 popGestureEnabled）时轮不到这里；
    // 全部 decline 时（预测关、根部、或任何 popGestureEnabled=false 的页面）
    // 由这里保住 commit 派发——否则引擎不派发 commit，系统按默认行为
    // 直接 finish 退出应用。commit 统一走 handleCommitBackGesture
    // （播放页优先，其余根栈 maybePop 回退到经典返回）
    return true;
  }

  @override
  void handleCommitBackGesture() {
    // 与 didPopRoute 同序：播放页优先，其余交给根栈
    // （shell 的 PopScope 决定 pop 二级页 / 切回主 tab / 再按一次退出）
    if (playerOpenNotifier.value) {
      playerNavigatorKey.currentState?.maybePop();
      return;
    }
    appNavigatorKey.currentState?.maybePop();
  }

  // 按键返回（引擎 popRoute）链路：handlePopRoute 按注册顺序遍历，
  // 本 observer 在 app initState 注册、先于 Router——播放页开着时
  // 先关播放页，防止根栈二级页被 go_router 抢先 pop（返回手势
  // 走 handleCommitBackGesture 已天然播放页优先，无此问题）
  @override
  Future<bool> didPopRoute() async {
    if (playerOpenNotifier.value) {
      playerNavigatorKey.currentState?.maybePop();
      return true;
    }
    return false;
  }
}

final _branchKeys = <GlobalKey>[GlobalKey(), GlobalKey()];
final appRouter = GoRouter(
  navigatorKey: appNavigatorKey,
  observers: [AppLogRouteObserver(), TransitionTracker()],
  initialLocation: '/home',
  routes: [
    StatefulShellRoute(
      pageBuilder: (context, state, navigationShell) => _ShellPage(
        key: state.pageKey,
        navigationShell: navigationShell,
      ),
      navigatorContainerBuilder: (context, navigationShell, children) {
        return PredictiveBackTabContainer(
          navigationShell: navigationShell,
          currentIndex: navigationShell.currentIndex,
          children: [
            for (var i = 0; i < children.length && i < _branchKeys.length; i++)
              KeyedSubtree(key: _branchKeys[i], child: children[i]),
          ],
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const _ShellTabEntry(
                portraitPageId: 'home',
                landscapePageId: 'ls-home',
                child: HomePage(),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/mine',
              builder: (context, state) => const _ShellTabEntry(
                portraitPageId: 'mine',
                landscapePageId: 'ls-mine',
                child: MinePage(),
              ),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const SettingsPage(),
        key: state.pageKey,
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/effects',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const EffectsPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/search',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => SearchPage(
          initialQuery: state.uri.queryParameters['q'],
        ),
        key: state.pageKey,
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/search/result',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const SearchResultPage(),
        key: state.pageKey,
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/library',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => KeyedSubtree(
          key: musicLibraryPageKeys[0],
          child: LibraryPage(
            initialTab:
                int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
          ),
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/library/folders',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const LibraryFolderPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/song-list',
      pageBuilder: (context, state) {
        final args = state.extra as SongListArgs;
        return _coverBackPage(
          context,
          (_) => HideShellChrome(
            child: SongListPage(title: args.title, loader: args.loader),
          ),
          key: state.pageKey,
        );
      },
    ),
    GoRoute(
      path: '/recognize',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const RecognizePage(),
        key: state.pageKey,
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/scan',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const ScanPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/tv-login-confirm',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) {
          final extra = state.extra;
          final code = (extra is Map ? extra['code'] : null) as String? ?? '';
          final info =
              (extra is Map ? extra['info'] : null) as TvLoginScanInfo?;
          return TvLoginConfirmPage(code: code, info: info ?? const TvLoginScanInfo());
        },
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/shareBridge',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const SongShareBridgePage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/account',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AccountPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/account',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AccountSettingsPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/settings/:category',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => SettingsCategoryPage(
          category: SettingsCategory.fromPath(
            state.pathParameters['category'] ?? 'general',
          ),
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/feedback',
      pageBuilder: (context, state) {
        final tab =
            int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0;
        return _coverPage(
          context,
          (_) => FeedbackPage(initialTab: tab),
          key: state.pageKey,
        );
      },
    ),
    GoRoute(
      path: '/about',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AboutPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/debug',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const DebugPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/leaderboard',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const LeaderboardPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/plugin',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const PluginPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/playlists',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => HideShellChrome(
          child: KeyedSubtree(
            key: musicLibraryPageKeys[3],
            child: const PlaylistsPage(),
          ),
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/playlist-import',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const PlaylistImportPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/playlist/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => PlaylistDetailPage(
          playlistId: state.pathParameters['id'] ?? '',
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/favorites',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => KeyedSubtree(
          key: musicLibraryPageKeys[1],
          child: FavoritesPage(
            initialTab:
                int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
          ),
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/recent',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => KeyedSubtree(
          key: musicLibraryPageKeys[2],
          child: const RecentPage(),
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/download',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const HideShellChrome(child: DownloadPage()),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/wallpaper',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const WallpaperCenterPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/theme',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const ThemeCenterPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/batch-rename',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const BatchRenamePage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/remote-library',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const RemoteLibraryPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/qmc-decrypt',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const QmcDecryptPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/audio-convert',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AudioConvertPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/audio-trim',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AudioTrimPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/home/daily',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const DailyRecommendPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/home/toplists',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const TopListsPage(),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/online-detail',
      pageBuilder: (context, state) {
        final args = state.extra as OnlineDetailArgs;
        return _coverBackPage(
          context,
          (_) => OnlineDetailPage(args: args),
          key: state.pageKey,
        );
      },
    ),
  ],
);

class BottomNavItem {
  final String title;
  final IconData icon;
  final String location;

  /// 主题图标槽位 id；为 null 表示该导航项不参与主题换图。
  ///
  /// 保留 [icon] 不动、另加一个可选槽位，是为了让"未启用主题时渲染与之前完全
  /// 一致"这件事在类型层面就成立——不必把 IconData 改成可空或联合类型，
  /// 三个渲染点（底栏/侧栏/横屏 rail）也不需各自处理空值。
  final String? themeSlot;

  const BottomNavItem(this.title, this.icon, this.location, {this.themeSlot});
}

final List<BottomNavItem> bottomNavItems = [
  BottomNavItem(tr('首页'), Icons.home, '/home', themeSlot: 'nav.home'),
  BottomNavItem(tr('我的'), Icons.person_outline_rounded, '/mine',
      themeSlot: 'nav.settings'),
];

String navTitle(BuildContext context, BottomNavItem item) {
  final l = Localizations.of<AppLocalizations>(context, AppLocalizations);
  return switch (item.location) {
    '/home' => l?.navHome ?? tr('首页'),
    '/mine' => l?.navMine ?? tr('我的'),
    _ => l?.navEffects ?? tr('音效'),
  };
}

Page<void> _coverBackPage(
  BuildContext context,
  WidgetBuilder builder, {
  LocalKey? key,
  String? location,
}) {
  final predictiveBack =
      ProviderScope.containerOf(context, listen: false)
          .read(settingsProvider)
          .valueOrNull
          ?.enablePredictiveBack ??
      true;
  return _CoverBackPage(
    key: key,
    builder: builder,
    predictiveBack: predictiveBack,
    location: location,
  );
}

class _ShellPage extends Page<void> {
  const _ShellPage({required super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Route<void> createRoute(BuildContext context) {
    return _ShellRoute(page: this);
  }
}

class _ShellTabEntry extends ConsumerWidget {
  const _ShellTabEntry({
    required this.child,
    required this.portraitPageId,
    required this.landscapePageId,
  });

  final Widget child;

  /// 主题包每页壁纸的页面 id（竖屏 home/mine，横屏 ls-home/ls-mine）
  final String portraitPageId;
  final String landscapePageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final landscape = ref.watch(isLandscapeProvider);
    return PageWallpaperScope(
      pageId: landscape ? landscapePageId : portraitPageId,
      child: landscape ? child : AppPageBackground(child: child),
    );
  }
}

class _ShellRoute extends PageRoute<void> {
  _ShellRoute({required _ShellPage page}) : super(settings: page);

  StatefulNavigationShell get _navigationShell =>
      (settings as _ShellPage).navigationShell;

  @override
  bool get opaque => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: AppShell(navigationShell: _navigationShell),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_isSmooth(context)) {
      return _SmoothFadeForwards(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
    }
    return child;
  }
}

class _SmoothFadeForwards extends StatelessWidget {
  const _SmoothFadeForwards({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget? child;

  static final Animatable<Offset> _forwardTranslation = Tween<Offset>(
    begin: const Offset(0.25, 0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<Offset> _backwardTranslation = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(0.25, 0),
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<Offset> _secondaryForwardTranslation = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-0.25, 0),
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<Offset> _secondaryBackwardTranslation =
      Tween<Offset>(
    begin: const Offset(-0.25, 0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<double> _fadeOut = Tween<double>(
    begin: 1,
    end: 0,
  ).chain(CurveTween(curve: const Interval(0, 0.25)));

  static final Animatable<double> _fadeIn = Tween<double>(
    begin: 0,
    end: 1,
  ).chain(
    CurveTween(curve: const Interval(0, 0.75, curve: Curves.easeOutCubic)),
  );

  @override
  Widget build(BuildContext context) {
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, anim, child) => FadeTransition(
        opacity: _fadeIn.animate(anim),
        child: SlideTransition(
          position: _forwardTranslation.animate(anim),
          child: RouteStaticSnapshot(animation: anim, child: child!),
        ),
      ),
      reverseBuilder: (context, anim, child) => IgnorePointer(
        ignoring: anim.status == AnimationStatus.forward,
        child: FadeTransition(
          opacity: _fadeOut.animate(anim),
          child: SlideTransition(
            position: _backwardTranslation.animate(anim),
            child: RouteStaticSnapshot(animation: anim, child: child!),
          ),
        ),
      ),
      child: DualTransitionBuilder(
        animation: ReverseAnimation(secondaryAnimation),
        forwardBuilder: (context, anim, child) => FadeTransition(
          opacity: _fadeIn.animate(anim),
          child: SlideTransition(
            position: _secondaryBackwardTranslation.animate(anim),
            child: child,
          ),
        ),
        reverseBuilder: (context, anim, child) => FadeTransition(
          opacity: _fadeOut.animate(anim),
          child: SlideTransition(
            position: _secondaryForwardTranslation.animate(anim),
            child: child,
          ),
        ),
        // 被覆盖侧（壳层/旧界面）同样冻结为静态快照：此前只有主动画侧
        // （推入/弹出的页面）有 RouteStaticSnapshot，壳层的淡出/淡入
        // 全程 live 渲染——整壳 saveLayer + 壳内玻璃 BackdropFilter
        // 逐帧重采样，是转场卡顿主源。快照包在 Fade/Slide 之内，
        // 冻结图随转场一起淡出平移；state 稳定（不随方向重建）。
        child: RouteStaticSnapshot(
          animation: ReverseAnimation(secondaryAnimation),
          child: child!,
        ),
      ),
    );
  }
}

bool _enablePredictiveBack(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.enablePredictiveBack ??
    true;

bool _livePredictiveBack(BuildContext? context, bool fallback) {
  if (context == null) return fallback;
  return ProviderScope.containerOf(context, listen: false)
          .read(settingsProvider)
          .valueOrNull
          ?.enablePredictiveBack ??
      true;
}

PageTransitionStyle _pageTransitionStyle(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.pageTransitionStyle ??
    PageTransitionStyle.cover;

bool _isSmooth(BuildContext context) =>
    _pageTransitionStyle(context) == PageTransitionStyle.smooth;

Page<void> _coverPage(
  BuildContext context,
  WidgetBuilder builder, {
  LocalKey? key,
  String? location,
}) {
  return _CoverPage(
    key: key,
    builder: builder,
    predictiveBack: _enablePredictiveBack(context),
    location: location,
  );
}

PageRoute<T> coverPageRoute<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
}) {
  return _CoverRoute<T>(
    settings: settings ?? RouteSettings(),
    builder: builder,
    predictiveBack: _enablePredictiveBack(context),
  );
}

class _CoverPage extends Page<void> {
  const _CoverPage({
    super.key,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
      location: location,
    );
  }
}

mixin _CoverGestureCommit<T> on PageRoute<T> {
  @override
  void handleCommitBackGesture() {
    final AnimationController? ctrl = controller;
    navigator?.pop();
    if (ctrl != null && ctrl.isAnimating) {
      late final AnimationStatusListener listener;
      listener = (AnimationStatus status) {
        navigator?.didStopUserGesture();
        ctrl.removeStatusListener(listener);
      };
      ctrl.addStatusListener(listener);
    } else {
      navigator?.didStopUserGesture();
    }
  }
}

class _CoverRoute<T> extends PageRoute<T> with _CoverGestureCommit<T> {
  _CoverRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

  @override
  void install() {
    super.install();
    overlayEntries.first.opaque = opaque;
  }

  @override
  bool get opaque => true;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return AppPageBackground(child: builder(context));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (kFrameworkPredictiveCompare) {
      return const PredictiveBackPageTransitionsBuilder(
        fallbackColor: Colors.transparent,
      ).buildTransitions(this, context, animation, secondaryAnimation, child);
    }
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (_isSmooth(context)) {
          return _SmoothFadeForwards(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: child,
          );
        }
        final isPortrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        final curved = CurvedAnimation(
          parent: animation,
          curve: isPortrait ? Curves.linear : Curves.easeOut,
          reverseCurve: isPortrait ? Curves.linear : Curves.easeOut.flipped,
        );
        final begin = isPortrait ? const Offset(1, 0) : const Offset(0.25, 0);
        final page = isPortrait
            ? RouteStaticSnapshot(animation: animation, child: child)
            : FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0, 0.45, curve: Curves.easeOutCubic),
                  reverseCurve:
                      const Interval(0, 0.45, curve: Curves.easeOutCubic),
                ),
                child: child,
              );
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: RoutePageBackdrop(
            completion: animation,
            location: location,
            child: page,
          ),
        );
      },
    );
  }
}

class _PlayerCoverPage extends Page<void> {
  const _PlayerCoverPage({
    super.key,
    required this.builder,
    required this.predictiveBack,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  Route<void> createRoute(BuildContext context) {
    return _PlayerCoverRoute(
      settings: this,
      builder: (context) => PopScope<void>(
        canPop: true,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) return;
          // 预测返回手势全程已有封面回拨动画，跳过避免叠加
          if (PredictiveCoverReturn.instance.returning.value) return;
          final src = PredictiveCoverReturn.instance.sourceRect;
          if (src.isEmpty) return;
          final (sp, nu, tp) = PredictiveCoverReturn.instance.coverSource;
          // 普通返回：飞行期间同样隐藏播放页真封面（避免双封面），
          // flight 在落地瞬间完成，真封面恢复、副本淡出叠回
          final flight = FlyingCover.instance.launch(
            fromRect: src,
            songPath: sp,
            networkUrl: nu,
            thumbPath: tp,
            radius: (src.width * 0.08).clamp(6.0, 32.0).toDouble(),
            targetProvider: () =>
                FlyingCover.instance.targetRect ??
                PredictiveCoverReturn.instance.targetRect,
          );
          PredictiveCoverReturn.instance.returning.value = true;
          unawaited(flight.whenComplete(() {
            PredictiveCoverReturn.instance.returning.value = false;
          }));
        },
        child: builder(context),
      ),
      predictiveBack: predictiveBack,
    );
  }
}

class _PlayerCoverRoute extends PageRoute<void> with _CoverGestureCommit<void> {
  _PlayerCoverRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 450);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 播放页不走 go_router（无 matchedLocation），按当前方向映射页面 id
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return PageWallpaperScope(
      pageId: landscape ? 'ls-player' : 'player',
      child: builder(context),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final fade = CurvedAnimation(
          parent: animation,
          curve: const Interval(0, 0.45, curve: Curves.easeOut),
          reverseCurve: const Interval(0, 0.45, curve: Curves.easeIn),
        );
        final exit = SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: fade,
            child: RouteStaticSnapshot(animation: animation, child: child),
          ),
        );
        if (phase == PredictiveBackPhase.idle) {
          return exit;
        }
        return Stack(
          children: [
            exit,
            PredictiveCoverReturnView(animation: animation),
          ],
        );
      },
    );
  }
}

class _CoverBackPage extends Page<void> {
  const _CoverBackPage({
    super.key,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverBackRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
      location: location,
    );
  }
}

class _CoverBackRoute extends PageRoute<void> with _CoverGestureCommit<void> {
  _CoverBackRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

  @override
  bool get opaque => true;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return AppPageBackground(child: builder(context));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (kFrameworkPredictiveCompare) {
      return const PredictiveBackPageTransitionsBuilder(
        fallbackColor: Colors.transparent,
      ).buildTransitions(this, context, animation, secondaryAnimation, child);
    }
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (_isSmooth(context)) {
          final smooth = _SmoothFadeForwards(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: child,
          );
          if (phase == PredictiveBackPhase.idle) return smooth;
          return TransitionBackdrop(
            child: Stack(
              children: [
                smooth,
                PredictiveCoverReturnView(animation: animation),
              ],
            ),
          );
        }
        final isPortrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        final curved = CurvedAnimation(
          parent: animation,
          curve: isPortrait ? Curves.linear : Curves.easeOut,
          reverseCurve: isPortrait ? Curves.linear : Curves.easeOut.flipped,
        );
        final begin = isPortrait ? const Offset(1, 0) : const Offset(0.25, 0);
        final page = isPortrait
            ? RouteStaticSnapshot(animation: animation, child: child)
            : FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0, 0.45, curve: Curves.easeOutCubic),
                  reverseCurve:
                      const Interval(0, 0.45, curve: Curves.easeOutCubic),
                ),
                child: child,
              );
        final transition = SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: RoutePageBackdrop(
            completion: animation,
            location: location,
            child: page,
          ),
        );
        if (phase != PredictiveBackPhase.idle) {
          return Stack(
            children: [
              transition,
              PredictiveCoverReturnView(animation: animation),
            ],
          );
        }
        return transition;
      },
    );
  }
}
