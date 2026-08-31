import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// 扫描目录的授权已失效（清除数据/系统撤销/存储卡拔出等），需要用户重新授权。
class FolderUnauthorizedException implements Exception {
  final String folder;
  const FolderUnauthorizedException(this.folder);
  @override
  String toString() => '「$folder」授权已失效，请重新授权';
}

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
        coverPath: coverThumbPath,
      );
}

/// 歌手目录项。
class ArtistInfo {
  final int id;
  final String name;
  final int count;
  final String? avatarPath;
  /// 该歌手任一歌曲路径，用于展示歌手封面（内嵌封面）。
  final String firstSongPath;
  const ArtistInfo({
    required this.id,
    required this.name,
    required this.count,
    this.avatarPath,
    this.firstSongPath = '',
  });

  // Rust ArtistCatalogItem 为 snake_case，兼容 camelCase。
  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        avatarPath: (j['avatar_path'] ?? j['avatarPath']) as String?,
        firstSongPath:
            ((j['first_song_path'] ?? j['firstSongPath']) as String?) ?? '',
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

  // Rust AlbumCatalogItem 为 snake_case，兼容 camelCase。
  factory AlbumInfo.fromJson(Map<String, dynamic> j) => AlbumInfo(
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        artist: j['artist'] as String? ?? '',
        firstSongPath:
            ((j['first_song_path'] ?? j['firstSongPath']) as String?) ?? '',
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

  // Rust FolderNode 序列化为 snake_case，兼容读取 camelCase 以防上游改动。
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
  /// 授权已失效的 SAF 扫描目录（重新授权后旧曲库数据可直接复活，无需重扫）。
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
      // 并行拉取全部曲库数据源（相互独立、无相互依赖），首屏等待时长从
      // 「串行求和」降到「最慢一项」。对齐 RwaS 启动并发预热的思路，
      // 减少本地库首开的白屏等待。
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
        // getLibraryFolders 返回 [{path, song_count}, ...]，取出 path。
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
      // 启动即探测 SAF 目录授权状态（清除数据/系统撤销后失效的目录
      // 需要用户感知并重新授权，否则表现为「扫描到 0 首」的静默失败）。
      await checkSafFolderAuthorization();
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// 探测全部 SAF 扫描目录的授权状态，把失效目录记入
  /// [LibraryState.unauthorizedFolders] 供 UI 展示重新授权引导。
  Future<void> checkSafFolderAuthorization() async {
    final safFolders =
        state.folders.where((f) => SafChannel.isSafTree(f)).toList();
    if (safFolders.isEmpty) {
      // 目录全被移除时清掉遗留的失效记录，避免横幅残留。
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

  /// 本地歌曲自定义顺序的持久化 key。
  static const _customOrderKey = 'localSongsCustomOrder';

  Future<List<String>> _readCustomOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_customOrderKey) ?? const [];
  }

  /// 把已保存的用户自定的本地歌曲顺序应用到扫描结果上：
  /// 存在的路径按保存顺序排在前面，扫描新增的路径附加在队尾。
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

  /// 按指定 path 顺序重排本地歌曲（拖拽排序），并持久化自定义顺序。
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

  /// 格式大类 → 实际扩展名白名单（与 Rust is_ext_allowed 对应）。
  static const _formatExtensions = <String, List<String>>{
    'flac': ['flac'],
    'mp3': ['mp3'],
    'wav': ['wav'],
    'aac': ['aac'],
    'm4a': ['m4a', 'm4b', 'mp4'],
    'ogg': ['ogg', 'oga'],
    'aiff': ['aif', 'aiff'],
  };

  /// 起始即只从 DB 读取当前已入库歌曲，刷新到 UI（不动 loading/目录/目录树）。
  /// 用于增量扫描：每扫完一个目录就把该目录已入库结果先展示出来，
  /// 实现「先扫完先见」，避免全部目录解析完才出第一屏。
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
      // 增量刷新失败不阻断扫描，最终由 load() 兜底。
    }
  }

  /// 扫描全部已配置目录，按选定格式白名单入库，返回扫描到的歌曲总数。
  Future<int> scanAllFolders() async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final settings = _ref.read(settingsProvider).valueOrNull;
    final selectedFormats = settings?.scanFormats ?? kSupportedScanFormats;
    final minDuration = settings?.libraryMinDurationSeconds ?? 0;

    // 展开为扩展名白名单。
    final allowed = <String>[
      for (final f in selectedFormats) ...(_formatExtensions[f] ?? [f]),
    ];

    final foldersJson = await getLibraryFolders(dbPath: dbPath);
    final folders = (jsonDecode(foldersJson) as List)
        .map((e) => (e as Map<String, dynamic>)['path'] as String? ?? '')
        .where((p) => p.isNotEmpty)
        .toList();

    // 每次全量扫描前清理上一轮 SAF 物化副本，避免磁盘堆积。
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
        // 授权失效单独归类：load() 内的授权探测会把它写入
        // unauthorizedFolders 驱动 UI 的重新授权引导。
        errors.add(e.toString());
      } catch (e) {
        // 单个目录失败不阻断其它目录，但记录错误以便暴露给用户。
        errors.add('$folder: $e');
      }
      // 该目录扫描已完成（已入库），立即刷新歌曲到 UI，先见先出。
      await _reloadSongsFromDb();
    }
    await load();
    // 一首都没扫到且有错误时，抛出以便 UI 展示真实原因。
    if (total == 0 && errors.isNotEmpty) {
      throw Exception('扫描失败：${errors.first}');
    }
    return total;
  }

  /// 扫描单个目录：SAF tree 走 Android 侧枚举+fd 解析，普通路径走原路径扫描。
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

  /// SAF 扫描：Android 侧递归枚举白名单音频 → fd 直读解析元数据并提取内嵌
  /// 封面（全程零复制）→ 仅 fd 解析失败的文件临时物化一份带扩展名的真实
  /// 文件重解析（用完即删，兜底部分机型 /proc/self/fd 读取限制）→ 批量增量入库。
  Future<int> _scanSafTree(
    String dbPath,
    String treeUri,
    List<String> allowed,
    int minDuration,
  ) async {
    // 授权失效（清除数据/系统撤销/存储卡拔出）时显式失败，
    // 不再表现为「扫到 0 首」的静默成功。
    if (!await SafChannel.isTreeAvailable(treeUri)) {
      throw FolderUnauthorizedException(
          await SafChannel.friendlyTreeName(treeUri));
    }
    final files = await SafChannel.listAudioTree(treeUri, allowed);
    if (files.isEmpty) return 0;
    // song 主键为 `{tree}/document/{docId}`，增量快照用同构的根路径匹配。
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
          // duration=0 意味着标签/属性完全没读到（fd 读取失败的典型特征）。
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
          // fd 解析失败：临时物化（保留扩展名，Rust 的 WAV/MP3 补救解析
          // 依赖扩展名）重解析并提取封面，随后立即删除，不占磁盘。
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
        // 扫描期即回写封面路径，入库后列表/歌手/专辑可直接命中，无需懒提取。
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
    // 内存快路径：本地页完成加载后 state.songs 已是全量曲库，直接按 albumKey 过滤，
    // 免去每次开专辑页的 DB 往返 + JSON 反序列化（对齐 RwaS 的内存索引缓存）。
    // 空命中含「专辑歌曲尚未计入内存 / 正在增量扫描」的可能，回落 DB 兜底。
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

  /// 按路径批量取歌曲（用于收藏等自定义路径集合）。
  ///
  /// 已从库中移除的路径不会返回，因此结果可能少于传入路径数。
  Future<List<Song>> songsByPaths(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final dbPath = await _ref.read(dbPathProvider.future);
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
    debugPrint('[play] playList ${songs.length} 首 index=$index');
    await _playList(songs, index);
  }

  Future<void> _playList(List<Song> songs, int index) async {
    final items = songs.map((s) => s.toQueueItem()).toList();
    await _ref
        .read(playerProvider.notifier)
        .playQueue(items, startIndex: index);
  }

  /// 将文件夹下的歌曲导入为一个歌单（名称默认取文件夹名）。
  Future<int> importFolderAsPlaylist(String path, {String? name}) async {
    final songs = await songsByFolder(path);
    if (songs.isEmpty) return 0;
    final folderName = path.split(RegExp(r'[\\/]')).last;
    final playlistName = (name == null || name.trim().isEmpty)
        ? folderName
        : name.trim();
    final pm = _ref.read(playlistManagerProvider.notifier);
    // 创建歌单（新歌单被追加为最后一个），取其 id 后写入歌曲。
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