import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings.dart';
import '../widgets/glass_settings.dart';

final wallpaperActiveProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.customBackground.active ?? false),
  );
});

Color appScaffoldBackground(BuildContext context, WidgetRef ref) {
  return ref.watch(wallpaperActiveProvider)
      ? Colors.transparent
      : appSurfaceBg(context);
}

ColorScheme? lightBaseScheme;
ColorScheme? darkBaseScheme;

TextTheme? lightBaseTextTheme;
TextTheme? darkBaseTextTheme;

Color appSurfaceBg(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF222222) : const Color(0xFFF4F4F6);
}

Color appCardColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF303030) : const Color(0xFFFFFFFF);
}

Color appCardFill(BuildContext context, WidgetRef ref) =>
    ref.watch(wallpaperActiveProvider)
        ? wallpaperBlockFill(context, ref)
        : appCardColor(context);