import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_backup_import.dart';
import '../playlist/playlist_provider.dart';
import '../rust/api.dart';
import 'saf_channel.dart';

class FolderUnauthorizedException implements Exception {
  final String folder;
  const FolderUnauthorizedException(this.folder);
  @override
  String toString() => '「$folder」授权已失效，请重新授权';
}

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
        coverPath: coverThumbPath,
      );
}

class ArtistInfo {
  final int id;
  final String name;
  final int count;
  final String? avatarPath;
  final String firstSongPath;
  const ArtistInfo({
    required this.id,
    required this.name,
    required this.count,
    this.avatarPath,
    this.firstSongPath = '',
  });

  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        avatarPath: (j['avatar_path'] ?? j['avatarPath']) as String?,
        firstSongPath:
            ((j['first_song_path'] ?? j['firstSongPath']) as String?) ?? '',
      );
}

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
        firstSongPath:
            ((j['first_song_path'] ?? j['firstSongPath']) as String?) ?? '',
      );
}

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
        childCount:
            ((j['child_count'] ?? j['childCount']) as num?)?.toInt() ?? 0,
        songCount:
            ((j['song_count'] ?? j['songCount']) as num?)?.toInt() ?? 0,
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
  final List<String> unauthorizedFolders;
  const LibraryState({
    this.songs = const [],
    this.folders = const [],
    this.artists = const [],
    this.albums = const [],
    this.folderRoot = const [],
    this.loading = true,
    this.error,
    this.unauthorizedFolders = const [],
  });

  LibraryState copyWith({
    List<Song>? songs,
    List<String>? folders,
    List<ArtistInfo>? artists,
    List<AlbumInfo>? albums,
    List<FolderNodeData>? folderRoot,
    bool? loading,
    String? error,
    List<String>? unauthorizedFolders,
  }) {
    return LibraryState(
      songs: songs ?? this.songs,
      folders: folders ?? this.folders,
      artists: artists ?? this.artists,
      albums: albums ?? this.albums,
      folderRoot: folderRoot ?? this.folderRoot,
      loading: loading ?? this.loading,
      error: error ?? this.error,
      unauthorizedFolders: unauthorizedFolders ?? this.unauthorizedFolders,
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
      final results = await Future.wait<String>([
        getLibrarySongsCached(dbPath: dbPath),
        getLibraryFolders(dbPath: dbPath),
        getLibraryArtistCatalog(dbPath: dbPath),
        getLibraryAlbumCatalog(dbPath: dbPath),
        getLibraryHierarchy(dbPath: dbPath),
      ]);
      final songsJson = results[0];
      final foldersJson = results[1];
      final artistsJson = results[2];
      final albumsJson = results[3];
      final treeJson = results[4];
      final folders = (jsonDecode(foldersJson) as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String? ?? '')
          .where((p) => p.isNotEmpty)
          .toList();
      final parsedSongs = _parseSongs(songsJson);
      state = LibraryState(
        songs: await _applyCustomOrder(parsedSongs),
        folders: folders,
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
      await checkSafFolderAuthorization();
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> checkSafFolderAuthorization() async {
    final safFolders =
        state.folders.where((f) => SafChannel.isSafTree(f)).toList();
    if (safFolders.isEmpty) {
      if (state.unauthorizedFolders.isNotEmpty) {
        state = state.copyWith(unauthorizedFolders: const []);
      }
      return;
    }
    final lost = <String>[];
    for (final f in safFolders) {
      if (!await SafChannel.isTreeAvailable(f)) lost.add(f);
    }
    state = state.copyWith(unauthorizedFolders: lost);
  }

  List<Song> _parseSongs(String json) => (jsonDecode(json) as List)
      .map((e) => Song.fromJson(e as Map<String, dynamic>))
      .toList();

  static const _customOrderKey = 'localSongsCustomOrder';

  Future<List<String>> _readCustomOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_customOrderKey) ?? const [];
  }

  Future<List<Song>> _applyCustomOrder(List<Song> songs) async {
    final saved = await _readCustomOrder();
    if (saved.isEmpty) return songs;
    final set = saved.toSet();
    final byPath = {for (final s in songs) s.path: s};
    return <Song>[
      for (final p in saved)
        if (byPath.containsKey(p)) byPath[p]!,
      for (final s in songs)
        if (!set.contains(s.path)) s,
    ];
  }

  Future<void> reorderLocalSongs(List<String> orderedPaths) async {
    final current = state.songs;
    final pathSet = orderedPaths.toSet();
    final byPath = {for (final s in current) s.path: s};
    final reordered = <Song>[
      for (final p in orderedPaths)
        if (byPath.containsKey(p)) byPath[p]!,
      for (final s in current)
        if (!pathSet.contains(s.path)) s,
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _customOrderKey, reordered.map((s) => s.path).toList());
    state = state.copyWith(songs: reordered);
  }

  static const _formatExtensions = <String, List<String>>{
    'flac': ['flac'],
    'mp3': ['mp3'],
    'wav': ['wav'],
    'aac': ['aac'],
    'm4a': ['m4a', 'm4b', 'mp4'],
    'ogg': ['ogg', 'oga'],
    'opus': ['opus'],
    'aiff': ['aif', 'aiff'],
    'dsf': ['dsf', 'dff'],
    'ape': ['ape'],
    'wv': ['wv'],
    'qmc': ['mgg', 'mgg0', 'mggl', 'mflac', 'mflac0', 'qmc0', 'qmc2', 'qmc3', 'qmcflac', 'qmcogg'],
  };

  Future<void> _reloadSongsFromDb() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final songsJson = await getLibrarySongsCached(dbPath: dbPath);
      final parsed = _parseSongs(songsJson);
      state = state.copyWith(
        songs: await _applyCustomOrder(parsed),
        loading: false,
        error: null,
      );
    } catch (_) {
    }
  }

  Future<int> scanAllFolders() async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final settings = _ref.read(settingsProvider).valueOrNull;
    final selectedFormats = settings?.scanFormats ?? kSupportedScanFormats;
    final minDuration = settings?.libraryMinDurationSeconds ?? 0;

    final allowed = <String>[
      for (final f in selectedFormats) ...(_formatExtensions[f] ?? [f]),
    ];

    final foldersJson = await getLibraryFolders(dbPath: dbPath);
    final folders = (jsonDecode(foldersJson) as List)
        .map((e) => (e as Map<String, dynamic>)['path'] as String? ?? '')
        .where((p) => p.isNotEmpty)
        .toList();

    final tmp = await getTemporaryDirectory();
    final safScanRoot = p.join(tmp.path, 'saf_scan');
    SafChannel.clearScannedCopiesRoot(safScanRoot);

    var total = 0;
    final errors = <String>[];
    for (final folder in folders) {
      try {
        total += await _scanFolder(
          dbPath,
          folder,
          allowed,
          minDuration,
        );
      } on FolderUnauthorizedException catch (e) {
        errors.add(e.toString());
      } catch (e) {
        errors.add('$folder: $e');
      }
      await _reloadSongsFromDb();
    }
    await load();
    if (total == 0 && errors.isNotEmpty) {
      throw Exception('扫描失败：${errors.first}');
    }
    return total;
  }

  Future<int> _scanFolder(
    String dbPath,
    String folder,
    List<String> allowed,
    int minDuration,
  ) async {
    if (SafChannel.isSafTree(folder)) {
      return _scanSafTree(dbPath, folder, allowed, minDuration);
    }
    final songsJson = await scanMusicFolder(
      dbPath: dbPath,
      folderPath: folder,
      minimumDurationSeconds: minDuration > 0 ? minDuration : null,
      allowedFormats: allowed,
    );
    return (jsonDecode(songsJson) as List).length;
  }

  Future<int> _scanSafTree(
    String dbPath,
    String treeUri,
    List<String> allowed,
    int minDuration,
  ) async {
    if (!await SafChannel.isTreeAvailable(treeUri)) {
      throw FolderUnauthorizedException(
          await SafChannel.friendlyTreeName(treeUri));
    }
    final files = await SafChannel.listAudioTree(treeUri, allowed);
    if (files.isEmpty) return 0;
    final folderKey = SafChannel.treeRootPath(treeUri);
    final songs = <Map<String, dynamic>>[];
    final cacheRoot = await _ref.read(coverCacheRootProvider.future);
    final tmp = await getTemporaryDirectory();
    final scanDir = p.join(tmp.path, 'saf_scan');

    for (final f in files) {
      final path = SafChannel.songPath(treeUri, f.docId);
      final fd = await SafChannel.openFd(treeUri, f.docId);
      if (fd < 0) continue;
      try {
        var parsed = <String, dynamic>{};
        var fdOk = false;
        try {
          final songJson = await parseAudioFromFdAndroid(
            fd: fd,
            fileName: f.name,
            pathKey: path,
            format: f.ext,
          );
          parsed = jsonDecode(songJson) as Map<String, dynamic>;
          fdOk = (parsed['duration'] as num? ?? 0) > 0;
        } catch (_) {
          fdOk = false;
        }

        String? coverPath;
        if (fdOk) {
          try {
            coverPath = await extractSongCoverThumbnailFromFd(
              cacheRoot: cacheRoot,
              path: path,
              fd: fd,
            );
          } catch (_) {}
        } else {
          final localCopy = await SafChannel.copyTreeDocToInternal(
              treeUri, f.docId, scanDir);
          if (localCopy.isNotEmpty && File(localCopy).existsSync()) {
            try {
              final songJson = await parseAudioFromPathAndroid(
                filePath: localCopy,
                fileName: f.name,
                pathKey: path,
                format: f.ext,
              );
              final reparsed = jsonDecode(songJson) as Map<String, dynamic>;
              if ((reparsed['duration'] as num? ?? 0) > 0) {
                parsed = reparsed;
              }
              try {
                coverPath = await extractSongCoverThumbnailFromPath(
                  cacheRoot: cacheRoot,
                  sourceKey: path,
                  realPath: localCopy,
                );
              } catch (_) {}
            } catch (_) {} finally {
              try {
                final file = File(localCopy);
                if (file.existsSync()) file.deleteSync();
              } catch (_) {}
            }
          }
        }
        if (parsed.isEmpty) continue;
        if (coverPath != null && coverPath.isNotEmpty) {
          parsed['cover_thumb_path'] = coverPath;
        }
        songs.add(parsed);
      } finally {
        await SafChannel.closeFd(fd);
      }
    }
    if (songs.isEmpty) return 0;
    await scanSafSongsCommit(
      dbPath: dbPath,
      folderKey: folderKey,
      songsJson: jsonEncode(songs),
      minimumDurationSeconds: minDuration > 0 ? minDuration : null,
    );
    return songs.length;
  }

  Future<List<Song>> songsByArtist(String name) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsByArtist(
        dbPath: dbPath, artistName: name);
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  Future<List<Song>> songsByAlbum(String key) async {
    if (!state.loading && state.songs.isNotEmpty) {
      final hit = state.songs.where((s) => s.albumKey == key).toList();
      if (hit.isNotEmpty) return hit;
    }
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson =
        await getLibrarySongPathsByAlbum(dbPath: dbPath, albumKey: key);
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  Future<List<Song>> songsByFolder(String path) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsForFolderView(
        dbPath: dbPath, folderPath: path, query: null, sortMode: 'title');
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  Future<List<Song>> songsByPaths(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final dbPath = await _ref.read(dbPathProvider.future);
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  Future<void> playFrom(int index) async {
    final songs = state.songs;
    if (songs.isEmpty) return;
    await _playList(songs, index);
  }

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

  Future<int> importFolderAsPlaylist(String path, {String? name}) async {
    final songs = await songsByFolder(path);
    if (songs.isEmpty) return 0;
    final folderName = path.split(RegExp(r'[\\/]')).last;
    final playlistName = (name == null || name.trim().isEmpty)
        ? folderName
        : name.trim();
    final pm = _ref.read(playlistManagerProvider.notifier);
    await pm.create(playlistName);
    final created =
        _ref.read(playlistManagerProvider).playlists;
    if (created.isEmpty) return 0;
    final id = created.last.id;
    final imported = songs
        .map((s) => ImportedSong(
              title: s.title,
              artist: s.artist,
              album: s.album,
              duration: s.duration,
              coverThumbPath: s.coverThumbPath,
              localPath: s.path,
              path: s.path,
            ))
        .toList();
    await pm.addSongs(id, imported);
    return songs.length;
  }
}

final libraryProvider = StateNotifierProvider<LibraryNotifier, LibraryState>(
  (ref) => LibraryNotifier(ref),
);