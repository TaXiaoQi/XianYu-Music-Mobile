part of 'routes.dart';

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
    late final _PlayerCoverRoute route;
    route = _PlayerCoverRoute(
      settings: this,
      builder: (context) => PopScope<void>(
        canPop: true,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) return;
          // 转场打断：进入动画未完成就返回（快速开合）。此刻出向封面
          // 飞行仍在途中（真封面被藏、锚点矩形随页面滑动不在最终位），
          // 再启动返程飞行会从错位起飞且强杀出向副本，两副本叠加
          // 反向转场直接一团糟。打断路径：取消出向副本即止——页面沿
          // 反向转场滑回底部，播放条在拔页后淡入，封面天然归位，
          // 无需第二次飞行
          if (route.animation?.status != AnimationStatus.completed) {
            FlyingCover.instance.cancel();
            return;
          }
          // 预测返回手势全程已有封面回拨动画，跳过避免叠加
          if (PredictiveCoverReturn.instance.returning.value) return;
          // 歌词页关闭一律不飞封面（封面源在屏幕外，飞入很奇怪），
          // 顺手复位歌词态，下次打开从封面页起步
          final lyricsOn = PredictiveCoverReturn.instance.lyricsActive.value;
          PredictiveCoverReturn.instance.lyricsActive.value = false;
          if (lyricsOn) return;
          final src = PredictiveCoverReturn.instance.sourceRect;
          if (src.isEmpty) return;
          final (sp, nu, tp) = PredictiveCoverReturn.instance.coverSource;
          // 沉浸式源为全宽直角整块图（radiusHint=0）：副本以直角全矩
          // 形起飞（与真封面同位同形），落到迷你条圆形封面；传统源
          // 维持卡片圆角估算与默认圆形落点
          final srcRadius = PredictiveCoverReturn.instance.sourceRadius;
          final dstRect = FlyingCover.instance.targetRect ??
              PredictiveCoverReturn.instance.targetRect;
          // 普通返回：飞行期间同样隐藏播放页真封面（避免双封面），
          // flight 在落地瞬间完成，真封面恢复、副本淡出叠回
          final flight = FlyingCover.instance.launch(
            fromRect: src,
            songPath: sp,
            networkUrl: nu,
            thumbPath: tp,
            radius: srcRadius ?? (src.width * 0.08).clamp(6.0, 32.0).toDouble(),
            targetRadius: srcRadius == null
                ? null
                : (dstRect != null && dstRect.width > 0
                    ? dstRect.width / 2
                    : null),
            targetProvider: () =>
                FlyingCover.instance.targetRect ??
                PredictiveCoverReturn.instance.targetRect,
          );
          PredictiveCoverReturn.instance.returning.value = true;
          unawaited(
            flight.whenComplete(() {
              PredictiveCoverReturn.instance.returning.value = false;
            }),
          );
        },
        child: builder(context),
      ),
      predictiveBack: predictiveBack,
    );
    return route;
  }
}

class _PlayerCoverRoute extends PageRoute<void> with _CoverGestureCommit<void> {
  _PlayerCoverRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  @override
  // 系统返回手势不应被“预测动画开关”禁用；播放页是独立 Navigator，
  // 必须由当前路由认领手势后才能提交 maybePop() 返回上一页。
  bool get popGestureEnabled => isCurrent;

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
    // 播放页不走 go_router（无 matchedLocation），按当前方向映射页面 id
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return PageWallpaperScope(
      pageId: landscape ? 'ls-player' : 'player',
      child: builder(context),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final fade = CurvedAnimation(
          parent: animation,
          curve: const Interval(0, 0.45, curve: Curves.easeOut),
          reverseCurve: const Interval(0, 0.45, curve: Curves.easeIn),
        );
        final exit = SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: fade,
            child: RouteStaticSnapshot(animation: animation, child: child),
          ),
        );
        if (phase == PredictiveBackPhase.idle ||
            // 歌词页关闭：封面源在屏幕外，手势回拨同样跳过
            PredictiveCoverReturn.instance.lyricsActive.value) {
          return exit;
        }
        return Stack(
          children: [
            exit,
            PredictiveCoverReturnView(animation: animation),
          ],
        );
      },
    );
  }
}
