import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../core/application_logger.dart';
import '../auth/auth_provider.dart';
import '../widgets/predictive_back_transitions.dart';
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
import '../../pages/recognize/recognize_page.dart';
import '../../pages/scan/scan_page.dart';
import '../../pages/scan/tv_login_confirm_page.dart';
import '../../pages/deeplink/song_share_bridge.dart';
import '../../pages/debug/debug_page.dart';
import 'shell.dart';
import '../i18n/i18n.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

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
              builder: (context, state) =>
                  const _ShellTabEntry(child: HomePage()),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/mine',
              builder: (context, state) =>
                  const _ShellTabEntry(child: MinePage()),
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
      ),
    ),
    GoRoute(
      path: '/search/result',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const SearchResultPage(),
        key: state.pageKey,
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
          (_) => SongListPage(title: args.title, loader: args.loader),
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
      path: '/player',
      pageBuilder: (context, state) {
        final predictiveBack =
            ProviderScope.containerOf(
              context,
              listen: false,
            ).read(settingsProvider).valueOrNull?.enablePredictiveBack ??
            true;
        return _PlayerCoverPage(
          key: state.pageKey,
          predictiveBack: predictiveBack,
          builder: (_) => const PlayerPage(),
        );
      },
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
        (_) => KeyedSubtree(
          key: musicLibraryPageKeys[3],
          child: const PlaylistsPage(),
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
        (_) => const DownloadPage(),
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
  const BottomNavItem(this.title, this.icon, this.location);
}

final List<BottomNavItem> bottomNavItems = [
  BottomNavItem(tr('首页'), Icons.home, '/home'),
  BottomNavItem(tr('我的'), Icons.person_outline_rounded, '/mine'),
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
  const _ShellTabEntry({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isLandscapeProvider)) return child;
    return AppPageBackground(child: child);
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
        child: child,
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
}) {
  return _CoverPage(
    key: key,
    builder: builder,
    predictiveBack: _enablePredictiveBack(context),
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
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
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
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  bool get popGestureEnabled => isCurrent && predictiveBack;

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
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeOutCubic.flipped,
                ),
                child: child,
              );
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: page,
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
      builder: builder,
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
  bool get popGestureEnabled => isCurrent && predictiveBack;

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
    return builder(context);
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
        final exit = SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: curved,
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
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverBackRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
    );
  }
}

class _CoverBackRoute extends PageRoute<void> with _CoverGestureCommit<void> {
  _CoverBackRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  bool get popGestureEnabled => isCurrent && predictiveBack;

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
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeOutCubic.flipped,
                ),
                child: child,
              );
        final transition = SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: page,
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
