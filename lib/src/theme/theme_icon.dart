import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/application_logger.dart';
import 'theme_store.dart';

/// 图标槽加载失败的诊断日志：URL 404/防盗链/网络异常/文件缺失都会走到
/// 这里，每个失败 URL 只记一次（errorBuilder 可能被多帧反复调用）。
final Set<String> _loggedFailingUrls = {};

void _logIconError(String? slotId, String url) {
  if (_loggedFailingUrls.add(url)) {
    AppLog.warn('theme',
        '主题图标加载失败 slot=$slotId url=$url（已回落内置图标）');
  }
}

/// data URL 的解码缓存：同一 URL（同一主题包）只解码一次，避免
/// Image.memory 每帧重复解码巨型 base64（编辑器导出的本地包图标即此形态）。
final Map<String, Uint8List?> _dataUrlCache = {};

Uint8List? _decodeDataUrl(String url) {
  if (_dataUrlCache.containsKey(url)) return _dataUrlCache[url];
  Uint8List? bytes;
  final idx = url.indexOf(',');
  if (idx > 0) {
    try {
      bytes = base64Decode(url.substring(idx + 1));
    } on FormatException {
      bytes = null;
    }
  }
  _dataUrlCache[url] = bytes;
  return bytes;
}

/// 按槽位 URL 形态出图：
///  · `data:`——旧版本导入未物化的存量包兜底 → 内存图（解码结果缓存）；
///  · 本地路径——导入时已物化落盘（主流形态）→ 文件图；
///  · http(s)——广场实时下发兜底 → 网络缓存图。
/// 加载中/失败一律回落内置图标（[fallback]，随调用方 color 染色），
/// 保证不出现空位。自定义图保持原色直出、不随槽位 color 染色——
/// 主题作者上传的即所见（v3 决策）。
Widget _themedImage(
  String? slotId,
  String url, {
  double? size,
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  required Widget fallback,
}) {
  final w = width ?? size;
  final h = height ?? size;
  if (url.startsWith('data:')) {
    final bytes = _decodeDataUrl(url);
    if (bytes == null) {
      _logIconError(slotId, url);
      return fallback;
    }
    return Image.memory(
      bytes,
      width: w,
      height: h,
      fit: fit,
      errorBuilder: (_, _, _) => fallback,
    );
  }
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return Image.file(
      File(url),
      width: w,
      height: h,
      fit: fit,
      errorBuilder: (_, _, _) {
        _logIconError(slotId, url);
        return fallback;
      },
    );
  }
  return CachedNetworkImage(
    imageUrl: url,
    width: w,
    height: h,
    fit: fit,
    placeholder: (_, _) => fallback,
    errorWidget: (_, _, _) {
      _logIconError(slotId, url);
      return fallback;
    },
  );
}

/// 主题包预览图（主题中心列表卡片）：与图标槽同规则出图。
/// preview 参与包 id 派生不做物化改写，编辑器导出的本地包可能是
/// data URL，由 [_themedImage] 的三态分支兜底；失败回落 [fallback]。
Widget themePreviewImage(
  String url, {
  required double size,
  BoxFit fit = BoxFit.cover,
  required Widget fallback,
}) {
  return _themedImage(null, url, size: size, fit: fit, fallback: fallback);
}

/// 主题图标槽的渲染入口：该槽有自定义图就出图，否则回落内置图标。
///
/// 契约见《主题中心-移动端客户端对接说明》§4.1：URL 直出、取不到回落内置资源。
/// 底部导航、搜索框等是每帧渲染的高频区域，网络形态必须走缓存。
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

  // 自定义图原色直出；color 只作用于兜底/加载中的内置图标。
  return _themedImage(
    slotId,
    url,
    size: size,
    fallback: Icon(fallback, size: size, color: color),
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
}) {
  final library = ref.watch(themeLibraryProvider);
  final url = slotId == null ? null : library.themeIcon(slotId);
  if (url == null) return fallback;
  return _themedImage(
    slotId,
    url,
    size: size,
    fallback: fallback,
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
  return _themedImage(
    slotId,
    url,
    width: width,
    height: height,
    fallback: const SizedBox.shrink(),
  );
}
