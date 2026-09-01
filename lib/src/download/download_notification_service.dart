import 'dart:io';
import 'package:flutter/services.dart';

/// 负责发送并实时更新系统通知栏的下载进度弹窗
class DownloadNotificationService {
  static const _channel = MethodChannel('xianyu/download_notification');

  /// 更新下载通知弹窗与进度
  static Future<void> update({
    required String currentTitle,
    required String currentArtist,
    required int doneCount,
    required int totalCount,
    required int progressPercent,
    bool isFinished = false,
    bool isFailed = false,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
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
    } catch (_) {}
  }

  /// 消除下载通知
  static Future<void> dismiss() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('dismissDownloadNotification');
    } catch (_) {}
  }
}
