import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class PlatformCaps {
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isIOS => !kIsWeb && Platform.isIOS;

  static bool get isOhos => !kIsWeb && Platform.operatingSystem == 'ohos';

  static bool get supportsFloatingLyrics => isAndroid;

  static bool get supportsStatusBarLyrics => isAndroid;

  static bool get supportsHomeWidgets => isAndroid;

  static bool get supportsLiveActivity => isIOS;

  static bool get supportsFolderScan => isAndroid;

  static bool get supportsSandboxLibrary => isOhos;

  static bool get showsLibraryAddEntry => supportsFolderScan || supportsSandboxLibrary;

  static bool get supportsCustomDownloadDir => isAndroid;

  static bool get supportsQQShare => isAndroid || isIOS;

  static bool get supportsInAppUpdate => isAndroid;

  static bool get supportsDownloadNotification => isAndroid;
}
