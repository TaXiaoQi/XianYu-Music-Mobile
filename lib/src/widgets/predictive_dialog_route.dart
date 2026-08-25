import 'package:flutter/material.dart';

/// 让弹窗参与 Android 预测返回的自定义页面路由。
///
/// 原生 [DialogRoute]（showDialog 产生）不是 PageRoute，Navigator 的预测返回
/// 接管器（_PredictiveBackGestureDetectorState）要求 `route.isCurrent &&
/// route.popGestureEnabled` 才会返回 true——只有用
/// [PredictiveBackPageTransitionsBuilder] 构建过渡的页面路由满足。因此普通
/// 弹窗在预测返回手势下既无跟手行程也无法跟手，只走一次性 pop。
///
/// 本路由把弹窗建模为 [PageRoute]，过渡交给
/// [PredictiveBackPageTransitionsBuilder]，让弹窗获得与二级页面一致的预测
/// 返回「行程」：手指拖动时整屏缩放成圆角矩形跟随，松手提交即关闭弹窗。
///
/// 使用要点：必须经 root Navigator push（GoRouter 的预测返回只认 root
/// Navigator）；不要包在 showDialog 里，直接调用 [Navigator.push] 或
/// [showPredictiveDialog]。
class PredictiveBackDialogRoute<T> extends PageRoute<T> {
  PredictiveBackDialogRoute({
    required this.builder,
    this.dismissible = true,
    super.settings,
  });

  final WidgetBuilder builder;
  final bool dismissible;

  static const PredictiveBackPageTransitionsBuilder _predictive =
      PredictiveBackPageTransitionsBuilder();

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

  // 遮罩由 buildPage 自行绘制，路由层不透出 barrier。
  @override
  Color? get barrierColor => null;

  // 满足预测返回接管条件：成为当前页且允许返回时，返回手势才跟手。
  @override
  bool get popGestureEnabled => isCurrent && dismissible;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scrim =
        (isDark ? Colors.black : Colors.black).withValues(alpha: isDark ? 0.54 : 0.32);
    // 仅「可外部关闭」的弹窗参与预测返回；不可外部关闭的（如仅允许内部
    // 按钮操作的面板）用 PopScope 同时拦截系统返回与预测返回，保持语义。
    return PopScope(
      canPop: dismissible,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 半透明遮罩：可关闭时点击关掉，不可关闭时拦截点击不穿透。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismissible ? () => Navigator.of(context).pop() : null,
              child: Container(color: scrim),
            ),
            Center(child: builder(context)),
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
    // 交给官方预测返回过渡：gesture 中整屏缩放跟手，松手提交关闭；
    // 非导航（按钮/编程）时回退 FadeForwards 弹入。
    return _predictive.buildTransitions(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// 打开一个支持预测返回的弹窗（root Navigator，可被返回手势跟手关闭）。
Future<T?> showPredictiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    PredictiveBackDialogRoute<T>(
      builder: builder,
      dismissible: barrierDismissible,
    ),
  );
}