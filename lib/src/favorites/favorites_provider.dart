import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/player_provider.dart';

/// 收藏歌曲（本地或在线）。
class FavoriteEntry {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String? onlineSongJson;
  final String? onlineQuality;
  final int addedAt;

  FavoriteEntry({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.onlineSongJson,
    this.onlineQuality,
    required this.addedAt,
  });

  bool get isOnline =>
      path.startsWith('lx://') || path.startsWith('plugin://');

  QueueItem toQueueItem() => QueueItem(
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        onlineSongJson: onlineSongJson,
        onlineQuality: onlineQuality,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': durationMs,
        'onlineSongJson': onlineSongJson,
        'onlineQuality': onlineQuality,
        'addedAt': addedAt,
      };

  factory FavoriteEntry.fromJson(Map<String, dynamic> j) => FavoriteEntry(
        path: j['path'] as String? ?? '',
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        onlineSongJson: j['onlineSongJson'] as String?,
        onlineQuality: j['onlineQuality'] as String?,
        addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 收藏存储（SharedPreferences 持久化，支持本地与在线歌曲）。
class FavoritesStore {
  static const _key = 'xianyu_favorites_v1';

  Future<List<FavoriteEntry>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => FavoriteEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveAll(List<FavoriteEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }
}

class FavoritesState {
  final List<FavoriteEntry> entries;
  final bool loading;

  const FavoritesState({this.entries = const [], this.loading = true});

  FavoritesState copyWith({List<FavoriteEntry>? entries, bool? loading}) {
    return FavoritesState(
      entries: entries ?? this.entries,
      loading: loading ?? this.loading,
    );
  }
}

class FavoritesManager extends StateNotifier<FavoritesState> {
  FavoritesManager(this._ref) : super(const FavoritesState()) {
    refresh();
  }

  final Ref _ref;
  final FavoritesStore _store = FavoritesStore();

  Future<void> refresh() async {
    final entries = await _store.loadAll();
    state = FavoritesState(entries: entries, loading: false);
  }

  bool isFavorite(String path) =>
      state.entries.any((e) => e.path == path);

  Future<void> toggle(QueueItem item) async {
    final existing = state.entries.where((e) => e.path == item.path).toList();
    if (existing.isNotEmpty) {
      await remove(item.path);
    } else {
      await add(item);
    }
  }

  Future<void> add(QueueItem item) async {
    if (isFavorite(item.path)) return;
    final entry = FavoriteEntry(
      path: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      durationMs: item.durationMs,
      onlineSongJson: item.onlineSongJson,
      onlineQuality: item.onlineQuality,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final entries = [entry, ...state.entries];
    await _store.saveAll(entries);
    state = FavoritesState(entries: entries, loading: false);
  }

  Future<void> remove(String path) async {
    final entries = state.entries.where((e) => e.path != path).toList();
    await _store.saveAll(entries);
    state = FavoritesState(entries: entries, loading: false);
  }

  Future<void> clear() async {
    await _store.saveAll(const []);
    state = const FavoritesState(entries: [], loading: false);
  }

  /// 播放收藏（从指定索引开始）。
  Future<void> play(int index) async {
    final entries = state.entries;
    if (entries.isEmpty) return;
    final items = entries.map((e) => e.toQueueItem()).toList();
    await _ref.read(playerProvider.notifier).playQueue(items, startIndex: index);
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesManager, FavoritesState>((ref) {
  return FavoritesManager(ref);
});
