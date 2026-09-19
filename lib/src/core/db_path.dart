import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<String> _resolveAppDataDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = p.join(base.path, 'xianyu');
  final d = Directory(dir);
  if (!d.existsSync()) d.createSync(recursive: true);
  return dir;
}

final dbPathProvider = FutureProvider<String>((ref) async {
  final appDir = await _resolveAppDataDir();
  return p.join(appDir, 'library.db');
});

final appDataDirProvider = FutureProvider<String>((ref) async {
  return await _resolveAppDataDir();
});

final coverCacheRootProvider = FutureProvider<String>((ref) async {
  final appData = await _resolveAppDataDir();
  final legacy = Directory(p.join(appData, 'covers'));
  if (legacy.existsSync()) {
    try {
      legacy.deleteSync(recursive: true);
    } catch (_) {}
  }
  final root = Directory(p.join(appData, 'cover_cache'));
  if (!root.existsSync()) root.createSync(recursive: true);
  return root.path;
});