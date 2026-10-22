import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/page_wallpaper.dart';
import '../widgets/glass_settings.dart';

/// 页面感知的壁纸激活态：当前页被主题包定义了壁纸，或全局用户壁纸开启。
/// 页面作用域之外（根层/chrome）pageId 为 null，等价于全局语义。
/// wallpaperActiveProvider 随 pageIdProvider 的每页 override 一起作用域化，
/// 必须声明直接依赖，否则嵌套作用域内读取会抛 Riverpod 断言。
final wallpaperActiveProvider = Provider<bool>((ref) {
  return ref.watch(pageWallpaperActiveProvider);
}, dependencies: [pageWallpaperActiveProvider]);

Color appScaffoldBackground(BuildContext context, WidgetRef ref) {
  return ref.watch(wallpaperActiveProvider)
      ? Colors.transparent
      : appSurfaceBg(context);
}

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

/// 次要前景色（文字/图标）：以 onSurface 为基底降透明。
/// onSurfaceVariant/outline 在壁纸文字颜色为「跟随主题」时不参与翻转，
/// 直接铺在壁纸上会发灰不可读；onSurface 始终跟随壁纸文字模式翻转。
Color appSecondaryFg(ColorScheme scheme) =>
    scheme.onSurface.withValues(alpha: 0.62);