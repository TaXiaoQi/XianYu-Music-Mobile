import 'package:flutter/material.dart';

import 'predictive_dialog_route.dart';

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
      // 跟随当前主题（含壁纸模式字体颜色），不还原基础 scheme：
      // dialogTheme 已随字体颜色翻转，还原会把白卡片/深文字拼回深底上
      final dialog = Dialog(
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: MediaQuery.removePadding(
            context: dialogContext,
            removeTop: true,
            removeBottom: true,
            child: builder(dialogContext),
          ),
        ),
      );
      return dialog;
    },
  );
}
