import 'dart:io';

import 'package:flutter/services.dart';

/// MediaStore 写入回退（原生侧见 MainActivity.kt 的 `xianyu/media_store` 通道
/// 与 MediaStoreWriter.kt）。部分国产 ROM 在已授予「所有文件访问」时仍拦截
/// 对公共存储的直接路径写入；API 29+ 应用对自有媒体条目免存储权限，经
/// ContentResolver 落盘可绕开直写限制。
class MediaStoreWriter {
  static const MethodChannel _ch = MethodChannel('xianyu/media_store');

  /// 当前设备是否具备回退能力（Android API 29+ 且通道可达）。
  static Future<bool> get available async {
    if (!Platform.isAndroid) return false;
    try {
      final sdk = await _ch.invokeMethod<int>('getSdkInt');
      return sdk != null && sdk >= 29;
    } catch (_) {
      return false;
    }
  }

  /// 把 [srcPath]（通常为应用缓存临时文件）经 MediaStore 写入公共存储的
  /// [relativePath] 目录（音频须在 Music/ 下，非媒体文件须在 Download/ 下）。
  /// 返回真实落盘绝对路径（同名冲突由 MediaStore 去重，以回查结果为准）；
  /// 失败返回 null（调用方维持原直写错误路径）。
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

  /// 按绝对路径删除本应用经 MediaStore 写入的条目；失败返回 false。
  static Future<bool> deleteMedia(String path) async {
    try {
      return await _ch.invokeMethod<bool>('deleteMedia', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
