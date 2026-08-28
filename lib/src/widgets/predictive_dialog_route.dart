import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_colors.dart';
import 'predictive_back_transitions.dart';

/// 弹窗面板不透明（#FFF/#262626 等），文字须按面板明暗用基础前景（黑/白），
/// 不能继承自定义壁纸启用的「亮字/暗字」整体前景（否则白底白字/黑底黑字）。
/// 壁纸分支会对页面 textTheme 全局 apply，这里为弹窗 route 统一恢复
/// 基础 colorScheme + textTheme，覆盖所有经 showPredictiveDialog 的弹窗，
/// 避免逐弹窗手改而遗漏。
Widget _restoreBaseTheme(BuildContext context, Widget child) {
  final t = Theme.of(context);
  final dark = t.brightness == Brightness.dark;
  final scheme = dark ? darkBaseScheme : lightBaseScheme;
  final tt = dark ? darkBaseTextTheme : lightBaseTextTheme;
  if (scheme == null) return child;
  return Theme(
    data: t.copyWith(colorScheme: scheme, textTheme: tt ?? t.textTheme),
    child: child,
  );
}

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
/// 预测返回的「手指信息」（progress/swipeEdge/touchOffset）由系统经
/// `OnBackInvokedCallback` 下发给框架，框架再通过 [TransitionRoute] 的默认
/// 钩子把 progress 写进路由动画控制器驱动缩放。这里**不做任何自定义手势
/// 接管、也不留兜底**，完全照抄 PiliNara/main 的做法——只提供
/// [PredictiveBackPageTransitionsBuilder] 并保持默认钩子不变，因此同一设备上
/// 能得到与二级页面完全一致的跟手行程。
///
/// 使用要点：必须经 root Navigator push（GoRouter 的预测返回只认 root
/// Navigator）；不要包在 showDialog 里，直接调用 [Navigator.push] 或
/// [showPredictiveDialog]。
class PredictiveBackDialogRoute<T> extends PageRoute<T> {
  PredictiveBackDialogRoute({
    required this.builder,
    this.dismissible = false,
    this.closableByBack = true,
    super.settings,
  });

  final WidgetBuilder builder;

  /// 是否能点击遮罩关闭（桌面端「禁止关闭」语义：默认 false）。
  final bool dismissible;

  /// 系统返回 / 预测返回能否关闭弹窗（Android 标准：返回关闭与点遮罩解耦，
  /// 默认 true，即使点遮罩/下滑被禁用也能用返回关闭）。
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

  // 遮罩由 buildPage 自行绘制，路由层不透出 barrier。
  @override
  Color? get barrierColor => null;

  // 满足预测返回接管条件：成为当前页且允许「返回关闭」时，返回手势才跟手。
  // 预测返回手势本身交给 TransitionRoute 的默认实现即可（与 PiliNara 一致）。
  @override
  bool get popGestureEnabled => isCurrent && closableByBack;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scrim =
        (isDark ? Colors.black : Colors.black).withValues(alpha: isDark ? 0.54 : 0.32);
    // 点遮罩关闭由 dismissible 控制；返回与预测返回由 closableByBack 控制。
    // 两者独立：桌面端语义默认禁用点遮罩关闭，但 Android 返回仍能关闭弹窗。
    return PopScope(
      canPop: closableByBack,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 半透明遮罩：dismissible 时点击关掉，否则拦截点击不穿透。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismissible ? () => Navigator.of(context).pop() : null,
              child: Container(color: scrim),
            ),
            Center(child: _restoreBaseTheme(context, builder(context))),
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
    // 关键：必须「始终」挂载 PredictiveBackGestureDetector（WidgetsBinding
    // observer），否则手势开始时（popGestureInProgress 仍为 false）没有
    // observer 认领预测返回，弹窗全程无跟手反馈，只能滑到系统提交阈值才
    // 瞬间关闭——表现为「要滑很长一段才有反应」。detector 内部再按
    // popGestureInProgress 分流：手势中走官方 predictive 过渡（整屏缩放跟手），
    // 非手势的打开/关闭（按钮、编程、系统返回）用纯淡入淡出。
    return PredictiveBackGestureDetector(
      route: this,
      builder:
          (
            BuildContext context,
            PredictiveBackPhase phase,
            PredictiveBackEvent? startBackEvent,
            PredictiveBackEvent? currentBackEvent,
          ) {
            if (popGestureInProgress) {
              return PredictiveBackSharedElementPageTransition(
                animation: animation,
                phase: phase,
                secondaryAnimation: secondaryAnimation,
                startBackEvent: startBackEvent,
                currentBackEvent: currentBackEvent,
                child: child,
              );
            }
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

/// 打开一个支持预测返回的弹窗（root Navigator，可被返回手势跟手关闭）。
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

/// 底部漂浮弹窗路由：与 [PredictiveBackDialogRoute] 使用同一套预测返回接管，
/// 但弹窗贴在屏幕底部、从下往上覆盖，交互动效为竖直滑入/滑出。
///
/// 打开/关闭（按钮、编程、系统返回）与预测返回共用**同一条**竖直过渡：
/// 动画值 0→1 时弹窗自底部滑入、遮罩淡入；1→0 时滑出。因预测返回期间框架
/// 会把手指进度写入本路由的 `animation`，返回手势即表现为弹窗随手指下移，
/// 与普通关闭的动作方向完全一致（「预测和普通一样」）。
class PredictiveBackSheetRoute<T> extends PageRoute<T> {
  PredictiveBackSheetRoute({
    required this.builder,
    this.dismissible = false,
    this.closableByBack = true,
    this.maxWidth = 720,
    super.settings,
  });

  final WidgetBuilder builder;
  final bool dismissible;
  final bool closableByBack;

  /// 弹窗面板最大宽度；手机屏幕宽度小于该值时自然全宽，实现「从下往上覆盖」。
  final double maxWidth;

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
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scrim = Colors.black.withValues(alpha: isDark ? 0.54 : 0.32);
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // 遮罩淡入淡出 + 弹窗自底部竖直滑入/滑出，全部由路由 animation 驱动；
    // 预测返回时框架把手指进度写进 animation，同一份过渡自然跟随手指下滑。
    return Stack(
      fit: StackFit.expand,
      children: [
        FadeTransition(
          opacity: curved,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: dismissible ? () => Navigator.of(context).pop() : null,
            child: Container(color: scrim),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionalTranslation(
            translation: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).evaluate(curved),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: _restoreBaseTheme(context, builder(context)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 过渡已内置在 buildPage，这里只需挂上预测返回接管器（WidgetsBinding
    // observer），不做额外转场——普通与预测共用同一过渡。
    return PredictiveBackGestureDetector(
      route: this,
      builder:
          (
            BuildContext context,
            PredictiveBackPhase phase,
            PredictiveBackEvent? startBackEvent,
            PredictiveBackEvent? currentBackEvent,
          ) => child,
    );
  }
}

/// 打开一个从底部覆盖的预测返回弹窗（root Navigator）。
Future<T?> showPredictiveBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = false,
  bool closableByBack = true,
  double maxWidth = 720,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    PredictiveBackSheetRoute<T>(
      builder: builder,
      dismissible: barrierDismissible,
      closableByBack: closableByBack,
      maxWidth: maxWidth,
    ),
  );
}
