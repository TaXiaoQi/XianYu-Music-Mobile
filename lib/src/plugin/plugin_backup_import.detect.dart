part of 'plugin_backup_import.dart';

class _DetectedBackup {
  final String format;
  final List<Map<String, dynamic>> sheets;
  final int? version;
  final bool restoreStringifiedIds;

  _DetectedBackup({
    required this.format,
    required this.sheets,
    this.version,
    required this.restoreStringifiedIds,
  });
}

String? _inferFormatFromSongFields(List<Map<String, dynamic>> sheets) {
  var bakaScore = 0;
  var mfScore = 0;
  var sampleCount = 0;
  const maxSamples = 50;

  for (final sheet in sheets) {
    final musicList = sheet['musicList'];
    if (musicList is! List) continue;
    for (final song in musicList) {
      if (sampleCount >= maxSamples) break;
      sampleCount++;
      final s = song is Map ? song.cast<String, dynamic>() : <String, dynamic>{};
      if (s['artist'] is String && (s['artist'] as String).trim().isNotEmpty) bakaScore += 2;
      if (s['title'] is String && (s['title'] as String).trim().isNotEmpty && !s.containsKey('name')) bakaScore += 1;
      if (s['album'] is String && (s['album'] as String).trim().isNotEmpty && !s.containsKey('albumName')) bakaScore += 1;
      if (s['singer'] is String && (s['singer'] as String).trim().isNotEmpty) mfScore += 2;
      if (s['name'] is String && (s['name'] as String).trim().isNotEmpty && !s.containsKey('title')) mfScore += 1;
      if (s['albumName'] is String && (s['albumName'] as String).trim().isNotEmpty) mfScore += 1;
      if (s.containsKey('musicId') && !s.containsKey('id')) mfScore += 2;
    }
    if (sampleCount >= maxSamples) break;
  }

  if (sampleCount == 0) return null;
  final threshold = (sampleCount * 0.3) > 2 ? (sampleCount * 0.3).floor() : 2;
  if (bakaScore > mfScore + threshold) return 'bakamusic';
  if (mfScore > bakaScore + threshold) return 'musicfree';
  return null;
}

List<String> _getBackupIdentityFields(Map<String, dynamic> data) {
  final fields = <Object?>[
    data['author'],
    data['creator'],
    data['exportedBy'],
    data['appName'],
    data['app'],
    data['data'] is Map ? (data['data'] as Map)['author'] : null,
    data['data'] is Map ? (data['data'] as Map)['creator'] : null,
    data['schema'],
  ];
  return fields
      .whereType<String>()
      .map((f) => f.trim().toLowerCase())
      .toList();
}

bool _hasToskysunSignature(Map<String, dynamic> data) {
  return _getBackupIdentityFields(data).any((f) => f.contains('toskysun'));
}

bool _hasMusicFreeAuthorSignature(Map<String, dynamic> data) {
  return _getBackupIdentityFields(data).any((f) => f.contains('时迁酱'));
}

_DetectedBackup _detectBackup(Map<String, dynamic> data) {
  final version = data['version'] is num ? (data['version'] as num).toInt() : null;

  final lxData = data['type'] == 'myList' && data['data'] is Map
      ? (data['data'] as Map).cast<String, dynamic>()
      : data['type'] == 'allData_v3' && data['data'] is Map && (data['data'] as Map)['lists'] is Map
          ? ((data['data'] as Map)['lists'] as Map).cast<String, dynamic>()
          : data;

  final lxBackupType = data['type'];
  List<Map<String, dynamic>>? lxBackupLists;
  if ((lxBackupType == 'allData_v2' || lxBackupType == 'allData') &&
      data['playList'] is List) {
    lxBackupLists = (data['playList'] as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  } else if ((lxBackupType == 'playList_v3' ||
          lxBackupType == 'playList_v2' ||
          lxBackupType == 'playList') &&
      data['data'] is List) {
    lxBackupLists = (data['data'] as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }
  if (lxBackupLists != null) {
    final sheets = <Map<String, dynamic>>[];
    for (final list in lxBackupLists) {
      final songs = list['list'];
      if (songs is! List || songs.isEmpty) continue;
      sheets.add({
        'name': list['name'] ?? tr('未命名歌单'),
        'musicList': songs
            .whereType<Map>()
            .map((e) => _flattenLxMeta(e.cast<String, dynamic>()))
            .toList(),
      });
    }
    return _DetectedBackup(format: 'lxmusic', sheets: sheets, restoreStringifiedIds: false);
  }

  if (lxBackupType == 'setting_v2' || lxBackupType == 'setting') {
    throw   FormatException(tr('未找到可导入的歌单'));
  }

  final defaultList = lxData['defaultList'];
  final loveList = lxData['loveList'];
  final userList = lxData['userList'];
  if (defaultList is List || loveList is List || userList is List) {
    final sheets = <Map<String, dynamic>>[];
    if (loveList is List && loveList.isNotEmpty) {
      sheets.add({
        'name': tr('我的收藏'),
        'musicList': loveList
            .whereType<Map>()
            .map((e) => _flattenLxMeta(e.cast<String, dynamic>()))
            .toList(),
      });
    }
    if (userList is List) {
      for (final list in userList) {
        if (list is! Map) continue;
        final songs = list['list'];
        if (songs is! List || songs.isEmpty) continue;
        sheets.add({
          'name': list['name'] ?? tr('未命名歌单'),
          'musicList': songs
              .whereType<Map>()
              .map((e) => _flattenLxMeta(e.cast<String, dynamic>()))
              .toList(),
        });
      }
    }
    if (defaultList is List && defaultList.isNotEmpty) {
      sheets.add({
        'name': tr('试听列表'),
        'musicList': defaultList
            .whereType<Map>()
            .map((e) => _flattenLxMeta(e.cast<String, dynamic>()))
            .toList(),
      });
    }
    return _DetectedBackup(format: 'lxmusic', sheets: sheets, restoreStringifiedIds: false);
  }

  final schema = data['schema'];
  if (schema is String && schema.startsWith('bakamusic')) {
    final sheets = _extractSheets(data);
    return _DetectedBackup(
      format: 'bakamusic',
      sheets: sheets,
      version: version,
      restoreStringifiedIds: version == _stringifiedTrackIdBackupVersion,
    );
  }

  final nestedSheets = data['data'] is Map && (data['data'] as Map)['musicSheets'] is List
      ? ((data['data'] as Map)['musicSheets'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList()
      : null;
  final topLevelSheets = data['musicSheets'] is List
      ? (data['musicSheets'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList()
      : null;
  final identifiedSheets = nestedSheets ?? topLevelSheets ?? <Map<String, dynamic>>[];

  if (_hasToskysunSignature(data)) {
    return _DetectedBackup(
      format: 'bakamusic',
      sheets: identifiedSheets,
      version: version,
      restoreStringifiedIds: version == _stringifiedTrackIdBackupVersion,
    );
  }

  if (_hasMusicFreeAuthorSignature(data)) {
    return _DetectedBackup(
      format: 'musicfree',
      sheets: identifiedSheets,
      version: version,
      restoreStringifiedIds: false,
    );
  }

  if (nestedSheets != null) {
    final inferred = _inferFormatFromSongFields(nestedSheets);
    if (inferred == 'musicfree') {
      return _DetectedBackup(
          format: 'musicfree', sheets: nestedSheets, version: version, restoreStringifiedIds: false);
    }
    return _DetectedBackup(
      format: 'bakamusic',
      sheets: nestedSheets,
      version: version,
      restoreStringifiedIds: version == _stringifiedTrackIdBackupVersion,
    );
  }

  if (topLevelSheets != null) {
    final inferred = _inferFormatFromSongFields(topLevelSheets);
    if (inferred == 'bakamusic') {
      return _DetectedBackup(
        format: 'bakamusic',
        sheets: topLevelSheets,
        version: version,
        restoreStringifiedIds: version == _stringifiedTrackIdBackupVersion,
      );
    }
    return _DetectedBackup(
        format: 'musicfree', sheets: topLevelSheets, version: version, restoreStringifiedIds: false);
  }

  throw   FormatException(tr('无法识别备份格式，请选择 BakaMusic、MusicFree 或洛雪音乐导出的备份文件'));
}

List<Map<String, dynamic>> _extractSheets(Map<String, dynamic> data) {
  final nested = data['data'] is Map && (data['data'] as Map)['musicSheets'] is List
      ? (data['data'] as Map)['musicSheets'] as List
      : null;
  final top = data['musicSheets'] is List ? data['musicSheets'] as List : null;
  final sheets = nested ?? top ?? <dynamic>[];
  return sheets
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();
}

PreparedPluginBackupImport preparePluginBackupImport(
  String jsonContent,
  List<PluginSource> installedPlugins,
) {
  Map<String, dynamic> data;
  try {
    final decoded = jsonDecode(jsonContent);
    if (decoded is! Map) {
      throw   FormatException(tr('备份文件不是有效的 JSON 对象'));
    }
    data = decoded.cast<String, dynamic>();
  } on FormatException {
    rethrow;
  } catch (_) {
    throw   FormatException(tr('文件不是有效的 JSON 格式'));
  }

  final detected = _detectBackup(data);
  final playlists = <PluginBackupPlaylist>[];
  final failures = <PluginBackupFailedSong>[];
  final associationMap = <String, PluginBackupAssociation>{};
  final missingPluginMap = <String, MissingBackupPlugin>{};
  var totalSongCount = 0;
  var importedSongCount = 0;
  var migratedTrackIdCount = 0;

  for (var sheetIndex = 0; sheetIndex < detected.sheets.length; sheetIndex++) {
    final sheet = detected.sheets[sheetIndex];
    final rawName = sheet['title'] ?? sheet['name'];
    final playlistName = (rawName?.toString() ?? '').trim().isNotEmpty
        ? rawName.toString().trim()
        : tr('未命名歌单 {n}', {'n': sheetIndex + 1});
    final rawSongs = sheet['musicList'] is List
        ? (sheet['musicList'] as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
        : <Map<String, dynamic>>[];
    final songs = <ImportedSong>[];
    totalSongCount += rawSongs.length;

    for (final rawSong in rawSongs) {
      final title = _extractTitle(rawSong);
      final artist = _extractArtist(rawSong);
      final id = _extractSongId(rawSong);
      final platform = _describePlatform(rawSong['platform'] ?? rawSong['source']);

      if (title.isEmpty) {
        failures.add(PluginBackupFailedSong(
          playlist: playlistName,
          title: tr('未命名歌曲'),
          artist: artist,
          platform: platform.displayName,
          reason: tr('歌曲缺少标题'),
          reasonCode: 'invalid-song',
        ));
        continue;
      }

      final localPath = _resolveLocalPath(rawSong);
      if (localPath.isNotEmpty) {
        songs.add(_createLocalSong(rawSong, localPath));
        importedSongCount += 1;
        final localAssoc = associationMap['__local__'];
        if (localAssoc != null) {
          localAssoc.songCount += 1;
        } else {
          associationMap['__local__'] = PluginBackupAssociation(
            pluginId: 'local',
            pluginName: tr('本地文件'),
            pluginFormat: 'musicfree',
            enabled: true,
            platform: tr('本地文件'),
            songCount: 1,
          );
        }
        continue;
      }

      if (id.isEmpty || platform.normalized.isEmpty) {
        failures.add(PluginBackupFailedSong(
          playlist: playlistName,
          title: title,
          artist: artist,
          platform: platform.displayName,
          reason: platform.normalized.isNotEmpty ? tr('歌曲缺少平台歌曲 ID') : tr('歌曲缺少来源平台'),
          reasonCode: 'invalid-song',
        ));
        continue;
      }

      final plugin = _findMatchingPlugin(platform, installedPlugins, detected.format);
      if (plugin == null) {
        failures.add(PluginBackupFailedSong(
          playlist: playlistName,
          title: title,
          artist: artist,
          platform: platform.displayName,
          reason: tr('缺少可处理“{platform}”的插件', {'platform': platform.displayName}),
          reasonCode: 'missing-plugin',
        ));
        final missing = missingPluginMap[platform.canonical];
        if (missing != null) {
          missingPluginMap[platform.canonical] = MissingBackupPlugin(
              platform: platform.displayName, songCount: missing.songCount + 1);
        } else {
          missingPluginMap[platform.canonical] =
              MissingBackupPlugin(platform: platform.displayName, songCount: 1);
        }
        continue;
      }

      final song = plugin.format == PluginFormat.lx && platform.lxSource != null
          ? _createLxSong(rawSong, plugin, platform)
          : _createMusicFreeSong(rawSong, plugin, platform, detected.restoreStringifiedIds);
      if (detected.restoreStringifiedIds &&
          _pickRawSongId(rawSong) is String &&
          int.tryParse(_pickRawSongId(rawSong).toString()) != null) {
        migratedTrackIdCount += 1;
      }
      songs.add(song);
      importedSongCount += 1;

      final associationKey = '${plugin.id}\u0000${platform.canonical}';
      final association = associationMap[associationKey];
      if (association != null) {
        association.songCount += 1;
      } else {
        associationMap[associationKey] = PluginBackupAssociation(
          pluginId: plugin.id,
          pluginName: plugin.name,
          pluginFormat: plugin.format.value,
          enabled: plugin.enabled,
          platform: platform.displayName,
          songCount: 1,
        );
      }
    }

    if (songs.isNotEmpty) {
      playlists.add(PluginBackupPlaylist(
        name: playlistName,
        songs: songs,
        originalSongCount: rawSongs.length,
      ));
    }
  }

  return PreparedPluginBackupImport(
    format: detected.format,
    sourcePlaylistCount: detected.sheets.length,
    totalSongCount: totalSongCount,
    importedSongCount: importedSongCount,
    playlists: playlists,
    failures: failures,
    associations: associationMap.values.toList(),
    missingPlugins: missingPluginMap.values.toList(),
    backupVersion: detected.version,
    migratedTrackIds: detected.restoreStringifiedIds,
    migratedTrackIdCount: migratedTrackIdCount,
  );
}

