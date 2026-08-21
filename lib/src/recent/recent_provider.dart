import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../favorites/favorites_provider.dart';
import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';

/// 最近播放记录项。
class RecentEntry {
  final String songPath;
  final int playedAt;
  final Song? song;
  final QueueItem? onlineItem;
  const RecentEntry({
    required this.songPath,
    required this.playedAt,
    this.song,
    this.onlineItem,
  });

  QueueItem? toQueueItem() => song?.toQueueItem() ?? onlineItem;
}

class RecentState {
  final List<RecentEntry> entries;
  final bool loading;
  const RecentState({this.entries = const [], this.loading = true});

  RecentState copyWith({List<RecentEntry>? entries, bool? loading}) {
    return RecentState(
      entries: entries ?? this.entries,
      loading: loading ?? this.loading,
    );
  }
}

class RecentManager extends StateNotifier<RecentState> {
  RecentManager(this._ref) : super(const RecentState()) {
    refresh();
  }

  final Ref _ref;

  Future<void> refresh() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final json = await statsGetRecentHistory(dbPath: dbPath, limit: BigInt.from(200));
      final list = (jsonDecode(json) as List)
          .map((e) => e as Map<String, dynamic>)
          .toList();
      final paths = list
          .map((e) => e['songPath'] as String? ?? '')
          .where((p) => p.isNotEmpty)
          .toList();

      // 本地歌曲：批量查询曲库元数据。
      final localPaths = paths.where((p) => !_isOnline(p)).toList();
      final songMap = <String, Song>{};
      if (localPaths.isNotEmpty) {
        try {
          final songsJson =
              await getLibrarySongsByPaths(dbPath: dbPath, paths: localPaths);
          for (final e in jsonDecode(songsJson) as List) {
            final s = Song.fromJson(e as Map<String, dynamic>);
            songMap[s.path] = s;
          }
        } catch (_) {}
      }

      final entries = <RecentEntry>[];
      for (final e in list) {
        final path = e['songPath'] as String? ?? '';
        if (path.isEmpty) continue;
        final playedAt = (e['playedAt'] as num?)?.toInt() ?? 0;
        if (_isOnline(path)) {
          // 在线歌曲：尝试从收藏中恢复元数据。
          final fav = _ref
              .read(favoritesProvider)
              .entries
              .where((f) => f.path == path)
              .toList();
          if (fav.isNotEmpty) {
            entries.add(RecentEntry(
              songPath: path,
              playedAt: playedAt,
              onlineItem: fav.first.toQueueItem(),
            ));
          } else {
            entries.add(RecentEntry(songPath: path, playedAt: playedAt));
          }
        } else {
          entries.add(RecentEntry(
            songPath: path,
            playedAt: playedAt,
            song: songMap[path],
          ));
        }
      }
      state = RecentState(entries: entries, loading: false);
    } catch (_) {
      state = const RecentState(entries: [], loading: false);
    }
  }

  bool _isOnline(String path) =>
      path.startsWith('lx://') || path.startsWith('plugin://');

  /// 播放全部（或从指定索引开始）。
  Future<void> play(int index) async {
    final items = state.entries
        .map((e) => e.toQueueItem())
        .whereType<QueueItem>()
        .toList();
    if (items.isEmpty) return;
    await _ref.read(playerProvider.notifier).playQueue(items, startIndex: index);
  }

  Future<void> remove(String songPath) async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      await statsRemoveFromRecentHistory(
          dbPath: dbPath, songPaths: [songPath]);
    } catch (_) {}
    await refresh();
  }

  Future<void> clear() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      await statsClearRecentHistory(dbPath: dbPath);
    } catch (_) {}
    await refresh();
  }
}

final recentProvider = StateNotifierProvider<RecentManager, RecentState>((ref) {
  return RecentManager(ref);
});
