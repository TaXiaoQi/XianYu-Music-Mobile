import 'dart:io';

import 'package:flutter/services.dart';

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
