import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_store.dart';

/// 主题图标槽的渲染入口：该槽有自定义图就出图，否则回落内置图标。
///
/// 契约见《主题中心-移动端客户端对接说明》§4.1：URL 直出、取不到回落内置资源。
/// 走 [CachedNetworkImage] 而非裸 `Image.network`——底部导航、搜索框等是每帧渲染
/// 的高频区域，必须缓存；加载中与加载失败也一律回落内置图标，保证不会出现空位。
Widget themeSlotIcon(
  WidgetRef ref,
  String? slotId, {
  required IconData fallback,
  double? size,
  Color? color,
}) {
  // 始终 watch，再按需查表：避免"有时 watch 有时不 watch"导致的订阅不一致。
  final library = ref.watch(themeLibraryProvider);
  final url = slotId == null ? null : library.themeIcon(slotId);
  if (url == null) return Icon(fallback, size: size, color: color);

  // Icon 会继承父级 color，图片不会——这里显式传色，保持原有 tint 语义。
  return CachedNetworkImage(
    imageUrl: url,
    width: size,
    height: size,
    fit: BoxFit.contain,
    color: color,
    placeholder: (_, _) => Icon(fallback, size: size, color: color),
    errorWidget: (_, _, _) => Icon(fallback, size: size, color: color),
  );
}

/// 与 [themeSlotIcon] 同规则，但回落是**任意 widget**。
///
/// 用于现有图标不是 `IconData` 而是自绘组件的槽位（如皮肤钮的 `SkinIcon`）：
/// 未启用主题时原样返回那个 widget，所以观感与接线前**逐像素一致**。
Widget themeSlotWidget(
  WidgetRef ref,
  String? slotId, {
  required Widget fallback,
  double? size,
  Color? color,
}) {
  final library = ref.watch(themeLibraryProvider);
  final url = slotId == null ? null : library.themeIcon(slotId);
  if (url == null) return fallback;
  return CachedNetworkImage(
    imageUrl: url,
    width: size,
    height: size,
    fit: BoxFit.contain,
    color: color,
    placeholder: (_, _) => fallback,
    errorWidget: (_, _, _) => fallback,
  );
}

/// 贴纸槽：与图标同规则，但不套用图标尺寸/着色（贴纸是装饰图，保留原色）。
Widget themeSlotSticker(
  WidgetRef ref,
  String? slotId, {
  required double width,
  double? height,
}) {
  final library = ref.watch(themeLibraryProvider);
  final url = slotId == null ? null : library.themeSticker(slotId);
  if (url == null) return const SizedBox.shrink();
  return CachedNetworkImage(
    imageUrl: url,
    width: width,
    height: height,
    fit: BoxFit.contain,
    placeholder: (_, _) => const SizedBox.shrink(),
    errorWidget: (_, _, _) => const SizedBox.shrink(),
  );
}
