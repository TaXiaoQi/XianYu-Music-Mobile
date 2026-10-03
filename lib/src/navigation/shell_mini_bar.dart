part of 'shell.dart';

mixin HidesShellChrome<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// 缓存 StateController 而非 ProviderContainer：本页可能被每页壁纸的
  /// 嵌套 ProviderScope 包住（RoutePageBackdrop/PageWallpaperScope），pop
  /// 后该子 container 已销毁，dispose 的 postFrame 若再经 container.read
  /// 会抛 "ProviderContainer already disposed" 且丢失减量——计数泄漏后
  /// chrome 永久隐藏。未 override 的全局 provider 状态挂在根 container
  /// 上，缓存 notifier 跨卸载读取始终安全且指向同一份计数。
  StateController<int>? _navBarHidden;

  bool _counted = false;

  bool get hidesChrome => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !hidesChrome) return;
      if (EmbeddedShellScope.of(context)) return;
      _navBarHidden = ProviderScope.containerOf(context, listen: false)
          .read(navBarHiddenProvider.notifier);
      _counted = true;
      AppLogger.instance.log('shell', '进入二级页面 ${widget.runtimeType}');
      _navBarHidden!.state++;
    });
  }

  @override
  void dispose() {
    if (_counted) {
      final controller = _navBarHidden;
      _counted = false;
      AppLogger.instance.log('shell', '离开二级页面 ${widget.runtimeType}');
      if (controller != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (controller.state > 0) controller.state--;
        });
      }
    }
    super.dispose();
  }
}


/// 页面级 mini 播放条黑名单：混入的页面（设置、搜索等）持有期间
/// miniBarHiddenProvider >0，全局播放条在该页面落定后隐藏、离开后恢复；
/// 转场期间不生效（条不受切换动画影响，落定后才淡出/淡入）

mixin HideMiniBar<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// 缓存 StateController 而非 ProviderContainer，原因同 HidesShellChrome：
  /// 嵌套 ProviderScope 包住的页面 pop 后子 container 已销毁，dispose 的
  /// postFrame 经 container.read 会抛 fatal 且丢失减量，miniBarHiddenProvider
  /// 计数泄漏 >0 → 全局 mini 播放条被永久隐藏（重启前不再恢复）
  StateController<int>? _miniBarHidden;

  bool _miniBarCounted = false;

  /// 本页被上层路由覆盖（push 了详情/子页）时是否继续压住播放条。
  /// 默认 true 维持整树隐藏（设置体系等依赖父级计数连坐）；
  /// 音源榜单等"详情页应恢复播放条"的页面覆写为 false。
  bool get hideMiniBarWhenCovered => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (EmbeddedShellScope.of(context)) return;
      _miniBarHidden = ProviderScope.containerOf(context, listen: false)
          .read(miniBarHiddenProvider.notifier);
      _miniBarCounted = true;
      _miniBarHidden!.state++;
      if (hideMiniBarWhenCovered) return;
      // 监听被覆盖状态：覆盖层落定（secondaryAnimation completed）释放
      // 计数让播放条回归，覆盖层 pop 回来（dismissed）后重新压住
      final coverAnim = ModalRoute.of(context)?.secondaryAnimation;
      coverAnim?.addStatusListener(_onCoverStatusChanged);
      // 极端情况：页面创建时已被覆盖（如状态恢复），直接释放
      if (coverAnim?.status == AnimationStatus.completed) _releaseCount();
    });
  }

  void _onCoverStatusChanged(AnimationStatus status) {
    if (hideMiniBarWhenCovered) return;
    if (status == AnimationStatus.completed) {
      // 覆盖层落定：本页不可见，释放计数（已释放时幂等）
      _releaseCount();
    } else if (status == AnimationStatus.dismissed) {
      // 覆盖层离开、本页重新可见：重新压住
      if (_miniBarCounted || !mounted) return;
      _miniBarHidden?.state++;
      _miniBarCounted = true;
    }
    // forward/reverse 为转场途中，保持前一状态不动
  }

  void _releaseCount() {
    if (!_miniBarCounted) return;
    _miniBarCounted = false;
    final controller = _miniBarHidden;
    if (controller != null && controller.state > 0) controller.state--;
  }

  @override
  void dispose() {
    if (_miniBarCounted) {
      final controller = _miniBarHidden;
      _miniBarCounted = false;
      if (controller != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (controller.state > 0) controller.state--;
        });
      }
    }
    super.dispose();
  }
}

class HideShellChrome extends ConsumerStatefulWidget {
  const HideShellChrome({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<HideShellChrome> createState() => _HideShellChromeState();
}

class _HideShellChromeState extends ConsumerState<HideShellChrome>
    with HidesShellChrome {
  @override
  Widget build(BuildContext context) => widget.child;
}
