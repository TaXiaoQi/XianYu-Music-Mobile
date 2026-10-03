import 'dart:io';
import 'package:flutter/services.dart';

import '../core/application_logger.dart';

class DownloadNotificationService {
  static const _channel = MethodChannel('xianyu/download_notification');

  static Future<void> update({
    required String currentTitle,
    required String currentArtist,
    required int doneCount,
    required int totalCount,
    required int progressPercent,
    bool isFinished = false,
    bool isFailed = false,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('updateDownloadProgress', {
        'currentTitle': currentTitle,
        'currentArtist': currentArtist,
        'doneCount': doneCount,
        'totalCount': totalCount,
        'progressPercent': progressPercent,
        'isFinished': isFinished,
        'isFailed': isFailed,
      });
    } catch (e) {
      AppLog.warn('download', '更新下载通知失败: $e');
    }
  }

  static Future<void> dismiss() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('dismissDownloadNotification');
    } catch (e) {
      AppLog.warn('download', '清除下载通知失败: $e');
    }
  }
}
