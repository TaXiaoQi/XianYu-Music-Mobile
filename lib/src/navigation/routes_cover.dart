part of 'routes.dart';

Page<void> _coverBackPage(
  BuildContext context,
  WidgetBuilder builder, {
  LocalKey? key,
  String? location,
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
    location: location,
  );
}

bool _enablePredictiveBack(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.enablePredictiveBack ??
    true;

bool _livePredictiveBack(BuildContext? context, bool fallback) {
  if (context == null) return fallback;
  return ProviderScope.containerOf(context, listen: false)
          .read(settingsProvider)
          .valueOrNull
          ?.enablePredictiveBack ??
      true;
}

PageTransitionStyle _pageTransitionStyle(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.pageTransitionStyle ??
    PageTransitionStyle.cover;

bool _isSmooth(BuildContext context) =>
    _pageTransitionStyle(context) == PageTransitionStyle.smooth;

Page<void> _coverPage(
  BuildContext context,
  WidgetBuilder builder, {
  LocalKey? key,
  String? location,
}) {
  return _CoverPage(
    key: key,
    builder: builder,
    predictiveBack: _enablePredictiveBack(context),
    location: location,
  );
}

PageRoute<T> coverPageRoute<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
}) {
  return _CoverRoute<T>(
    settings: settings ?? RouteSettings(),
    builder: builder,
    predictiveBack: _enablePredictiveBack(context),
  );
}

class _CoverPage extends Page<void> {
  const _CoverPage({
    super.key,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
      location: location,
    );
  }
}

mixin _CoverGestureCommit<T> on PageRoute<T> {
  @override
  void handleCommitBackGesture() {
    final AnimationController? ctrl = controller;
    navigator?.pop();
    if (ctrl != null && ctrl.isAnimating) {
      late final AnimationStatusListener listener;
      listener = (AnimationStatus status) {
        navigator?.didStopUserGesture();
        ctrl.removeStatusListener(listener);
      };
      ctrl.addStatusListener(listener);
    } else {
      navigator?.didStopUserGesture();
    }
  }
}

class _CoverRoute<T> extends PageRoute<T> with _CoverGestureCommit<T> {
  _CoverRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

  @override
  void install() {
    super.install();
    overlayEntries.first.opaque = opaque;
  }

  @override
  bool get opaque => true;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

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
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return AppPageBackground(child: builder(context));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (kFrameworkPredictiveCompare) {
      return const PredictiveBackPageTransitionsBuilder(
        fallbackColor: Colors.transparent,
      ).buildTransitions(this, context, animation, secondaryAnimation, child);
    }
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (_isSmooth(context)) {
          return _SmoothFadeForwards(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: child,
          );
        }
        final isPortrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        final curved = CurvedAnimation(
          parent: animation,
          curve: isPortrait ? Curves.linear : Curves.easeOut,
          reverseCurve: isPortrait ? Curves.linear : Curves.easeOut.flipped,
        );
        final begin = isPortrait ? const Offset(1, 0) : const Offset(0.25, 0);
        final page = isPortrait
            ? RouteStaticSnapshot(animation: animation, child: child)
            : FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0, 0.45, curve: Curves.easeOutCubic),
                  reverseCurve:
                      const Interval(0, 0.45, curve: Curves.easeOutCubic),
                ),
                child: child,
              );
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: RoutePageBackdrop(
            completion: animation,
            location: location,
            child: page,
          ),
        );
      },
    );
  }
}

class _CoverBackPage extends Page<void> {
  const _CoverBackPage({
    super.key,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverBackRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
      location: location,
    );
  }
}

class _CoverBackRoute extends PageRoute<void> with _CoverGestureCommit<void> {
  _CoverBackRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

  @override
  bool get opaque => true;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

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
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return AppPageBackground(child: builder(context));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (kFrameworkPredictiveCompare) {
      return const PredictiveBackPageTransitionsBuilder(
        fallbackColor: Colors.transparent,
      ).buildTransitions(this, context, animation, secondaryAnimation, child);
    }
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (_isSmooth(context)) {
          final smooth = _SmoothFadeForwards(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: child,
          );
          if (phase == PredictiveBackPhase.idle) return smooth;
          return TransitionBackdrop(
            child: Stack(
              children: [
                smooth,
                PredictiveCoverReturnView(animation: animation),
              ],
            ),
          );
        }
        final isPortrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        final curved = CurvedAnimation(
          parent: animation,
          curve: isPortrait ? Curves.linear : Curves.easeOut,
          reverseCurve: isPortrait ? Curves.linear : Curves.easeOut.flipped,
        );
        final begin = isPortrait ? const Offset(1, 0) : const Offset(0.25, 0);
        final page = isPortrait
            ? RouteStaticSnapshot(animation: animation, child: child)
            : FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0, 0.45, curve: Curves.easeOutCubic),
                  reverseCurve:
                      const Interval(0, 0.45, curve: Curves.easeOutCubic),
                ),
                child: child,
              );
        final transition = SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: RoutePageBackdrop(
            completion: animation,
            location: location,
            child: page,
          ),
        );
        if (phase != PredictiveBackPhase.idle) {
          return Stack(
            children: [
              transition,
              PredictiveCoverReturnView(animation: animation),
            ],
          );
        }
        return transition;
      },
    );
  }
}
