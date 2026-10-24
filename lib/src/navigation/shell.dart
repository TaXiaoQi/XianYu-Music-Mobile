import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/application_logger.dart';
import '../core/app_colors.dart';
import '../core/haptics.dart';
import '../core/settings.dart';
import '../core/system_ui.dart';
import '../theme/theme_icon.dart';
import '../theme/theme_tint.dart';
import '../auth/auth_provider.dart';
import '../widgets/glass_settings.dart';
import '../widgets/landscape_page_fade.dart';
import 'landscape_tab_switcher.dart';
import '../widgets/blur_budget.dart';
import '../widgets/orientation_transition.dart';
import '../widgets/app_toast.dart';
import '../widgets/predictive_dialog_route.dart';
import '../notifications/notification_service.dart';
import '../sync/auto_sync.dart';
import '../sync/sync_provider.dart' show syncProvider;
import '../widgets/mini_player_bar.dart' show LiveLiquidSurface;
import '../widgets/page_search_bar.dart';
import '../widgets/press_scale.dart';
import '../widgets/bilipai_glass.dart';
import '../widgets/chrome_glass_frame.dart';
import '../widgets/custom_background.dart' show PageWallpaperScope;
import '../../pages/library/library_page.dart';
import '../../pages/library/library_folder_page.dart';
import '../../pages/library/song_list_page.dart';
import '../../pages/home/online_detail_page.dart';
import '../library/library_provider.dart' show Song;
import '../player/player_provider.dart' show QueueItem;
import '../../pages/cloud/cloud_disk_page.dart';
import '../cloud/cloud_registry.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/playlist/playlists_page.dart';
import '../widgets/floating_search_bar.dart';
import '../widgets/skin_icon.dart';
import '../widgets/flat_top_bar.dart';
import '../widgets/glass_appbar.dart' show GlassTopBar;
import '../widgets/landscape_top_bar.dart';
import '../../pages/account/account_page.dart';
import '../../pages/download/download_page.dart';
import '../../pages/settings/folder_picker_page.dart';
import '../../pages/remote/remote_library_page.dart';
import '../../pages/cloud/cloud_bind_page.dart';
import '../../pages/cloud/cloud_folder_picker_page.dart';
import '../../pages/home/daily_recommend_page.dart';
import '../../pages/home/top_lists_page.dart';
import '../../pages/home/recommend_sheets_page.dart';
import '../../pages/leaderboard/leaderboard_page.dart';
import '../../pages/leaderboard/leaderboard_prefetch.dart';
import '../../pages/search/search_page.dart';
import 'routes.dart';
import '../i18n/i18n.dart';
import 'dart:async';

part 'shell_mini_bar.dart';
part 'shell_back.dart';
part 'shell_landscape.dart';
part 'shell_bottom_bar.dart';
part 'shell_sliding_nav.dart';
part 'shell_side_rail.dart';

const double kLandscapeRailWidth = 210;
const double kLandscapeRailIconWidth = 60;
const double kLandscapeRailCollapseAt = 120;

/// 品牌胶囊「弦予」短档最小 rail 宽：再窄直接隐藏
const double kLandscapeBrandShortMinRail = 100;

/// 品牌胶囊全称档最小 rail 宽：低于此降「弦予」短档（100-150 区间）
const double kLandscapeBrandFullMinRail = 150;

final isLandscapeProvider = StateProvider<bool>((ref) => false);

final landscapeLibraryProvider = StateProvider<int?>((ref) => null);

final landscapeLibrarySearchActiveProvider = StateProvider<bool>(
  (ref) => false,
);

final landscapeLibraryQueryProvider = StateProvider<String>((ref) => '');

final landscapeLibrarySearchCtrlProvider = Provider<TextEditingController>((
  ref,
) {
  final ctrl = TextEditingController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

final landscapeLibrarySearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode();
  ref.onDispose(node.dispose);
  return node;
});

final landscapeAccountOpenProvider = StateProvider<bool>((ref) => false);

final landscapeDownloadOpenProvider = StateProvider<bool>((ref) => false);

final landscapePlaylistOpenProvider = StateProvider<String?>((ref) => null);

final landscapeContentPathProvider = StateProvider<String?>((ref) => null);

/// 横屏右容器二级详情载荷：从一级面板（本地/网盘/搜索等）下钻的
/// 歌手/专辑/歌单详情内嵌右容器展示（替换当前面板内容，返回即清空
/// 回到一级面板）；竖屏仍走原路由全屏页，不受影响。
sealed class LandscapeDetail {
  const LandscapeDetail();
}

/// 本地歌曲列表（本地库歌手/专辑下钻、搜索页本地命中下钻）
class LandscapeSongListDetail extends LandscapeDetail {
  const LandscapeSongListDetail({required this.title, required this.loader});

  final String title;
  final Future<List<Song>> Function() loader;
}

/// 在线歌手/专辑/歌单/榜单详情
class LandscapeOnlineDetail extends LandscapeDetail {
  const LandscapeOnlineDetail(this.args);

  final OnlineDetailArgs args;
}

/// 网盘歌手/专辑分组下钻
class LandscapeCloudGroupDetail extends LandscapeDetail {
  const LandscapeCloudGroupDetail({required this.title, required this.items});

  final String title;
  final List<QueueItem> items;
}

/// 本地扫描目录勾选（文件夹页「添加目录」下钻）
class LandscapeFolderPickerDetail extends LandscapeDetail {
  const LandscapeFolderPickerDetail();
}

/// 远程音乐库管理（文件夹页左列入口下钻）
class LandscapeRemoteLibraryDetail extends LandscapeDetail {
  const LandscapeRemoteLibraryDetail();
}

/// 音源管理（文件夹页/网盘页/网盘浏览器入口下钻）
class LandscapeCloudManageDetail extends LandscapeDetail {
  const LandscapeCloudManageDetail();
}

/// 网盘已选文件夹管理（文件夹页网盘树「选择文件夹」下钻）
class LandscapeCloudPickerDetail extends LandscapeDetail {
  const LandscapeCloudPickerDetail({
    required this.providerId,
    required this.accountId,
  });

  final String providerId;
  final String accountId;
}

final landscapeDetailProvider = StateProvider<LandscapeDetail?>((ref) => null);

final musicLibraryPageKeys = List<GlobalKey>.generate(6, (_) => GlobalKey());

final landscapePaneOpenProvider = Provider<bool>((ref) {
  return ref.watch(landscapeAccountOpenProvider) ||
      ref.watch(landscapeDownloadOpenProvider) ||
      ref.watch(landscapeDetailProvider) != null ||
      ref.watch(landscapePlaylistOpenProvider) != null ||
      ref.watch(landscapeSearchOpenProvider) ||
      ref.watch(landscapeContentPathProvider) != null;
});

final landscapeSettingsCategoryProvider = StateProvider<String?>((ref) => null);

const Set<String> kLandscapeSettingPaths = <String>{
  '/settings/account',
  '/settings/general',
  '/settings/appearance',
  '/settings/lyrics',
  '/settings/playback',
  '/settings/download',
  '/settings/watch',
  '/settings/dlna',
  '/settings/tools',
  '/settings/advanced',
  '/about',
  '/plugin',
  '/plugin-manage',
  '/nav-manage',
  '/theme',
  '/wallpaper',
};

final navBarInsetProvider = Provider<double>((ref) {
  final landscape = ref.watch(isLandscapeProvider);
  final s = ref.watch(settingsProvider).valueOrNull;
  if (landscape || s?.navBarPosition == NavBarPosition.side) return 82;
  // 顶部导航没有底栏：页面只需给 mini 播放条留白
  if (s?.navBarPosition == NavBarPosition.top) return 82;
  // 悬浮底栏是覆盖式，页面需多留白避让；固定底栏占位在布局内，只需留 mini 播放条。
  return (s?.floatingNavBar ?? false) ? 175 : 82;
});

final navBarHiddenProvider = StateProvider<int>((ref) => 0);

/// 当前是否处于根路径（'/'、'/home'、'/mine'）：底栏 hidden = 计数 >0 ||
/// 非 root 路径，设置等未混 HidesShellChrome 的二级页面靠后者隐藏；
/// 顶层 NavDropletOverlay 据此对齐底栏显隐
final navOnRootPathProvider = StateProvider<bool>((ref) => true);

/// 壳层顶栏分支覆盖：分支页（如插件管理）把标题与右上角动作上交壳层，
/// 页面自身只渲染内容——底栏/顶栏/搜索条全部复用公共容器。
/// 页面 initState 注册、dispose 清除；未注册时顶栏走各分支默认形态
class ShellTopBarAction {
  const ShellTopBarAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
}

class ShellTopBarOverride {
  const ShellTopBarOverride({required this.title, required this.actions});

  final String title;
  final List<ShellTopBarAction> actions;
}

final shellTopBarOverrideProvider = StateProvider<ShellTopBarOverride?>(
  (ref) => null,
);

/// mini 播放条页面黑名单计数：混入 HideMiniBar 的页面（设置、搜索等）
/// 持有期间 >0，全局播放条在该页面落定后隐藏、离开后恢复
final miniBarHiddenProvider = StateProvider<int>((ref) => 0);

final sideBarExpandedProvider = StateProvider<bool>((ref) => false);

class EmbeddedShellScope extends InheritedWidget {
  const EmbeddedShellScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EmbeddedShellScope>() != null;

  @override
  bool updateShouldNotify(EmbeddedShellScope oldWidget) => false;
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  DateTime? _lastBackTime;

  bool _notificationsChecked = false;

  @override
  void initState() {
    super.initState();
    ref.read(autoSyncProvider).start();
    // 启动即静默预热排行榜：进个人中心点统计卡时直接命中缓存，
    // 不再先闪一屏空骨架（预热失败/未完成时页面行为与以前一致）
    unawaited(prefetchLeaderboard(ref));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 对齐桌面端：登录同步只在登录态发生 false→true 变化时触发。
      // 先等凭据恢复落定再挂监听——启动时恢复的旧会话不再全量对账，
      // 避免每次打开 app 都对服务端做一轮推拉（防污染 + 省流量）
      await ref.read(authProvider.notifier).whenRestored;
      if (!mounted) return;
      ref.listenManual<bool>(authProvider.select((s) => s.user != null), (
        prev,
        next,
      ) {
        if (prev == false && next == true && mounted) {
          ref.read(syncProvider.notifier).syncOnLoginSuccess(context);
        }
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_notificationsChecked) return;
      _notificationsChecked = true;
      ref
          .read(notificationServiceProvider)
          .checkOnStartup(context)
          .catchError((_) {});
    });
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 页签切换（首页⇄我的）不走路由转场，转场 false 沿的抓帧触发不到；
    // 而底栏/顶栏的透底内容已换页，必须刷新 chrome 缓存帧——否则在新
    // 页签推入二级页时，转场裁剪出的是旧页签的透底
    if (widget.navigationShell.currentIndex !=
        oldWidget.navigationShell.currentIndex) {
      // 旧页签的缓存帧立即失效：补抓完成前 chrome 面拿到的帧为 null，
      // 转场裁剪/adopt 落到毛玻璃兜底——宁缺勿错，绝不裁出上个页签的透底
      final stale = chromeGlassFrame.value;
      chromeGlassFrame.value = null;
      if (stale != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => stale.image.dispose(),
        );
      }
      schedule(const Duration(milliseconds: 300));
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.navigationShell.currentIndex;
    final hiddenCount = ref.watch(navBarHiddenProvider);
    final isSubPage = hiddenCount > 0 || GoRouter.of(context).canPop();

    // 会话失效弹窗挂常驻壳层：失效由任意页面的鉴权请求触发（同步/统计/
    // 榜单心跳等），此前只在账号页 build 里兜底，其余页面只会静默变未
    // 登录态，点进账号页才知道原因。根导航弹窗保证任意页面即时可见
    ref.listen<AuthState>(authProvider, (prev, next) {
      if ((prev?.sessionExpired ?? false) || !next.sessionExpired) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSessionExpiredDialog();
      });
    });

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent e) {
        if (e.buttons == kBackMouseButton) _handleBack();
      },
      child: PopScope(
        canPop: isSubPage,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _handleBack();
        },
        child: _ShellScaffold(
          navigationShell: widget.navigationShell,
          index: index,
        ),
      ),
    );
  }

  // 「登录」仅在不在账号页时才 push，避免账号页上重复叠页
  Future<void> _showSessionExpiredDialog() async {
    final router = GoRouter.of(context);
    await showPredictiveDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(tr('登录状态已失效')),
        content: Text(tr('登录状态已失效，请重新登录。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('确认')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (_ShellScaffoldState._routerTopPath(
                    router.routerDelegate.currentConfiguration,
                  ) !=
                  '/account') {
                router.push('/account');
              }
            },
            child: Text(tr('登录')),
          ),
        ],
      ),
    );
    if (mounted) ref.read(authProvider.notifier).consumeSessionExpired();
  }
}

class _ShellScaffold extends ConsumerStatefulWidget {
  const _ShellScaffold({required this.navigationShell, required this.index});

  final StatefulNavigationShell navigationShell;
  final int index;

  @override
  ConsumerState<_ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends ConsumerState<_ShellScaffold>
    with WidgetsBindingObserver {
  static final _jellyKey = GlobalKey<State<_JellySwitch>>();

  late final GoRouter _router;

  bool _isRootPath = true;

  double _railWidth = kLandscapeRailWidth;

  /// 拖拽宽度持久化：拖动中防抖落盘，启动时恢复
  static const _railWidthKey = 'landscape.railWidth';
  Timer? _railWidthPersistTimer;

  void _scheduleRailWidthPersist() {
    _railWidthPersistTimer?.cancel();
    _railWidthPersistTimer = Timer(const Duration(milliseconds: 300), () {
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setDouble(_railWidthKey, _railWidth),
      );
    });
  }

  Future<void> _restoreRailWidth() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_railWidthKey);
    if (saved == null || !mounted) return;
    final restored = saved
        .clamp(
          kLandscapeRailIconWidth,
          math.max(MediaQuery.sizeOf(context).width * 0.5, kLandscapeRailWidth),
        )
        .toDouble();
    if (restored != _railWidth) {
      setState(() => _railWidth = restored);
    }
  }

  StreamSubscription<dynamic>? _rotationSub;

  /// 悬浮 chrome（底栏/悬浮顶栏）完全隐藏后整树卸载。Impeller 下
  /// Opacity(0.01) 常绘子树的 alpha 泄漏——内容以约 10% 亮度透出，二级页上
  /// 残留底栏与选中圆形（与 mini 播放条幽灵 bar 同源，那里已用整树卸载修掉）
  bool _chromeGone = false;

  /// 重挂载恢复帧：隐式动画（AnimatedOpacity/AnimatedScale）首建不播动画，
  /// 挂回首帧若目标值已是 1.0/1.0 会硬切，需先以隐藏目标渲染一帧
  bool _chromeRecovering = false;

  /// 恢复窗口：停绘后挂回的首帧 backdrop 采样未就绪，降级磨砂防黑闪
  bool _chromeFading = false;

  bool? _lastChromeHidden;
  Timer? _chromeGoneTimer;
  Timer? _chromeFadeTimer;

  static const _rootPaths = {'/', '/home', '/mine', '/plugin'};

  static bool _isRootPathOf(String path) => _rootPaths.contains(path);

  /// hidden 变化时调度悬浮 chrome 的整树卸载/挂回：淡出动画（240ms）结束后
  /// 停绘，恢复时先挂回并按隐藏目标渲染一帧再翻回真实目标，保住淡入/缩放
  /// 隐式动画。与 mini 播放条 _syncBarGone 同构。
  void _syncChromeHidden() {
    if (!mounted) return;
    _syncChromeGone(
      ref.read(navBarHiddenProvider) > 0 || !ref.read(navOnRootPathProvider),
    );
  }

  void _syncChromeGone(bool hidden) {
    if (_lastChromeHidden == hidden) return;
    _lastChromeHidden = hidden;
    if (hidden) {
      _chromeGoneTimer?.cancel();
      _chromeGoneTimer = Timer(const Duration(milliseconds: 320), () {
        if (mounted) setState(() => _chromeGone = true);
        // 缓存帧失效推迟到整树卸载此刻：root→sub push 的退出动画（240ms
        // 淡出+缩放）与路由转场重叠，此间 useChromeFrame 玻璃面靠缓存帧
        // 裁剪（无 backdrop 采样）呈现——立即失效会让整个退出窗口回落到
        // 实时 blur backdrop 逐帧采样（root→sub 转场卡顿主源）。卸载后
        // 无消费方面（useChromeFrame 面全部随树卸载），此刻失效无残影
        final stale = chromeGlassFrame.value;
        if (stale != null) {
          chromeGlassFrame.value = null;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => stale.image.dispose(),
          );
        }
      });
    } else {
      _chromeGoneTimer?.cancel();
      if (_chromeGone) {
        _chromeGone = false;
        _chromeRecovering = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _chromeRecovering = false);
        });
        _chromeFadeTimer?.cancel();
        _chromeFading = true;
        _chromeFadeTimer = Timer(const Duration(milliseconds: 280), () {
          if (mounted) setState(() => _chromeFading = false);
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _router = GoRouter.of(context);
    _isRootPath = _isRootPathOf(
      _routerTopPath(_router.routerDelegate.currentConfiguration),
    );
    ref.read(navOnRootPathProvider.notifier).state = _isRootPath;
    _router.routerDelegate.addListener(_onRouteChanged);
    // 悬浮 chrome 显隐驱动整树卸载/挂回：hidden = 计数 >0 || 非 root 路径，
    // 两路都要监听（二级页靠后者隐藏，计数不增）
    ref.listenManual(navBarHiddenProvider, (_, _) => _syncChromeHidden());
    ref.listenManual(navOnRootPathProvider, (_, _) => _syncChromeHidden());
    // 冷启动直接落在二级页时上面两个监听都不会触发，先同步一次
    _syncChromeGone(ref.read(navBarHiddenProvider) > 0 || !_isRootPath);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _rotationSub = const EventChannel(
        'xianyu/rotation/events',
      ).receiveBroadcastStream().listen(_onRotationEvent, onError: (_) {});
    }
    unawaited(_restoreRailWidth());
  }

  void _onRotationEvent(Object? e) {
    if (!mounted) return;
    final v = e is num ? e.toInt() : null;
    if (v == null) return;
    if (v == 1) {
      ref.read(isLandscapeProvider.notifier).state = false;
    } else if (v == 2) {
      ref.read(isLandscapeProvider.notifier).state = true;
    }
  }

  void _onRouteChanged() {
    if (!mounted) return;
    // 不能用 currentConfiguration.uri.path：push 二级页（ImperativeRouteMatch）
    // 后 uri.path 仍停留在 shell 分支的路径（/home 或 /mine），不会变成
    // /settings——根因是它只反映 shell 分支 location。取 matches.last 的
    // 实际位置（_routerTopPath），与底栏/横屏逻辑的判定保持同源
    final top = _routerTopPath(_router.routerDelegate.currentConfiguration);
    final rootNow = _isRootPathOf(top);
    if (rootNow != _isRootPath) {
      setState(() => _isRootPath = rootNow);
      ref.read(navOnRootPathProvider.notifier).state = rootNow;
    }
    if (rootNow) {
      final notifier = ref.read(navBarHiddenProvider.notifier);
      if (notifier.state > 0) notifier.state = 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.routerDelegate.removeListener(_onRouteChanged);
    _libPaneMountTimer?.cancel();
    _rotationSub?.cancel();
    _chromeGoneTimer?.cancel();
    _chromeFadeTimer?.cancel();
    // 拖完立刻退出的场景：取消防抖并直接落盘
    _railWidthPersistTimer?.cancel();
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setDouble(_railWidthKey, _railWidth),
    );
    super.dispose();
  }

  static const Set<String> _noRotateRedirectPaths = <String>{
    '/player',
    '/scan',
    '/recognize',
    '/tv-login-confirm',
    '/shareBridge',
  };

  static String _routerTopPath(RouteMatchList config) {
    final last = config.matches.lastOrNull;
    if (last is ImperativeRouteMatch) return last.matches.uri.path;
    if (last is RouteMatch) return last.matchedLocation;
    if (last is ShellRouteMatch) return last.matchedLocation;
    return config.uri.path;
  }

  String? _rotateBackPath;

  bool? _lastPhysicalLandscape;

  bool _libPaneMountable = true;
  Timer? _libPaneMountTimer;

  // 转场中顶栏复用的旧 widget 实例（identical → 子树跳过 rebuild 保帧）
  Widget? _topBarCache;

  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null || !mounted) return;
    final size = view.physicalSize / view.devicePixelRatio;
    final landscape = size.width >= size.height * 1.05;
    final noti = ref.read(isLandscapeProvider.notifier);
    if (noti.state != landscape) {
      noti.state = landscape;
    }
    final flipped =
        _lastPhysicalLandscape != null && _lastPhysicalLandscape != landscape;
    _lastPhysicalLandscape = landscape;
    if (!flipped) return;

    // 横竖屏切换会重建/迁移部分页面；先释放后层账号等输入框的残留焦点，
    // 避免 IME 在播放页因尺寸变化被重新拉起。
    FocusManager.instance.primaryFocus?.unfocus();

    if (!landscape) {
      final lib = ref.read(landscapeLibraryProvider);
      final playlist = ref.read(landscapePlaylistOpenProvider);
      final searchOpen = ref.read(landscapeSearchOpenProvider);
      final searchResults = ref.read(landscapeSearchResultsProvider);
      final download = ref.read(landscapeDownloadOpenProvider);
      final account = ref.read(landscapeAccountOpenProvider);
      final content = ref.read(landscapeContentPathProvider);
      final detail = ref.read(landscapeDetailProvider);
      void closeAll() {
        ref.read(landscapeLibraryProvider.notifier).state = null;
        ref.read(landscapeSearchOpenProvider.notifier).state = false;
        ref.read(landscapeSearchResultsProvider.notifier).state = false;
        ref.read(landscapeDownloadOpenProvider.notifier).state = false;
        ref.read(landscapeAccountOpenProvider.notifier).state = false;
        ref.read(landscapePlaylistOpenProvider.notifier).state = null;
        ref.read(landscapeContentPathProvider.notifier).state = null;
        ref.read(landscapeDetailProvider.notifier).state = null;
      }

      final back = _rotateBackPath;
      _rotateBackPath = null;
      closeAll();
      final top = _routerTopPath(_router.routerDelegate.currentConfiguration);
      final onShell = _isRootPathOf(top);
      final onSettings = top == '/settings';
      if (onSettings && kLandscapeSettingPaths.contains(back)) {
        final category = ref.read(landscapeSettingsCategoryProvider);
        context.push(category ?? back!);
      } else if (onShell) {
        if (lib != null) {
          const libRoutes = [
            '/library',
            '/cloud-disk',
            '/favorites',
            '/recent',
            '/playlists',
            '/library/folders',
          ];
          context.push(libRoutes[lib.clamp(0, libRoutes.length - 1)]);
        } else if (searchOpen) {
          context.push(searchResults ? '/search/result' : '/search');
        } else if (content != null) {
          context.push(content);
        } else if (detail != null) {
          // 二级详情恢复为竖屏路由页（网盘分组无对应路由，退回网盘页）
          switch (detail) {
            case LandscapeSongListDetail d:
              context.push(
                '/song-list',
                extra: SongListArgs(title: d.title, loader: d.loader),
              );
            case LandscapeOnlineDetail d:
              context.push('/online-detail', extra: d.args);
            case LandscapeCloudGroupDetail _:
              context.push('/cloud-disk');
            case LandscapeFolderPickerDetail _:
              context.push('/library/folders');
            case LandscapeRemoteLibraryDetail _:
              context.push('/remote-library');
            case LandscapeCloudManageDetail _:
              context.push('/cloud');
            case LandscapeCloudPickerDetail d:
              context.push(
                '/cloud/folder-picker/${d.providerId}?account=${d.accountId}',
              );
          }
        } else if (playlist != null) {
          context.push('/playlist/$playlist');
        } else if (download) {
          context.push('/download');
        } else if (account) {
          context.push('/account');
        }
      }
      return;
    }
    final path = _routerTopPath(_router.routerDelegate.currentConfiguration);
    const libRoutes = [
      '/library',
      '/cloud-disk',
      '/favorites',
      '/recent',
      '/playlists',
      '/library/folders',
    ];
    if (path == '/search' || path == '/search/result') {
      _rotateBackPath = path;
      ref.read(landscapeSearchOpenProvider.notifier).state = true;
      ref.read(landscapeSearchResultsProvider.notifier).state =
          path == '/search/result';
      while (context.canPop()) {
        context.pop();
      }
    } else if (kLandscapeSettingPaths.contains(path)) {
      _rotateBackPath = path;
      ref.read(landscapeSettingsCategoryProvider.notifier).state = path;
      final hasSettingsBelow = _router
          .routerDelegate
          .currentConfiguration
          .matches
          .any((m) => m is RouteMatch && m.matchedLocation == '/settings');
      if (hasSettingsBelow) {
        context.pop();
      } else {
        context.go('/settings');
      }
    } else if (libRoutes.contains(path)) {
      _rotateBackPath = path;
      _deferLibPaneMount();
      ref.read(landscapeLibraryProvider.notifier).state = libRoutes.indexOf(
        path,
      );
      while (context.canPop()) {
        context.pop();
      }
    } else if (path == '/home/daily' ||
        path == '/home/toplists' ||
        path == '/home/recommend-sheets' ||
        path == '/leaderboard') {
      _rotateBackPath = path;
      ref.read(landscapeContentPathProvider.notifier).state = path;
      while (context.canPop()) {
        context.pop();
      }
    } else if (path == '/download') {
      _rotateBackPath = path;
      ref.read(landscapeDownloadOpenProvider.notifier).state = true;
      while (context.canPop()) {
        context.pop();
      }
    } else if (path == '/account') {
      _rotateBackPath = path;
      ref.read(landscapeAccountOpenProvider.notifier).state = true;
      while (context.canPop()) {
        context.pop();
      }
    } else if (path.startsWith('/playlist/')) {
      _rotateBackPath = path;
      ref.read(landscapePlaylistOpenProvider.notifier).state = path
          .split('/')
          .last;
      while (context.canPop()) {
        context.pop();
      }
    } else if (path == '/song-list' || path == '/online-detail') {
      // 竖屏打开的二级详情旋进横屏：转二级面板（载荷从路由 extra 取）
      final extra = _router.routerDelegate.currentConfiguration.extra;
      if (extra is SongListArgs) {
        ref.read(landscapeDetailProvider.notifier).state =
            LandscapeSongListDetail(title: extra.title, loader: extra.loader);
      } else if (extra is OnlineDetailArgs) {
        ref.read(landscapeDetailProvider.notifier).state =
            LandscapeOnlineDetail(extra);
      }
      while (context.canPop()) {
        context.pop();
      }
    } else if (path == '/remote-library') {
      _rotateBackPath = path;
      ref.read(landscapeDetailProvider.notifier).state =
          const LandscapeRemoteLibraryDetail();
      while (context.canPop()) {
        context.pop();
      }
    } else if (path == '/cloud') {
      _rotateBackPath = path;
      ref.read(landscapeDetailProvider.notifier).state =
          const LandscapeCloudManageDetail();
      while (context.canPop()) {
        context.pop();
      }
    } else if (path.startsWith('/cloud/folder-picker/')) {
      _rotateBackPath = path;
      // _routerTopPath 只含 path 无 query，account 从完整 uri 取
      final account = _router
          .routerDelegate
          .currentConfiguration
          .uri
          .queryParameters['account'];
      ref
          .read(landscapeDetailProvider.notifier)
          .state = LandscapeCloudPickerDetail(
        providerId: path.split('/').last,
        accountId: account ?? '',
      );
      while (context.canPop()) {
        context.pop();
      }
    } else if (!_noRotateRedirectPaths.contains(path) && path != '/settings') {
      _rotateBackPath = path;
      while (context.canPop()) {
        context.pop();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final screen = MediaQuery.maybeOf(context);
    final landscape =
        screen == null || screen.size.width >= screen.size.height * 1.05;

    if (_lastImmersive != landscape) {
      _lastImmersive = landscape;
      _applyLandscapeImmersive(landscape);
    }
  }

  bool _lastImmersive = false;

  (bool, bool, bool, Color?, int)? _lastNavBarSent;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final safeBottom = padding.bottom;

    final landscape = screenSize.width >= screenSize.height * 1.05;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final noti = ref.read(isLandscapeProvider.notifier);
      if (noti.state != landscape) {
        noti.state = landscape;
      }
    });

    final floating =
        ref.watch(
          settingsProvider.select((s) => s.valueOrNull?.floatingNavBar),
        ) ??
        true;

    // 顶部导航模式：不出底栏/侧栏，页面切换由顶栏右侧导航球承担
    final navTop =
        !landscape &&
        ref.watch(
              settingsProvider.select((s) => s.valueOrNull?.navBarPosition),
            ) ==
            NavBarPosition.top;

    final libSel = ref.watch(landscapeLibraryProvider);

    final accountOpen = landscape && ref.watch(landscapeAccountOpenProvider);

    final downloadOpen = landscape && ref.watch(landscapeDownloadOpenProvider);

    final playlistOpenId = landscape
        ? ref.watch(landscapePlaylistOpenProvider)
        : null;

    final searchOpenRaw = ref.watch(landscapeSearchOpenProvider);
    final searchResults = ref.watch(landscapeSearchResultsProvider);
    final searchOpen = landscape && searchOpenRaw;

    final contentPath = landscape
        ? ref.watch(landscapeContentPathProvider)
        : null;

    final landscapeDetail = landscape
        ? ref.watch(landscapeDetailProvider)
        : null;

    final Widget? landPane;
    final Object? landPaneTrigger;
    // 二级详情（歌手/专辑/歌单/网盘分组）从一级面板内下钻，优先级最高：
    // 覆盖当前面板展示，返回即清空回到一级面板
    if (landscapeDetail != null) {
      landPaneTrigger = 'detail:${identityHashCode(landscapeDetail)}';
      landPane = EmbeddedShellScope(
        child: _LandscapeDetailPane(detail: landscapeDetail),
      );
    } else if (accountOpen) {
      landPaneTrigger = 'account';
      landPane = EmbeddedShellScope(
        child: _AccountPane(
          onBack: () =>
              ref.read(landscapeAccountOpenProvider.notifier).state = false,
        ),
      );
    } else if (searchOpen) {
      landPaneTrigger = 'search';
      landPane = EmbeddedShellScope(
        child: _SearchPane(showResults: searchResults),
      );
    } else if (contentPath != null) {
      landPaneTrigger = 'content:$contentPath';
      landPane = EmbeddedShellScope(
        child: _ContentPane(
          path: contentPath,
          onBack: () =>
              ref.read(landscapeContentPathProvider.notifier).state = null,
        ),
      );
    } else if (playlistOpenId != null) {
      landPaneTrigger = 'pl:$playlistOpenId';
      landPane = EmbeddedShellScope(
        child: _PlaylistDetailPane(playlistId: playlistOpenId),
      );
    } else if (downloadOpen) {
      landPaneTrigger = 'download';
      landPane = const EmbeddedShellScope(child: _DownloadPane());
    } else {
      landPaneTrigger = null;
      landPane = null;
    }
    final anyPaneOpen = landPane != null;

    const libPaneActive = false;

    final floatingSearchBar = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false),
    );

    // 横屏恒铺满到摄像头(挖孔)区域：原「横屏使用摄像头区域」开关已移除
    final useCameraArea = landscape;

    final landscapeFadeEnabled =
        landscape &&
        ref.watch(
          settingsProvider.select(
            (s) => s.valueOrNull?.landscapeTransitionEnabled ?? true,
          ),
        );

    final libPaneMountable = landscape && _libPaneMountable;
    final Widget landscapeHome = Offstage(
      offstage: anyPaneOpen,
      child: EmbeddedShellScope(
        child: LandscapeTabSwitcher(
          currentIndex: libPaneMountable
              ? (libSel == null ? 0 : 1 + libSel)
              : 0,
          enabled: landscapeFadeEnabled,
          suppress: anyPaneOpen,
          children: [
            BranchFadeIn(
              shellIndex: widget.navigationShell.currentIndex,
              enabled: landscapeFadeEnabled,
              child: widget.navigationShell,
            ),
            if (libPaneMountable) ...[
              const _MusicLibraryPane(index: 0),
              const _MusicLibraryPane(index: 1),
              const _MusicLibraryPane(index: 2),
              const _MusicLibraryPane(index: 3),
              const _MusicLibraryPane(index: 4),
              const _MusicLibraryPane(index: 5),
            ],
          ],
        ),
      ),
    );

    final hiddenCount = ref.watch(navBarHiddenProvider);
    final hidden = hiddenCount > 0 || !_isRootPath;

    // 三键区底色：三大键恒定存在，底色恒定涂底栏色块的等效不透明色
    // （固定底栏=fill 合成到页面背景；悬浮=页面背景色；横屏沉浸=透明），
    // 不随底栏显隐分叉——二级页同样有底色保证三键可读。签名变化才发送
    // （hidden 只参与触发重申）——通道里原生会顺带重申，堵住悬浮↔固定
    // 切换、进出二级页、横竖屏时引擎改写系统栏的空档。旧安卓（API≤32）
    // 原生涂色+重申布局 flag；新安卓（API≥33）原生关对比度 scrim 并涂色
    // （35+ 涂色被系统忽略，三键区条带垫由 app.dart 呈现——随底栏材质
    // 色块/玻璃，通道仍发以维护图标亮度）。壁纸模式（竖屏且底栏导航）：
    // 原生涂透明，三键区材质交
    // 给 Flutter 侧磨砂垫/固定底栏玻璃延伸呈现，与顶栏底栏同一份毛玻璃
    // 链，避免死色块色差；侧边栏/横屏沉浸不在此列，维持涂色
    final wallpaperGlass = wallpaperGlassActive(ref);
    final navSide =
        landscape ||
        (ref.watch(
              settingsProvider.select((s) => s.valueOrNull?.navBarPosition),
            ) ==
            NavBarPosition.side);
    final Color? navBarColor;
    if (!navSide && wallpaperGlass) {
      navBarColor = null;
    } else if (landscape) {
      navBarColor = null;
    } else if (floating || navTop) {
      // 顶部导航没有固定底栏，三键区同悬浮模式涂页面背景色
      navBarColor = Theme.of(context).scaffoldBackgroundColor;
    } else {
      final (fill, _) = fixedNavBarSurfaceFill(context, ref);
      navBarColor = Color.alphaBlend(
        fill,
        Theme.of(context).scaffoldBackgroundColor,
      );
    }
    final navBarSent = (
      landscape,
      floating,
      hidden,
      navBarColor,
      // 纳入当前页签：tab 间切换原签名不变、不重发，引擎/ROM 恰在此空档
      // 涂黑三键区时无人对账（实测 Android 12 首启切底栏变黑，进二级页
      // 才恢复——hidden 变化重发即愈）；纳入序号让每次切页签都重申
      widget.navigationShell.currentIndex,
    );
    if (navBarSent != _lastNavBarSent) {
      _lastNavBarSent = navBarSent;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        SystemUiChannel.setNavigationBarColor(navBarColor);
      });
    }

    // chrome 缓存帧抓取门控：竖屏悬浮 chrome（底栏/悬浮顶栏）可见且为
    // 液态材质时才允许抓帧，保证缓存帧里的 chrome 区域是有效液态输出
    chromeGlassFrameActive.value =
        !landscape &&
        !hidden &&
        (ref.watch(
              settingsProvider.select((s) => s.valueOrNull?.liquidGlass),
            ) ??
            true) &&
        !ref.watch(
          settingsProvider.select(
            (s) => performancePriority(s.valueOrNull ?? const AppSettings()),
          ),
        );

    void select(int i) {
      if (i == widget.navigationShell.currentIndex || i == widget.index) return;
      if (searchOpenRaw) closeLandscapeSearch(ref);
      ref.read(landscapeContentPathProvider.notifier).state = null;
      widget.navigationShell.goBranch(
        i,
        initialLocation: i == widget.navigationShell.currentIndex,
      );
    }

    // 转场中沿用上次构建的顶栏实例（identical → Element 跳过子树 rebuild）：
    // 标题/按钮变化会连带毛玻璃 BackdropFilter 重新采样 backdrop 层，
    // 转场中该层不稳定即闪黑；锁定后落定才更新标题
    // 分支页注册的顶栏覆盖（如插件管理）：标题/动作上交壳层，页面纯内容
    final topOverride = ref.watch(shellTopBarOverrideProvider);
    final useOverride = widget.index == 2 && topOverride != null;
    final Widget topBar;
    if (globalIsTransitioning.value && _topBarCache != null) {
      topBar = _topBarCache!;
    } else {
      topBar = _topBarCache = GlassTopBar(
        titleSpacing: widget.index == 0 ? 18 : null,
        title: useOverride
            ? Text(tr(topOverride.title))
            : widget.index == 1
            ? Text(tr('个人中心'))
            : Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: tr('弦予')),
                    TextSpan(
                      text: tr('音乐'),
                      style: const TextStyle(
                        color: Color(0xFFEC4141),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
        actions: [
          if (useOverride)
            for (final action in topOverride.actions)
              IconButton(
                icon: Icon(action.icon),
                tooltip: tr(action.tooltip),
                onPressed: action.onPressed,
              )
          else if (widget.index == 0)
            // 皮肤/设置在左，顶部导航球固定最右；固定顶栏下不画玻璃底，
            // 与旁边皮肤/设置一致只出图标，点击直接切换首页/我的
            IconButton(
              icon: themeSlotWidget(
                ref,
                'entry.wallpaper',
                fallback: const SkinIcon(),
              ),
              tooltip: tr('皮肤'),
              onPressed: () => context.push('/wallpaper'),
            )
          else
            IconButton(
              icon: themeSlotIcon(
                ref,
                'mine.settings',
                fallback: Icons.settings_outlined,
              ),
              tooltip: tr('设置'),
              onPressed: () => context.push('/settings'),
            ),
          if (navTop) ...[
            // 顶部导航球显示目标页图标：在首页显示「我的」人头、在
            // 我的显示「首页」房子，与底栏图标同款（含主题槽位）
            IconButton(
              icon: themeSlotIcon(
                ref,
                widget.index == 0 ? 'nav.settings' : 'nav.home',
                fallback: widget.index == 0
                    ? Icons.person_outline_rounded
                    : Icons.home,
              ),
              onPressed: () => select(widget.index == 0 ? 1 : 0),
            ),
          ],
          const SizedBox(width: 16),
        ],
        bottom: PageSearchBarBottom(
          onTap: () => context.push('/search'),
          onRecognize: () => context.push('/recognize'),
        ),
      );
    }

    Widget buildRailDivider() => Positioned(
      left: _railWidth - 14,
      top: 0,
      bottom: 0,
      width: 28,
      child: _ShellRailDivider(
        onDragUpdate: (dx) {
          final screenW = MediaQuery.sizeOf(context).width;
          final leftSafe = padding.left;
          setState(() {
            _railWidth = (_railWidth + dx).clamp(
              leftSafe + kLandscapeRailIconWidth,
              screenW * 0.5,
            );
          });
          _scheduleRailWidthPersist();
        },
      ),
    );

    // navSide 已在上方三键区底色决策处算好（含横屏判定），此处复用
    final isSide = navSide;

    final expanded = ref.watch(sideBarExpandedProvider);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
          ),
          ValueListenableBuilder<double>(
            valueListenable: orientationContentFade,
            builder: (context, fade, child) =>
                Opacity(opacity: fade, child: child),
            child: Padding(
              // 只垫横向；竖向由页面自垫（悬浮态垫 chrome、固定态垫带高）。
              // 壳层垫 top 会把滚动视口压到带底——内容滚到带下缘就出视口，
              // 顶栏实时模糊永远采不到穿过带下的内容（设置页能透正是因为
              // 其面板页面自垫）。tab 页固定态自垫 GlassTopBar.height(topInset:8)
              padding: EdgeInsets.only(
                left: landscape ? _railWidth : 0,
                right: (landscape && !useCameraArea) ? padding.right : 0,
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    // 悬浮/固定顶栏本体都挂外层全屏 Stack（悬浮胶囊行从屏
                    // 幕左缘起排、固定玻璃贯通到屏幕左缘），此处只放页面内容
                    child: _landscapeFadePanel(
                      useCameraArea: useCameraArea,
                      padding: padding,
                      context: context,
                      child: landscapeHome,
                    ),
                  ),
                  if (landscape)
                    Positioned.fill(
                      child: useCameraArea
                          ? MediaQuery(
                              data: MediaQuery.of(context).copyWith(
                                padding: padding.copyWith(left: 0, right: 0),
                              ),
                              child: _landscapeSlide(
                                enabled: landscapeFadeEnabled,
                                open: anyPaneOpen,
                                trigger: landPaneTrigger,
                                child: landPane,
                              ),
                            )
                          : _landscapeSlide(
                              enabled: landscapeFadeEnabled,
                              open: anyPaneOpen,
                              trigger: landPaneTrigger,
                              child: landPane,
                            ),
                    ),
                  if (landscape &&
                      anyPaneOpen &&
                      !accountOpen &&
                      contentPath == null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LandscapeGlobalTopBar(
                        currentIndex: widget.index,
                        floating: floatingSearchBar,
                      ),
                    ),
                ],
              ),
            ),
          ),

          // 横屏 rail：SafeArea 布局两态共用；悬浮态顶部品牌玻璃卡由
          // rail 自挂（railBrand），固定态品牌挂顶栏带 head 位
          if (landscape)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _railWidth,
              child: _LandscapeRail(
                index: widget.index,
                onSelect: select,
                railWidth: _railWidth,
                floating: floatingSearchBar,
              ),
            ),

          if (landscape) buildRailDivider(),

          // 固定顶栏（无 pane）：挂外层全屏 Stack，玻璃贯通到屏幕左缘、
          // 盖在 rail 列表上层（品牌行由带 head 位承载，不被玻璃盖）。
          // 不能挂内层 Stack：那层的兄弟层会被 Padding.top 下移。
          if (landscape &&
              !floatingSearchBar &&
              !(anyPaneOpen || libPaneActive) &&
              contentPath == null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ValueListenableBuilder<double>(
                valueListenable: orientationContentFade,
                builder: (context, fade, child) =>
                    Opacity(opacity: fade, child: child),
                child: LandscapeGlobalTopBar(
                  currentIndex: widget.index,
                  floating: false,
                  // 玻璃贯通到屏幕左缘，工具行内容从 rail 右缘起排
                  leadingIndent: _railWidth,
                ),
              ),
            ),

          // 悬浮顶栏（无 pane）：与固定顶栏同层挂外层全屏 Stack——工具行
          // 从 rail 中线起排（拖分隔线联动，固定顶栏同口径），品牌胶囊贴
          // 左压在 rail 上方、rail 收窄到放不下时隐藏；pane 打开时让位
          // pane 自带 chrome（仅条件挂载，无需渐隐）
          if (landscape &&
              floatingSearchBar &&
              !(anyPaneOpen || libPaneActive) &&
              contentPath == null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LandscapeGlobalTopBar(
                currentIndex: widget.index,
                floating: true,
                // 工具行从 rail 右缘起排，拖分隔线联动（固定顶栏同口径）；
                // 品牌胶囊按 rail 宽三级联动（顶栏内判定）
                leadingIndent: _railWidth,
              ),
            ),

          if (isSide && !landscape)
            _SideNavRail(
              index: widget.index,
              hidden: hidden,
              expanded: expanded,
              onToggleExpand: () {
                ref.read(sideBarExpandedProvider.notifier).state = !expanded;
              },
              onSelect: select,
            ),

          if (!isSide && !navTop && floating)
            Positioned(
              left: 12,
              right: 12,
              bottom: 18 + safeBottom,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                // 液态 shader 最低 0.01 保温（整树停绘后重显首帧采样
                // 黑闪）；毛玻璃普通 blur 归零停绘，淡入首绘发生在极低
                // alpha（不可见），防 saveLayer 内首帧重采样闪白
                opacity: (hidden || _chromeRecovering)
                    ? glassHiddenOpacityFloor(ref)
                    : 1.0,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  scale: (hidden || _chromeRecovering) ? 0.92 : 1.0,
                  child: IgnorePointer(
                    ignoring: hidden || _chromeRecovering,
                    // 淡出结束后整树卸载：Impeller 下 0.01 常绘子树的
                    // alpha 泄漏会让底栏与选中圆形残留在二级页上
                    child: _chromeGone
                        ? const SizedBox.shrink()
                        : _JellySwitch(
                            key: _jellyKey,
                            mode: true,
                            child: _LiquidNavBar(
                              index: widget.index,
                              onSelect: select,
                              degraded: _chromeFading || _chromeRecovering,
                            ),
                          ),
                  ),
                ),
              ),
            ),

          if (!landscape)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 12,
              right: 12,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                // 液态 shader 0.01 保温防重显黑闪；毛玻璃归零停绘，
                // 淡入首绘在极低 alpha 下防 saveLayer 内重采样闪白
                opacity: (floatingSearchBar && !hidden && !_chromeRecovering)
                    ? 1.0
                    : glassHiddenOpacityFloor(ref),
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  // 与悬浮底栏同款缩小退让（0.92），退场不再只是淡出
                  scale: (floatingSearchBar && !hidden && !_chromeRecovering)
                      ? 1.0
                      : 0.92,
                  child: IgnorePointer(
                    ignoring:
                        !(floatingSearchBar && !hidden && !_chromeRecovering),
                    child: _chromeGone
                        ? const SizedBox.shrink()
                        : FloatingTopBar(
                            chromeFrame: true,
                            title: widget.index == 1
                                ? Text(
                                    tr('个人中心'),
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  )
                                : useOverride
                                ? Text(
                                    tr(topOverride.title),
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  )
                                : Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(text: tr('弦予')),
                                        TextSpan(
                                          text: tr('音乐'),
                                          style: const TextStyle(
                                            color: Color(0xFFEC4141),
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                            onSearchTap: () => context.push('/search'),
                            onRecognize: () => context.push('/recognize'),
                            actions: [
                              if (widget.index == 0)
                                BiliPaiIconButton(
                                  iconChild: themeSlotWidget(
                                    ref,
                                    'entry.wallpaper',
                                    fallback: const SkinIcon(),
                                  ),
                                  tooltip: tr('皮肤'),
                                  onTap: () => context.push('/wallpaper'),
                                )
                              else if (useOverride)
                                for (final action in topOverride.actions)
                                  BiliPaiIconButton(
                                    iconChild: Icon(action.icon),
                                    tooltip: tr(action.tooltip),
                                    onTap: action.onPressed,
                                  )
                              else
                                BiliPaiIconButton(
                                  iconChild: themeSlotWidget(
                                    ref,
                                    'mine.settings',
                                    fallback: const Icon(
                                      Icons.settings_outlined,
                                    ),
                                  ),
                                  tooltip: tr('设置'),
                                  onTap: () => context.push('/settings'),
                                ),
                              // 顶部导航：悬浮顶栏保留侧栏气泡同款玻璃圆球，
                              // 图标显示目标页（首页⇄我的互切），紧挨皮肤/设置
                              if (navTop)
                                BiliPaiIconButton(
                                  iconChild: themeSlotIcon(
                                    ref,
                                    widget.index == 0
                                        ? 'nav.settings'
                                        : 'nav.home',
                                    fallback: widget.index == 0
                                        ? Icons.person_outline_rounded
                                        : Icons.home,
                                  ),
                                  onTap: () =>
                                      select(widget.index == 0 ? 1 : 0),
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),

          if (!landscape && !floatingSearchBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                // 顶栏恒为毛玻璃 BackdropFilter（无 shader 层）：归零停绘，
                // 淡入首绘在极低 alpha 下防 saveLayer 内重采样闪白
                // 竖屏分支通用容器：所有分支（首页/插件/我的）都显示壳顶栏，
                // 分支标题/动作差异由页面经 shellTopBarOverrideProvider 注册
                opacity: !hidden ? 1.0 : 0.0,
                child: IgnorePointer(ignoring: hidden, child: topBar),
              ),
            ),
          const OrientationTransitionOverlay(),
        ],
      ),
      bottomNavigationBar: (!isSide && !floating && !navTop)
          ? _JellySwitch(
              key: _jellyKey,
              mode: false,
              child: _FixedChrome(
                index: widget.index,
                hidden: hidden,
                onSelect: select,
              ),
            )
          : null,
      extendBody: !isSide && !floating && !navTop,
    );
  }
}
