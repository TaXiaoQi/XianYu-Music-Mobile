import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_logger.dart';

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

/// root navigator 的 key。
///
/// 全屏二级页（收藏/最近/搜索/账号）必须挂在 root navigator 上
/// （GoRoute.parentNavigatorKey 指向它）：若留在 branch 内部 navigator，
/// 预测性返回开启时系统返回会 pop root 栈顶的 shell route 导致直接回桌面。
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

/// 主路由：底部导航使用 StatefulShellRoute 保持各 tab 状态。
final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/home',
  // 诊断日志：记录 root navigator 上的路由进出。
  observers: [DiagRouteObserver('root')],
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
        StatefulShellBranch(
          observers: [DiagRouteObserver('home')],
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const HomePage(),
              // 收藏 / 最近 / 搜索作为主页子路由：parentNavigatorKey 指向 root，
              // 页面成为 root 栈顶、自己承接系统返回（预测性返回兼容）。
              routes: [
                GoRoute(
                  path: 'favorites',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (context, state) => const FavoritesPage(),
                ),
                GoRoute(
                  path: 'recent',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (context, state) => const RecentPage(),
                ),
                GoRoute(
                  path: 'search',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (context, state) => const SearchPage(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          observers: [DiagRouteObserver('library')],
          routes: [
            GoRoute(
              path: '/library',
              builder: (context, state) => const LibraryPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          observers: [DiagRouteObserver('effects')],
          routes: [
            GoRoute(
              path: '/effects',
              builder: (context, state) => const EffectsPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          observers: [DiagRouteObserver('settings')],
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsPage(),
              // 账号页同理挂 root navigator，返回时 pop 自己而不是 shell。
              routes: [
                GoRoute(
                  path: 'account',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (context, state) => const AccountPage(),
                ),
              ],
            ),
          ],
        ),
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
