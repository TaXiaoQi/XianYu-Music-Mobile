import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

import '../rust/frb_generated.dart' as frb;
import 'application_logger.dart';

/// 初始化 RustLib 桥接（只初始化一次）。
///
/// 已知平台不手动指定 externalLibrary，交由生成的 [defaultExternalLibraryLoaderConfig]
/// 按平台加载正确的库名：Android `libxianyu_core.so`、Windows `xianyu_core.dll`
/// 等。手动传裸名 `xianyu_core` 会导致 Android 下 dlopen 失败。
///
/// 鸿蒙（ohos）不在 frb 2.12 加载器的已知平台表里（未知平台直接抛异常），
/// 参照 PoC 验证过的方案显式 dlopen：HAP 的 `libs/<abi>/libxianyu_core.so`
/// 由系统加载器按名解析，语义与 Android 一致。
final rustInitProvider = FutureProvider<void>((ref) async {
  final sw = Stopwatch()..start();
  AppLog.info('startup', 'Rust 初始化开始');
  debugPrint('[startup] rust init begin');
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
  debugPrint('[startup] rust init done in ${sw.elapsedMilliseconds}ms');
});
