import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class PlatformCaps {
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isIOS => !kIsWeb && Platform.isIOS;

  static bool get isOhos => !kIsWeb && Platform.operatingSystem == 'ohos';

  /// 桌面歌词：Android 走系统悬浮窗；iOS 走画中画（PiP）小窗，
  /// 两者都是「跨应用悬浮」的合法手段，Dart 层协议一致
  static bool get supportsFloatingLyrics => isAndroid || isIOS;

  static bool get supportsStatusBarLyrics => isAndroid;

  /// 蓝牙/车机歌词：歌词行写入媒体会话标题走蓝牙 AVRCP。
  /// Android 走 MediaSession，iOS 走 Now Playing（audio_service），
  /// 两端媒体会话都承载，iOS 同样可用
  static bool get supportsBluetoothLyrics => isAndroid || isIOS;

  static bool get supportsHomeWidgets => isAndroid;

  static bool get supportsLiveActivity => isIOS;

  static bool get supportsFolderScan => isAndroid;

  /// 沙盒曲库模型：无系统级媒体库扫描的平台，通过文件选择器把音频
  /// 复制进应用沙盒目录（Documents/Music 等）后扫描入库。
  /// 鸿蒙原生如此；iOS 沙盒同理（file_picker 文档选择器 → 拷贝 → 扫描）
  static bool get supportsSandboxLibrary => isOhos || isIOS;

  /// 下载歌曲批量移动到系统公共目录：仅鸿蒙有公共目录写权限
  static bool get supportsBatchMoveToPublicDir => isOhos;

  static bool get showsLibraryAddEntry => supportsFolderScan || supportsSandboxLibrary;

  static bool get supportsCustomDownloadDir => isAndroid;

  static bool get supportsQQShare => isAndroid || isIOS || isOhos;

  static bool get supportsInAppUpdate => isAndroid;

  static bool get supportsDownloadNotification => isAndroid;
}
