import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../pages/home/home_page.dart';
import '../../pages/library/library_page.dart';
import '../../pages/effects/effects_page.dart';
import '../../pages/search/search_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/account/account_page.dart';
import '../../pages/feedback/feedback_page.dart';
import '../../pages/about/about_page.dart';
import '../../pages/leaderboard/leaderboard_page.dart';
import '../../pages/sync/sync_page.dart';
import '../../pages/plugin/plugin_page.dart';
import '../../pages/playlist/playlists_page.dart';
import 'shell.dart';

/// 主路由：底部导航使用 StatefulShellRoute 保持各 tab 状态。
final appRouter = GoRouter(
  initialLocation: '/home',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return AppShell(navigationShell: navigationShell);
      },
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomePage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/library',
            builder: (context, state) => const LibraryPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/effects',
            builder: (context, state) => const EffectsPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/search',
            builder: (context, state) => const SearchPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsPage(),
          ),
        ]),
      ],
    ),
    // 播放页为全屏覆盖，不占底部导航。
    GoRoute(
      path: '/player',
      builder: (context, state) => const PlayerPage(),
    ),
    // 账号页（从设置页进入）。
    GoRoute(
      path: '/account',
      builder: (context, state) => const AccountPage(),
    ),
    // 意见反馈页（从设置页进入）。
    GoRoute(
      path: '/feedback',
      builder: (context, state) => const FeedbackPage(),
    ),
    // 关于页（从设置页进入）。
    GoRoute(
      path: '/about',
      builder: (context, state) => const AboutPage(),
    ),
    // 听歌排行榜（从设置页进入）。
    GoRoute(
      path: '/leaderboard',
      builder: (context, state) => const LeaderboardPage(),
    ),
    // 同步与备份（从设置页进入）。
    GoRoute(
      path: '/sync',
      builder: (context, state) => const SyncPage(),
    ),
    // 插件管理（从设置页进入）。
    GoRoute(
      path: '/plugin',
      builder: (context, state) => const PluginPage(),
    ),
    // 我的歌单（从设置页进入）。
    GoRoute(
      path: '/playlists',
      builder: (context, state) => const PlaylistsPage(),
    ),
    // 收藏 / 最近（主页网格进入）。
    GoRoute(
      path: '/favorites',
      builder: (context, state) => const FavoritesPage(),
    ),
    GoRoute(
      path: '/recent',
      builder: (context, state) => const RecentPage(),
    ),
  ],
);

// 底部导航条目（配合导航栏）
class BottomNavItem {
  final String title;
  final IconData icon;
  final String location;
  const BottomNavItem(this.title, this.icon, this.location);
}

const bottomNavItems = [
  BottomNavItem('主界面', Icons.home, '/home'),
  BottomNavItem('音乐库', Icons.library_music, '/library'),
  BottomNavItem('音效', Icons.graphic_eq, '/effects'),
  BottomNavItem('搜索', Icons.search, '/search'),
  BottomNavItem('设置', Icons.settings, '/settings'),
];
