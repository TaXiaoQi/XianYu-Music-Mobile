part of 'plugin_backup_import.dart';

// ==================== M3U / M3U8 ====================

typedef LocalSongRef = ({
  String path,
  String title,
  String artist,
  String album,
  int duration,
  String? coverThumbPath,
});

final RegExp _audioExtRegex = RegExp(
  r'\.(flac|mp3|wav|ape|ogg|opus|m4a|aac|wv|dsf|dff|webm|mp4)$',
  caseSensitive: false,
);

String _extractBaseName(String filePath) {
  final fileName = filePath.split(RegExp(r'[\\/]')).last;
  return fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
}

ImportedSong _createSongFromPath(
  String filePath,
  String titleFromMeta,
  String artistFromMeta,
  int duration,
) {
  final trimmedPath = filePath.trim();
  final fileName = trimmedPath.split(RegExp(r'[\\/]')).last;
  final baseName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');

  var title = titleFromMeta;
  var artist = artistFromMeta;

  if (title.isEmpty && baseName.isNotEmpty) {
    final dashIdx = baseName.lastIndexOf('-');
    if (dashIdx > 0) {
      title = baseName.substring(0, dashIdx).trim();
      artist = baseName.substring(dashIdx + 1).trim();
    } else {
      title = baseName;
      artist = tr('未知歌手');
    }
  }
  if (title.isEmpty) title = fileName;
  if (artist.isEmpty) artist = tr('未知歌手');

  return ImportedSong(
    title: title,
    artist: artist,
    album: tr('未知专辑'),
    duration: duration,
    localPath: trimmedPath,
    path: trimmedPath,
  );
}

List<PluginBackupPlaylist> _parseM3UContent(String content, String fileName) {
  final base = _extractBaseName(fileName);
  final playlistName = base.isEmpty ? tr('导入的歌单') : base;
  final songs = <ImportedSong>[];
  var pendingDuration = 0;
  var pendingTitle = '';
  var pendingArtist = '';

  for (final rawLine in content.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF:')) {
      final rest = line.substring('#EXTINF:'.length);
      final commaIdx = rest.indexOf(',');
      if (commaIdx >= 0) {
        pendingDuration = int.tryParse(rest.substring(0, commaIdx)) ?? 0;
        final info = rest.substring(commaIdx + 1);
        final dashIdx = info.lastIndexOf(' - ');
        if (dashIdx >= 0) {
          pendingArtist = info.substring(0, dashIdx).trim();
          pendingTitle = info.substring(dashIdx + 3).trim();
        } else {
          pendingTitle = info.trim();
          pendingArtist = '';
        }
      }
    } else if (line.startsWith('#')) {
    } else {
      songs.add(
          _createSongFromPath(line, pendingTitle, pendingArtist, pendingDuration));
      pendingDuration = 0;
      pendingTitle = '';
      pendingArtist = '';
    }
  }

  if (songs.isEmpty) {
    throw   FormatException(tr('M3U 文件中未找到有效的歌曲条目'));
  }
  return [
    PluginBackupPlaylist(
        name: playlistName, songs: songs, originalSongCount: songs.length),
  ];
}

List<PluginBackupPlaylist> _parseSaltPlayerContent(
    String content, String fileName) {
  final base = _extractBaseName(fileName);
  final playlistName = base.isEmpty ? tr('导入的歌单') : base;
  final songs = <ImportedSong>[];
  for (final rawLine in content.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (!_audioExtRegex.hasMatch(line) && !line.contains(RegExp(r'[\\/]'))) {
      continue;
    }
    songs.add(_createSongFromPath(line, '', '', 0));
  }
  if (songs.isEmpty) {
    throw   FormatException(tr('文件中未找到有效的歌曲路径'));
  }
  return [
    PluginBackupPlaylist(
        name: playlistName, songs: songs, originalSongCount: songs.length),
  ];
}

String _normMeta(String s) => s.trim().toLowerCase();

ImportedSong _matchLocalSong(ImportedSong song, List<LocalSongRef> localSongs) {
  if (File(song.path).existsSync()) return song;
  final key = '${_normMeta(song.title)}|${_normMeta(song.artist)}';
  final candidates = localSongs
      .where((s) => '${_normMeta(s.title)}|${_normMeta(s.artist)}' == key)
      .toList();
  if (candidates.isEmpty) return song;
  if (candidates.length == 1) {
    final c = candidates.first;
    return ImportedSong(
      title: song.title,
      artist: song.artist,
      album: c.album.isNotEmpty ? c.album : song.album,
      duration: song.duration,
      coverThumbPath: c.coverThumbPath,
      localPath: c.path,
      path: c.path,
    );
  }
  if (song.duration > 0) {
    LocalSongRef? best;
    var bestDiff = 5;
    for (final c in candidates) {
      final diff = (c.duration - song.duration).abs();
      if (diff <= bestDiff) {
        bestDiff = diff;
        best = c;
      }
    }
    if (best != null) {
      return ImportedSong(
        title: song.title,
        artist: song.artist,
        album: best.album.isNotEmpty ? best.album : song.album,
        duration: song.duration,
        coverThumbPath: best.coverThumbPath,
        localPath: best.path,
        path: best.path,
      );
    }
  }
  return song;
}

PreparedPluginBackupImport preparePlaylistFileImport(
  String content,
  String fileName, {
  List<LocalSongRef> localSongs = const [],
}) {
  final isM3U = content.trimLeft().startsWith('#EXTM3U');
  var playlists = isM3U
      ? _parseM3UContent(content, fileName)
      : _parseSaltPlayerContent(content, fileName);

  if (localSongs.isNotEmpty) {
    playlists = playlists
        .map((pl) => PluginBackupPlaylist(
              name: pl.name,
              songs: pl.songs.map((s) => _matchLocalSong(s, localSongs)).toList(),
              originalSongCount: pl.originalSongCount,
            ))
        .toList();
  }

  final total = playlists.fold<int>(0, (sum, pl) => sum + pl.songs.length);
  return PreparedPluginBackupImport(
    format: isM3U ? 'm3u' : 'txt',
    sourcePlaylistCount: playlists.length,
    totalSongCount: total,
    importedSongCount: total,
    playlists: playlists,
    failures: const [],
    associations: [
      PluginBackupAssociation(
        pluginId: 'local',
        pluginName: tr('本地文件'),
        pluginFormat: 'musicfree',
        enabled: true,
        platform: tr('本地文件'),
        songCount: total,
      ),
    ],
    missingPlugins: const [],
    migratedTrackIds: false,
    migratedTrackIdCount: 0,
  );
}

