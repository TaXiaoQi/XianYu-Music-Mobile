import 'dart:convert';

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

  @override
  Widget build(BuildContext context) {
    final url = avatar;
    if (url == null || url.isEmpty) return fallback;
    if (url.startsWith('data:image')) {
      final comma = url.indexOf(',');
      if (comma > 0) {
        try {
          final bytes = base64Decode(url.substring(comma + 1));
          return Image.memory(bytes,
              fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
        } catch (_) {
          return fallback;
        }
      }
      return fallback;
    }
    return Image.network(url,
        fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
  }
}
