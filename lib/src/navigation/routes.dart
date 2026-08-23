import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/gen/app_localizations.dart';

import '../../pages/home/home_page.dart';
import '../../pages/home/daily_recommend_page.dart';
import '../../pages/home/top_lists_page.dart';
import '../../pages/home/online_detail_page.dart';
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
import '../../pages/download/download_page.dart';
import '../../pages/settings/batch_rename_page.dart';
import '../../pages/settings/scan_folders_page.dart';
import '../../pages/remote/remote_library_page.dart';
import '../../pages/tools/qmc_decrypt_page.dart';
import '../../pages/wallpaper/wallpaper_center_page.dart';
import '../../pages/recognize/recognize_page.dart';
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
          ),
        ]),
      ],
    ),
    // 搜索页（从主页搜索栏进入）。
    GoRoute(
      path: '/search',
      builder: (context, state) => const SearchPage(),
    ),
    // 听歌识曲（从搜索页进入）。
    GoRoute(
      path: '/recognize',
      builder: (context, state) => const RecognizePage(),
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
    // 下载管理（从设置页进入）。
    GoRoute(
      path: '/download',
      builder: (context, state) => const DownloadPage(),
    ),
    // 壁纸中心（从设置页进入）。
    GoRoute(
      path: '/wallpaper',
      builder: (context, state) => const WallpaperCenterPage(),
    ),
    // 批量重命名（从设置页进入）。
    GoRoute(
      path: '/batch-rename',
      builder: (context, state) => const BatchRenamePage(),
    ),
    // 扫描文件夹（从设置页进入）。
    GoRoute(
      path: '/scan-folders',
      builder: (context, state) => const ScanFoldersPage(),
    ),
    // 远程音乐库 WebDAV 管理（从设置页进入）。
    GoRoute(
      path: '/remote-library',
      builder: (context, state) => const RemoteLibraryPage(),
    ),
    // QMC 独立文件解密（从设置页进入）。
    GoRoute(
      path: '/qmc-decrypt',
      builder: (context, state) => const QmcDecryptPage(),
    ),
    // 每日推荐（首页发现区进入）。
    GoRoute(
      path: '/home/daily',
      builder: (context, state) => const DailyRecommendPage(),
    ),
    // 音源榜单（首页发现区进入）。
    GoRoute(
      path: '/home/toplists',
      builder: (context, state) => const TopListsPage(),
    ),
    // 在线详情：歌手/专辑/歌单/榜单（参数经 extra 传递）。
    GoRoute(
      path: '/online-detail',
      builder: (context, state) {
        final args = state.extra as OnlineDetailArgs;
        return OnlineDetailPage(args: args);
      },
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
  BottomNavItem('设置', Icons.settings, '/settings'),
];

/// 底栏/侧栏导航项标题（跟随当前本地化语言）。
String navTitle(BuildContext context, BottomNavItem item) {
  final l = AppLocalizations.of(context);
  return switch (item.location) {
    '/home' => l.navHome,
    '/library' => l.navLibrary,
    '/effects' => l.navEffects,
    _ => l.navSettings,
  };
}
