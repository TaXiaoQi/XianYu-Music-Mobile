import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/frb_generated.dart' as frb;
import 'application_logger.dart';

/// 初始化 RustLib 桥接（只初始化一次）。
///
/// 不手动指定 externalLibrary，交由生成的 [defaultExternalLibraryLoaderConfig]
/// 按平台加载正确的库名：Android `libxianyu_core.so`、Windows `xianyu_core.dll`
/// 等。手动传裸名 `xianyu_core` 会导致 Android 下 dlopen 失败。
final rustInitProvider = FutureProvider<void>((ref) async {
  final sw = Stopwatch()..start();
  AppLog.info('startup', 'Rust 初始化开始');
  debugPrint('[startup] rust init begin');
  try {
    await frb.RustLib.init(forceSameCodegenVersion: false);
  } catch (e, st) {
    AppLog.error('startup', 'Rust 初始化失败: $e\n$st');
    rethrow;
  }
  AppLog.info('startup', 'Rust 初始化完成 ${sw.elapsedMilliseconds}ms');
  debugPrint('[startup] rust init done in ${sw.elapsedMilliseconds}ms');
});