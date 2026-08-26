import 'package:flutter/material.dart';

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
}) {
  return showPredictiveDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
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
    ),
  );
}