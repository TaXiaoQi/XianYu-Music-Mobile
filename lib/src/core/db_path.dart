import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用数据目录（small & beautiful：仅存库与缓存，不拉大文件）。
Future<String> _resolveAppDataDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = p.join(base.path, 'xianyu');
  final d = Directory(dir);
  if (!d.existsSync()) d.createSync(recursive: true);
  return dir;
}

/// 数据库文件路径（主库）。
final dbPathProvider = FutureProvider<String>((ref) async {
  final appDir = await _resolveAppDataDir();
  return p.join(appDir, 'library.db');
});

/// 数据目录（供 write_state_json / covers 缓存等使用）。
final appDataDirProvider = FutureProvider<String>((ref) async {
  return await _resolveAppDataDir();
});

/// 封面缓存根目录（系统临时缓存目录）。
///
/// 封面缩略图可随时从音频标签重新提取，放系统缓存目录让 Android
/// 在存储紧张时自动回收；顺带清理旧版本遗留在应用数据目录下的
/// 封面缓存，避免成为永不回收的孤儿文件。
final coverCacheRootProvider = FutureProvider<String>((ref) async {
  final legacy = Directory(
    p.join(await _resolveAppDataDir(), 'covers'),
  );
  if (legacy.existsSync()) {
    try {
      legacy.deleteSync(recursive: true);
    } catch (_) {/* 清理失败不影响运行 */}
  }
  final tmp = await getTemporaryDirectory();
  return tmp.path;
});