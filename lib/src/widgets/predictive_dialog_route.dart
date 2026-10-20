import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'predictive_back_transitions.dart';

class PredictiveBackDialogRoute<T> extends PageRoute<T> {
  PredictiveBackDialogRoute({
    required this.builder,
    this.dismissible = false,
    this.closableByBack = true,
    super.settings,
  });

  final WidgetBuilder builder;

  final bool dismissible;

  final bool closableByBack;

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => dismissible ? 'Close' : null;

  @override
  Color? get barrierColor => null;

  @override
  bool get popGestureEnabled => isCurrent && closableByBack;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scrim =
        (isDark ? Colors.black : Colors.black).withValues(alpha: isDark ? 0.54 : 0.32);
    return PopScope(
      canPop: closableByBack,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismissible ? () => Navigator.of(context).pop() : null,
              child: Container(color: scrim),
            ),
            Center(
              child: DialogKeyboardLift(
                // 弹窗直接跟随当前主题（含壁纸模式字体颜色翻转后的
                // dialogTheme/容器色），不再还原基础主题——历史上曾靠
                // 还原绕过白底白字，后来 dialogTheme 已整体翻转深底，
                // 再还原会变成深底黑字不可读
                child: builder(context),
              ),
            ),
          ],
        ),
      ),
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
      builder:
          (
            BuildContext context,
            PredictiveBackPhase phase,
            PredictiveBackEvent? startBackEvent,
            PredictiveBackEvent? currentBackEvent,
          ) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(opacity: curved, child: child);
          },
    );
  }
}

Future<T?> showPredictiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = false,
  bool closableByBack = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    PredictiveBackDialogRoute<T>(
      builder: builder,
      dismissible: barrierDismissible,
      closableByBack: closableByBack,
    ),
  );
}

class DialogKeyboardLift extends StatefulWidget {
  const DialogKeyboardLift({super.key, required this.child});

  final Widget child;

  @override
  State<DialogKeyboardLift> createState() => _DialogKeyboardLiftState();
}

class _DialogKeyboardLiftState extends State<DialogKeyboardLift> {
  final GlobalKey _key = GlobalKey();
  double _dialogH = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureOnce());
  }

  void _measureOnce() {
    if (!mounted || _dialogH > 0) return;
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _dialogH = box.size.height;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final sizeH = mq.size.height;
    final keyboard = mq.viewInsets.bottom;
    double translateY = 0;
    if (keyboard > 0 && _dialogH > 0) {
      final fullH = sizeH + keyboard;
      final naturalTop = (fullH - _dialogH) / 2;
      final currentTop = (sizeH - _dialogH) / 2;
      final visibleBottom = sizeH;
      double desiredTop = naturalTop;
      if (desiredTop + _dialogH > visibleBottom) {
        final floor = visibleBottom - _dialogH;
        desiredTop = floor < 0 ? 0.0 : floor;
      }
      translateY = desiredTop - currentTop;
    }
    return Transform.translate(
      offset: Offset(0, translateY),
      child: RepaintBoundary(
        child: KeyedSubtree(key: _key, child: widget.child),
      ),
    );
  }
}
