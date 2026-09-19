import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'floating_search_bar.dart';

class FlatTopBar extends ConsumerWidget {
  const FlatTopBar({
    super.key,
    this.leading,
    required this.title,
    this.actions = const [],
    this.bottom,
    this.backgroundColor,
  });

  final Widget? leading;
  final String title;
  final List<Widget> actions;

  final PreferredSizeWidget? bottom;

  final Color? backgroundColor;

  static double height(BuildContext context, {double bottom = 0}) {
    return MediaQuery.paddingOf(context).top + kToolbarHeight + bottom;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final floating = !landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    if (floating) {
      return floatingChromeBar(
        context,
        leading: leading,
        title: Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        actions: actions,
        bottom: bottom,
      );
    }
    return Container(
      color:
          backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top),
          SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                ?leading,
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: leading == null ? 18 : 0,
                      right: 16,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          ?bottom,
        ],
      ),
    );
  }
}
