library;

import 'dart:convert';
import 'dart:io';

import 'plugin_models.dart';
import '../i18n/i18n.dart';

class ImportedSong {
  final String title;
  final String artist;
  final String album;
  final int duration;
  final String? coverUrl;
  final String? coverThumbPath;
  final String? localPath;
  final String? pluginId;
  final String? source;
  final String? format;
  final Map<String, dynamic>? musicInfo;
  final bool addedInApp;
  final String path;

  ImportedSong({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.coverUrl,
    this.coverThumbPath,
    this.localPath,
    this.pluginId,
    this.source,
    this.format,
    this.musicInfo,
    this.addedInApp = false,
    required this.path,
  });

  bool get isLocal => localPath != null && localPath!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'coverUrl': coverUrl,
        'coverThumbPath': coverThumbPath,
        'localPath': localPath,
        'pluginId': pluginId,
        'source': source,
        'format': format,
        'musicInfo': musicInfo,
        if (addedInApp) 'addedInApp': true,
        'path': path,
      };

  factory ImportedSong.fromJson(Map<String, dynamic> j) => ImportedSong(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        coverUrl: j['coverUrl'] as String?,
        coverThumbPath: j['coverThumbPath'] as String?,
        localPath: j['localPath'] as String?,
        pluginId: j['pluginId'] as String?,
        source: j['source'] as String?,
        format: j['format'] as String?,
        musicInfo: j['musicInfo'] is Map
            ? (j['musicInfo'] as Map).cast<String, dynamic>()
            : null,
        addedInApp: j['addedInApp'] == true,
        path: j['path'] as String? ?? '',
      );

  ImportedSong copyWith({
    String? pluginId,
    String? source,
    String? format,
    Map<String, dynamic>? musicInfo,
    bool? addedInApp,
  }) => ImportedSong(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        coverUrl: coverUrl,
        coverThumbPath: coverThumbPath,
        localPath: localPath,
        pluginId: pluginId ?? this.pluginId,
        source: source ?? this.source,
        format: format ?? this.format,
        musicInfo: musicInfo ?? this.musicInfo,
        addedInApp: addedInApp ?? this.addedInApp,
        path: path,
      );
}

class PluginBackupPlaylist {
  final String name;
  final List<ImportedSong> songs;
  final int originalSongCount;
  final String? cloudId;
  final bool isCloud;
  // 来源信息：云同步/备份链路透传，保证导入歌单跨设备保留源端更新能力
  final String? sourcePluginId;
  final String? sourceUrl;
  final Map<String, dynamic>? sourceRaw;

  PluginBackupPlaylist({
    required this.name,
    required this.songs,
    required this.originalSongCount,
    this.cloudId,
    this.isCloud = false,
    this.sourcePluginId,
    this.sourceUrl,
    this.sourceRaw,
  });
}

class PluginBackupFailedSong {
  final String playlist;
  final String title;
  final String artist;
  final String platform;
  final String reason;
  final String reasonCode;

  PluginBackupFailedSong({
    required this.playlist,
    required this.title,
    required this.artist,
    required this.platform,
    required this.reason,
    required this.reasonCode,
  });
}

class PluginBackupAssociation {
  final String pluginId;
  final String pluginName;
  final String pluginFormat;
  final bool enabled;
  final String platform;
  int songCount;

  PluginBackupAssociation({
    required this.pluginId,
    required this.pluginName,
    required this.pluginFormat,
    required this.enabled,
    required this.platform,
    required this.songCount,
  });
}

class MissingBackupPlugin {
  final String platform;
  final int songCount;

  MissingBackupPlugin({required this.platform, required this.songCount});
}

class PreparedPluginBackupImport {
  final String format;
  final int sourcePlaylistCount;
  final int totalSongCount;
  final int importedSongCount;
  final List<PluginBackupPlaylist> playlists;
  final List<PluginBackupFailedSong> failures;
  final List<PluginBackupAssociation> associations;
  final List<MissingBackupPlugin> missingPlugins;
  final int? backupVersion;
  final bool migratedTrackIds;
  final int migratedTrackIdCount;

  PreparedPluginBackupImport({
    required this.format,
    required this.sourcePlaylistCount,
    required this.totalSongCount,
    required this.importedSongCount,
    required this.playlists,
    required this.failures,
    required this.associations,
    required this.missingPlugins,
    this.backupVersion,
    required this.migratedTrackIds,
    required this.migratedTrackIdCount,
  });
}

const int _stringifiedTrackIdBackupVersion = 2;
const int _currentTrackIdBackupVersion = 3;

class _PlatformDescriptor {
  final String displayName;
  final String normalized;
  final String canonical;
  final String? lxSource;

  _PlatformDescriptor({
    required this.displayName,
    required this.normalized,
    required this.canonical,
    this.lxSource,
  });
}

List<Map<String, Object?>> get _platformAliases => [
  {
    'canonical': 'netease',
    'displayName': tr('网易云音乐'),
    'lxSource': 'wy',
    'aliases': ['wy', 'netease', tr('网易'), tr('网易云'), tr('网易云音乐')],
  },
  {
    'canonical': 'qq',
    'displayName': tr('QQ音乐'),
    'lxSource': 'tx',
    'aliases': ['tx', 'qq', 'qqmusic', tr('腾讯'), tr('腾讯音乐'), tr('qq音乐')],
  },
  {
    'canonical': 'kuwo',
    'displayName': tr('酷我音乐'),
    'lxSource': 'kw',
    'aliases': ['kw', 'kuwo', tr('酷我'), tr('酷我音乐')],
  },
  {
    'canonical': 'kugou',
    'displayName': tr('酷狗音乐'),
    'lxSource': 'kg',
    'aliases': ['kg', 'kugou', tr('酷狗'), tr('酷狗音乐')],
  },
  {
    'canonical': 'migu',
    'displayName': tr('咪咕音乐'),
    'lxSource': 'mg',
    'aliases': ['mg', 'migu', tr('咪咕'), tr('咪咕音乐')],
  },
  {
    'canonical': 'bilibili',
    'displayName': tr('哔哩哔哩'),
    'aliases': ['bilibili', tr('b站'), tr('哔哩哔哩')],
  },
];

String _normalizePlatformLabel(Object? value) {
  return (value?.toString() ?? '')
      .replaceAll(RegExp(r'[\s_.\-—/\\()[\]（）【】·]+'), '')
      .replaceAll(RegExp(r'(?:音乐|music|音源|source|插件|plugin)+$'), '')
      .toLowerCase();
}

_PlatformDescriptor _describePlatform(Object? value) {
  final original = (value?.toString() ?? '').trim();
  final normalized = _normalizePlatformLabel(original);

  for (final definition in _platformAliases) {
    final aliases = (definition['aliases'] as List)
        .map((a) => _normalizePlatformLabel(a))
        .toList();
    for (final alias in aliases) {
      if (normalized == alias || (alias.length >= 2 && normalized.contains(alias))) {
        return _PlatformDescriptor(
          displayName: original.isEmpty ? definition['displayName'] as String : original,
          normalized: normalized,
          canonical: definition['canonical'] as String,
          lxSource: definition['lxSource'] as String?,
        );
      }
    }
  }

  return _PlatformDescriptor(
    displayName: original.isEmpty ? tr('未知来源') : original,
    normalized: normalized,
    canonical: normalized,
  );
}

int _pluginMatchScore(
  PluginSource plugin,
  _PlatformDescriptor platform,
  String? format,
) {
  if (!plugin.format.isMfCompatible && plugin.format != PluginFormat.lx) {
    return 0;
  }

  if (plugin.format == PluginFormat.lx &&
      platform.lxSource != null &&
      plugin.sources.contains(platform.lxSource)) {
    return format == 'lxmusic' ? 150 : 120;
  }

  var best = 0;
  final labels = [plugin.name, ...plugin.sources];
  for (final label in labels) {
    final normalized = _normalizePlatformLabel(label);
    if (normalized.isEmpty) continue;
    if (normalized == platform.normalized) {
      final score = plugin.format.isMfCompatible ? 140 : 110;
      if (score > best) best = score;
    }
    final descriptor = _describePlatform(label);
    if (descriptor.canonical.isNotEmpty &&
        descriptor.canonical == platform.canonical) {
      final score = plugin.format.isMfCompatible ? 130 : 100;
      if (score > best) best = score;
    }
  }

  return best;
}

PluginSource? _findMatchingPlugin(
  _PlatformDescriptor platform,
  List<PluginSource> installedPlugins,
  String? format,
) {
  final scored = <(PluginSource, int)>[];
  for (final plugin in installedPlugins) {
    final score = _pluginMatchScore(plugin, platform, format);
    if (score > 0) scored.add((plugin, score));
  }
  scored.sort((a, b) {
    if (a.$1.enabled != b.$1.enabled) return a.$1.enabled ? -1 : 1;
    if (a.$2 != b.$2) return b.$2 - a.$2;
    if (a.$1.format != b.$1.format) {
      if (format == 'lxmusic') {
        return a.$1.format == PluginFormat.lx ? -1 : 1;
      }
      return a.$1.format.isMfCompatible ? -1 : 1;
    }
    return 0;
  });
  return scored.isEmpty ? null : scored.first.$1;
}

PluginSource? findPluginForPlatform({
  required String platformLabel,
  required List<PluginSource> installedPlugins,
  required PluginFormat format,
  bool allowCrossFormat = false,
}) {
  final descriptor = _describePlatform(platformLabel);
  if (descriptor.normalized.isEmpty) return null;
  final candidates = allowCrossFormat
      ? installedPlugins
      : installedPlugins.where((p) => p.format == format).toList();
  return _findMatchingPlugin(
    descriptor,
    candidates,
    format == PluginFormat.lx ? 'lxmusic' : 'bakamusic',
  );
}

PluginSource? findPluginForPlatformCrossFormat({
  required String platformLabel,
  required List<PluginSource> installedPlugins,
  required PluginFormat originalFormat,
}) {
  return findPluginForPlatform(
    platformLabel: platformLabel,
    installedPlugins: installedPlugins,
    format: originalFormat,
    allowCrossFormat: true,
  );
}

List<PluginSource> listEnabledPluginsForPlatform({
  required String platformLabel,
  required List<PluginSource> installedPlugins,
  required PluginFormat format,
  String? excludeId,
}) {
  final descriptor = _describePlatform(platformLabel);
  if (descriptor.normalized.isEmpty) return const [];
  final formatTag = format == PluginFormat.lx ? 'lxmusic' : 'bakamusic';
  final scored = <(PluginSource, int)>[];
  for (final plugin in installedPlugins) {
    if (!plugin.enabled || plugin.id == excludeId) continue;
    final score = _pluginMatchScore(plugin, descriptor, formatTag);
    if (score > 0) scored.add((plugin, score));
  }
  scored.sort((a, b) {
    if (a.$2 != b.$2) return b.$2 - a.$2;
    return (a.$1.sortOrder ?? 0).compareTo(b.$1.sortOrder ?? 0);
  });
  return scored.map((e) => e.$1).toList();
}

String lxSourceKeyForPlatform(String platformLabel) {
  final desc = _describePlatform(platformLabel);
  return desc.lxSource ?? '';
}

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

// ==================== M3U / M3U8 / 椒盐音乐 TXT 解析 ====================

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

String describeBackupVersion(PreparedPluginBackupImport prepared) {
  final formatName = switch (prepared.format) {
    'bakamusic' => 'BakaMusic',
    'musicfree' => 'MusicFree',
    'lxmusic' => tr('洛雪音乐'),
    'm3u' => tr('M3U 播放列表'),
    'txt' => tr('椒盐音乐'),
    _ => tr('未知格式'),
  };
  if (prepared.format == 'm3u' || prepared.format == 'txt') {
    return formatName;
  }
  if (prepared.backupVersion == null) {
    return tr('{name} 备份（未标注版本）', {'name': formatName});
  }
  final label = '$formatName v${prepared.backupVersion}';
  if (prepared.migratedTrackIds) {
    return prepared.migratedTrackIdCount > 0
        ? tr('{label} 旧版备份，已还原 {n} 首歌曲 ID 以恢复逐字歌词', {'label': label, 'n': prepared.migratedTrackIdCount})
        : tr('{label} 旧版备份', {'label': label});
  }
  if (prepared.format == 'bakamusic' && prepared.backupVersion! >= _currentTrackIdBackupVersion) {
    return tr('{label} 新版备份', {'label': label});
  }
  return label;
}
