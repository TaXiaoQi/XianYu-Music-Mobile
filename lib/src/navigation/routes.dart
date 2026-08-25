import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../../l10n/gen/app_localizations.dart';

import '../../pages/home/home_page.dart';
import '../../pages/home/daily_recommend_page.dart';
import '../../pages/home/top_lists_page.dart';
import '../../pages/home/online_detail_page.dart';
import '../../pages/library/library_page.dart';
import '../../pages/mine/mine_page.dart';
import '../../pages/effects/effects_page.dart';
import '../../pages/search/search_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/settings/settings_category_page.dart';
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
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const HomePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/mine',
              builder: (context, state) => const MinePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/effects',
              builder: (context, state) => const EffectsPage(),
            ),
          ],
        ),
      ],
    ),
    // 设置页（从「我的」页菜单与首页顶栏进入，二级推入页）。
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
    // 搜索页（从主页搜索栏进入）。
    GoRoute(path: '/search', builder: (context, state) => const SearchPage()),
    // 音乐库（从「我的」页与主页网格进入）：tab=0 全部 / 1 歌手 / 2 专辑 / 3 文件夹。
    GoRoute(
      path: '/library',
      builder: (context, state) => LibraryPage(
        initialTab: int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
      ),
    ),
    // 听歌识曲（从搜索页进入）。
    GoRoute(
      path: '/recognize',
      builder: (context, state) => const RecognizePage(),
    ),
    // 播放页为全屏覆盖，不占底部导航。
    // 统一使用「从下往上覆盖」转场：打开时整页上滑覆盖，关闭时从上往下收回。
    // 开启预测返回时接管边缘返回手势做跟手行程（关闭的覆盖方向跟随手指向上下滑）。
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
    // 账号页（从「我的」页进入）。
    GoRoute(path: '/account', builder: (context, state) => const AccountPage()),
    // 设置分类详情页（从设置导航页进入）。压在根 Navigator 上，
    // 避免 StatefulShellBranch 嵌套 Navigator 导致预测返回动画失效。
    GoRoute(
      path: '/settings/:category',
      builder: (context, state) => SettingsCategoryPage(
        category: SettingsCategory.fromPath(
          state.pathParameters['category'] ?? 'general',
        ),
      ),
    ),
    // 意见反馈页（从设置页进入）。
    GoRoute(
      path: '/feedback',
      builder: (context, state) => const FeedbackPage(),
    ),
    // 关于页（从设置页进入）。
    GoRoute(path: '/about', builder: (context, state) => const AboutPage()),
    // 听歌排行榜（从设置页进入）。
    GoRoute(
      path: '/leaderboard',
      builder: (context, state) => const LeaderboardPage(),
    ),
    // 插件管理（从设置页进入）。
    GoRoute(path: '/plugin', builder: (context, state) => const PluginPage()),
    // 我的歌单（从设置页进入）。
    GoRoute(
      path: '/playlists',
      builder: (context, state) => const PlaylistsPage(),
    ),
    // 导入歌单（从「我的」页进入）：备份文件 / 本地文件 / 云端导入。
    GoRoute(
      path: '/playlist-import',
      builder: (context, state) => const PlaylistImportPage(),
    ),
    // 收藏 / 最近（主页网格与「我的」页进入）。收藏页 tab=0 单曲 / 1 歌单 / 2 专辑。
    GoRoute(
      path: '/favorites',
      builder: (context, state) => FavoritesPage(
        initialTab: int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
      ),
    ),
    GoRoute(path: '/recent', builder: (context, state) => const RecentPage()),
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
    // 扫描目录管理已合并到本地库「文件夹」页（/library?tab=3），原独立页已删除。
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
  BottomNavItem('首页', Icons.home, '/home'),
  BottomNavItem('我的', Icons.person_outline_rounded, '/mine'),
  BottomNavItem('音效', Icons.graphic_eq, '/effects'),
];

/// 底栏/侧栏导航项标题（跟随当前本地化语言）。
/// 用可空版 Localizations.of：生成的 AppLocalizations.of 内含 !，在无
/// Localizations 祖先的 context（如预热沙盒）调用会空指针崩溃。
String navTitle(BuildContext context, BottomNavItem item) {
  final l = Localizations.of<AppLocalizations>(context, AppLocalizations);
  return switch (item.location) {
    '/home' => l?.navHome ?? '首页',
    '/mine' => l?.navMine ?? '我的',
    _ => l?.navEffects ?? '音效',
  };
}

/// 播放页「从下往上覆盖」转场的 Page 封装（谓词返回用 [Page] 而非 [PageRoute]）。
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

/// 播放页覆盖路由：打开从底部上滑覆盖，关闭从上往下收回。
class _PlayerCoverRoute extends PageRoute<void> {
  _PlayerCoverRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  // 用户开启预测返回时才接管边缘返回手势，做跟手行程；否则关闭也走
  // 普通 pop，仍由反向覆盖（从上往下）动画收回。
  @override
  bool get popGestureEnabled => isCurrent && predictiveBack;

  @override
  bool get opaque => true;

  // 全屏不透明页，不透出遮罩（抽象要求实现，实际不使用）。
  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

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
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }
}
