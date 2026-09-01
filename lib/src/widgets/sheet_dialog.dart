import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import 'predictive_dialog_route.dart';

/// 把原本从底部滑出的上弹窗内容改为居中弹窗展示（对齐「修改弦予号」弹窗风格）。
///
/// - 居中于屏幕，固定最大宽度，过高内容由内容自身滚动
/// - 不可点击遮罩、不可下滑关闭（桌面端语义），但系统返回/预测返回可关闭
/// - 用 [showPredictiveDialog] 建模为参与预测返回的页面路由，
///   使返回手势可关闭弹窗
/// - [builder] 收到的是弹窗自身的 context，可直接 `Navigator.pop(context)` 关闭
Future<T?> showSheetDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = true,
  double maxWidth = 380,
}) {
  return showPredictiveDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) {
      final dialog = Dialog(
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          // 弹窗是屏幕居中的 Dialog，并不贴着状态栏/底部安全区；若内容里用了
          // SafeArea，会凭空多加一段状态栏高度的顶部/底部空白。这里把安全区内边距
          // 清零（保留 viewInsets，键盘避让仍正常），统一消除所有该风格弹窗的顶部空白。
          child: MediaQuery.removePadding(
            context: dialogContext,
            removeTop: true,
            removeBottom: true,
            child: builder(dialogContext),
          ),
        ),
      );
      // 弹窗面板不透明（#FFF/#262626），其文字应保持明暗主题各自的内置前景，
      // 用基础配色恢复，避免自定义壁纸启用的「亮字/暗字」前景把弹窗文字也变成
      // 白底白字/黑底黑字。PredictiveBackDialogRoute 已统一恢复 colorScheme +
      // textTheme，此处沿用 base colorScheme 语义，视觉一致。
      final base = Theme.of(dialogContext).brightness == Brightness.dark
          ? darkBaseScheme
          : lightBaseScheme;
      // 键盘避让已在 PredictiveBackDialogRoute 的 Center 下统一处理（DialogKeyboardLift），
      // 这里不再重复包裹，避免二次位移。
      return base == null
          ? dialog
          : Theme(
              data: Theme.of(dialogContext).copyWith(colorScheme: base),
              child: dialog,
            );
    },
  );
}

/// 底部漂浮弹窗（播放页音质 / 下载 / 播放列表等）：从下往上覆盖、支持预测返回。
///
/// - 面板贴屏幕底部、圆角顶角，手机屏自然全宽铺满（覆盖式抽屉）
/// - 不可点遮罩、不可下滑关闭（桌面端语义），但系统返回/预测返回可关闭
/// - 键盘弹出时整体上移避让（底部 padding = viewInsets），收起自动回落
/// - 面板不透明，文字沿用明暗主题各自的内置前景，避免自定义壁纸把弹窗文字
///   变成白底白字 / 黑底黑字
Future<T?> showBottomSheetDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = false,
}) {
  return showPredictiveBottomSheet<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) {
      final base = Theme.of(dialogContext).brightness == Brightness.dark
          ? darkBaseScheme
          : lightBaseScheme;
      final scheme = base ?? Theme.of(dialogContext).colorScheme;
      final themed = Theme(data: base == null ? Theme.of(dialogContext) : Theme.of(dialogContext).copyWith(colorScheme: base), child: builder(dialogContext));
      return Material(
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        elevation: 20,
        shadowColor: Colors.black45,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(dialogContext).bottom,
          ),
          child: SafeArea(top: false, child: themed),
        ),
      );
    },
  );
}

/// 键盘避让已统一放到 [PredictiveBackDialogRoute] 的 Center 下（DialogKeyboardLift），
/// 所有 showPredictiveDialog / showSheetDialog 居中弹窗自动生效；定义见
/// predictive_dialog_route.dart。