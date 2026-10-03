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
      child: DualTransitionBuilder(
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
        // 被覆盖侧（壳层/旧界面）同样冻结为静态快照：此前只有主动画侧
        // （推入/弹出的页面）有 RouteStaticSnapshot，壳层的淡出/淡入
        // 全程 live 渲染——整壳 saveLayer + 壳内玻璃 BackdropFilter
        // 逐帧重采样，是转场卡顿主源。快照包在 Fade/Slide 之内，
        // 冻结图随转场一起淡出平移；state 稳定（不随方向重建）。
        child: RouteStaticSnapshot(
          animation: ReverseAnimation(secondaryAnimation),
          child: child!,
        ),
      ),
    );
  }
}
