import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import '../plugin/plugin_provider.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import 'glass_settings.dart';
import 'page_search_bar.dart';

class FloatingSearchBar extends ConsumerWidget {
  const FloatingSearchBar({super.key, required this.onTap, this.onRecognize});

  final VoidCallback onTap;

  final VoidCallback? onRecognize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('搜索歌曲、歌手、专辑'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (onRecognize != null &&
                  ref.watch(pluginManagerProvider
                      .select((s) => s.sources.any((p) => p.enabled)))) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRecognize,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.mic_none,
                      size: 17,
                      color: Color(0xFFEC4141),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return FloatingGlassSurface(child: content);
  }
}

class FloatingGlassSurface extends ConsumerWidget {
  const FloatingGlassSurface({super.key, required this.child, this.radius = 22});

  final Widget child;

  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));
    final settling = ref.watch(chromeGlassSettlingProvider);
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;

    if (liquid) {
      final quality = liquidGlassQualitySetting(ref);
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final glass = BiliPaiGlass(
        radius: radius,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: bilipaiBackdropBlurOf(quality),
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: settling
            ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
            : bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: child,
      );
      return liquidGlassShell(context, child: glass, radius: radius);
    }
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: child,
      lowPerf: lowPerf,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
      forceSolid: settling,
      keepFilter: settling,
    );
  }
}

class BiliPaiPill extends ConsumerWidget {
  const BiliPaiPill({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 20,
    this.alwaysLive = false,
    this.freshBackdrop = false,
  });

  final Widget child;

  final VoidCallback? onTap;

  final double radius;

  final bool alwaysLive;

  final bool freshBackdrop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));
    final settling = ref.watch(chromeGlassSettlingProvider);
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );

    if (liquid) {
      final quality = liquidGlassQualitySetting(ref);
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final glass = BiliPaiGlass(
        radius: radius,
        alwaysLive: alwaysLive,
        freshBackdrop: freshBackdrop,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: bilipaiBackdropBlurOf(quality),
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: settling
            ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
            : bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: content,
      );
      return liquidGlassShell(context, child: glass, radius: radius);
    }
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: content,
      lowPerf: lowPerf,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
      forceSolid: settling,
      keepFilter: settling,
    );
  }
}

class FloatingSourcePill extends ConsumerWidget {
  const FloatingSourcePill({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
    this.height = 40,
  });

  final String name;

  final bool selected;

  final VoidCallback onTap;

  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final radius = height / 2;
    return BiliPaiPill(
      onTap: onTap,
      radius: radius,
      alwaysLive: true,
      freshBackdrop: true,
      child: Container(
        height: height,
        constraints: BoxConstraints(
          minWidth: height + 12,
        ),
        padding: EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class BiliPaiIconButton extends StatelessWidget {
  const BiliPaiIconButton({
    super.key,
    this.icon,
    this.iconChild,
    this.onTap,
    this.color,
    this.tooltip,
  });

  final IconData? icon;
  final Widget? iconChild;
  final VoidCallback? onTap;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final iconWidget = SizedBox(
      width: 40,
      height: 40,
      child: IconTheme(
        data: const IconThemeData(size: 20).copyWith(
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: iconChild ??
            Icon(
              icon,
              size: 20,
              color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
    return BiliPaiPill(
      onTap: onTap,
      child: tooltip == null
          ? iconWidget
          : Tooltip(message: tooltip!, child: iconWidget),
    );
  }
}

class FloatingTopBar extends StatelessWidget {
  const FloatingTopBar({
    super.key,
    required this.title,
    required this.onSearchTap,
    this.onRecognize,
    this.actions = const [],
  });

  final Widget title;

  final VoidCallback onSearchTap;

  final VoidCallback? onRecognize;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        BiliPaiPill(
          radius: 20,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              height: 40,
              child: Align(alignment: Alignment.centerLeft, child: title),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FloatingSearchBar(
            onTap: onSearchTap,
            onRecognize: onRecognize,
          ),
        ),
        for (final action in actions) ...[
          const SizedBox(width: 10),
          action,
        ],
      ],
    );
  }
}

class FloatingGlassSearchField extends ConsumerWidget {
  const FloatingGlassSearchField({
    super.key,
    required this.controller,
    this.hint,
    this.readOnly = false,
    this.autofocus = false,
    this.isDense = true,
    this.onChanged,
    this.onTap,
    this.onSubmitted,
    this.showClear = false,
    this.onClear,
  });

  final TextEditingController controller;
  final String? hint;
  final bool readOnly;
  final bool autofocus;

  final bool isDense;

  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final ValueChanged<String>? onSubmitted;
  final bool showClear;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingGlassSurface(
      radius: 22,
      child: SizedBox(
        height: 44,
        child: TextField(
          controller: controller,
          readOnly: readOnly,
          autofocus: autofocus,
          textInputAction: TextInputAction.search,
          style: TextStyle(
            fontSize: 14.5,
            color: scheme.onSurface,
          ),
          textAlignVertical: TextAlignVertical.center,
          cursorColor: scheme.primary,
          onChanged: onChanged,
          onTap: onTap,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 14.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            isDense: isDense,
            contentPadding: const EdgeInsets.symmetric(horizontal: 15),
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search, size: 19, color: scheme.onSurfaceVariant),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 40, minHeight: 44),
            suffixIcon: showClear
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 19),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                        width: 32, height: 44),
                    onPressed: onClear,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class FloatingTabPill extends StatelessWidget {
  const FloatingTabPill({super.key, required this.child, this.height = 48});

  final Widget child;

  final double height;

  @override
  Widget build(BuildContext context) {
    return FloatingGlassSurface(
      radius: height / 2,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Theme(
            data: Theme.of(context).copyWith(
              tabBarTheme: TabBarThemeData(
                dividerColor: Colors.transparent,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class FloatingSearchTopBar extends StatelessWidget {
  const FloatingSearchTopBar({
    super.key,
    required this.field,
    this.onBack,
    this.action,
    this.tabPill,
    this.bottomPill,
  });

  final Widget field;

  final VoidCallback? onBack;

  final Widget? action;

  final Widget? tabPill;

  final Widget? bottomPill;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (onBack != null) ...[
              BiliPaiIconButton(icon: Icons.arrow_back, onTap: onBack),
              const SizedBox(width: 10),
            ],
            Expanded(child: field),
            if (action != null) ...[
              const SizedBox(width: 10),
              action!,
            ],
          ],
        ),
        if (tabPill != null) ...[
          const SizedBox(height: 10),
          tabPill!,
        ],
        if (bottomPill != null) ...[
          const SizedBox(height: 10),
          bottomPill!,
        ],
      ],
    );
  }
}

Widget floatingChromeBar(
  BuildContext context, {
  Widget? leading,
  required Widget title,
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
}) {
  final statusBar = MediaQuery.paddingOf(context).top;
  final bottomH = bottom?.preferredSize.height ?? 0;
  final lead = leading == null
      ? const <Widget>[]
      : [
          _chromeGlassAction(context, leading),
          const SizedBox(width: 10),
        ];
  Widget? bottomRow;
  if (bottom is PageSearchBarBottom) {
    bottomRow = SizedBox(
      height: bottomH,
      child: Align(
        alignment: Alignment.center,
        child: FloatingSearchBar(
          onTap: bottom.onTap,
          onRecognize: bottom.onRecognize,
        ),
      ),
    );
  } else if (bottom != null) {
    bottomRow = FloatingTabPill(height: bottomH, child: bottom);
  }
  return RepaintBoundary(
    child: Padding(
      padding: EdgeInsets.fromLTRB(12, statusBar + 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: kToolbarHeight - 8,
            child: Row(
              children: [
                ...lead,
                BiliPaiPill(
                  radius: 20,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(
                      height: 40,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DefaultTextStyle(
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          child: title,
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                for (final a in actions) ...[
                  const SizedBox(width: 10),
                  _chromeGlassAction(context, a),
                ],
              ],
            ),
          ),
          ?bottomRow,
        ],
      ),
    ),
  );
}

Widget _chromeGlassAction(BuildContext context, Widget w) {
  if (w is BackButton) {
    return BiliPaiIconButton(
      icon: Icons.arrow_back,
      onTap: w.onPressed ?? () => Navigator.of(context).maybePop(),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
    );
  }
  if (w is IconButton) {
    final ic = w.icon;
    return BiliPaiIconButton(
      icon: ic is Icon ? ic.icon : null,
      iconChild: ic is Icon ? null : ic,
      color: w.color ?? (ic is Icon ? ic.color : null),
      tooltip: w.tooltip,
      onTap: w.onPressed,
    );
  }
  if (w is SizedBox) return w;
  return BiliPaiPill(
    radius: 20,
    child: IconTheme(
      data: const IconThemeData(size: 20)
          .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      child: w,
    ),
  );
}
