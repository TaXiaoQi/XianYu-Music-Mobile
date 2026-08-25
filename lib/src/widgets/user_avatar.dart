import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 账号头像图片。
///
/// 服务端 avatar 存的是 `data:image/...;base64,...`（桌面端 `<img src>` 原生
/// 支持），Flutter 的 [Image.network] 不认 data URL，必须解码为字节后用
/// [Image.memory] 渲染；http(s) URL 才走网络加载。
class UserAvatarImage extends StatelessWidget {
  const UserAvatarImage({super.key, required this.avatar, required this.fallback});

  final String? avatar;
  final Widget fallback;

  /// 按 data URL 缓存解码字节。`Image.memory` 以字节实例身份作为缓存键，
  /// 每次 build 重新 `base64Decode` 会生成新实例导致反复解码、切换页面时闪烁；
  /// 缓存保证同一头像始终复用同一字节实例，从而命中 Flutter 内置图像缓存。
  static final Map<String, Uint8List> _bytesCache = {};
  static const int _maxCache = 12;

  @override
  Widget build(BuildContext context) {
    final url = avatar;
    if (url == null || url.isEmpty) return fallback;
    if (url.startsWith('data:image')) {
      final bytes = _cachedBytes(url);
      if (bytes == null) return fallback;
      return Image.memory(bytes,
          fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
    }
    return Image.network(url,
        fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
  }

  /// 解码并缓存某 data URL 的字节；解码失败返回 null。
  static Uint8List? _cachedBytes(String url) {
    final cached = _bytesCache[url];
    if (cached != null) return cached;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      final bytes = base64Decode(url.substring(comma + 1));
      if (_bytesCache.length >= _maxCache) {
        _bytesCache.remove(_bytesCache.keys.first);
      }
      _bytesCache[url] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
