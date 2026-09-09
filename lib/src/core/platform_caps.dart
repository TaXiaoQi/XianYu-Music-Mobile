import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台能力集中判定：UI 层按能力隐藏入口，避免散落 `Platform.isX` 裸判断。
///
/// 原则：依赖 Android 原生 API、iOS 系统不提供等价能力的功能（悬浮歌词窗、
/// 状态栏歌词、桌面小组件、任意目录扫描、QQ 直分享、应用内更新），在 iOS 上
/// 隐藏入口而非置灰；后续若以原生等价物（Live Activity / WidgetKit 等）补齐，
/// 只需调整这里的判定。
abstract final class PlatformCaps {
  /// 当前是否 Android。
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// 当前是否 iOS。
  static bool get isIOS => !kIsWeb && Platform.isIOS;

  /// 悬浮歌词窗（Android WindowManager overlay，iOS 无全局悬浮窗 API）。
  static bool get supportsFloatingLyrics => isAndroid;

  /// 状态栏/通知栏歌词（Android 自定义通知文本，iOS 无等价能力；二期可评估
  /// Live Activity 锁屏歌词）。
  static bool get supportsStatusBarLyrics => isAndroid;

  /// 桌面播放小组件（Android AppWidget，iOS 需 WidgetKit 原生扩展，二期）。
  static bool get supportsHomeWidgets => isAndroid;

  /// 扫描任意本地文件夹（Android SAF/MediaStore；iOS 沙盒限制不可行，
  /// 本地库仅限应用内文件——下载与「文件」App 导入）。
  static bool get supportsFolderScan => isAndroid;

  /// 自定义下载目录（Android 直写任意目录；iOS 固定应用 Documents/Downloads，
  /// 经「文件」App 访问）。
  static bool get supportsCustomDownloadDir => isAndroid;

  /// QQ 互联直分享（tencent_kit Android 端已配置；iOS 需 Universal Link
  /// 域名关联，二期补齐，当前走系统分享面板）。
  static bool get supportsQQShare => isAndroid;

  /// 应用内检查更新（Android apk 自更新；iOS 由 App Store 托管）。
  static bool get supportsInAppUpdate => isAndroid;

  /// 下载进度系统通知（Android 通知渠道；iOS 应用内已有进度 UI，二期可用
  /// 本地通知补齐）。
  static bool get supportsDownloadNotification => isAndroid;
}
