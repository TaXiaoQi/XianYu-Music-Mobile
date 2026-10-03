part of 'routes.dart';

/// 播放页开合状态（五级模型第二级：顶层播放 Navigator）。
/// 播放页不经过 go_router（appRouter），独立在播放条之上，
/// 转场时物理盖过播放条；本通知供条显隐/深链接/投屏判断。
final playerOpenNotifier = ValueNotifier<bool>(false);

final playerNavigatorKey = GlobalKey<NavigatorState>();

/// 打开播放页（顶层 Navigator，物理盖过播放条）。
/// 替代原 appRouter.push('/player')：入口只翻转通知，
/// 真正插页由 PlayerNavigatorHost 的监听器完成——
/// 不持有从未挂载的孤儿 GlobalKey（那会让 openPlayer 静默失效）。
void openPlayer() {
  if (playerOpenNotifier.value) return;
  playerOpenNotifier.value = true;
}

/// 关闭播放页（走 Navigator.pop：转场 + 返程封面飞行照常触发）。
void closePlayer() {
  if (!playerOpenNotifier.value) return;
  playerNavigatorKey.currentState?.maybePop();
}

/// 播放页独立 Navigator 宿主：挂在 MaterialApp.builder 的 Stack 中，
/// 层级在 MiniPlayerOverlay（播放条）之上、飞行封面 Overlay 之下。
class PlayerNavigatorHost extends ConsumerStatefulWidget {
  const PlayerNavigatorHost({super.key});

  @override
  ConsumerState<PlayerNavigatorHost> createState() =>
      _PlayerNavigatorHostState();
}

class _PlayerNavigatorHostState extends ConsumerState<PlayerNavigatorHost>
    with WidgetsBindingObserver {
  bool _pageOpen = false;

  /// 开合单一同步点：任何入口翻转 playerOpenNotifier 后，
  /// 在这里统一插页/拔页（含构建期触发的帧末推迟保护）。
  void _onPlayerOpenChanged() {
    final open = playerOpenNotifier.value;
    if (!mounted || open == _pageOpen) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && playerOpenNotifier.value != _pageOpen) {
          setState(() => _pageOpen = playerOpenNotifier.value);
        }
      });
      return;
    }
    setState(() => _pageOpen = open);
  }

  void _syncClosed() {
    if (!_pageOpen) return;
    playerOpenNotifier.value = false; // 统一经监听器回调拔页
  }

  // 新版引擎把 Android back 映射为 escape KeyDown：
  // 用全局键盘监听（焦点无关），播放页内任何组件抢焦点都不影响拦截
  bool _onKey(KeyEvent event) {
    if (_pageOpen &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      playerNavigatorKey.currentState?.maybePop();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    PredictiveBackOffFallback.instance.ensureRegistered();
    _pageOpen = playerOpenNotifier.value; // 通知早于挂载时的兜底对齐
    playerOpenNotifier.addListener(_onPlayerOpenChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    playerOpenNotifier.removeListener(_onPlayerOpenChanged);
    super.dispose();
  }

  // Android 系统返回兜底：播放页不在 go_router 栈上，
  // go_router.popRoute() 返回 false 后会轮到本 observer 关闭播放页
  @override
  Future<bool> didPopRoute() async {
    if (_pageOpen) {
      playerNavigatorKey.currentState?.maybePop();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final predictiveBack = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.enablePredictiveBack)) ??
        true;
    return Navigator(
      key: playerNavigatorKey,
      // pages API 不允许空列表：常驻一个透明待机页兜底，
      // 播放页在其上插入/拔出（拔出后回到透明待机态）
      pages: [
        const _PlayerIdlePage(),
        if (_pageOpen)
          _PlayerCoverPage(
            key: const ValueKey('player-page'),
            predictiveBack: predictiveBack,
            builder: (_) => const PlayerPage(),
          ),
      ],
      onDidRemovePage: (page) {
        // 播放页被移除（pop 完成）：同步开合状态，条按返回节奏淡入
        if (page.key == const ValueKey('player-page')) {
          _syncClosed();
        }
      },
    );
  }
}

/// 播放 Navigator 的常驻待机页：满足 pages API 非空要求。
/// 故意不用 PageRouteBuilder——ModalRoute 的 barrier 会吸走其下
/// 所有触摸；裸 Route 无 barrier，纯透明占位不拦截任何事件。
class _PlayerIdlePage extends Page<void> {
  const _PlayerIdlePage();

  @override
  Route<void> createRoute(BuildContext context) =>
      _PlayerIdleRoute(settings: this);
}

class _PlayerIdleRoute extends Route<void> {
  _PlayerIdleRoute({super.settings});

  final OverlayEntry _entry =
      OverlayEntry(builder: (_) => const SizedBox.shrink());

  @override
  List<OverlayEntry> get overlayEntries => <OverlayEntry>[_entry];
}

/// 预测返回手势的兜底认领者。
///
/// 引擎只在有认领者时才派发 commit：各路由 detector 因预测关闭、根部
/// （无可弹路由）或任何 popGestureEnabled=false 而 decline 时，若无人
/// 认领，commit 不进 Dart，系统按默认行为直接 finish 退出应用。
/// 这里无条件兜底认领（observer 逆序遍历中 detector 先被问，认领时
/// 轮不到这里），commit 时按经典返回处理（播放页优先，其余走 go_router
/// 栈：pop 二级页 / 切回主 tab / 再按一次退出）。
class PredictiveBackOffFallback with WidgetsBindingObserver {
  PredictiveBackOffFallback._();

  static final PredictiveBackOffFallback instance =
      PredictiveBackOffFallback._();

  static bool _registered = false;

  void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    WidgetsBinding.instance.addObserver(instance);
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 按键返回走经典链路（escape KeyDown / popRoute），不认领
    if (backEvent.isButtonEvent) return false;
    // 兜底认领：observer 逆序遍历中，各路由的 detector（注册更晚）先被问，
    // detector 认领（预测开且该页 popGestureEnabled）时轮不到这里；
    // 全部 decline 时（预测关、根部、或任何 popGestureEnabled=false 的页面）
    // 由这里保住 commit 派发——否则引擎不派发 commit，系统按默认行为
    // 直接 finish 退出应用。commit 统一走 handleCommitBackGesture
    // （播放页优先，其余根栈 maybePop 回退到经典返回）
    return true;
  }

  @override
  void handleCommitBackGesture() {
    // 与 didPopRoute 同序：播放页优先，其余交给根栈
    // （shell 的 PopScope 决定 pop 二级页 / 切回主 tab / 再按一次退出）
    if (playerOpenNotifier.value) {
      playerNavigatorKey.currentState?.maybePop();
      return;
    }
    appNavigatorKey.currentState?.maybePop();
  }

  // 按键返回（引擎 popRoute）链路：handlePopRoute 按注册顺序遍历，
  // 本 observer 在 app initState 注册、先于 Router——播放页开着时
  // 先关播放页，防止根栈二级页被 go_router 抢先 pop（返回手势
  // 走 handleCommitBackGesture 已天然播放页优先，无此问题）
  @override
  Future<bool> didPopRoute() async {
    if (playerOpenNotifier.value) {
      playerNavigatorKey.currentState?.maybePop();
      return true;
    }
    return false;
  }
}
