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
    return _PlayerCoverRoute(
      settings: this,
      builder: (context) => PopScope<void>(
        canPop: true,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) return;
          // 预测返回手势全程已有封面回拨动画，跳过避免叠加
          if (PredictiveCoverReturn.instance.returning.value) return;
          final src = PredictiveCoverReturn.instance.sourceRect;
          if (src.isEmpty) return;
          final (sp, nu, tp) = PredictiveCoverReturn.instance.coverSource;
          // 普通返回：飞行期间同样隐藏播放页真封面（避免双封面），
          // flight 在落地瞬间完成，真封面恢复、副本淡出叠回
          final flight = FlyingCover.instance.launch(
            fromRect: src,
            songPath: sp,
            networkUrl: nu,
            thumbPath: tp,
            radius: (src.width * 0.08).clamp(6.0, 32.0).toDouble(),
            targetProvider: () =>
                FlyingCover.instance.targetRect ??
                PredictiveCoverReturn.instance.targetRect,
          );
          PredictiveCoverReturn.instance.returning.value = true;
          unawaited(flight.whenComplete(() {
            PredictiveCoverReturn.instance.returning.value = false;
          }));
        },
        child: builder(context),
      ),
      predictiveBack: predictiveBack,
    );
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
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

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
        if (phase == PredictiveBackPhase.idle) {
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
