import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'image_decode.dart';

class UserAvatarImage extends StatelessWidget {
  const UserAvatarImage({
    super.key,
    required this.avatar,
    required this.fallback,
    this.size = 56,
  });

  final String? avatar;
  final Widget fallback;

  final double size;

  static final Map<String, Uint8List> _bytesCache = {};
  static const int _maxCache = 12;

  @override
  Widget build(BuildContext context) {
    final url = avatar;
    final cw = size.cacheSize(context)?.clamp(1, 256).toInt();
    if (url == null || url.isEmpty) return fallback;
    if (url.startsWith('data:image')) {
      final bytes = _cachedBytes(url);
      if (bytes == null) return fallback;
      return Image.memory(bytes,
          fit: BoxFit.cover,
          cacheWidth: cw,
          errorBuilder: (_, _, _) => fallback);
    }
    return Image.network(url,
        fit: BoxFit.cover,
        cacheWidth: cw,
        errorBuilder: (_, _, _) => fallback);
  }

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
