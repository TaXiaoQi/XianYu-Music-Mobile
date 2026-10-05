import 'dart:convert';

import '../core/application_logger.dart';
import '../rust/api.dart' as frb;
import 'fallback_modules/registry.dart';
import 'fallback_modules/types.dart'
    show kFallbackModuleLxToplist, kFallbackModulePluginFallback;
import 'plugin_models.dart';

final RegExp _qqPattern = RegExp(r'qq', caseSensitive: false);

bool isQqMusicPluginSource(PluginSource source, [String? platform]) {
  final haystack = '${source.name}|${platform ?? ''}';
  return _qqPattern.hasMatch(haystack);
}

const List<String> _qqPluginQualityKeys = ['128k', '320k', 'flac', 'hires'];

Map<String, dynamic> _lxItemToQqMusicFreeItem(Map<String, dynamic> item) {
  final qualities = <String, dynamic>{};
  final types = item['lx_types'];
  if (types is Map) {
    for (final key in _qqPluginQualityKeys) {
      final t = types[key];
      if (t is Map) {
        final size = t['size'];
        qualities[key] = {'size': size is String ? size : null};
      }
    }
  }
  final songmid = (item['songmid'] ?? '').toString();
  final albumId = item['album_id'];
  final albumMid = item['album_mid'] ?? item['album_id'];
  return {
    'id': (item['song_id'] ?? songmid).toString(),
    'songmid': songmid,
    'title': item['name'] ?? '',
    'artist': item['singer'] ?? '',
    'album': item['album_name'] ?? '',
    'albumid': albumId,
    'albummid': albumMid,
    'artwork': item['img'],
    'interval': item['interval'] ?? '',
    'qualities': qualities,
    '_hostLxFallback': true,
  };
}

/// 热修模块回传桌面端 PluginSearchResult 形状（rawData 携带原始 MusicFree
/// item）；内置路径回传本端 MusicFree item 形状——按 songmid 字段区分。
PluginSearchResult _hostFallbackItemToResult(
    Map<String, dynamic> m, PluginSource source) {
  if (m['songmid'] != null) {
    return PluginSearchResult(
      name: (m['title'] ?? '').toString(),
      singer: (m['artist'] ?? '').toString(),
      albumName: (m['album'] ?? '').toString(),
      songmid: m['songmid'].toString(),
      source: source.name,
      interval: (m['interval'] ?? '').toString(),
      img: m['artwork']?.toString(),
      rawData: m,
    );
  }
  final raw = m['rawData'] is Map
      ? Map<String, dynamic>.from(m['rawData'] as Map)
      : null;
  final durationMs = (m['duration'] as num?)?.toInt() ?? 0;
  final rawInterval = raw == null ? '' : (raw['interval'] ?? '').toString();
  return PluginSearchResult(
    name: (m['title'] ?? m['name'] ?? raw?['title'] ?? '').toString(),
    singer: (m['artist'] ?? raw?['artist'] ?? '').toString(),
    albumName: (m['album'] ?? raw?['album'] ?? '').toString(),
    songmid: ((raw?['songmid'] ?? m['id']) ?? '').toString(),
    source: (m['platform'] ?? source.name).toString(),
    interval: rawInterval.isNotEmpty
        ? rawInterval
        : durationMs > 0
            ? _formatSeconds(durationMs ~/ 1000)
            : '',
    img: (m['coverUrl'] ?? raw?['artwork'])?.toString(),
    rawData: raw,
  );
}

Map<String, dynamic> _hostFallbackAlbumToItem(Map<String, dynamic> m) {
  if (m['albumMID'] != null) return m;
  final raw = m['rawData'] is Map
      ? Map<String, dynamic>.from(m['rawData'] as Map)
      : null;
  if (raw != null && raw['albumMID'] != null) return raw;
  final mid = ((m['platformId'] ?? m['id']) ?? '').toString();
  return {
    'id': m['id'],
    'albumId': m['id'],
    'albumMID': mid,
    'title': m['name'],
    'name': m['name'],
    'artwork': m['coverUrl'],
    'date': m['year'],
    'artist': m['artist'],
    'description': m['description'],
  };
}

Future<List<Map<String, dynamic>>> _qqHostSearchBuiltinItems(
    PluginSource source, String keyword,
    {int limit = 30}) async {
  try {
    final json = await frb.lxSearch(source: 'tx', keyword: keyword, limit: limit);
    final list = jsonDecode(json);
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .map(_lxItemToQqMusicFreeItem)
        .where((m) => (m['songmid'] ?? '').toString().isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<List<PluginSearchResult>> qqHostSearchFallback(
    PluginSource source,
    String keyword, {
    int limit = 30,
  }) async {
  Future<List<Map<String, dynamic>>> builtinItems() =>
      _qqHostSearchBuiltinItems(source, keyword, limit: limit);
  // 模块回传桌面端结果形状；ok:true 但 data 为空视为模块无结论，回退内置
  final items = await dispatchFallbackModule<List<dynamic>?>(
    kFallbackModulePluginFallback,
    'hostSearchFallback',
    {'source': source.toJson(), 'keyword': keyword, 'page': 1, 'limit': limit},
    builtinItems,
  );
  return (items ?? await builtinItems())
      .whereType<Map>()
      .map((e) => _hostFallbackItemToResult(e.cast<String, dynamic>(), source))
      .toList();
}

Map<String, dynamic> qqRawAlbumToMusicFreeItem(Map<String, dynamic> album) {
  final albumMid = (album['albumMID'] ?? album['album_mid'] ?? '').toString();
  final id = album['albumID'] ?? album['albumid'];
  final albumName = album['albumName'] ?? album['album_name'];
  return {
    'id': id,
    'albumId': id,
    'albumMID': albumMid,
    'title': albumName,
    'name': albumName,
    'artwork': album['albumPic'] ??
        (albumMid.isNotEmpty
            ? 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albumMid.jpg'
            : null),
    'date': album['publicTime'] ?? album['pub_time'],
    'singerID': album['singerID'] ?? album['singer_id'],
    'artist': album['singerName'] ?? album['singer_name'],
    'singerMID': album['singerMID'] ?? album['singer_mid'],
    'description': album['desc'],
  };
}

Future<List<Map<String, dynamic>>> _qqHostAlbumSearchBuiltinItems(
    PluginSource source, String keyword,
    {int page = 1, int limit = 30}) async {
  try {
    final json =
        await frb.txSearchAlbums(keyword: keyword, page: page, limit: limit);
    final list = jsonDecode(json);
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => qqRawAlbumToMusicFreeItem(e.cast<String, dynamic>()))
        .where((m) => (m['albumMID'] ?? '').toString().isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<List<Map<String, dynamic>>> qqHostAlbumSearchFallback(
    PluginSource source,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
  Future<List<Map<String, dynamic>>> builtinItems() =>
      _qqHostAlbumSearchBuiltinItems(source, keyword, page: page, limit: limit);
  final items = await dispatchFallbackModule<List<dynamic>?>(
    kFallbackModulePluginFallback,
    'hostAlbumSearchFallback',
    {
      'source': source.toJson(),
      'keyword': keyword,
      'page': page,
      'limit': limit,
    },
    builtinItems,
  );
  return (items ?? await builtinItems())
      .whereType<Map>()
      .map((e) => _hostFallbackAlbumToItem(e.cast<String, dynamic>()))
      .toList();
}

Future<List<Map<String, dynamic>>> _qqHostAlbumSongsBuiltinItems(
    PluginSource source, String albumMid,
    {int page = 1, int limit = 30}) async {
  try {
    final json =
        await frb.txAlbumSongs(albumMid: albumMid, page: page, limit: limit);
    final list = jsonDecode(json);
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .map(_lxItemToQqMusicFreeItem)
        .where((m) => (m['songmid'] ?? '').toString().isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<List<PluginSearchResult>> qqHostAlbumSongsFallback(
    PluginSource source,
    String albumMid, {
    int page = 1,
    int limit = 30,
  }) async {
  Future<List<Map<String, dynamic>>> builtinItems() =>
      _qqHostAlbumSongsBuiltinItems(source, albumMid, page: page, limit: limit);
  final items = await dispatchFallbackModule<List<dynamic>?>(
    kFallbackModulePluginFallback,
    'hostAlbumSongsFallback',
    {
      'source': source.toJson(),
      'albumMid': albumMid,
      'page': page,
      'limit': limit,
    },
    builtinItems,
  );
  return (items ?? await builtinItems())
      .whereType<Map>()
      .map((e) => _hostFallbackItemToResult(e.cast<String, dynamic>(), source))
      .toList();
}

Future<List<PluginSearchResult>> qqFillSongDurations(
  PluginSource source,
  String? platform,
  List<PluginSearchResult> results,
) async {
  if (!isQqMusicPluginSource(source, platform)) return results;
  if (results.isEmpty) return results;
  // builtin 返回 null 仅作占位：本地实现在统一出口执行，避免网络调用重复发起
  final updated = await dispatchFallbackModule<List<dynamic>?>(
    kFallbackModulePluginFallback,
    'fillSongDurations',
    {
      'source': source.toJson(),
      'platform': platform,
      'results': results.map(_resultWithDurationHint).toList(),
    },
    () async => null,
  );
  if (updated == null) return _fillSongDurationsBuiltin(source, results);
  return updated.whereType<Map>().map((e) {
    final m = Map<String, dynamic>.from(e);
    final base = m['songmid'] != null
        ? PluginSearchResult.fromJson(m)
        : _hostFallbackItemToResult(m, source);
    final raw = m['rawData'];
    final secs = raw is Map ? raw['duration'] : null;
    return secs is num && secs > 0
        ? base.copyWith(interval: _formatSeconds(secs.toInt()))
        : base;
  }).toList();
}

/// 桌面端 fillSongDurations 契约：duration 为毫秒。已有 interval 的条目带上
/// duration 提示，避免热修模块重复拉取全量时长。
Map<String, dynamic> _resultWithDurationHint(PluginSearchResult r) {
  final json = r.toJson();
  final secs = _intervalToSecs(r.interval);
  if (secs != null) json['duration'] = secs * 1000;
  return json;
}

int? _intervalToSecs(String interval) {
  final match = RegExp(r'^(\d{1,3}):(\d{1,2})$').firstMatch(interval.trim());
  if (match == null) return null;
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}

Future<List<PluginSearchResult>> _fillSongDurationsBuiltin(
  PluginSource source,
  List<PluginSearchResult> results,
) async {
  final missing = results
      .where((r) =>
          r.interval.trim().isEmpty &&
          r.rawData != null &&
          r.rawData!['id'] != null &&
          (r.rawData!['id'] as String?)?.isNotEmpty != false)
      .toList();
  if (missing.isEmpty) return results;
  try {
    final ids = missing.map((r) => r.rawData!['id'].toString()).toList();
    final mapJson =
        await frb.txBatchTrackInterval(songIdsJson: jsonEncode(ids));
    final map = jsonDecode(mapJson);
    if (map is! Map || map.isEmpty) return results;
    return results.map((r) {
      if (r.interval.trim().isNotEmpty) return r;
      final id = r.rawData?['id'];
      final secs = id == null ? null : map[id.toString()];
      if (secs is! num || secs <= 0) return r;
      r.rawData!['duration'] = secs;
      return r.copyWith(interval: _formatSeconds(secs.toInt()));
    }).toList();
  } catch (_) {
    return results;
  }
}

String _formatSeconds(int secs) {
  if (secs < 0) secs = 0;
  final m = (secs ~/ 60).toString();
  final s = (secs % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

final RegExp _qqTrialUrlRe =
    RegExp(r'/RS0\d[A-Za-z0-9]{8,}\.(mp3|m4a|flac)(?:[?#]|$)', caseSensitive: false);
bool isQqTrialMediaUrl(String? url) =>
    url != null && _qqTrialUrlRe.hasMatch(url);

PluginSearchResult lxSearchItemToResult(String sourceKey, Map<String, dynamic> m) {
  final raw = Map<String, dynamic>.from(m)
    ..['source'] = sourceKey
    ..['_hostLxFallback'] = true;
  final types = <Map<String, dynamic>>[];
  final rawTypes = m['types'];
  if (rawTypes is List) {
    for (final t in rawTypes) {
      if (t is Map) types.add(t.cast<String, dynamic>());
    }
  }
  final lxTypes = <String, dynamic>{};
  final rawLxTypes = m['lx_types'];
  if (rawLxTypes is Map) {
    lxTypes.addAll(rawLxTypes.cast<String, dynamic>());
  }
  return PluginSearchResult(
    name: (m['name'] ?? '').toString(),
    singer: (m['singer'] ?? '').toString(),
    albumName: (m['album_name'] ?? '').toString(),
    albumId: m['album_id']?.toString(),
    songmid: (m['songmid'] ?? '').toString(),
    source: sourceKey,
    interval: (m['interval'] ?? '').toString(),
    img: m['img']?.toString(),
    hash: m['hash']?.toString(),
    strMediaMid: m['str_media_mid']?.toString(),
    songId: m['song_id'],
    albumMid: m['album_mid']?.toString(),
    copyrightId: m['copyright_id']?.toString(),
    types: types,
    lxTypes: lxTypes.isEmpty ? null : lxTypes,
    rawData: raw,
  );
}

Future<List<PluginSearchResult>> lxHostSearchFallback(
  PluginSource source,
  String sourceKey,
  String keyword, {
  int limit = 30,
}) async {
  try {
    final json =
        await frb.lxSearch(source: sourceKey, keyword: keyword, limit: limit);
    final list = jsonDecode(json);
    AppLog.debug('plugin', '[lxHostSearch] source=$sourceKey keyword=$keyword '
        'list=${(list is List) ? list.length : 'nonList'}');
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((m) => (m['songmid'] ?? '').toString().isNotEmpty)
        .map((m) => lxSearchItemToResult(sourceKey, m))
        .toList();
  } catch (e, st) {
    AppLog.warn('plugin', '[lxHostSearch] source=$sourceKey EXCEPTION: $e\n$st');
    return const [];
  }
}

Future<List<Map<String, dynamic>>> lxHostPlaylistSearchFallback(
  PluginSource source,
  String sourceKey,
  String keyword, {
  int page = 1,
  int limit = 30,
}) async {
  try {
    final json = await frb.lxSearchPlaylists(
      source: sourceKey,
      keyword: keyword,
      page: page,
      limit: limit,
    );
    final list = jsonDecode(json);
    AppLog.debug('plugin', '[lxHostPlaylistSearch] source=$sourceKey keyword=$keyword '
        'list=${(list is List) ? list.length : 'nonList'}');
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((m) => (m['playlist_id'] ?? '').toString().isNotEmpty)
        .map((m) {
          final playlistId = (m['playlist_id'] ?? '').toString();
          return <String, dynamic>{
            'id': playlistId,
            'title': (m['title'] ?? '').toString(),
            'artist': (m['artist'] ?? '').toString(),
            'coverUrl': m['cover_url']?.toString(),
            'trackCount': m['track_count'],
            'playCount': m['play_count'],
            'source': sourceKey,
            '_lxSource': sourceKey,
            '_lxPlaylistId': playlistId,
          };
        })
        .where((m) => (m['title'] as String).isNotEmpty)
        .toList();
  } catch (e, st) {
    AppLog.warn(
        'plugin', '[lxHostPlaylistSearch] source=$sourceKey EXCEPTION: $e\n$st');
    return const [];
  }
}

Future<List<PluginSearchResult>> lxHostPlaylistTracksFallback(
  PluginSource source,
  String sourceKey,
  String playlistId, {
  int page = 1,
  int limit = 100,
}) async {
  try {
    final json = await frb.lxPlaylistTracks(
      source: sourceKey,
      playlistId: playlistId,
      page: page,
      limit: limit,
    );
    final result = jsonDecode(json);
    if (result is! Map) return const [];
    final list = result['list'];
    AppLog.debug('plugin', '[lxHostPlaylistTracks] source=$sourceKey '
        'playlistId=$playlistId page=$page '
        'list=${(list is List) ? list.length : 'nonList'}');
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((m) => (m['songmid'] ?? '').toString().isNotEmpty)
        .map((m) => lxSearchItemToResult(sourceKey, m))
        .toList();
  } catch (e, st) {
    AppLog.warn('plugin',
        '[lxHostPlaylistTracks] source=$sourceKey EXCEPTION: $e\n$st');
    return const [];
  }
}

/// LX 榜单分组兜底（lx_toplist 模块，服务端下发 JS 优先、Rust builtin 兜底）。
/// 返回单分组 `[{ title, data: [board] }]`，与 JS 模块返回形状一致。
Future<List<dynamic>> lxToplistBoardsFallback(List<String> sourceKeys) async {
  if (sourceKeys.isEmpty) return const [];
  Future<List<dynamic>> builtin() async {
    // Dart 层超时兜底：Rust 各平台请求有 6-8s 上界，但桥传输层挂起时 await
    // 永不返回，列表页会永久转圈；异常上抛，由页面 catch 转「失败点击重试」态
    AppLog.info('plugin',
        '[lxToplistBoards] builtin 开始: sources=$sourceKeys');
    final json = await frb.lxToplistBoards(sources: sourceKeys)
        .timeout(const Duration(seconds: 12));
    AppLog.info(
        'plugin', '[lxToplistBoards] builtin 返回 ${json.length} 字节');
    final boards = jsonDecode(json);
    if (boards is! List) return const [];
    return [
      {'title': '音源榜单', 'data': boards},
    ];
  }

  return dispatchFallbackModule<List<dynamic>>(
    kFallbackModuleLxToplist,
    'getTopLists',
    {'sources': sourceKeys},
    builtin,
  );
}

/// LX 榜单歌曲页兜底：模块/builtin 均返回 `{ list, isEnd }`，
/// 统一取 list 过滤 songmid 非空；失败返回 const []。
Future<List<Map<String, dynamic>>> lxToplistBoardSongsFallback(
  String sourceKey,
  String boardId, {
  int page = 1,
  int limit = 30,
}) async {
  Future<Map<String, dynamic>?> builtin() async {
    try {
      // Dart 层超时兜底：Rust 内部有 8s+5s 封面上界，桥传输层挂起时 await 永不返回
      final json = await frb.lxToplistBoardSongs(
        source: sourceKey,
        boardId: boardId,
        page: page,
        limit: limit,
      ).timeout(const Duration(seconds: 15));
      final result = jsonDecode(json);
      return result is Map ? result.cast<String, dynamic>() : null;
    } catch (e, st) {
      AppLog.warn('plugin',
          '[lxToplistBoardSongs] source=$sourceKey board=$boardId EXCEPTION: $e\n$st');
      return null;
    }
  }

  final result = await dispatchFallbackModule<Map<String, dynamic>?>(
    kFallbackModuleLxToplist,
    'getTopListDetail',
    {'source': sourceKey, 'id': boardId, 'page': page, 'limit': limit},
    builtin,
  );
  final list = result?['list'];
  if (list is! List) return const [];
  return list
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .where((m) => (m['songmid'] ?? '').toString().isNotEmpty)
      .toList();
}