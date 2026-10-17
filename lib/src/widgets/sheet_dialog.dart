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

Future<T?> showBottomSheetDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = false,
}) {
  return showPredictiveBottomSheet<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final themed = Theme(data: theme, child: builder(dialogContext));
      return Material(
        color: theme.colorScheme.surface,
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
