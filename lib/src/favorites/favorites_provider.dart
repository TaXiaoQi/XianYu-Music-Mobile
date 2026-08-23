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
  final String? coverUrl;
  final String? source;
  final String? onlineInfoJson;
  final int addedAt;

  FavoriteEntry({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.onlineSongJson,
    this.onlineQuality,
    this.coverUrl,
    this.source,
    this.onlineInfoJson,
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
        coverUrl: coverUrl,
        source: source,
        onlineInfoJson: onlineInfoJson,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': durationMs,
        'onlineSongJson': onlineSongJson,
        'onlineQuality': onlineQuality,
        'coverUrl': coverUrl,
        'source': source,
        'onlineInfoJson': onlineInfoJson,
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
        coverUrl: j['coverUrl'] as String?,
        source: j['source'] as String?,
        onlineInfoJson: j['onlineInfoJson'] as String?,
        addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 收藏的歌单/专辑/榜单（收藏集，非单曲）。
class FavoriteCollection {
  final String key;
  final String kind; // playlist | album | toplist
  final String pluginId;
  final String title;
  final String subtitle;
  final String? coverUrl;
  final Map<String, dynamic> raw;
  final int addedAt;

  FavoriteCollection({
    required this.key,
    required this.kind,
    required this.pluginId,
    required this.title,
    required this.subtitle,
    this.coverUrl,
    required this.raw,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind,
        'pluginId': pluginId,
        'title': title,
        'subtitle': subtitle,
        'coverUrl': coverUrl,
        'raw': raw,
        'addedAt': addedAt,
      };

  factory FavoriteCollection.fromJson(Map<String, dynamic> j) =>
      FavoriteCollection(
        key: j['key'] as String? ?? '',
        kind: j['kind'] as String? ?? 'playlist',
        pluginId: j['pluginId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        subtitle: j['subtitle'] as String? ?? '',
        coverUrl: j['coverUrl'] as String?,
        raw: (j['raw'] as Map? ?? const {}).cast<String, dynamic>(),
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
  final List<FavoriteCollection> collections;
  final bool loading;

  const FavoritesState(
      {this.entries = const [], this.collections = const [], this.loading = true});

  FavoritesState copyWith({
    List<FavoriteEntry>? entries,
    List<FavoriteCollection>? collections,
    bool? loading,
  }) {
    return FavoritesState(
      entries: entries ?? this.entries,
      collections: collections ?? this.collections,
      loading: loading ?? this.loading,
    );
  }

  bool contains(String path) => entries.any((e) => e.path == path);

  bool isCollectionFavorite(String key) =>
      collections.any((c) => c.key == key);
}

/// 收藏集的持久化存储。
class FavoritesCollectionStore {
  static const _key = 'xianyu_favorite_collections_v1';

  Future<List<FavoriteCollection>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => FavoriteCollection.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveAll(List<FavoriteCollection> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(items.map((e) => e.toJson()).toList()));
  }
}

class FavoritesManager extends StateNotifier<FavoritesState> {
  FavoritesManager(this._ref) : super(const FavoritesState()) {
    refresh();
  }

  final Ref _ref;
  final FavoritesStore _store = FavoritesStore();
  final FavoritesCollectionStore _collectionStore = FavoritesCollectionStore();

  Future<void> refresh() async {
    final entries = await _store.loadAll();
    final collections = await _collectionStore.loadAll();
    state = FavoritesState(
      entries: entries,
      collections: collections,
      loading: false,
    );
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
      coverUrl: item.coverUrl,
      source: item.source,
      onlineInfoJson: item.onlineInfoJson,
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
    state = FavoritesState(
      entries: const [],
      collections: state.collections,
      loading: false,
    );
  }

  /// 收藏/取消收藏整张歌单、专辑或榜单。
  Future<void> toggleCollection({
    required String kind, // playlist | album | toplist
    required String pluginId,
    required String title,
    String subtitle = '',
    String? coverUrl,
    required Map<String, dynamic> raw,
  }) async {
    final key = '$kind:$pluginId:$title';
    final current = state.collections;
    if (current.any((c) => c.key == key)) {
      final next = current.where((c) => c.key != key).toList();
      await _collectionStore.saveAll(next);
      state = state.copyWith(collections: next);
      return;
    }
    final item = FavoriteCollection(
      key: key,
      kind: kind,
      pluginId: pluginId,
      title: title,
      subtitle: subtitle,
      coverUrl: coverUrl,
      raw: raw,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final next = [item, ...current];
    await _collectionStore.saveAll(next);
    state = state.copyWith(collections: next);
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
