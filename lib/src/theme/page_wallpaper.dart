import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'theme_package.dart';
import 'theme_store.dart';

export 'theme_package.dart' show PageWallpaper;
export 'theme_store.dart' show themeLibraryProvider;

/// 当前页面 id：由每页作用域（PageWallpaperScope / RoutePageBackdrop）向下
/// 注入，作用域之外为 null（即全局壁纸语义）。页面内的脚手架底色、组件
/// 色块等壁纸相关解析据此按页生效。
final pageIdProvider = Provider<String?>((ref) => null);

/// 覆盖路由的路径 → 页面 id；未映射路径返回 null（回落全局壁纸）。
/// 竖屏/横屏各自成页：home 与 ls-home 是包内两个独立槽位。
String? pageIdForLocation(String? location, {required bool landscape}) {
  if (location == null || location.isEmpty) return null;
  if (landscape) {
    return switch (location) {
      '/player' => 'ls-player',
      '/settings' => 'ls-settings',
      _ => null,
    };
  }
  return switch (location) {
    '/player' => 'player',
    '/settings' => 'settings',
    '/recognize' => 'recognize',
    '/search' => 'search',
    '/search/result' => 'search_result',
    _ => null,
  };
}

/// 主题包页面壁纸 → 客户端 CustomBackground：0~100 整数语义与全局壁纸设置
/// 完全一致（blur 渲染 ×0.6、scale/100、位移按页面宽高百分比），缺省参数
/// 取 CustomBackground 既有默认；横屏参数未设置时回落竖屏值。
/// ref 已由导入层归一化为本地文件路径。
CustomBackground pageWallpaperToCustomBackground(PageWallpaper wp) {
  return CustomBackground(
    enabled: true,
    imagePath: wp.ref,
    mediaType: WallpaperMediaType.image,
    blur: wp.blur ?? 20,
    opacity: wp.opacity ?? 100,
    maskAlpha: wp.maskAlpha ?? 40,
    scale: wp.scale ?? 100,
    translateX: wp.translateX ?? 0,
    translateY: wp.translateY ?? 0,
    landscapeScale: wp.landscapeScale ?? wp.scale ?? 100,
    landscapeTranslateX: wp.landscapeTranslateX ?? wp.translateX ?? 0,
    landscapeTranslateY: wp.landscapeTranslateY ?? wp.translateY ?? 0,
  );
}

/// 当前页的主题包壁纸：仅包内定义了该页时非空，不回落全局。
/// 依赖链上的 provider 必须声明 dependencies（pageIdProvider 会被每页
/// 作用域 override，Riverpod 据此在作用域内重建本 provider）。
final themedPageWallpaperProvider = Provider<CustomBackground?>((ref) {
  final pageId = ref.watch(pageIdProvider);
  if (pageId == null) return null;
  final wp = ref.watch(
      themeLibraryProvider.select((s) => s.active?.wallpapers[pageId]));
  if (wp == null) return null;
  return pageWallpaperToCustomBackground(wp);
}, dependencies: [pageIdProvider]);

/// 当前页生效壁纸：包页面壁纸优先，未覆盖回落全局用户壁纸（可能为 null）。
final pageWallpaperProvider = Provider<CustomBackground?>((ref) {
  final themed = ref.watch(themedPageWallpaperProvider);
  if (themed != null) return themed;
  final cb = ref
      .watch(settingsProvider.select((s) => s.valueOrNull?.customBackground));
  return (cb != null && cb.active) ? cb : null;
}, dependencies: [themedPageWallpaperProvider]);

/// 当前页是否有壁纸背景（包页面壁纸或全局壁纸）。
final pageWallpaperActiveProvider = Provider<bool>((ref) {
  return ref.watch(pageWallpaperProvider) != null;
}, dependencies: [pageWallpaperProvider]);
