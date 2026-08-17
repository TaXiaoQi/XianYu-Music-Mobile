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