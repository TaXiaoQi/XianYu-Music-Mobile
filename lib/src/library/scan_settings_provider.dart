import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart';

/// 扫描目录项（复用 SQLite library_folders）。
class ScanFolder {
  final String path;
  final int songCount;
  const ScanFolder({required this.path, required this.songCount});

  factory ScanFolder.fromJson(Map<String, dynamic> j) => ScanFolder(
        path: (j['path'] as String?) ?? '',
        songCount: (j['song_count'] as num?)?.toInt() ?? 0,
      );
}

/// 扫描目录列表（读 SQLite）。增删后调用 refresh 刷新。
class ScanFoldersNotifier extends AsyncNotifier<List<ScanFolder>> {
  @override
  Future<List<ScanFolder>> build() => _load();

  Future<List<ScanFolder>> _load() async {
    final dbPath = await ref.read(dbPathProvider.future);
    final jsonStr = await getLibraryFolders(dbPath: dbPath);
    final list = (jsonDecode(jsonStr) as List)
        .map((e) => ScanFolder.fromJson(e as Map<String, dynamic>))
        .toList();
    return list;
  }

  /// 添加扫描目录。
  Future<void> addFolder(String path) async {
    final dbPath = await ref.read(dbPathProvider.future);
    await addLibraryFolder(dbPath: dbPath, path: path);
    state = AsyncData(await _load());
  }

  /// 移除扫描目录。
  Future<void> removeFolder(String path) async {
    final dbPath = await ref.read(dbPathProvider.future);
    await removeLibraryFolder(dbPath: dbPath, path: path);
    state = AsyncData(await _load());
  }

  /// 手动刷新。
  Future<void> refresh() async {
    state = AsyncData(await _load());
  }
}

final scanFoldersProvider =
    AsyncNotifierProvider<ScanFoldersNotifier, List<ScanFolder>>(
  ScanFoldersNotifier.new,
);
