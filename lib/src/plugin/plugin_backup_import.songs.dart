part of 'plugin_backup_import.dart';

int _parseDurationSeconds(Object? value) {
  if (value is String && value.contains(':')) {
    final parts = value.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.isNotEmpty) {
      return parts.fold<int>(0, (total, part) => total * 60 + part);
    }
  }
  final numeric = value is num ? value : double.tryParse(value?.toString() ?? '');
  if (numeric == null || !numeric.isFinite || numeric <= 0) return 0;
  return (numeric > 1000 ? numeric / 1000 : numeric).floor();
}

String _formatInterval(int seconds) {
  final minutes = (seconds / 60).floor();
  final remaining = seconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}

String _extractArtist(Map<String, dynamic> rawSong) {
  final artist = rawSong['artist'];
  if (artist is String && artist.trim().isNotEmpty) return artist.trim();
  final singer = rawSong['singer'];
  if (singer is String && singer.trim().isNotEmpty) return singer.trim();
  final singerList = rawSong['singerList'];
  if (singerList is List) {
    final names = singerList
        .map((a) => a is String ? a : (a is Map ? a['name']?.toString() : null))
        .whereType<String>()
        .where((n) => n.isNotEmpty)
        .toList();
    if (names.isNotEmpty) return names.join(', ');
  }
  return tr('未知歌手');
}

String _extractAlbum(Map<String, dynamic> rawSong) {
  final album = rawSong['album'];
  if (album is String && album.trim().isNotEmpty) return album.trim();
  if (album is Map && album['name'] != null) return album['name'].toString();
  final albumName = rawSong['albumName'];
  if (albumName is String && albumName.trim().isNotEmpty) return albumName.trim();
  final al = rawSong['al'];
  if (al is Map && al['name'] != null) return al['name'].toString();
  return tr('未知专辑');
}

Object? _pickRawSongId(Map<String, dynamic> rawSong) {
  for (final key in ['id', 'songmid', 'songId', 'songid', 'musicId', 'hash']) {
    if (rawSong.containsKey(key) && rawSong[key] != null) {
      return rawSong[key];
    }
  }
  return '';
}

String _extractSongId(Map<String, dynamic> rawSong) {
  return _pickRawSongId(rawSong).toString().trim();
}

Object? _normalizeTrackId(Object? value, bool restoreStringifiedNumber) {
  if (value is num) {
    return value.toDouble().isFinite ? value : null;
  }
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  if (!restoreStringifiedNumber) return text;
  final numericId = int.tryParse(text);
  if (numericId != null && numericId.toString() == text) {
    return numericId;
  }
  return text;
}

String _extractTitle(Map<String, dynamic> rawSong) {
  final title = rawSong['title'];
  if (title is String && title.trim().isNotEmpty) return title.trim();
  final name = rawSong['name'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  final songname = rawSong['songname'];
  if (songname is String && songname.trim().isNotEmpty) return songname.trim();
  return '';
}

String _resolveLocalPath(Map<String, dynamic> rawSong) {
  final localPath = rawSong['localPath'];
  if (localPath is String && localPath.trim().isNotEmpty) {
    return localPath.trim();
  }
  final url = rawSong['url'];
  if (url is String && url.startsWith('file:')) {
    var p = url;
    if (p.startsWith('file:///')) {
      p = p.substring('file:///'.length);
    } else if (p.startsWith('file://')) {
      p = p.substring('file://'.length);
    }
    try {
      return Uri.decodeComponent(p).replaceAll('/', '\\');
    } catch (_) {
      return p;
    }
  }
  final qualities = rawSong['qualities'];
  if (qualities is Map) {
    for (final q in qualities.values) {
      if (q is Map) {
        final qUrl = q['url'];
        if (qUrl is String && qUrl.startsWith('file:')) {
          var p = qUrl;
          if (p.startsWith('file:///')) {
            p = p.substring('file:///'.length);
          } else if (p.startsWith('file://')) {
            p = p.substring('file://'.length);
          }
          try {
            return Uri.decodeComponent(p).replaceAll('/', '\\');
          } catch (_) {
            return p;
          }
        }
      }
    }
  }
  return '';
}

Map<String, dynamic> _flattenLxMeta(Map<String, dynamic> rawSong) {
  final meta = rawSong['meta'];
  if (meta is! Map) return rawSong;
  final flattened = <String, dynamic>{};
  meta.forEach((k, v) => flattened[k.toString()] = v);
  final qualitys = meta['_qualitys'];
  if (qualitys != null) flattened['qualities'] = qualitys;
  final picUrl = meta['picUrl'];
  if (picUrl != null) flattened['img'] = picUrl;
  final filePath = meta['filePath'];
  if (filePath != null) flattened['localPath'] = filePath;
  rawSong.forEach((k, v) {
    if (!flattened.containsKey(k)) flattened[k] = v;
  });
  return flattened;
}

ImportedSong _createLocalSong(Map<String, dynamic> rawSong, String localPath) {
  return ImportedSong(
    title: _extractTitle(rawSong),
    artist: _extractArtist(rawSong),
    album: _extractAlbum(rawSong),
    duration: _parseDurationSeconds(rawSong['duration'] ?? rawSong['interval'] ?? rawSong['dt']),
    coverUrl: (rawSong['artwork'] ?? rawSong['coverUrl'] ?? rawSong['img'])?.toString(),
    localPath: localPath,
    path: localPath,
  );
}

ImportedSong _createMusicFreeSong(
  Map<String, dynamic> rawSong,
  PluginSource plugin,
  _PlatformDescriptor platform,
  bool restoreStringifiedIds,
) {
  final id = _extractSongId(rawSong);
  final title = _extractTitle(rawSong);
  final artist = _extractArtist(rawSong);
  final album = _extractAlbum(rawSong);
  final duration = _parseDurationSeconds(rawSong['duration'] ?? rawSong['interval'] ?? rawSong['dt']);
  final rawId = _pickRawSongId(rawSong);
  final normalizedId = _normalizeTrackId(rawId, restoreStringifiedIds) ?? id;

  final musicItem = <String, dynamic>{
    ...rawSong,
    'id': normalizedId,
    'title': title,
    'artist': artist,
    'album': album,
    'platform': rawSong['platform'] ?? platform.displayName,
  };
  final staleUrl = musicItem['url'];
  if (staleUrl is String && staleUrl.startsWith('http')) {
    musicItem.remove('url');
  }
  final path = 'plugin://${Uri.encodeComponent(platform.displayName)}/${Uri.encodeComponent(id)}';
  return ImportedSong(
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    coverUrl: (rawSong['artwork'] ?? rawSong['coverUrl'] ?? rawSong['img'])?.toString(),
    pluginId: plugin.id,
    source: platform.displayName,
    format: 'musicfree',
    musicInfo: musicItem,
    path: path,
  );
}

ImportedSong _createLxSong(
  Map<String, dynamic> rawSong,
  PluginSource plugin,
  _PlatformDescriptor platform,
) {
  final meta = rawSong['meta'];
  final metaMap = meta is Map ? meta : const <String, dynamic>{};
  final rawId = (rawSong['songmid'] ?? rawSong['mid'] ?? metaMap['songId'] ?? metaMap['songid'] ?? rawSong['id'] ?? rawSong['hash'] ?? metaMap['hash'] ?? '')
      .toString()
      .trim();
  final lxPrefix = platform.lxSource != null ? '${platform.lxSource}_' : '';
  final id = lxPrefix.isNotEmpty && rawId.startsWith(lxPrefix)
      ? rawId.substring(lxPrefix.length)
      : rawId;
  final duration = _parseDurationSeconds(rawSong['duration'] ?? rawSong['interval'] ?? rawSong['dt'] ?? metaMap['interval']);
  final qualityEntries = rawSong['qualities'] ?? metaMap['qualitys'];
  final types = <Map<String, dynamic>>[];
  final qualityMap = <String, dynamic>{};
  if (qualityEntries is Map) {
    qualityEntries.forEach((type, value) {
      final v = value is Map ? value : const <String, dynamic>{};
      final size = v['size']?.toString();
      final hash = v['hash'];
      types.add({'type': type, 'size': size, 'hash': hash});
      qualityMap[type.toString()] = {'size': size, 'hash': hash};
    });
  }
  final lxItem = <String, dynamic>{
    'name': _extractTitle(rawSong),
    'singer': _extractArtist(rawSong),
    'albumName': _extractAlbum(rawSong),
    'albumId': metaMap['albumId'] ?? rawSong['albumId'] ?? rawSong['album_id'] ?? rawSong['albumid'] ?? '',
    'songmid': id,
    'source': platform.lxSource,
    'interval': rawSong['interval'] is String
        ? rawSong['interval']
        : _formatInterval(duration),
    'img': (metaMap['picUrl'] ?? rawSong['artwork'] ?? rawSong['coverUrl'] ?? rawSong['img'])?.toString(),
    'types': types,
    '_types': qualityMap,
    'hash': metaMap['hash'] ?? rawSong['hash'] ?? rawSong['320hash'],
    'strMediaMid': (metaMap['strMediaMid'] ?? rawSong['strMediaMid'] ?? rawSong['songmid'] ?? rawSong['mid'] ?? id).toString(),
    'songId': metaMap['songId'] ?? metaMap['songid'] ?? rawSong['songId'] ?? rawSong['songid'],
    'albumMid': metaMap['albumMid'] ?? rawSong['albumMid'] ?? rawSong['albummid'],
    'copyrightId': metaMap['copyrightId'] ?? rawSong['copyrightId'],
  };
  final path = 'lx://${platform.lxSource}/${Uri.encodeComponent(id)}';
  return ImportedSong(
    title: _extractTitle(rawSong),
    artist: _extractArtist(rawSong),
    album: _extractAlbum(rawSong),
    duration: duration,
    coverUrl: (rawSong['artwork'] ?? rawSong['coverUrl'] ?? rawSong['img'])?.toString(),
    pluginId: plugin.id,
    source: platform.lxSource,
    format: 'lx',
    musicInfo: lxItem,
    path: path,
  );
}

