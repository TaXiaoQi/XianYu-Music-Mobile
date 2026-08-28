import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../core/application_logger.dart';
import '../widgets/predictive_back_transitions.dart';
import '../widgets/predictive_cover_return.dart';
import '../widgets/predictive_back_tab_switch.dart';
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
import '../../pages/wallpaper/wallpaper_center_page.dart';
import '../../pages/recognize/recognize_page.dart';
import '../../pages/debug/debug_page.dart';
import 'shell.dart';
import '../i18n/i18n.dart';

/// 主路由：底部导航使用 StatefulShellRoute 保持各 tab 状态。
final appNavigatorKey = GlobalKey<NavigatorState>();
final appRouter = GoRouter(
  navigatorKey: appNavigatorKey,
  observers: [AppLogRouteObserver()],
  initialLocation: '/home',
  routes: [
    StatefulShellRoute(
      builder: (context, state, navigationShell) {
        return AppShell(navigationShell: navigationShell);
      },
      navigatorContainerBuilder: (context, navigationShell, children) {
        return PredictiveBackTabContainer(
          navigationShell: navigationShell,
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
      ],
    ),
    // 设置页（从「我的」页菜单与首页顶栏进入，二级推入页）。
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const SettingsPage(),
        key: state.pageKey,
      ),
    ),
    // 音效页（原底部导航项，现为二级推入页，从传统播放页「音效」入口进入）。
    GoRoute(
      path: '/effects',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const EffectsPage(),
        key: state.pageKey,
      ),
    ),
    // 搜索页（从主页搜索栏进入）。
    GoRoute(
      path: '/search',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const SearchPage(),
        key: state.pageKey,
      ),
    ),
    // 搜索结果页（搜索页提交后进入，独立路由以承载迷你播放条）。
    GoRoute(
      path: '/search/result',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const SearchResultPage(),
        key: state.pageKey,
      ),
    ),
    // 音乐库（从「我的」页与主页网格进入）：tab=0 全部 / 1 歌手 / 2 专辑 / 3 文件夹。
    GoRoute(
      path: '/library',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => LibraryPage(
          initialTab:
              int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
        ),
        key: state.pageKey,
      ),
    ),
    // 听歌识曲（从搜索页进入）。
    GoRoute(
      path: '/recognize',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const RecognizePage(),
        key: state.pageKey,
      ),
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
    GoRoute(path: '/account', pageBuilder: (context, state) => _coverPage(
      context,
      (_) => const AccountPage(),
      key: state.pageKey,
    )),
    // 账号设置页（从设置导航页进入）。需注册在 /settings/:category 之前，
    // 否则会被分类路由捕获。
    GoRoute(
      path: '/settings/account',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AccountSettingsPage(),
        key: state.pageKey,
      ),
    ),
    // 设置分类详情页（从设置导航页进入）。压在根 Navigator 上，
    // 避免 StatefulShellBranch 嵌套 Navigator 导致预测返回动画失效。
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
    // 意见反馈页（从设置页进入）。
    GoRoute(
      path: '/feedback',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const FeedbackPage(),
        key: state.pageKey,
      ),
    ),
    // 关于页（从设置页进入）。
    GoRoute(
      path: '/about',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AboutPage(),
        key: state.pageKey,
      ),
    ),
    // 调试页（关于页版本号连点 5 次进入）。
    GoRoute(
      path: '/debug',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const DebugPage(),
        key: state.pageKey,
      ),
    ),
    // 听歌排行榜（从设置页进入）。
    GoRoute(
      path: '/leaderboard',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const LeaderboardPage(),
        key: state.pageKey,
      ),
    ),
    // 插件管理（从设置页进入）。
    GoRoute(
      path: '/plugin',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const PluginPage(),
        key: state.pageKey,
      ),
    ),
    // 我的歌单（从设置页进入）。
    GoRoute(
      path: '/playlists',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const PlaylistsPage(),
        key: state.pageKey,
      ),
    ),
    // 导入歌单（从「我的」页进入）：备份文件 / 本地文件 / 云端导入。
    GoRoute(
      path: '/playlist-import',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const PlaylistImportPage(),
        key: state.pageKey,
      ),
    ),
    // 自建歌单详情（从「我的」页与歌单列表进入）。注册为顶层 GoRoute 压在
    // root navigator 上，使 GoRouter.canPop() 如实反映栈深——若用裸
    // Navigator.pop 压进 branch 内部 Navigator，返回会被 shell 误判而直接退出。
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
    // 收藏 / 最近（主页网格与「我的」页进入）。收藏页 tab=0 单曲 / 1 歌单 / 2 专辑。
    GoRoute(
      path: '/favorites',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => FavoritesPage(
          initialTab:
              int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/recent',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const RecentPage(),
        key: state.pageKey,
      ),
    ),
    // 下载管理（从设置页进入）。
    GoRoute(
      path: '/download',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const DownloadPage(),
        key: state.pageKey,
      ),
    ),
    // 壁纸中心（从设置页进入）。
    GoRoute(
      path: '/wallpaper',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const WallpaperCenterPage(),
        key: state.pageKey,
      ),
    ),
    // 批量重命名（从设置页进入）。
    GoRoute(
      path: '/batch-rename',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const BatchRenamePage(),
        key: state.pageKey,
      ),
    ),
    // 扫描目录管理已合并到本地库「文件夹」页（/library?tab=3），原独立页已删除。
    // 远程音乐库 WebDAV 管理（从设置页进入）。
    GoRoute(
      path: '/remote-library',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const RemoteLibraryPage(),
        key: state.pageKey,
      ),
    ),
    // QMC 独立文件解密（从设置页进入）。
    GoRoute(
      path: '/qmc-decrypt',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const QmcDecryptPage(),
        key: state.pageKey,
      ),
    ),
    // 每日推荐（首页发现区进入）。
    GoRoute(
      path: '/home/daily',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const DailyRecommendPage(),
        key: state.pageKey,
      ),
    ),
    // 音源榜单（首页发现区进入）。
    GoRoute(
      path: '/home/toplists',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const TopListsPage(),
        key: state.pageKey,
      ),
    ),
    // 在线详情：歌手/专辑/歌单/榜单（参数经 extra 传递）。
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

// 底部导航条目（配合导航栏）
class BottomNavItem {
  final String title;
  final IconData icon;
  final String location;
  const BottomNavItem(this.title, this.icon, this.location);
}

get bottomNavItems => [
  BottomNavItem(tr('首页'), Icons.home, '/home'),
  BottomNavItem(tr('我的'), Icons.person_outline_rounded, '/mine'),
];

/// 底栏/侧栏导航项标题（跟随当前本地化语言）。
/// 用可空版 Localizations.of：生成的 AppLocalizations.of 内含 !，在无
/// Localizations 祖先的 context（如预热沙盒）调用会空指针崩溃。
String navTitle(BuildContext context, BottomNavItem item) {
  final l = Localizations.of<AppLocalizations>(context, AppLocalizations);
  return switch (item.location) {
    '/home' => l?.navHome ?? tr('首页'),
    '/mine' => l?.navMine ?? tr('我的'),
    _ => l?.navEffects ?? tr('音效'),
  };
}

/// 构建带「预测返回封面回拨」的普通二级页 [Page]。
///
/// 供收藏/本地/歌单等含迷你播放条的列表页使用，让它们在预测返回手势中也
/// 出现封面飞回播放条，与普通返回一致。读取全局预测返回开关。
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

/// 通用设置类二级页的覆盖式路由封装：无封面回拨、`opaque=false`，
/// 覆盖滑动动画期间下层真实绘制自带底色，返回时实时透出下层页面。
Page<void> _coverPage(
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
  return _CoverPage(
    key: key,
    builder: builder,
    predictiveBack: predictiveBack,
  );
}

/// 通用设置类覆盖页（无封面回拨，供设置链页面使用）。
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

/// 通用设置类覆盖路由：覆盖滑动 + 预测返回，`opaque=false`。
class _CoverRoute extends PageRoute<void> {
  _CoverRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  bool get popGestureEnabled => isCurrent && predictiveBack;

  // 非不透明：动画期间下层真实绘制并自带底色，返回时实时透出下层页面。
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
    // 始终挂载预测返回手势认领；非手势走覆盖滑动。
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (popGestureInProgress) {
          return PredictiveBackSharedElementPageTransition(
            animation: animation,
            phase: phase,
            secondaryAnimation: secondaryAnimation,
            startBackEvent: startBackEvent,
            currentBackEvent: currentBackEvent,
            child: child,
          );
        }
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }
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

  // 覆盖式路由设为非不透明，动画期间下层页面真实绘制并自带底色，
  // 返回/进入时实时透出下层，避免「动画结束下层才加载」。
  @override
  bool get opaque => false;

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
    // 必须「始终」挂载 PredictiveBackGestureDetector 认领系统预测返回手势，
    // 否则边缘滑动无跟手行程直接 pop。手势中走官方 predictive 过渡（整屏缩放
    // 跟手），非手势的打开/关闭保持「从下往上覆盖 + 淡入淡出」。
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (popGestureInProgress) {
          return Stack(
            children: [
              PredictiveBackSharedElementPageTransition(
                animation: animation,
                phase: phase,
                secondaryAnimation: secondaryAnimation,
                startBackEvent: startBackEvent,
                currentBackEvent: currentBackEvent,
                child: child,
              ),
              // 预测返回手势中叠加「封面飞回播放条」：随手指进度把大封面缩向
              // 迷你条封面位置，把系统预测行程与原有封面回拨语义统一。
              PredictiveCoverReturnView(animation: animation),
            ],
          );
        }
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        // 上滑覆盖 + 淡入淡出：打开时淡入上滑，收回时下移渐隐，
        // 与全局 FadeForwards 转场风格保持一致，避免纯平移显得生硬。
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

/// 普通二级页面（收藏/本地/歌单…）预测返回的封面回拨包装。
///
/// 这些页面用主题默认转场（Android 下为 FadeForwards + 框架预测返回整屏缩放），
/// 预测返回时封面不会飞回播放条。本包装让它们在保持既有 FadeForwards 观感的同时，
/// 在预测返回手势中叠加 [PredictiveCoverReturnView]，复现普通返回的封面回拨。
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

class _CoverBackRoute extends PageRoute<void> {
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
    // 必须「始终」挂载 PredictiveBackGestureDetector 认领系统预测返回手势；
    // 手势中渲染官方 predictive 过渡（整屏缩放跟手）+ 封面回拨叠加，
    // 非手势的打开/关闭沿用覆盖式滑动，观感与普通二级页保持一致。
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (popGestureInProgress) {
          return Stack(
            children: [
              PredictiveBackSharedElementPageTransition(
                animation: animation,
                phase: phase,
                secondaryAnimation: secondaryAnimation,
                startBackEvent: startBackEvent,
                currentBackEvent: currentBackEvent,
                child: child,
              ),
              // 预测返回手势中叠加「封面飞回播放条」。
              PredictiveCoverReturnView(animation: animation),
            ],
          );
        }
        // 覆盖式滑动：本页从右滑入盖住旧页，旧页静止。路由为不透明（opaque）
        // 关闭的覆盖式，动画期间下层绘制自带底色，无需再手动铺背景。
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }
}
