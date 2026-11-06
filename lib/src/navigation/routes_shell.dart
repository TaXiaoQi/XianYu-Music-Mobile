part of 'routes.dart';

class _ShellPage extends Page<void> {
  const _ShellPage({required super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Route<void> createRoute(BuildContext context) {
    return _ShellRoute(page: this);
  }
}

class _ShellTabEntry extends ConsumerWidget {
  const _ShellTabEntry({
    required this.child,
    required this.portraitPageId,
    required this.landscapePageId,
  });

  final Widget child;

  /// 主题包每页壁纸的页面 id（竖屏 home/mine，横屏 ls-home/ls-mine）
  final String portraitPageId;
  final String landscapePageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final landscape = ref.watch(isLandscapeProvider);
    return PageWallpaperScope(
      pageId: landscape ? landscapePageId : portraitPageId,
      child: landscape ? child : AppPageBackground(child: child),
    );
  }
}

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
  Duration get transitionDuration => const Duration(milliseconds: 250);

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
    if (_isSmooth(context)) {
      return _SmoothFadeForwards(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
    }
    return child;
  }
}

class _SmoothFadeForwards extends StatelessWidget {
  const _SmoothFadeForwards({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget? child;

  static final Animatable<Offset> _forwardTranslation = Tween<Offset>(
    begin: const Offset(0.25, 0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<Offset> _backwardTranslation = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(0.25, 0),
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<Offset> _secondaryForwardTranslation = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-0.25, 0),
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<Offset> _secondaryBackwardTranslation =
      Tween<Offset>(
    begin: const Offset(-0.25, 0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeInOutCubicEmphasized));

  static final Animatable<double> _fadeOut = Tween<double>(
    begin: 1,
    end: 0,
  ).chain(CurveTween(curve: const Interval(0, 0.25)));

  /// 预测返回手势期专用：_fadeOut 的 (0, 0.25) 区间在 300ms 正常 pop 里
  /// 是快速让位交叉淡出，但跟手拖拽时表现为「行程刚起步就没底色」。
  /// 手势期前半程保持完全不透明，末段随平移淡出。
  static final Animatable<double> _gestureFadeOut = Tween<double>(
    begin: 1,
    end: 0,
  ).chain(CurveTween(curve: const Interval(0.55, 1, curve: Curves.easeIn)));

  static final Animatable<double> _fadeIn = Tween<double>(
    begin: 0,
    end: 1,
  ).chain(
    CurveTween(curve: const Interval(0, 0.75, curve: Curves.easeOutCubic)),
  );

  @override
  Widget build(BuildContext context) {
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, anim, child) => FadeTransition(
        opacity: _fadeIn.animate(anim),
        child: SlideTransition(
          position: _forwardTranslation.animate(anim),
          child: RouteStaticSnapshot(animation: anim, child: child!),
        ),
      ),
      reverseBuilder: (context, anim, child) => IgnorePointer(
        ignoring: anim.status == AnimationStatus.forward,
        child: FadeTransition(
          opacity: _fadeOut.animate(anim),
          child: SlideTransition(
            position: _backwardTranslation.animate(anim),
            child: RouteStaticSnapshot(animation: anim, child: child!),
          ),
        ),
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: predictiveBackGestureActive,
        // 预测返回手势期：被覆盖页跳过 status 驱动的淡入编排，直接全亮
        // 渲染——手势期顶层路由控制器直接改 value、status 停在
        // completed，这里的 DualTransitionBuilder(ReverseAnimation(
        // secondary)) 也翻成 completed 走正向淡入分支，编排卡在中间
        // 透明度上，下层页面近乎黑屏。正常 push/pop status 正常流转，
        // 编排不受影响。快照 state 经 VLB child 传递，切换不丢状态。
        child: RouteStaticSnapshot(
          animation: ReverseAnimation(secondaryAnimation),
          child: child!,
        ),
        builder: (context, gestureActive, kid) => gestureActive
            ? kid!
            : DualTransitionBuilder(
                animation: ReverseAnimation(secondaryAnimation),
                forwardBuilder: (context, anim, child) => FadeTransition(
                  opacity: _fadeIn.animate(anim),
                  child: SlideTransition(
                    position: _secondaryBackwardTranslation.animate(anim),
                    child: child,
                  ),
                ),
                reverseBuilder: (context, anim, child) => FadeTransition(
                  opacity: _fadeOut.animate(anim),
                  child: SlideTransition(
                    position: _secondaryForwardTranslation.animate(anim),
                    child: child,
                  ),
                ),
                child: kid!,
              ),
      ),
    );
  }
}
