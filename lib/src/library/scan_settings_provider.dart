import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart';

class ScanFolder {
  final String path;
  final int songCount;
  const ScanFolder({required this.path, required this.songCount});

  factory ScanFolder.fromJson(Map<String, dynamic> j) => ScanFolder(
        path: (j['path'] as String?) ?? '',
        songCount: (j['song_count'] as num?)?.toInt() ?? 0,
      );
}

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

  Future<void> addFolder(String path) async {
    final dbPath = await ref.read(dbPathProvider.future);
    await addLibraryFolder(dbPath: dbPath, path: path);
    state = AsyncData(await _load());
  }

  Future<void> removeFolder(String path) async {
    final dbPath = await ref.read(dbPathProvider.future);
    await removeLibraryFolder(dbPath: dbPath, path: path);
    state = AsyncData(await _load());
  }

  Future<void> refresh() async {
    state = AsyncData(await _load());
  }
}

final scanFoldersProvider =
    AsyncNotifierProvider<ScanFoldersNotifier, List<ScanFolder>>(
  ScanFoldersNotifier.new,
);
