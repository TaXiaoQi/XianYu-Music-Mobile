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
import '../../pages/scan/scan_page.dart';
import '../../pages/scan/tv_login_confirm_page.dart';
import '../../pages/deeplink/song_share_bridge.dart';
import '../../pages/debug/debug_page.dart';
import 'shell.dart';
import '../i18n/i18n.dart';

/// 主路由：底部导航使用 StatefulShellRoute 保持各 tab 状态。
final appNavigatorKey = GlobalKey<NavigatorState>();
final appRouter = GoRouter(
  navigatorKey: appNavigatorKey,
  // TransitionTracker：push/pop 时标记全局转场，供 blur 预算在转场窗口降级。
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
          children: children,
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) =>
                  const AppPageBackground(child: HomePage()),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/mine',
              builder: (context, state) =>
                  const AppPageBackground(child: MinePage()),
            ),
          ],
        ),
      ],
    ),
    // 设置页（从「我的」页菜单与首页顶栏进入，二级推入页）。默认淡进淡出转场，
    // 与设置链路子页（账号/分类/关于等）统一，形成一致观感。
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
    // 搜索页（从主页搜索栏进入），搜索结果页另用独立路由承载迷你播放条。
    GoRoute(
      path: '/search',
      builder: (context, state) => const SearchPage(),
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
    // 扫码登录（从首页标题栏右侧扫码入口进入，扫描桌面端二维码）。
    GoRoute(
      path: '/scan',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const ScanPage(),
        key: state.pageKey,
      ),
    ),
    // 扫码确认登录（移动端扫到桌面端二维码后进入确认页）。
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
    // 瞬时桥接页：桌面组件「分享」钮拉起 App 后在此弹出当前歌曲分享菜单。
    GoRoute(
      path: '/shareBridge',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const SongShareBridgePage(),
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
    // 账号页（从「我的」页进入）。保留默认淡入淡出转场（淡出「应用在我的页和设置」）。
    GoRoute(
      path: '/account',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AccountPage(),
        key: state.pageKey,
      ),
    ),
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

/// 主 Shell 页（首页/我的）的自定义 [Page]：替代 go_router 默认的 MaterialPage，
/// 让旧页转场能随「切换动画」设置联动。
class _ShellPage extends Page<void> {
  const _ShellPage({required super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Route<void> createRoute(BuildContext context) {
    return _ShellRoute(page: this);
  }
}

/// 主 Shell 路由。
///
/// 根因：默认 MaterialPage 的 `MaterialRouteTransitionMixin.canTransitionTo`
/// 只对 Material 路由或带 `delegatedTransition` 的路由做旧页联动出场，而项目
/// 二级页是自定义 `_CoverRoute`（两者都不是），导致平滑模式下「我的/首页 →
/// 设置」时新页滑入、旧页 secondaryAnimation 恒为 dismissed 完全静止
/// （"平移只滑了半截"）。这里在平滑模式主动委托主题转场（FadeForwards 的
/// 旧页平移淡出），与新页入场对称，形成完整平移；覆盖模式保持旧页静止。
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
  Duration get transitionDuration => const Duration(milliseconds: 300);

  // 只对不透明整页路由（_CoverRoute/_CoverBackRoute）做旧页联动；
  // 弹窗（PredictiveBackDialogRoute 等，opaque=false）与播放页
  //（_PlayerCoverRoute，opaque=false）打开时下层保持静止，不跟随平移。
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
    // 平滑：委托主题默认转场（淡进淡出 + 原生平推），旧页平移淡出与新页
    // 滑入对称。转场时实时读取设置，改「切换动画」后立即生效。
    if (_isSmooth(context)) {
      return Theme.of(context).pageTransitionsTheme.buildTransitions(
        this,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    // 覆盖：旧页静止，由新页的覆盖滑动完成转场。
    return child;
  }
}

/// 通用二级页抽屉覆盖式路由封装：无封面回拨、`opaque=false`。
///
/// 抽屉覆盖（新页从右滑入盖住旧页）+ 返回贴手势露出下层，必须是
/// `opaque=false` 的路由，否则返回动画期间下层不绘制（MaterialPageRoute 固定
/// opaque）。

/// 读取全局预测返回开关。
bool _enablePredictiveBack(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.enablePredictiveBack ??
    true;

/// 读取全局页面切换动画风格（覆盖 / 平滑）。
PageTransitionStyle _pageTransitionStyle(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.pageTransitionStyle ??
    PageTransitionStyle.cover;

/// 转场时实时读取「是否为平滑模式」，避免路由创建时烘焙旧值导致切换不即时生效。
bool _isSmooth(BuildContext context) =>
    _pageTransitionStyle(context) == PageTransitionStyle.smooth;

/// 设置链路等普通二级页的纯平移路由（无封面回拨）。
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

/// 通用抽屉覆盖页（无封面回拨，供设置链路页面使用）。
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

/// 通用抽屉覆盖路由：覆盖滑动 + 预测返回，`opaque=false`。
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

  // 覆盖转场用 opaque=true：Flutter Overlay 对 opaque 路由在「转场动画期间」仍会
  // 绘制其下层（Cupertino 覆盖式转场即如此），动画结束后才隐藏下层。故声明
  // opaque=true 能同时满足——
  //  · 动画期间：下层真实绘制，返回时新页滑出、下层联动透出（抽屉覆盖效果保留）；
  //  · 静态：Overlay 跳过下层路由不绘制，页面的透明背景透出的是「根层壁纸/底色」，
  //    而非下层页面内容。
  // 此前用 opaque=false 会导致静态时下层路由持续绘制：壁纸(透明)模式下页面背景
  // 透明，下层「我的」等内容便永久穿透到设置页等二级页之上（「被覆盖的页面不消失」）。
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
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 内容面板背景透明，转场时由 buildTransitions 的固定全屏底色垫底。
    // 抽屉+壁纸模式下，页面直接烘焙壁纸为自身底色，成为不透明页，切换全程稳定。
    return AppPageBackground(child: builder(context));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 始终挂载预测返回手势认领；非手势走 FadeForwards 纯平移。
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        // 只信本路由认领的手势（phase 非 idle），不用 navigator 全局的
        // popGestureInProgress：上层弹窗提交后的几帧里该标志仍为 true，
        // 本页会误入跟手分支引发布局崩溃。
        if (phase != PredictiveBackPhase.idle) {
          // 预测返回缩放手势：透明页缩放会露出本路由透底层，同样铺壁纸/实色
          // 垫底，避免壁纸模式下缩放过程透见下层「穿模」。
          return TransitionBackdrop(
            child: PredictiveBackSharedElementPageTransition(
              animation: animation,
              phase: phase,
              secondaryAnimation: secondaryAnimation,
              startBackEvent: startBackEvent,
              currentBackEvent: currentBackEvent,
              child: child,
            ),
          );
        }
        // 平滑：委托主题默认转场（淡进淡出 + 原生平推）。这里在转场时实时
        // 读取设置，改「切换动画」后无需重进页面即可立即生效。
        if (_isSmooth(context)) {
          return Theme.of(context).pageTransitionsTheme.buildTransitions(
            this,
            context,
            animation,
            secondaryAnimation,
            child,
          );
        }
        // 覆盖：仅短距轻移（自约 1/4 宽入）。竖屏去掉淡入，否则转场中有几帧
        // 新旧页重叠透叠；横屏保持淡入+轻移，不动横屏观感。
        // 曲线用主题 FadeForwards 的原生同款 easeInOutCubicEmphasized
        //（缓起-加速-缓出，观感匀速顺滑）；easeOut 起步速度是匀速 2 倍、
        // 尾段急拖，前后段速度不一致。
        final isPortrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        final coverSlide = SlideTransition(
          position: animation.drive(
            Tween<Offset>(
              begin: const Offset(0.25, 0),
              end: Offset.zero,
            ).chain(
              CurveTween(
                curve: isPortrait
                    ? Curves.easeInOutCubicEmphasized
                    : Curves.easeOut,
              ),
            ),
          ),
          child: child,
        );
        if (isPortrait) {
          return coverSlide;
        }
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: coverSlide,
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
        // 只信本路由认领的手势（phase 非 idle），不用 navigator 全局的
        // popGestureInProgress：上层弹窗提交后的几帧里该标志仍为 true，
        // 本页会误入跟手分支引发布局崩溃。
        if (phase != PredictiveBackPhase.idle) {
          return TransitionBackdrop(
            child: Stack(
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
            ),
          );
        }
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        // 上滑覆盖 + 淡入淡出：打开时淡入上滑，收回时下移渐隐，
        // 与全局 FadeForwards 转场风格保持一致，避免纯平移显得生硬。
        return TransitionBackdrop(
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
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
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 内容面板背景透明，转场时由 buildTransitions 的固定全屏底色垫底。
    // 抽屉+壁纸模式下，页面直接烘焙壁纸为自身底色，成为不透明页，切换全程稳定。
    return AppPageBackground(child: builder(context));
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
        // 只信本路由认领的手势（phase 非 idle），不用 navigator 全局的
        // popGestureInProgress：上层弹窗提交后的几帧里该标志仍为 true，
        // 本页会误入跟手分支引发布局崩溃。
        if (phase != PredictiveBackPhase.idle) {
          return TransitionBackdrop(
            child: Stack(
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
            ),
          );
        }
        // 平滑：委托主题默认转场（淡进淡出 + 原生平推）。这里在转场时实时
        // 读取设置，改「切换动画」后无需重进页面即可立即生效。
        if (_isSmooth(context)) {
          return Theme.of(context).pageTransitionsTheme.buildTransitions(
            this,
            context,
            animation,
            secondaryAnimation,
            child,
          );
        }
        // 覆盖：仅短距轻移（自约 1/4 宽入）。竖屏去掉淡入，否则转场中有几帧
        // 新旧页重叠透叠；横屏保持淡入+轻移，不动横屏观感。
        // 曲线用主题 FadeForwards 的原生同款 easeInOutCubicEmphasized
        //（缓起-加速-缓出，观感匀速顺滑）；easeOut 起步速度是匀速 2 倍、
        // 尾段急拖，前后段速度不一致。
        final isPortrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        final coverSlide = SlideTransition(
          position: animation.drive(
            Tween<Offset>(
              begin: const Offset(0.25, 0),
              end: Offset.zero,
            ).chain(
              CurveTween(
                curve: isPortrait
                    ? Curves.easeInOutCubicEmphasized
                    : Curves.easeOut,
              ),
            ),
          ),
          child: child,
        );
        if (isPortrait) {
          return coverSlide;
        }
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: coverSlide,
        );
      },
    );
  }
}
