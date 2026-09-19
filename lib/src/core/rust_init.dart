import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

import '../rust/frb_generated.dart' as frb;
import 'application_logger.dart';

final rustInitProvider = FutureProvider<void>((ref) async {
  final sw = Stopwatch()..start();
  AppLog.info('startup', 'Rust 初始化开始');
  try {
    final knownPlatform = !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isWindows ||
            Platform.isIOS ||
            Platform.isMacOS ||
            Platform.isLinux);
    await frb.RustLib.init(
      forceSameCodegenVersion: false,
      externalLibrary: knownPlatform
          ? null
          : ExternalLibrary.open('libxianyu_core.so'),
    );
  } catch (e, st) {
    AppLog.error('startup', 'Rust 初始化失败: $e\n$st');
    rethrow;
  }
  AppLog.info('startup', 'Rust 初始化完成 ${sw.elapsedMilliseconds}ms');
});
