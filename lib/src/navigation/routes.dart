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

part 'routes_player_host.dart';
part 'routes_shell.dart';
part 'routes_cover.dart';
part 'routes_player_cover.dart';

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
