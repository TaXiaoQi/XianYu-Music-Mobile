import 'dart:convert';

import '../player/player_provider.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

/// 歌单/榜单条目（MusicFree 插件）。
class MfSheetItem {
  final String id;
  final String title;
  final String artist;
  final String? coverUrl;
  final int? playCount;
  final int? trackCount;
  final String platform;
  final String pluginId;
  final bool isTopList;
  final bool isAlbum;
  final Map<String, dynamic> raw;

  const MfSheetItem({
    required this.id,
    required this.title,
    this.artist = '',
    this.coverUrl,
    this.playCount,
    this.trackCount,
    this.platform = '',
    required this.pluginId,
    this.isTopList = false,
    this.isAlbum = false,
    required this.raw,
  });

  String get subtitle {
    final parts = <String>[
      if (artist.isNotEmpty) artist,
      if (trackCount != null && trackCount! > 0) '$trackCount 首',
      if (playCount != null && playCount! > 0) _formatCount(playCount!),
    ];
    return parts.join(' · ');
  }

  static String _formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

/// 歌手条目（MusicFree 插件）。
class MfArtistItem {
  final String id;
  final String name;
  final String? avatarUrl;
  final String platform;
  final String pluginId;
  final Map<String, dynamic> raw;

  const MfArtistItem({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.platform = '',
    required this.pluginId,
    required this.raw,
  });
}

/// 专辑条目（MusicFree 插件）。
class MfAlbumItem {
  final String id;
  final String name;
  final String artist;
  final String? coverUrl;
  final String platform;
  final String pluginId;
  final Map<String, dynamic> raw;

  const MfAlbumItem({
    required this.id,
    required this.name,
    this.artist = '',
    this.coverUrl,
    this.platform = '',
    required this.pluginId,
    required this.raw,
  });
}

/// 插件目录服务：榜单 / 歌单 / 歌手 / 专辑（对齐桌面端 pluginEngine.ts 的 MF 协议）。
class PluginCatalogService {
  final PluginEngine engine;
  final List<PluginSource> sources;

  PluginCatalogService(this.engine, this.sources);

  /// 已启用的 MusicFree 插件。
  List<PluginSource> get musicFreeSources =>
      sources.where((s) => s.enabled && s.format == PluginFormat.musicfree).toList();

  /// 插件可用方法（加载后元数据里的 _availableMethods）。
  Future<Set<String>> _availableMethods(PluginSource source) async {
    await engine.ensureLoaded(source);
    final meta = engine.metadataOf(source.id);
    final list = meta?['_availableMethods'];
    if (list is List) return list.map((e) => e.toString()).toSet();
    return const {};
  }

  Future<bool> supportsTopLists(PluginSource source) async =>
      (await _availableMethods(source)).contains('getTopLists');

  // ==================== 基础调用 ====================

  Future<dynamic> _call(PluginSource source, String method,
      List<dynamic> args, {
        int timeoutMs = 30000,
      }) async {
    await engine.ensureLoaded(source);
    return engine.call(source.id, method, args, timeoutMs: timeoutMs);
  }

  // ==================== 榜单 ====================

  /// 获取插件榜单列表（分类展平，对齐桌面 flattenTopListCategories）。
  Future<List<MfSheetItem>> getTopLists(PluginSource source) async {
    try {
      final result = await _call(source, 'getTopLists', []);
      if (result is! List) return const [];
      final items = <MfSheetItem>[];
      for (final category in result) {
        if (category is! Map) continue;
        final cat = category.cast<String, dynamic>();
        final data = cat['data'];
        if (data is List && data.isNotEmpty) {
          for (final e in data) {
            if (e is! Map) continue;
            final m = Map<String, dynamic>.from(e);
            m['_isTopList'] = true;
            items.add(_toSheet(m, source, categoryTitle: cat['title']));
          }
        } else {
          cat['_isTopList'] = true;
          items.add(_toSheet(cat, source));
        }
      }
      return items;
    } catch (_) {
      return const [];
    }
  }

  /// 榜单详情曲目。
  Future<List<PluginSearchResult>> getTopListDetail(
      PluginSource source, Map<String, dynamic> item, {int page = 1}) async {
    final list = await _tryCallList(
        source, 'getTopListDetail', [item, page]);
    return list;
  }

  // ==================== 歌单 ====================

  /// 歌单详情曲目：getMusicSheetInfo → 歌单名搜索回退。
  Future<List<PluginSearchResult>> getMusicSheetInfo(
      PluginSource source, Map<String, dynamic> item,
      {int page = 1}) async {
    final methods = await _availableMethods(source);
    if (methods.contains('getMusicSheetInfo')) {
      final list =
          await _tryCallList(source, 'getMusicSheetInfo', [item, page]);
      if (list.isNotEmpty) return list;
    }
    if (page == 1 && methods.contains('search')) {
      final title = _stripHtml(item['title'] ?? item['name'] ?? '');
      if (title.isNotEmpty) {
        return _tryCallList(source, 'search', [title, 1, 'music']);
      }
    }
    return const [];
  }

  /// 歌单详情曲目 + 分页结束标志（isEnd）。
  /// 与 getMusicSheetInfo 同逻辑，但保留 isEnd 供全量导入判断是否还有下一页，
  /// 避免按返回数量猜页大小（如每页 20 首的歌单被误判为已结束）导致丢歌。
  Future<({List<PluginSearchResult> songs, bool? isEnd})> getMusicSheetInfoWithEnd(
      PluginSource source, Map<String, dynamic> item,
      {int page = 1}) async {
    final methods = await _availableMethods(source);
    if (methods.contains('getMusicSheetInfo')) {
      final raw = await _tryCallRaw(source, 'getMusicSheetInfo', [item, page]);
      if (raw != null) {
        final list = extractMfResultList(raw);
        if (list.isNotEmpty) {
          final songs = list
              .map((e) => mfItemToSearchResult(e, source))
              .where((r) => r.name.isNotEmpty)
              .toList();
          return (songs: songs, isEnd: extractMfIsEnd(raw));
        }
      }
    }
    if (page == 1 && methods.contains('search')) {
      final title = _stripHtml(item['title'] ?? item['name'] ?? '');
      if (title.isNotEmpty) {
        final songs = await _tryCallList(source, 'search', [title, 1, 'music']);
        return (songs: songs, isEnd: true);
      }
    }
    return (songs: const <PluginSearchResult>[], isEnd: true);
  }

  /// 歌单搜索：sheet → playlist → 专辑回退（专辑也按歌单索引，对齐桌面）。
  Future<List<MfSheetItem>> searchSheets(
      PluginSource source, String keyword) async {
    for (final type in ['sheet', 'playlist', 'album']) {
      final list = await _tryCallRawList(source, 'search', [keyword, 1, type]);
      if (list.isEmpty) continue;
      final sheets = list.map((m) {
        if (type == 'album') m['_isAlbum'] = true;
        return _toSheet(m, source);
      }).where((s) => s.title.isNotEmpty).toList();
      if (sheets.isNotEmpty) return sheets;
    }
    return const [];
  }

  // ==================== 歌手 ====================

  /// 歌手搜索。
  Future<List<MfArtistItem>> searchArtists(
      PluginSource source, String keyword) async {
    final list = await _tryCallRawList(source, 'search', [keyword, 1, 'artist']);
    return list
        .map((m) => _toArtist(m, source))
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  /// 歌手作品（歌曲）。
  Future<List<PluginSearchResult>> getArtistWorks(
      PluginSource source, Map<String, dynamic> item, {int page = 1}) async {
    final methods = await _availableMethods(source);
    if (methods.contains('getArtistWorks')) {
      final list =
          await _tryCallList(source, 'getArtistWorks', [item, page, 'music']);
      if (list.isNotEmpty) return list;
    }
    if (page == 1 && methods.contains('search')) {
      final name = _stripHtml(item['name'] ?? item['title'] ?? item['artist'] ?? '');
      if (name.isNotEmpty) {
        return _tryCallList(source, 'search', [name, 1, 'music']);
      }
    }
    return const [];
  }

  /// 歌手专辑。
  Future<List<MfAlbumItem>> getArtistAlbums(
      PluginSource source, Map<String, dynamic> item, {int page = 1}) async {
    final list =
        await _tryCallRawList(source, 'getArtistWorks', [item, page, 'album']);
    return list
        .map((m) => _toAlbum(m, source))
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  /// 歌手简介。
  Future<String> getArtistInfo(
      PluginSource source, Map<String, dynamic> item) async {
    try {
      final methods = await _availableMethods(source);
      if (!methods.contains('getArtistInfo')) return '';
      final info = await _call(source, 'getArtistInfo', [item]);
      if (info is! Map) return '';
      return _extractDescription(info.cast<String, dynamic>());
    } catch (_) {
      return '';
    }
  }

  // ==================== 专辑 ====================

  /// 专辑搜索。
  Future<List<MfAlbumItem>> searchAlbums(
      PluginSource source, String keyword) async {
    final list = await _tryCallRawList(source, 'search', [keyword, 1, 'album']);
    return list
        .map((m) => _toAlbum(m, source))
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  /// 专辑详情曲目：getAlbumInfo。
  Future<List<PluginSearchResult>> getAlbumSongs(
      PluginSource source, Map<String, dynamic> item, {int page = 1}) async {
    final methods = await _availableMethods(source);
    if (!methods.contains('getAlbumInfo')) {
      if (methods.contains('search')) {
        final title = _stripHtml(item['title'] ?? item['name'] ?? item['album'] ?? '');
        if (title.isNotEmpty) {
          return _tryCallList(source, 'search', [title, 1, 'music']);
        }
      }
      return const [];
    }
    // QQ 插件读取大写 albumMID，缺失时补齐（对齐桌面）。
    final req = Map<String, dynamic>.from(item);
    final albumMid = req['albumMID'] ?? req['albummid'] ?? req['albumMid'];
    if (albumMid != null && req['albumMID'] == null) {
      req['albumMID'] = albumMid;
    }
    return _tryCallList(source, 'getAlbumInfo', [req, page]);
  }

  // ==================== 单曲搜索（MusicFree） ====================

  Future<List<PluginSearchResult>> searchMusic(
      PluginSource source, String keyword,
      {int limit = 30}) async {
    return _tryCallList(source, 'search', [keyword, 1, 'music'], limit: limit);
  }

  // ==================== 队列项转换 ====================

  /// MusicFree 歌曲搜索结果 → 播放队列项（format: musicfree 走 getMusicUrl）。
  static QueueItem toQueueItem(PluginSource source, PluginSearchResult r) {
    final songJson = jsonEncode({
      'pluginId': source.id,
      'format': 'musicfree',
      'musicInfo': r.toJson(),
    });
    return QueueItem(
      path: 'plugin://${source.id}/${r.songmid}',
      title: r.name,
      artist: r.singer,
      album: r.albumName,
      durationMs: _parseIntervalMs(r.interval),
      coverUrl: r.img,
      onlineSongJson: songJson,
      onlineQuality: '320k',
    );
  }

  // ==================== 内部工具 ====================

  Future<List<PluginSearchResult>> _tryCallList(
      PluginSource source, String method, List<dynamic> args,
      {int limit = 100}) async {
    final raw = await _tryCallRawList(source, method, args);
    final mapped = raw
        .map((e) => mfItemToSearchResult(e, source))
        .where((r) => r.name.isNotEmpty)
        .toList();
    return mapped.length > limit ? mapped.sublist(0, limit) : mapped;
  }

  /// 调用插件方法并返回原始结果（不提取列表），供需要 isEnd 等标志的场景使用。
  Future<dynamic> _tryCallRaw(
      PluginSource source, String method, List<dynamic> args) async {
    try {
      return await _call(source, method, args);
    } catch (_) {
      return null;
    }
  }

  /// 调用插件方法并取原始条目列表（不转搜索结果）。
  Future<List<Map<String, dynamic>>> _tryCallRawList(
      PluginSource source, String method, List<dynamic> args) async {
    try {
      final result = await _call(source, method, args);
      return extractMfResultList(result);
    } catch (_) {
      return const [];
    }
  }

  MfSheetItem _toSheet(Map<String, dynamic> m, PluginSource source,
      {dynamic categoryTitle}) {
    final id = (m['id'] ?? m['albumId'] ?? m['songId'] ?? m['musicId'] ?? '')
        .toString();
    return MfSheetItem(
      id: id,
      title: _stripHtml(m['title'] ?? m['name'] ?? m['album'] ?? ''),
      artist: _stripHtml(categoryTitle ?? m['artist'] ?? m['author'] ?? m['singer'] ?? ''),
      coverUrl: _extractCover(m),
      playCount: _toInt(m['playCount'] ?? m['playcount'] ?? m['play_count']),
      trackCount: _toInt(m['trackCount'] ?? m['trackcount'] ?? m['track_count']),
      platform: source.name,
      pluginId: source.id,
      isTopList: m['_isTopList'] == true,
      isAlbum: m['_isAlbum'] == true,
      raw: m,
    );
  }

  MfArtistItem _toArtist(Map<String, dynamic> m, PluginSource source) {
    final id = (m['id'] ?? m['artistId'] ?? '').toString();
    return MfArtistItem(
      id: id,
      name: _stripHtml(m['name'] ?? m['title'] ?? m['artist'] ?? ''),
      avatarUrl: _extractAvatar(m),
      platform: source.name,
      pluginId: source.id,
      raw: m,
    );
  }

  MfAlbumItem _toAlbum(Map<String, dynamic> m, PluginSource source) {
    final id = (m['id'] ?? m['albumId'] ?? m['albumMid'] ?? '').toString();
    return MfAlbumItem(
      id: id,
      name: _stripHtml(m['title'] ?? m['name'] ?? m['album'] ?? ''),
      artist: _extractArtistText(m),
      coverUrl: _extractCover(m),
      platform: source.name,
      pluginId: source.id,
      raw: m,
    );
  }
}

// ==================== 顶层工具函数（供页面复用） ====================

String _stripHtml(dynamic v) {
  if (v is! String) return '';
  return v.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}

int? _toInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// 从插件返回结果中提取 isEnd（分页结束标志），兼容 isEnd/is_end 及嵌套一层。
bool? extractMfIsEnd(dynamic result) {
  if (result is! Map) return null;
  final isEnd = result['isEnd'];
  if (isEnd is bool) return isEnd;
  final isEndSnake = result['is_end'];
  if (isEndSnake is bool) return isEndSnake;
  for (final v in result.values) {
    if (v is Map) {
      final inner = v['isEnd'];
      if (inner is bool) return inner;
      final innerSnake = v['is_end'];
      if (innerSnake is bool) return innerSnake;
    }
  }
  return null;
}

/// MusicFree 返回结果 → 歌曲列表（兼容 data/musicList/isEnd 等结构，对齐桌面 extractResultList）。
List<Map<String, dynamic>> extractMfResultList(dynamic result) {
  if (result is List) {
    return result.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
  if (result is! Map) return const [];
  const fields = [
    'musicList', 'musiclist', 'songList', 'songlist', 'song_list',
    'songs', 'tracks', 'dataList', 'list', 'items', 'data', 'resData',
    'sheetList', 'sheetlist', 'playlists', 'playlist',
  ];
  for (final f in fields) {
    final v = result[f];
    if (v is List && v.isNotEmpty) {
      return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
  }
  for (final f in fields) {
    final v = result[f];
    if (v is Map) {
      final inner = extractMfResultList(v);
      if (inner.isNotEmpty) return inner;
    }
  }
  return const [];
}

/// 提取歌手文本（字符串 / 对象数组，对齐桌面 extractArtist）。
String _extractArtistText(Map<String, dynamic> item) {
  final artist = item['artist'];
  if (artist is String) return _stripHtml(artist);
  final singer = item['singer'];
  if (singer is String) return _stripHtml(singer);
  for (final key in ['artists', 'ar']) {
    final v = item[key];
    if (v is List) {
      return v
          .map((a) => a is String ? a : (a is Map ? (a['name'] ?? '') : ''))
          .where((s) => s.toString().isNotEmpty)
          .join('/');
    }
  }
  return '';
}

/// 提取专辑名。
String _extractAlbumText(Map<String, dynamic> item) {
  final album = item['album'];
  if (album is String) return _stripHtml(album);
  if (album is Map && album['name'] is String) {
    return _stripHtml(album['name']);
  }
  for (final key in ['albumName', 'al']) {
    final v = item[key];
    if (v is String) return _stripHtml(v);
    if (v is Map && v['name'] is String) return _stripHtml(v['name']);
  }
  return '';
}

/// 提取封面（对齐桌面 extractCoverUrl 的常用字段）。
String? _extractCover(Map<String, dynamic> node) {
  const direct = [
    'artwork', 'cover', 'coverImg', 'coverUrl', 'cover_url', 'pic',
    'picurl', 'img', 'imgurl', 'imgUrl', 'albumPic', 'picture',
  ];
  for (final k in direct) {
    final v = node[k];
    if (v is String && v.startsWith('http')) return v;
  }
  for (final k in ['al', 'album']) {
    final v = node[k];
    if (v is Map) {
      for (final kk in ['picUrl', 'blurPicUrl']) {
        final u = v[kk];
        if (u is String && u.startsWith('http')) return u;
      }
    }
  }
  for (final k in ['picUrl', 'coverImgUrl']) {
    final v = node[k];
    if (v is String && v.startsWith('http')) return v;
  }
  return null;
}

/// 提取歌手头像。
String? _extractAvatar(Map<String, dynamic> item) {
  const candidates = [
    'avatarUrl', 'avatar', 'avatar_url', 'picUrl', 'pic_url', 'pic',
    'img1v1Url', 'headUrl', 'face', 'artistPic', 'coverUrl', 'img',
  ];
  for (final k in candidates) {
    final v = item[k];
    if (v is String && v.startsWith('http')) return v;
  }
  return _extractCover(item);
}

/// 提取简介文本。
String _extractDescription(Map<String, dynamic> raw) {
  const candidates = [
    'artistDesc', 'artistIntro', 'briefDesc', 'intro', 'desc',
    'description', 'profile', 'bio', 'biography',
  ];
  for (final k in candidates) {
    final v = raw[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is Map) {
      final inner = _extractDescription(Map<String, dynamic>.from(v));
      if (inner.isNotEmpty) return inner;
    }
  }
  return '';
}

/// 解析时长（ms/s 启发式：≥60000 视为毫秒，对齐桌面 parseDuration）。
int _parseDurationValue(dynamic v) {
  if (v == null) return 0;
  if (v is num) {
    if (!v.isFinite || v <= 0) return 0;
    return v >= 60000 ? v.toInt() : (v * 1000).toInt();
  }
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return 0;
    if (t.contains(':')) {
      final parts = t.split(':');
      if (parts.length == 2) {
        final m = int.tryParse(parts[0]);
        final s = int.tryParse(parts[1]);
        if (m != null && s != null) return (m * 60 + s) * 1000;
      }
    }
    final n = double.tryParse(t);
    if (n != null && n > 0) return n >= 60000 ? n.toInt() : (n * 1000).toInt();
  }
  return 0;
}

/// 提取条目时长（毫秒）。
int extractMfDurationMs(Map<String, dynamic> item) {
  const keys = [
    'duration', 'durationMs', 'interval', 'dt', 'time', 'length', 'dur',
    'len', 'timelength', 'songTime',
  ];
  for (final k in keys) {
    final ms = _parseDurationValue(item[k]);
    if (ms > 0) return ms;
  }
  for (final nested in ['al', 'album', 'song', 'music', 'data']) {
    final v = item[nested];
    if (v is Map) {
      for (final k in keys) {
        final ms = _parseDurationValue(v[k]);
        if (ms > 0) return ms;
      }
    }
  }
  return 0;
}

/// MusicFree 条目 → 统一搜索结果（对齐桌面 toPluginSearchResult）。
PluginSearchResult mfItemToSearchResult(
    Map<String, dynamic> item, PluginSource source) {
  final id = (item['id'] ?? item['songId'] ?? item['musicId'] ?? '').toString();
  final durationMs = extractMfDurationMs(item);
  final interval = durationMs > 0
      ? '${(durationMs ~/ 60000).toString().padLeft(2, '0')}:'
          '${((durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}'
      : '';
  return PluginSearchResult(
    name: _stripHtml(item['title'] ?? item['name'] ?? item['songname'] ?? ''),
    singer: _extractArtistText(item),
    albumName: _extractAlbumText(item),
    songmid: id,
    source: item['platform'] is String ? item['platform'] as String : source.name,
    interval: interval,
    img: _extractCover(item),
    songId: item['id'],
    rawData: Map<String, dynamic>.from(item),
  );
}

/// "mm:ss" → 毫秒。
int _parseIntervalMs(String interval) {
  final m = RegExp(r'^(\d+):(\d+)$').firstMatch(interval.trim());
  if (m == null) return 0;
  return (int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)) * 1000;
}
