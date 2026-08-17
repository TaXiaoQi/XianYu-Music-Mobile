import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../pages/library/library_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/account/account_page.dart';
import 'shell.dart';

/// 主路由：底部导航使用 StatefulShellRoute 保持各 tab 状态。
final appRouter = GoRouter(
  initialLocation: '/library',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return AppShell(navigationShell: navigationShell);
      },
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/library',
            builder: (context, state) => const LibraryPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/favorites',
            builder: (context, state) => const FavoritesPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/recent',
            builder: (context, state) => const RecentPage(),
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
  BottomNavItem('音乐库', Icons.library_music, '/library'),
  BottomNavItem('收藏', Icons.favorite, '/favorites'),
  BottomNavItem('最近', Icons.history, '/recent'),
  BottomNavItem('设置', Icons.settings, '/settings'),
];