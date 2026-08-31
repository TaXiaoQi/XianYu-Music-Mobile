// 原生系统分享通道（Android ACTION_SEND）。
//
// share_plus 的 Android 端为回报分享结果走 startActivityForResult + 带
// PendingIntent 的 chooser，国产 ROM（HyperOS 等）的自家分享面板只接管
// 普通 startActivity 发起的 chooser，该路径弹的是 AOSP 原生 sharesheet。
// 此通道复刻原生应用的发法（两参 createChooser + startActivity），
// 与 RwaS 等原生项目弹出的国产系统分享面板一致。
import 'dart:io';

import 'package:flutter/services.dart';

/// 发起系统分享。
/// 返回 true = 已弹出分享面板；false = 发起失败；null = 通道不可用
/// （非 Android 平台或旧版本包），调用方可回退 share_plus。
Future<bool?> shareViaSystem({String? text, String? filePath}) async {
  if (!Platform.isAndroid) return null;
  try {
    const channel = MethodChannel('xianyu/system_share');
    return await channel.invokeMethod<bool>('share', {
      if (text != null && text.isNotEmpty) 'text': text,
      if (filePath != null && filePath.isNotEmpty) 'filePath': filePath,
    });
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return null;
  }
}
