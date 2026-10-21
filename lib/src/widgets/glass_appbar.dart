import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../theme/theme_tint.dart';
import 'floating_search_bar.dart';
import 'glass_settings.dart';
import 'press_scale.dart';

/// 玻璃底带材质链（GlassTopBar 与行级 GlassBand 共用）：壁纸/毛玻璃口径
/// 填充 + BackdropFilter，毛玻璃关且非壁纸时实底兜底；壁纸模式不 solid，
/// 恒走组件色块滑条
Widget glassBandWrap(
  BuildContext context,
  WidgetRef ref, {
  String? themeSlot,
  bool flatBackdrop = false,

  /// 是否加入路由级共享 backdrop 回读组（navGroupFor）。同组多成员引擎
  /// 只制备一次：首个成员绘制时捕获渲染目标缓存，后绘制成员复用纹理
  /// （impeller canvas.cc FlipBackdrop/texture_slot）——横屏设置路由左
  /// 列带先画（此刻右面板内容尚未绘制），右面板带/面板内 TabBar 带复用
  /// 左带纹理时自己区域还是空背景，读作实底不透内容。右面板侧的带传
  /// false 独立回读，制备时机回到各自绘制点（同 SystemNavGlassPad 新
  /// 成员入组异常改独立回读的先例）
  bool sharedNavGroup = true,
  required Widget child,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final wallpaper = wallpaperGlassActive(ref);
  final frostedOn = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.frostedGlass ?? false));
  final solid = !wallpaper && !frostedOn;
  final sigma = navSurfaceBlurSigma(ref);
  // 壁纸模式组件色块:跟随设置的组件色块强度(widgetAlpha)与文字模式
  // 底色,与底栏/mini 条/卡片口径一致
  final fill = solid
      ? (isDark ? const Color(0xFF222222) : const Color(0xFFF4F4F6))
      : wallpaper
          ? wallpaperGlassFill(context, ref)
          : (isDark
              ? Colors.white.withValues(alpha: 0.20)
              : Colors.white.withValues(alpha: 0.52));
  final glassFill =
      themeSlot == null ? fill : themeTint(ref, themeSlot, fill);
  final inner = Container(
    decoration: BoxDecoration(color: glassFill, border: null),
    child: child,
  );
  if (solid || flatBackdrop) return inner;
  // 静态帧方案：显隐动画（AnimatedOpacity alpha<1）每帧递归重绘子树，
  // BackdropFilter 重 paint 即在 Opacity saveLayer 内重建采样层 → 黑帧；
  // RepaintBoundary 让动画帧复用旧玻璃 layer 不重采样（见
  // debug-liquid-glass-page-flash.md 第十轮），raster 期实时模糊不受影响
  final glass = RepaintBoundary(
    child: ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        // 按路由实例分组（navGroupFor）：与被盖住的 shell 成员绝不混组
        backdropGroupKey: sharedNavGroup ? navGroupFor(context) : null,
        child: inner,
      ),
    ),
  );
  final anim = ModalRoute.of(context)?.animation;
  if (anim == null) return glass;
  // push 进来的二级页：首帧玻璃制备发生在转场中途（backdrop 里叠着
  // 下层路由的滑出画面），RepaintBoundary 旧 raster 恒复用 → 顶栏一直
  // 读转场中间态（壁纸模式 Scaffold 透明，观感读实底；毛玻璃模式底
  // 色恒定无观感差异）。转场 completed 后换 key 重建 boundary，
  // 强制全新制备一次
  return AnimatedBuilder(
    animation: anim,
    builder: (context, child) => RepaintBoundary(
      key: ValueKey(anim.status == AnimationStatus.completed),
      child: child,
    ),
    child: glass,
  );
}

/// 行级玻璃底带：GlassTopBar 抽出的公共材质形态，给横屏设置面板的
/// TabBar 行等非工具栏内容衬底——内容从带下穿过被实时模糊
class GlassBand extends ConsumerWidget {
  const GlassBand({
    super.key,
    this.themeSlot,
    this.sharedNavGroup = true,
    required this.child,
  });

  final String? themeSlot;

  /// 右面板侧的带传 false 退出共享回读组（详见 glassBandWrap）
  final bool sharedNavGroup;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => glassBandWrap(
      context, ref,
      themeSlot: themeSlot, sharedNavGroup: sharedNavGroup, child: child);
}

/// 横屏设置页左列与右面板间拖拽分割条宽度（settings 页 _SettingsDivider）；
/// 右面板玻璃带向左延伸该宽度与左列顶栏相接，避免分割区在顶栏高度露出
/// 壁纸缝（带延伸后标题 spacing 需加回该宽度保持原位）
const double kLandscapeSettingsDividerWidth = 28;

/// 横屏设置面板宿主顶栏高度：embedded 内容顶距自垫该值让滚动内容从
/// 宿主顶栏下穿过被实时模糊。悬浮态胶囊收在挖孔区下缘（padding.top+8），
/// 带底高含挖孔区；固定态玻璃带贴顶（挖孔在横屏左缘，顶部不避让），
/// 顶距固定 8 与悬浮 chrome 同口径
double landscapePanelBand(BuildContext context, WidgetRef ref) {
  if (MediaQuery.of(context).orientation != Orientation.landscape) return 0;
  final floating = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
  return floating
      ? GlassTopBar.height(context)
      : GlassTopBar.height(context, topInset: 8);
}

class GlassTopBar extends ConsumerWidget {
  const GlassTopBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.bottom,
    this.bottomTabController,
    this.titleSpacing,
    this.flatBackdrop = false,
    this.forceDocked = false,
    this.themeSlot,
    this.topInset,
    this.leadingIndent = 0,
    this.sharedNavGroup = true,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  /// 悬浮态下传给 FloatingTabPill 启用水滴选择块;固定态忽略
  final TabController? bottomTabController;

  final double? titleSpacing;

  final bool forceDocked;

  final bool flatBackdrop;

  /// 主题色块槽位 id；该组件被多页复用，只在需要叠色的页面传入。
  final String? themeSlot;

  /// 顶距覆盖：横屏摄像头区延伸时 MediaQuery.padding.top 是挖孔高度
  /// （挖孔实际在左缘，顶部无需避让），固定带由调用方传 8 贴顶，
  /// 与悬浮 chrome 同口径
  final double? topInset;

  /// 内容行起始缩进：横屏固定带贯通到屏幕左缘时，返回/标题等工具行
  /// 内容从 rail 右缘起排，玻璃背景仍铺满整行衬在 rail 标题区背后
  final double leadingIndent;

  /// 右面板侧的带传 false 退出共享回读组（详见 glassBandWrap）
  final bool sharedNavGroup;

  static double height(
    BuildContext context, {
    PreferredSizeWidget? bottom,
    double? topInset,
  }) {
    return (topInset ?? MediaQuery.of(context).padding.top) +
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
        bottomTabController: bottomTabController,
      );
    }

    final statusBarHeight = topInset ?? MediaQuery.of(context).padding.top;
    return glassBandWrap(
      context,
      ref,
      themeSlot: themeSlot,
      flatBackdrop: flatBackdrop,
      sharedNavGroup: sharedNavGroup,
      child: _bar(context, statusBarHeight),
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
              if (leading != null)
                Padding(
                  padding: EdgeInsets.only(left: leadingIndent),
                  child: PressableScale(pressScale: 0.92, child: leading!),
                ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: titleSpacing ??
                        (leading == null ? 16 + leadingIndent : 0),
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
              // SizedBox 是列表里的占位间距，不参与按压
              if (actions != null)
                ...actions!.map(
                  (w) => w is SizedBox
                      ? w
                      : PressableScale(pressScale: 0.92, child: w),
                ),
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