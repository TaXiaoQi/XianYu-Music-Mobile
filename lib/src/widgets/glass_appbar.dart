import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'floating_search_bar.dart';
import 'glass_settings.dart';

class GlassTopBar extends ConsumerWidget {
  const GlassTopBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.bottom,
    this.titleSpacing,
    this.flatBackdrop = false,
    this.forceSolid = false,
    this.forceDocked = false,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final double? titleSpacing;

  final bool forceSolid;

  final bool forceDocked;

  final bool flatBackdrop;

  static double height(BuildContext context, {PreferredSizeWidget? bottom}) {
    return MediaQuery.of(context).padding.top +
        kToolbarHeight +
        (bottom?.preferredSize.height ?? 0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final floating = !forceDocked &&
        !landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    if (floating) {
      return floatingChromeBar(
        context,
        leading: leading,
        title: title ?? const SizedBox.shrink(),
        actions: actions ?? const [],
        bottom: bottom,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final prefSolid = glassShouldUseSolid(ref, lowPerf: lowPerf);
    final solid = forceSolid || prefSolid;
    final keepFilterAlive = forceSolid && !prefSolid;
    final wallpaper = wallpaperGlassActive(ref);
    final sigma = kNavSurfaceBlurSigma;
    final fill = solid
        ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
        : (wallpaper
            ? wallpaperNavGlassFill(context)
            : (isDark
                ? Colors.white.withValues(alpha: 0.20)
                : Colors.white.withValues(alpha: 0.52)));
    final glassFill = fill;

    final bar = _bar(context, statusBarHeight);
    final inner = Container(
      decoration: BoxDecoration(
        color: glassFill,
        border: null,
      ),
      child: bar,
    );
    if ((solid && !keepFilterAlive) || flatBackdrop) return inner;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: inner,
      ),
    );
  }

  Widget _bar(BuildContext context, double statusBarHeight) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: statusBarHeight),
        SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: titleSpacing ?? (leading == null ? 16 : 0),
                    right: 16,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      child: title ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              if (actions != null) ...?actions,
            ],
          ),
        ),
        ?bottom,
      ],
    );
  }
}

class PreferredSizeProxy extends StatelessWidget implements PreferredSizeWidget {
  const PreferredSizeProxy({
    super.key,
    required this.height,
    required this.child,
  });

  final double height;
  final Widget child;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) => child;
}