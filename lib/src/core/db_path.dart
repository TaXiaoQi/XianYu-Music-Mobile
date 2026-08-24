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

/// 封面缓存根目录（应用数据目录下的持久目录）。
///
/// SAF 歌曲的封面无法在扫描之外重新提取（Rust 打不开 content:// 路径），
/// 因此封面缓存必须放持久目录，绝不能放系统临时目录（Android 会随时清空
/// cache，清掉后 SAF 歌曲封面将永久丢失）。顺带清理旧版本遗留的临时方案
/// 目录（应用数据目录下的 `covers` 与系统临时目录根）。
final coverCacheRootProvider = FutureProvider<String>((ref) async {
  final appData = await _resolveAppDataDir();
  final legacy = Directory(p.join(appData, 'covers'));
  if (legacy.existsSync()) {
    try {
      legacy.deleteSync(recursive: true);
    } catch (_) {/* 清理失败不影响运行 */}
  }
  final root = Directory(p.join(appData, 'cover_cache'));
  if (!root.existsSync()) root.createSync(recursive: true);
  return root.path;
});