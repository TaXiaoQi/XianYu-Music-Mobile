import 'package:flutter/material.dart';

import '../core/app_colors.dart';
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
      final base = Theme.of(dialogContext).brightness == Brightness.dark
          ? darkBaseScheme
          : lightBaseScheme;
      return base == null
          ? dialog
          : Theme(
              data: Theme.of(dialogContext).copyWith(colorScheme: base),
              child: dialog,
            );
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
