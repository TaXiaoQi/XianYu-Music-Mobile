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
import 'animated_branch_container.dart';
import 'shell.dart';

/// 主路由：底部导航使用 StatefulShellRoute 保持各 tab 状态。
final appRouter = GoRouter(
  initialLocation: '/home',
  routes: [
    StatefulShellRoute(
      builder: (context, state, navigationShell) {
        return AppShell(navigationShell: navigationShell);
      },
      // 自定义分支容器：替代默认 IndexedStack（瞬切无动画），
      // 用淡入淡出 + 轻微缩放做过渡，同时保留每个 tab 的状态。
      navigatorContainerBuilder: (context, navigationShell, children) {
        return AnimatedBranchContainer(
          currentIndex: navigationShell.currentIndex,
          children: children,
        );
      },
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomePage(),
            // 收藏 / 最近作为主页子路由：保留底栏与迷你播放条，
            // 并能正确入栈（自带返回按钮、系统返回键回主页）。
            routes: [
              GoRoute(
                path: 'favorites',
                builder: (context, state) => const FavoritesPage(),
              ),
              GoRoute(
                path: 'recent',
                builder: (context, state) => const RecentPage(),
              ),
              // 搜索页：底栏已移除该入口（主界面顶部有搜索栏），
              // 保留为主页子路由，push 进入自带返回按钮。
              GoRoute(
                path: 'search',
                builder: (context, state) => const SearchPage(),
              ),
            ],
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
            path: '/settings',
            builder: (context, state) => const SettingsPage(),
            // 账号页作为设置子路由，同样保留底栏与迷你播放条。
            routes: [
              GoRoute(
                path: 'account',
                builder: (context, state) => const AccountPage(),
              ),
            ],
          ),
        ]),
      ],
    ),
    // 播放页为全屏覆盖，不占底部导航。
    GoRoute(
      path: '/player',
      builder: (context, state) => const PlayerPage(),
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

// 搜索不在底栏（主界面顶部已有搜索栏），顺序与 shell 分支一一对应。
const bottomNavItems = [
  BottomNavItem('主界面', Icons.home, '/home'),
  BottomNavItem('音乐库', Icons.library_music, '/library'),
  BottomNavItem('音效', Icons.graphic_eq, '/effects'),
  BottomNavItem('设置', Icons.settings, '/settings'),
];
