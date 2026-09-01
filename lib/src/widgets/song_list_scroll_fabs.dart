import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import '../core/settings.dart';
import '../i18n/i18n.dart';
import 'glass_settings.dart';

/// 歌曲列表悬浮按钮层：右下角「回到顶部」+「定位当前播放歌曲」两个圆形 FAB，
/// 行为对齐桌面端 SongTable（滚过一屏行高才出现回到顶部；当前歌不在视口内时
/// 显示定位钮，点击平滑滚动到该行）。
///
/// [rowTopOf] 返回指定歌曲行在列表内容坐标系中的顶部偏移（已含顶部 padding
/// 与分组表头），用于「定位播放」的目标位置与「当前行是否在视口内」的判定；
/// [itemExtent] 为每行固定高度。
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

  /// 列表内各条目对应的歌曲路径，用于匹配当前播放歌曲。
  final List<String> paths;

  /// 歌曲下标 → 该行在内容坐标系中的 top 偏移。
  final double Function(int songIndex) rowTopOf;

  /// 每行固定高度（itemExtent）。
  final double itemExtent;

  /// 距容器底部 / 右侧偏移。
  final double bottom;
  final double right;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(playerProvider.select((s) => s.current));
    // 「回到顶部」受常规设置开关控制（对齐桌面端 enableScrollToTopButton）。
    final enableScrollToTop = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.enableScrollToTopButton ?? true));
    // 壁纸模式：悬浮钮套用底栏同款磨砂（wallpaperNavGlassFill + 最深固定模糊）。
    final wallpaper = wallpaperGlassActive(ref);
    final currentIndex = current == null || current.path.isEmpty
        ? -1
        : paths.indexWhere((p) => p == current.path);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasClients = controller.hasClients;
        final offset = hasClients ? controller.offset : 0.0;
        // 首帧时 controller 已 attach 但 viewport 尺寸尚未经 layout 应用
        //（_viewportDimension 仍为 null），必须用 hasViewportDimension 兜底，
        // 否则直接读 viewportDimension 会触发 "Null check operator used on a null value"。
        final hasViewport =
            hasClients && controller.position.hasViewportDimension;
        final viewportH = hasViewport ? controller.position.viewportDimension : 0.0;
        // 滚过一屏行高才显示「回到顶部」（且开关开启）。
        final showTop =
            enableScrollToTop && hasClients && offset > itemExtent;
        // 当前歌在本列表内且不在视口内才显示「定位播放」。
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

/// 固定槽位内的显隐动画：按钮以淡入 + 缩放出现/消失，位置不随显隐跳动。
class _Slot extends StatelessWidget {
  const _Slot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
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

/// 圆形悬浮钮：毛玻璃底 + 细边框 + 投影（对齐桌面端 backdrop-blur 观感）。
///
/// 壁纸模式下与迷你播放条/悬浮底栏同口径：底用 [wallpaperNavGlassFill] 半透明
/// 磨砂、模糊用固定最深 [kNavSurfaceBlurSigma]，并去掉投影（避免半透明胶囊上
/// 投影透成黑色块），仅靠描边 + 模糊维持浮层层次。
class _ScrollFab extends StatelessWidget {
  const _ScrollFab({
    required this.wallpaper,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  /// 是否处于壁纸模式（由外层 [SongListScrollFabs] 根据设置计算传入）。
  final bool wallpaper;

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: wallpaper ? kNavSurfaceBlurSigma : 10,
            sigmaY: wallpaper ? kNavSurfaceBlurSigma : 10,
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: wallpaper
                      ? wallpaperNavGlassFill(context)
                      : (isDark
                          ? const Color(0x99000000)
                          : const Color(0xE6FFFFFF)),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                  boxShadow: wallpaper
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
                child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
