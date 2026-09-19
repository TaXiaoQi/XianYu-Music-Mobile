import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:path/path.dart' as p;

import '../rust/api.dart' as frb;
import '../rust/frb_generated.dart' as frbgen;
import 'application_logger.dart';
import 'db_path.dart';
import 'settings.dart';

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
    await frbgen.RustLib.init(
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

  // 在线播放流缓存初始化（对齐桌面端）：持久目录 + 容量上限。
  // 须在首次触碰流缓存前完成（默认 temp_dir 在 Android 不可持久）。
  try {
    final dataDir = await ref.read(appDataDirProvider.future);
    await frb.setStreamCacheDir(path: p.join(dataDir, 'stream_cache'));
    final settings = await ref.read(settingsProvider.future);
    await frb.setStreamCacheMaxSizeBytes(
      bytes: BigInt.from(settings.streamCacheSizeMB * 1024 * 1024),
    );
    AppLog.info('startup',
        '流缓存初始化: dir=${p.join(dataDir, 'stream_cache')} '
        'max=${settings.streamCacheSizeMB}MB');
  } catch (e) {
    AppLog.warn('startup', '流缓存初始化失败: $e');
  }
});
