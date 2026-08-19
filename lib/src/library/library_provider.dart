import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';

/// 曲库歌曲（小而美：仅保留播放/展示所需字段）。
class Song {
  final String path;
  final String title;
  final String artist;
  final String album;
  final String albumKey;
  final int duration;
  final String format;
  final String? coverThumbPath;
  const Song({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumKey,
    required this.duration,
    required this.format,
    this.coverThumbPath,
  });

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        path: j['path'] as String? ?? '',
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        albumKey: j['album_key'] as String? ?? '',
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        format: j['format'] as String? ?? '',
        coverThumbPath: j['cover_thumb_path'] as String?,
      );

  QueueItem toQueueItem() => QueueItem(
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationMs: duration * 1000,
      );
}

/// 歌手目录项。
class ArtistInfo {
  final int id;
  final String name;
  final int count;
  final String? avatarPath;
  const ArtistInfo({
    required this.id,
    required this.name,
    required this.count,
    this.avatarPath,
  });

  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        avatarPath: j['avatarPath'] as String?,
      );
}

/// 专辑目录项。
class AlbumInfo {
  final String key;
  final String name;
  final int count;
  final String artist;
  final String firstSongPath;
  const AlbumInfo({
    required this.key,
    required this.name,
    required this.count,
    required this.artist,
    required this.firstSongPath,
  });

  factory AlbumInfo.fromJson(Map<String, dynamic> j) => AlbumInfo(
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        artist: j['artist'] as String? ?? '',
        firstSongPath: j['firstSongPath'] as String? ?? '',
      );
}

/// 文件夹树节点。
class FolderNodeData {
  final String name;
  final String path;
  final List<FolderNodeData> children;
  final int childCount;
  final int songCount;
  const FolderNodeData({
    required this.name,
    required this.path,
    required this.children,
    required this.childCount,
    this.songCount = 0,
  });

  factory FolderNodeData.fromJson(Map<String, dynamic> j) => FolderNodeData(
        name: j['name'] as String? ?? '',
        path: j['path'] as String? ?? '',
        children: (j['children'] as List? ?? [])
            .map((e) => FolderNodeData.fromJson(e as Map<String, dynamic>))
            .toList(),
        childCount: (j['childCount'] as num?)?.toInt() ?? 0,
        songCount: (j['songCount'] as num?)?.toInt() ?? 0,
      );
}

class LibraryState {
  final List<Song> songs;
  final List<String> folders;
  final List<ArtistInfo> artists;
  final List<AlbumInfo> albums;
  final List<FolderNodeData> folderRoot;
  final bool loading;
  final String? error;
  const LibraryState({
    this.songs = const [],
    this.folders = const [],
    this.artists = const [],
    this.albums = const [],
    this.folderRoot = const [],
    this.loading = true,
    this.error,
  });

  LibraryState copyWith({
    List<Song>? songs,
    List<String>? folders,
    List<ArtistInfo>? artists,
    List<AlbumInfo>? albums,
    List<FolderNodeData>? folderRoot,
    bool? loading,
    String? error,
  }) {
    return LibraryState(
      songs: songs ?? this.songs,
      folders: folders ?? this.folders,
      artists: artists ?? this.artists,
      albums: albums ?? this.albums,
      folderRoot: folderRoot ?? this.folderRoot,
      loading: loading ?? this.loading,
      error: error ?? this.error,
    );
  }
}

class LibraryNotifier extends StateNotifier<LibraryState> {
  LibraryNotifier(this._ref) : super(const LibraryState()) {
    load();
  }

  final Ref _ref;

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final songsJson = await getLibrarySongsCached(dbPath: dbPath);
      final foldersJson = await getLibraryFolders(dbPath: dbPath);
      final artistsJson = await getLibraryArtistCatalog(dbPath: dbPath);
      final albumsJson = await getLibraryAlbumCatalog(dbPath: dbPath);
      final treeJson = await getLibraryHierarchy(dbPath: dbPath);
      state = LibraryState(
        songs: _parseSongs(songsJson),
        folders: (jsonDecode(foldersJson) as List).map((e) => e as String).toList(),
        artists: (jsonDecode(artistsJson) as List)
            .map((e) => ArtistInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
        albums: (jsonDecode(albumsJson) as List)
            .map((e) => AlbumInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
        folderRoot: (jsonDecode(treeJson) as List)
            .map((e) => FolderNodeData.fromJson(e as Map<String, dynamic>))
            .toList(),
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  List<Song> _parseSongs(String json) => (jsonDecode(json) as List)
      .map((e) => Song.fromJson(e as Map<String, dynamic>))
      .toList();

  /// 按歌手取歌曲列表。
  Future<List<Song>> songsByArtist(String name) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsByArtist(
        dbPath: dbPath, artistName: name);
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  /// 按专辑 key 取歌曲列表。
  Future<List<Song>> songsByAlbum(String key) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson =
        await getLibrarySongPathsByAlbum(dbPath: dbPath, albumKey: key);
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  /// 按文件夹取歌曲列表。
  Future<List<Song>> songsByFolder(String path) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsForFolderView(
        dbPath: dbPath, folderPath: path, query: null, sortMode: 'title');
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  /// 播放全部歌曲（或从指定索引开始）。
  Future<void> playFrom(int index) async {
    final songs = state.songs;
    if (songs.isEmpty) return;
    await _playList(songs, index);
  }

  /// 播放任意歌曲列表。
  Future<void> playList(List<Song> songs, int index) async {
    if (songs.isEmpty) return;
    await _playList(songs, index);
  }

  Future<void> _playList(List<Song> songs, int index) async {
    final items = songs.map((s) => s.toQueueItem()).toList();
    await _ref
        .read(playerProvider.notifier)
        .playQueue(items, startIndex: index);
  }
}

final libraryProvider = StateNotifierProvider<LibraryNotifier, LibraryState>(
  (ref) => LibraryNotifier(ref),
);

/// 音乐库页当前 Tab（0 全部 / 1 歌手 / 2 专辑 / 3 文件夹），供主页网格跳转。
final libraryTabProvider = StateProvider<int>((ref) => 0);