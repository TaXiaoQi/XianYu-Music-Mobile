import 'dart:async';
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
                childBuilder: (degraded) => _ScrollFab(
                  visible: showTop,
                  degraded: degraded,
                  wallpaper: wallpaper,
                  icon: Icons.keyboard_double_arrow_up_rounded,
                  tooltip: tr('回到顶部'),
                  onTap: onTop,
                ),
              ),
              const SizedBox(width: 10),
              _Slot(
                visible: showLocate,
                childBuilder: (degraded) => _ScrollFab(
                  visible: showLocate,
                  degraded: degraded,
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

class _Slot extends StatefulWidget {
  const _Slot({required this.visible, required this.childBuilder});

  final bool visible;

  /// 回调携带 degraded（淡入淡出窗口内为 true）：窗口中 opacity<1
  /// 产生 saveLayer，液态 shader 在其内采样图层自身内容会黑底，
  /// 调用方据此先用磨砂兜底，窗口过了再上实时液态
  final Widget Function(bool degraded) childBuilder;

  @override
  State<_Slot> createState() => _SlotState();
}

class _SlotState extends State<_Slot> {
  bool? _lastVisible;

  // 渲显分离：出现时先保持不可见（0.01 保底绘制）让玻璃管线把
  // backdrop 采样跑就绪，数帧后再淡入——小组件晚百来毫秒出现无感知，
  // 好过实底色块遮丑或采样黑帧；淡入淡出同为 180ms 对称动效，
  // 组件树常驻待命不销毁
  bool _shown = false;

  /// 淡入淡出窗口标记：_shown 翻转后仍需覆盖 180ms 透明度过渡，
  /// 期间 opacity<1（saveLayer）不能上液态 shader
  bool _fading = false;

  Timer? _fadeTimer;

  void _markFading() {
    _fadeTimer?.cancel();
    setState(() => _fading = true);
    _fadeTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _fading = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _lastVisible = widget.visible;
    if (widget.visible) _scheduleReveal();
  }

  @override
  void didUpdateWidget(_Slot oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visible = widget.visible;
    if (_lastVisible == visible) return;
    _lastVisible = visible;
    if (visible) {
      _scheduleReveal();
    } else {
      setState(() => _shown = false);
    }
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    super.dispose();
  }

  void _scheduleReveal() {
    if (_shown) return;
    // 6 帧（~100ms）：0.01 低透明度下引擎可能裁剪 backdrop readback，
    // 采样真正就绪偏晚；帧数不足切回玻璃会残留一两帧黑底
    var remaining = 6;
    void tick() {
      if (!mounted) return;
      if (!widget.visible) return;
      remaining--;
      if (remaining > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tick());
        return;
      }
      setState(() => _shown = true);
      _markFading();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tick());
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.visible && _shown;
    // degraded = 兜底窗口：0.01 保底期（ !_shown）、淡入过渡、淡出全程
    final degraded = !visible || _fading;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        // 最低压到 0.01 而非归零：opacity=0 会让整树停止绘制，玻璃管线
        // 与 backdrop 采样也随之停摆，渲染就绪无从谈起
        opacity: visible ? 1 : 0.01,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: visible ? 1 : 0.6,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: widget.childBuilder(degraded),
        ),
      ),
    );
  }
}

class _ScrollFab extends ConsumerStatefulWidget {
  const _ScrollFab({
    required this.visible,
    required this.degraded,
    required this.wallpaper,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final bool visible;

  /// true 时跳过液态 shader（透明度过渡窗口内会黑底），走磨砂兜底
  final bool degraded;

  final bool wallpaper;

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  ConsumerState<_ScrollFab> createState() => _ScrollFabState();
}

class _ScrollFabState extends ConsumerState<_ScrollFab> {
  @override
  Widget build(BuildContext context) {
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
      // 液态参数单点计算，兜底磨砂直接复用同一变量：液态磨砂公式
      // 将来调整时兜底自动跟随，不会出现两处口径漂移
      final blur = bilipaiBackdropBlurOf(quality);
      final tint = bilipaiSurfaceTint(context, ref, quality);
      if (widget.degraded) {
        // 兜底磨砂（opacity<1 的 saveLayer 窗口内不能上 shader）
        surface = ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: button(
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tint,
                ),
                child: iconWidget,
              ),
            ),
          ),
        );
      } else {
        surface = BiliPaiGlass(
          radius: 20,
          refract: bilipaiRefractOf(quality),
          chroma: bilipaiChromaOf(quality),
          blurSigma: blur,
          backgroundColor: tint,
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
      }
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
                    ? wallpaperGlassFill(context, ref)
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
