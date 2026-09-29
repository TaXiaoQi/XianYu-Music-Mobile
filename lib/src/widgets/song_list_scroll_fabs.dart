import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import '../core/settings.dart';
import '../i18n/i18n.dart';
import 'bilipai_glass.dart';
import 'glass_settings.dart';

class SongListScrollFabs extends ConsumerWidget {
  const SongListScrollFabs({
    super.key,
    required this.controller,
    required this.paths,
    required this.rowTopOf,
    required this.itemExtent,
    this.bottom = 12,
    this.right = 12,
  });

  final ScrollController controller;

  final List<String> paths;

  final double Function(int songIndex) rowTopOf;

  final double itemExtent;

  final double bottom;
  final double right;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(playerProvider.select((s) => s.current));
    final enableScrollToTop = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.enableScrollToTopButton ?? true));
    final wallpaper = wallpaperGlassActive(ref);
    final currentIndex = current == null || current.path.isEmpty
        ? -1
        : paths.indexWhere((p) => p == current.path);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasClients = controller.hasClients;
        final offset = hasClients ? controller.offset : 0.0;
        final hasViewport =
            hasClients && controller.position.hasViewportDimension;
        final viewportH = hasViewport ? controller.position.viewportDimension : 0.0;
        final showTop =
            enableScrollToTop && hasClients && offset > itemExtent;
        var showLocate = false;
        if (currentIndex >= 0 && hasClients && viewportH > 0) {
          final rowTop = rowTopOf(currentIndex);
          final rowBottom = rowTop + itemExtent;
          showLocate = !(rowBottom > offset && rowTop < offset + viewportH);
        }

        void onTop() => controller.animateTo(
              0,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            );

        void onLocate() {
          if (!hasClients || currentIndex < 0) return;
          final target = rowTopOf(currentIndex)
              .clamp(0.0, controller.position.maxScrollExtent);
          controller.animateTo(
            target,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
          );
        }

        return Positioned(
          right: right,
          bottom: bottom,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Slot(
                visible: showTop,
                child: _ScrollFab(
                  visible: showTop,
                  wallpaper: wallpaper,
                  icon: Icons.keyboard_double_arrow_up_rounded,
                  tooltip: tr('回到顶部'),
                  onTap: onTop,
                ),
              ),
              const SizedBox(width: 10),
              _Slot(
                visible: showLocate,
                child: _ScrollFab(
                  visible: showLocate,
                  wallpaper: wallpaper,
                  icon: Icons.my_location_rounded,
                  tooltip: tr('定位当前播放歌曲'),
                  onTap: onLocate,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        // 最低压到 0.01 而非归零：opacity=0 会让整树停止绘制，再次显示
        // 时首帧引擎 backdrop 采样未就绪闪黑；隐去期间保持绘制即可
        // 消除出现/消失两侧的黑闪
        opacity: visible ? 1 : 0.01,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: visible ? 1 : 0.6,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

class _ScrollFab extends ConsumerStatefulWidget {
  const _ScrollFab({
    required this.visible,
    required this.wallpaper,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final bool visible;

  final bool wallpaper;

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  ConsumerState<_ScrollFab> createState() => _ScrollFabState();
}

class _ScrollFabState extends ConsumerState<_ScrollFab> {
  bool? _lastVisible;
  bool _warmup = false;

  // 每次出现都以实底热身数帧（浅色白底/深色黑底，跟随主题），
  // 再交叉切回实时液态玻璃：出现瞬间引擎 backdrop 采样可能尚未跟上，
  // 直接出玻璃会先闪黑底。路由推入/返回（Offstage 换快照→还原）造成
  // 的重进由 BiliPaiGlass 的预烘焙图续展（_startTransitionResume）兜底
  void _syncVisible() {
    final visible = widget.visible;
    if (_lastVisible == visible) return;
    final rising = visible && _lastVisible != true;
    _lastVisible = visible;
    if (!rising || _warmup) return;
    _warmup = true;
    // 10 帧（~160ms）：0.01 低透明度下引擎可能裁剪 backdrop readback，
    // 采样真正就绪偏晚；热身过短会在切回玻璃后残留一两帧黑底
    var remaining = 10;
    void tick() {
      if (!mounted) return;
      remaining--;
      if (remaining > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tick());
        return;
      }
      setState(() => _warmup = false);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tick());
  }

  @override
  Widget build(BuildContext context) {
    _syncVisible();
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconWidget = Icon(widget.icon, size: 20, color: scheme.onSurfaceVariant);
    final onTap = widget.onTap;

    final lowPerf = ref.watch(
        settingsProvider.select((s) => performancePriority(s.valueOrNull ?? const AppSettings())));
    final liquid = (ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.liquidGlass)) ??
        true) &&
        !lowPerf;

    Widget button(Widget child) => Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: child,
          ),
        );

    Widget surface;
    if (liquid) {
      final quality = liquidGlassQualitySetting(ref);
      surface = BiliPaiGlass(
        radius: 20,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: bilipaiBackdropBlurOf(quality),
        backgroundColor: _warmup
            ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
            : bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: button(
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: iconWidget,
          ),
        ),
      );
      surface = liquidGlassShell(context, child: surface, radius: 20);
    } else {
      surface = ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: widget.wallpaper ? navSurfaceBlurSigma(ref) : 10,
            sigmaY: widget.wallpaper ? navSurfaceBlurSigma(ref) : 10,
          ),
          child: button(
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.wallpaper
                    ? wallpaperNavGlassFill(context)
                    : (isDark
                        ? const Color(0x99000000)
                        : const Color(0xE6FFFFFF)),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                ),
                boxShadow: widget.wallpaper
                    ? const []
                    : [
                        BoxShadow(
                          color: Colors.black
                              .withValues(alpha: isDark ? 0.30 : 0.10),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
              ),
              child: iconWidget,
            ),
          ),
        ),
      );
    }
    return Tooltip(message: widget.tooltip, child: surface);
  }
}
