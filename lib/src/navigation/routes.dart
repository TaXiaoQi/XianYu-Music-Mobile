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
import '../../pages/home/recommend_sheets_page.dart';
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
import '../../pages/settings/nav_manage_page.dart';
import '../../pages/settings/account_settings_page.dart';
import '../../pages/cloud/cloud_bind_page.dart';
import '../../pages/cloud/cloud_browser_page.dart';
import '../../pages/cloud/cloud_disk_page.dart';
import '../../pages/cloud/cloud_folder_picker_page.dart';
import '../../pages/cloud/cloud_link_import_page.dart';
import '../../pages/cloud/cloud_password_login_page.dart';
import '../../pages/cloud/cloud_qrcode_login_page.dart';
import '../../pages/cloud/cloud_webview_fields_login_page.dart';
import '../../pages/cloud/cloud_webview_login_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/account/account_page.dart';
import '../../pages/feedback/feedback_page.dart';
import '../../pages/about/about_page.dart';
import '../../pages/leaderboard/leaderboard_page.dart';
import '../../pages/plugin/plugin_page.dart';
import '../../pages/playlist/playlists_page.dart';
import '../../pages/download/download_page.dart';
import '../../pages/download/download_move_page.dart';
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

final _branchKeys = <GlobalKey>[GlobalKey(), GlobalKey(), GlobalKey()];
final appRouter = GoRouter(
  navigatorKey: appNavigatorKey,
  observers: [AppLogRouteObserver(), TransitionTracker()],
  initialLocation: '/home',
  routes: [
    StatefulShellRoute(
      pageBuilder: (context, state, navigationShell) =>
          _ShellPage(key: state.pageKey, navigationShell: navigationShell),
      navigatorContainerBuilder: (context, navigationShell, children) {
        return PredictiveBackTabContainer(
          navigationShell: navigationShell,
          currentIndex: navigationShell.currentIndex,
          branchIndices: [for (var i = 0; i < children.length; i++) i],
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
        // 插件分支：真分支保证切换后底栏/侧栏保留；标题与右上角动作
        // 经 shellTopBarOverrideProvider 上交壳顶栏（公共容器），页面纯内容
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/plugin',
              builder: (context, state) => const _ShellTabEntry(
                portraitPageId: 'plugin',
                landscapePageId: 'ls-plugin',
                child: PluginPage(embedded: true, asShellBranch: true),
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
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/search',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => SearchPage(initialQuery: state.uri.queryParameters['q']),
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
      pageBuilder: (context, state) =>
          _coverBackPage(context, (_) => const ScanPage(), key: state.pageKey),
    ),
    GoRoute(
      path: '/tv-login-confirm',
      pageBuilder: (context, state) => _coverBackPage(context, (_) {
        final extra = state.extra;
        final code = (extra is Map ? extra['code'] : null) as String? ?? '';
        final info = (extra is Map ? extra['info'] : null) as TvLoginScanInfo?;
        return TvLoginConfirmPage(
          code: code,
          info: info ?? const TvLoginScanInfo(),
        );
      }, key: state.pageKey),
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
      pageBuilder: (context, state) =>
          _coverPage(context, (_) => const AccountPage(), key: state.pageKey),
    ),
    GoRoute(
      path: '/settings/account',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const AccountSettingsPage(),
        key: state.pageKey,
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/cloud',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const CloudBindPage(),
        key: state.pageKey,
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/cloud/webview-login/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) =>
            CloudWebviewLoginPage(providerId: state.pathParameters['id'] ?? ''),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/cloud/fields-webview-login/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => CloudWebviewFieldsLoginPage(
          providerId: state.pathParameters['id'] ?? '',
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/cloud/password-login/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => CloudPasswordLoginPage(
          providerId: state.pathParameters['id'] ?? '',
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/cloud/qrcode-login/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) =>
            CloudQrcodeLoginPage(providerId: state.pathParameters['id'] ?? ''),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/cloud/browser/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => CloudBrowserPage(
          providerId: state.pathParameters['id'] ?? '',
          accountId: state.uri.queryParameters['account'],
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/cloud/folder-picker/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => CloudFolderPickerPage(
          providerId: state.pathParameters['id'] ?? '',
          accountId: state.uri.queryParameters['account'] ?? '',
        ),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/cloud/link-import',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const CloudLinkImportPage(),
        key: state.pageKey,
        location: state.matchedLocation,
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
        location: state.matchedLocation,
      ),
    ),
    GoRoute(
      path: '/feedback',
      pageBuilder: (context, state) {
        final tab = int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0;
        return _coverPage(
          context,
          (_) => FeedbackPage(initialTab: tab),
          key: state.pageKey,
        );
      },
    ),
    GoRoute(
      path: '/about',
      pageBuilder: (context, state) =>
          _coverPage(context, (_) => const AboutPage(), key: state.pageKey),
    ),
    GoRoute(
      path: '/debug',
      pageBuilder: (context, state) =>
          _coverPage(context, (_) => const DebugPage(), key: state.pageKey),
    ),
    GoRoute(
      path: '/leaderboard',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const LeaderboardPage(),
        key: state.pageKey,
      ),
    ),
    // 插件管理 cover 页（分享链接/首页入口等 push 场景，带返回键）；
    // 页签路径 /plugin 已是 shell 第三分支，两者分离避免路由抢占
    GoRoute(
      path: '/plugin-manage',
      pageBuilder: (context, state) =>
          _coverPage(context, (_) => const PluginPage(), key: state.pageKey),
    ),
    GoRoute(
      path: '/nav-manage',
      pageBuilder: (context, state) =>
          _coverPage(context, (_) => const NavManagePage(), key: state.pageKey),
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
      path: '/playlist/:id',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => PlaylistDetailPage(playlistId: state.pathParameters['id'] ?? ''),
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
      path: '/cloud-disk',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const HideShellChrome(child: CloudDiskPage()),
        key: state.pageKey,
      ),
    ),
    GoRoute(
      path: '/download-move',
      pageBuilder: (context, state) => _coverBackPage(
        context,
        (_) => const HideShellChrome(child: DownloadMovePage()),
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
      pageBuilder: (context, state) =>
          _coverPage(context, (_) => const AudioTrimPage(), key: state.pageKey),
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
      pageBuilder: (context, state) =>
          _coverPage(context, (_) => const TopListsPage(), key: state.pageKey),
    ),
    GoRoute(
      path: '/home/recommend-sheets',
      pageBuilder: (context, state) => _coverPage(
        context,
        (_) => const RecommendSheetsPage(),
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

  /// 页签 id（settings.navOrderPortrait/Landscape 的存储单位，导航栏
  /// 管理页按此排序展示）。与 branchIndex 解耦：id 稳定可持久化，
  /// branchIndex 是分支注册序
  final String navId;

  /// 对应 StatefulShellRoute 分支索引；显示顺序（导航栏管理排序）与
  /// 分支注册顺序解耦，页签点击/选中态一律走 branchIndex
  final int branchIndex;

  /// 需用户在导航栏管理里显式开启才显示的页签（如插件页签）。
  /// 所有按 id 过滤页签的地方一律判此标志，不再写死 id
  final bool optIn;

  /// 主题图标槽位 id；为 null 表示该导航项不参与主题换图。
  ///
  /// 保留 [icon] 不动、另加一个可选槽位，是为了让"未启用主题时渲染与之前完全
  /// 一致"这件事在类型层面就成立——不必把 IconData 改成可空或联合类型，
  /// 三个渲染点（底栏/侧栏/横屏 rail）也不需各自处理空值。
  final String? themeSlot;

  const BottomNavItem(
    this.title,
    this.icon,
    this.location, {
    required this.branchIndex,
    required this.navId,
    this.themeSlot,
    this.optIn = false,
  });
}

final List<BottomNavItem> bottomNavItems = [
  BottomNavItem(
    tr('首页'),
    Icons.home,
    '/home',
    branchIndex: 0,
    navId: 'home',
    themeSlot: 'nav.home',
  ),
  BottomNavItem(
    tr('我的'),
    Icons.person_outline_rounded,
    '/mine',
    branchIndex: 1,
    navId: 'mine',
    themeSlot: 'nav.settings',
  ),
];

/// 插件页签（默认不出现，导航栏管理页里按需开启）：shell 第三分支，
/// 切换后底栏/侧栏保留，与首页/我的同层级
final BottomNavItem pluginsNavItem = BottomNavItem(
  tr('插件'),
  Icons.extension_outlined,
  '/plugin',
  branchIndex: 2,
  navId: 'plugin',
  optIn: true,
);

/// 页签 id → 页签项的单一数据源：navItemsFor / 预测返回 tab 排序 /
/// 导航栏管理页都从这里取。新增分支只需登记一个 BottomNavItem 并把
/// id 加入 kDefaultNavOrder（settings.dart），其余页面自动跟随
final Map<String, BottomNavItem> navItemsById = {
  for (final it in [...bottomNavItems, pluginsNavItem]) it.navId: it,
};

/// 横屏 rail 的音乐库项：与导航页签合并成一组（顺序见
/// kDefaultNavOrderLandscape），paneIndex 为 landscapeLibraryProvider 的
/// 稳定面板 id（5=文件夹管理，归属「本地音乐」，不作为导航项）。
class LandscapeLibraryNavItem {
  const LandscapeLibraryNavItem({
    required this.navId,
    required this.title,
    required this.shortTitle,
    required this.icon,
    required this.paneIndex,
    this.requiresCloud = false,
  });

  final String navId;
  final String title;

  /// rail 窄档（折叠）简称
  final String shortTitle;
  final IconData icon;
  final int paneIndex;

  /// 已绑定网盘才显示（网盘音乐）
  final bool requiresCloud;
}

final Map<String, LandscapeLibraryNavItem> landscapeLibraryNavById = {
  for (final it in [
    LandscapeLibraryNavItem(
      navId: 'lib-local',
      title: tr('本地音乐'),
      shortTitle: tr('本地'),
      icon: Icons.library_music_outlined,
      paneIndex: 0,
    ),
    LandscapeLibraryNavItem(
      navId: 'lib-cloud',
      title: tr('网盘音乐'),
      shortTitle: tr('网盘'),
      icon: Icons.cloud_outlined,
      paneIndex: 1,
      requiresCloud: true,
    ),
    LandscapeLibraryNavItem(
      navId: 'lib-favorites',
      title: tr('我的收藏'),
      shortTitle: tr('收藏'),
      icon: Icons.favorite_outline,
      paneIndex: 2,
    ),
    LandscapeLibraryNavItem(
      navId: 'lib-recent',
      title: tr('最近播放'),
      shortTitle: tr('最近'),
      icon: Icons.history_outlined,
      paneIndex: 3,
    ),
    LandscapeLibraryNavItem(
      navId: 'lib-playlists',
      title: tr('我的歌单'),
      shortTitle: tr('歌单'),
      icon: Icons.queue_music_outlined,
      paneIndex: 4,
    ),
  ])
    it.navId: it,
};

/// 竖屏导航（底栏/悬浮导航/竖屏侧栏）页签列表；横屏 rail 传横屏顺序。
/// [order] 为页签 id 序（settings.navOrderPortrait/Landscape，已 normalize）
List<BottomNavItem> navItemsFor(bool showPlugins, List<String> order) {
  final items = <BottomNavItem>[];
  for (final id in order) {
    final item = navItemsById[id];
    if (item == null) continue;
    if (item.optIn && !showPlugins) continue;
    items.add(item);
  }
  // 保底：全部被过滤时退回默认两项，导航永远可用
  return items.isEmpty ? bottomNavItems : items;
}

String navTitle(BuildContext context, BottomNavItem item) {
  final l = Localizations.of<AppLocalizations>(context, AppLocalizations);
  return switch (item.location) {
    '/home' => l?.navHome ?? tr('首页'),
    '/mine' => l?.navMine ?? tr('我的'),
    '/plugin' => tr('插件'),
    _ => l?.navEffects ?? tr('音效'),
  };
}
