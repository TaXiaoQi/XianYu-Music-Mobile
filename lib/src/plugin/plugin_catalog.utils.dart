part of 'plugin_catalog.dart';

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

String? _extractAlbumId(Map<String, dynamic> item) {
  for (final key in ['albumId', 'album_id', 'al', 'album']) {
    final v = item[key];
    if (v is String) {
      final t = v.trim();
      if (t.isNotEmpty) return t;
    } else if (v is num && v != 0) {
      return v.toInt().toString();
    } else if (v is Map) {
      final id = v['id'];
      if (id is String && id.trim().isNotEmpty) return id.trim();
      if (id is num && id != 0) return id.toInt().toString();
    }
  }
  return null;
}

String _encryptNeteasePicId(String id) {
  const magic = '3go8&\$8*3*3h0k(2)2';
  final m = magic.codeUnits;
  final xored = List<int>.generate(
      id.length, (i) => id.codeUnitAt(i) ^ m[i % m.length]);
  final digest = md5.convert(xored);
  return base64.encode(digest.bytes).replaceAll('/', '_').replaceAll('+', '-');
}

String? _neteaseCoverUrlFromPicId(dynamic picId) {
  String? id;
  if (picId is String) {
    final t = picId.trim();
    if (t.isNotEmpty && t != '0' && RegExp(r'^\d+$').hasMatch(t)) id = t;
  } else if (picId is int && picId != 0 && picId < 9007199254740992) {
    id = picId.toString();
  }
  if (id == null) return null;
  return 'https://p1.music.126.net/${_encryptNeteasePicId(id)}/$id.jpg';
}

String? _neteaseCoverUrl(Map<String, dynamic> node) {
  final al = node['al'] is Map ? node['al'] as Map : null;
  final album = node['album'] is Map ? node['album'] as Map : null;
  final candidates = <dynamic>[
    if (al != null) ...[al['picId_str'], al['pic_str'], al['picId'], al['pic']],
    if (album != null)
      ...[album['picId_str'], album['pic_str'], album['picId'], album['pic']],
    node['picId_str'],
    node['pic_str'],
    node['picId'],
    node['pic'],
  ];
  for (final c in candidates) {
    final url = _neteaseCoverUrlFromPicId(c);
    if (url != null) return url;
  }
  return null;
}

String _normalizeKuwoCoverUrl(String url) {
  var out = url.trim().replaceFirst(RegExp(r'^http://'), 'https://');
  if (RegExp(r'^https://zimg\.kuwo\.cn/', caseSensitive: false).hasMatch(out)) {
    return out;
  }
  return out.replaceFirstMapped(
    RegExp(r'^https://[^/]+\.kuwo\.cn/(.+)$', caseSensitive: false),
    (m) => 'https://img3.kuwo.cn/${m.group(1)}',
  );
}

String? _buildKuwoShortCover(dynamic shortPath) {
  if (shortPath is! String || shortPath.trim().isEmpty) return null;
  var short = shortPath.trim().replaceFirst(RegExp(r'^/+'), '');
  if (short.isEmpty || !short.contains('/')) return null;
  short = short.replaceFirstMapped(RegExp(r'^\d+/'), (m) => '500/');
  return 'https://img3.kuwo.cn/star/albumcover/$short';
}

bool _looksLikeCoverUrl(dynamic v) {
  if (v is! String) return false;
  final s = v.trim();
  return s.startsWith('http') || s.startsWith('//');
}

String? _extractCoverFromNode(Map<String, dynamic> node) {
  final raw = (node['rawData'] is Map
          ? node['rawData'] as Map
          : node['raw'] is Map
              ? node['raw'] as Map
              : null) ??
      node;
  final direct = [
    'artwork', 'cover', 'coverImg', 'coverUrl', 'cover_url', 'pic',
    'picurl', 'img', 'imgurl', 'imgUrl', 'albumPic', 'picture',
  ];
  for (final k in direct) {
    final v = node[k];
    if (_looksLikeCoverUrl(v)) return v;
    final rv = raw[k];
    if (_looksLikeCoverUrl(rv)) return rv;
  }
  const kwShortKeys = [
    'web_albumpic_short', 'web_album_pic', 'album_pic',
    'albumpic_short', 'albumpic',
  ];
  for (final k in kwShortKeys) {
    final built = _buildKuwoShortCover(node[k]) ?? _buildKuwoShortCover(raw[k]);
    if (built != null) return built;
  }
  for (final key in ['al', 'album']) {
    for (final src in [node[key], raw[key]]) {
      if (src is! Map) continue;
      for (final kk in ['picUrl', 'blurPicUrl']) {
        final u = src[kk];
        if (_looksLikeCoverUrl(u)) return u;
      }
    }
  }
  for (final k in ['picUrl', 'coverImgUrl']) {
    final v = node[k];
    if (_looksLikeCoverUrl(v)) return v;
    final rv = raw[k];
    if (_looksLikeCoverUrl(rv)) return rv;
  }
  final ne = _neteaseCoverUrl(node);
  if (ne != null) return ne;
  if (raw != node) {
    final re = _neteaseCoverUrl(Map<String, dynamic>.from(raw));
    if (re != null) return re;
  }
  return null;
}

String? _extractCover(Map<String, dynamic> item) {
  const nestedKeys = ['song', 'data', 'music', 'musicInfo', 'detail'];
  var url = _extractCoverFromNode(item);
  for (final k in nestedKeys) {
    if (url != null) break;
    final v = item[k];
    if (v is Map) {
      url = _extractCoverFromNode(Map<String, dynamic>.from(v));
    }
  }
  final raw = item['rawData'];
  if (url == null && raw is Map) {
    for (final k in nestedKeys) {
      final v = raw[k];
      if (v is Map) {
        url = _extractCoverFromNode(Map<String, dynamic>.from(v));
        if (url != null) break;
      }
    }
  }
  if (url == null) return null;
  var out = url;
  if (out.startsWith('//')) out = 'https:$out';
  if (out.startsWith('http://')) out = out.replaceFirst('http://', 'https://');
  if (out.contains('kuwo.cn')) out = _normalizeKuwoCoverUrl(out);
  return out;
}

String? resolveSongCoverUrl(Map<String, dynamic> item) => _extractCover(item);

String? _extractAvatar(Map<String, dynamic> item) {
  const candidates = [
    'avatarUrl', 'avatar', 'avatar_url', 'picUrl', 'pic_url', 'pic',
    'img1v1Url', 'headUrl', 'face', 'artistPic', 'coverUrl', 'img',
  ];
  for (final k in candidates) {
    final v = item[k];
    if (_looksLikeCoverUrl(v)) return v;
  }
  return _extractCover(item);
}

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
    albumId: _extractAlbumId(item),
    songmid: id,
    source: item['platform'] is String ? item['platform'] as String : source.name,
    interval: interval,
    img: _extractCover(item),
    songId: item['id'],
    rawData: Map<String, dynamic>.from(item),
  );
}

int _parseIntervalMs(String interval) {
  final m = RegExp(r'^(\d+):(\d+)$').firstMatch(interval.trim());
  if (m == null) return 0;
  return (int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)) * 1000;
}

String? lxPlatformCodeOf(PluginSource source) {
  final srcs = source.sources.map((s) => s.trim().toLowerCase()).toSet();
  final name = source.name.toLowerCase();
  if (srcs.contains('kw') || name.contains('kuwo') || name.contains('酷我')) {
    return 'kw';
  }
  if (srcs.contains('kg') || name.contains('kugou') || name.contains('酷狗')) {
    return 'kg';
  }
  if (srcs.contains('tx') ||
      srcs.contains('qq') ||
      name.contains('qq') ||
      name.contains('企鹅')) {
    return 'tx';
  }
  if (srcs.contains('wy') || name.contains('netease') || name.contains('网易')) {
    return 'wy';
  }
  if (srcs.contains('mg') || name.contains('migu') || name.contains('咪咕')) {
    return 'mg';
  }
  return null;
}

String? _decodeLxCoverResult(String raw) {
  if (raw.isEmpty || raw == 'null') return null;
  try {
    final v = jsonDecode(raw);
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {
  }
  if (raw.startsWith('http')) return raw;
  return null;
}

Future<String?> fetchLxCoverForSong(
    PluginSource source, PluginSearchResult r) async {
  var platform = r.source.trim().toLowerCase();
  if (!const {'kw', 'kg', 'tx', 'wy', 'mg'}.contains(platform)) {
    platform = lxPlatformCodeOf(source) ?? '';
  }
  if (platform.isEmpty || r.songmid.isEmpty) return null;
  final rid =
      r.songmid.replaceFirst(RegExp(r'^MUSIC_', caseSensitive: false), '');
  if (rid.isEmpty) return null;
  try {
    final raw = await getLxCover(songInfoJson: jsonEncode({
      'songmid': rid,
      'source': platform,
      'name': r.name,
      'singer': r.singer,
      'albumName': r.albumName,
      'albumId': r.albumId,
      'albumMid': r.albumMid,
      'hash': r.hash,
      'strMediaMid': r.strMediaMid,
      'songId': r.songId,
      '_types': r.lxTypes,
    }));
    final cover = _decodeLxCoverResult(raw);
    if (cover == null || cover.isEmpty) return null;
    var out = cover;
    if (out.startsWith('//')) out = 'https:$out';
    if (out.startsWith('http://')) {
      out = out.replaceFirst('http://', 'https://');
    }
    if (out.contains('kuwo.cn')) out = _normalizeKuwoCoverUrl(out);
    return out;
  } catch (_) {
    return null;
  }
}
