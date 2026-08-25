import 'package:flutter/material.dart';

import 'predictive_dialog_route.dart';

/// 把原本从底部滑出的上弹窗内容改为居中弹窗展示（对齐「修改弦予号」弹窗风格）。
///
/// - 居中于屏幕，固定最大宽度，过高内容由内容自身滚动
/// - 不可点击遮罩、不可下滑关闭，只能通过内部按钮关闭
/// - 用 [showPredictiveDialog] 建模为参与预测返回的页面路由，
///   使返回手势对弹窗有跟手行程可随（内部按钮关闭语义由 PopScope 守卫）
/// - [builder] 收到的是弹窗自身的 context，可直接 `Navigator.pop(context)` 关闭
Future<T?> showSheetDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = false,
}) {
  return showPredictiveDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: builder(dialogContext),
      ),
    ),
  );
}