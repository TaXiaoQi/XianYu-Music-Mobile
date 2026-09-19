import 'dart:io';

import 'package:flutter/services.dart';

class MediaStoreWriter {
  static const MethodChannel _ch = MethodChannel('xianyu/media_store');

  static Future<bool> get available async {
    if (!Platform.isAndroid) return false;
    try {
      final sdk = await _ch.invokeMethod<int>('getSdkInt');
      return sdk != null && sdk >= 29;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> writeFromPath({
    required String relativePath,
    required String displayName,
    required String mime,
    required String srcPath,
  }) async {
    try {
      return await _ch.invokeMethod<String>('writeFromPath', {
        'relativePath': relativePath,
        'displayName': displayName,
        'mime': mime,
        'srcPath': srcPath,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<bool> deleteMedia(String path) async {
    try {
      return await _ch.invokeMethod<bool>('deleteMedia', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
