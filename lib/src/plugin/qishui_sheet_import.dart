import 'dart:convert';
import 'dart:io';

import '../core/application_logger.dart';
import 'kg_sheet_import.dart' show HostSheetImportResult;

/// 宿主侧汽水音乐歌单导入兜底。
///
/// 链路与公开 qishui 插件（BakaMusic 生态 qishui.js）逐点对齐：
/// ID 提取（纯数字/URL 参数/douyin 短链 302）→ PC API 游标分页
/// （api.qishui.com/luna/pc/playlist/detail）→ web 分享页兜底
/// （music.douyin.com/qishui/share/playlist 的 _ROUTER_DATA）。
/// 曲目条目结构与插件 importMusicSheet 输出一致，播放链路零差异。
class QishuiSheetImport {
  QishuiSheetImport._();

  static const _pcBase = 'https://api.qishui.com/luna/pc';
  static const _pcQuery =
      'aid=386088&app_name=luna_pc&region=cn&geo_region=cn&os_region=cn'
      '&sim_region=&device_id=2081836196178571&cdid=&iid=2081836196182667'
      '&version_name=3.8.0&version_code=30080000&channel=official'
      '&build_mode=master&network_carrier=&ac=wifi&tz_name=Asia/Shanghai'
      '&resolution=&device_platform=windows&device_type=Windows'
      '&os_version=Windows%2011%20Pro%20for%20Workstations'
      '&fp=2081836196178571';
  static const _pcHeaders = <String, String>{
    'Accept': '*/*',
    'Content-Type': 'application/json; charset=utf-8',
    'Accept-Encoding': 'gzip, deflate',
    'User-Agent': 'LunaPC/3.8.0(467160162)',
    'x-luna-background-type': 'foreground',
    'x-luna-is-background-req': '0',
    'x-luna-is-local-user': '0',
  };
  static const _webShareUrl =
      'https://music.douyin.com/qishui/share/playlist';
  static const _webShareHeaders = <String, String>{
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'User-Agent': 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
  };
  static const _douyinImageBase = 'https://p3-luna.douyinpic.com/img/';

  static const _qualityToBaka = <String, String>{
    'medium': '128k',
    'higher': '192k',
    'highest': '320k',
    'lossless': 'flac',
    'hi_res': 'hires',
    'spatial': 'atmos',
  };
  static const _fallbackBitrate = <String, int>{
    'medium': 128000,
    'higher': 192000,
    'highest': 320000,
    'lossless': 1411000,
    'hi_res': 2304000,
    'spatial': 324000,
  };

  /// 关键词是否汽水特征（链接域/关键词）
  static bool isQishuiKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('qishui') ||
        keyword.contains('汽水') ||
        t.contains('douyin.com');
  }

  /// 插件是否汽水系（纯数字歌单 ID 导入需要来源限定）
  static bool isQishuiSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('汽水') || n.contains('qishui')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'qishui' || t.contains('汽水') || t.contains('qishui')) {
        return true;
      }
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) async {
    if (keyword.trim().isEmpty) return null;
    try {
      final id = await _extractQishuiId(keyword);
      if (id == null || id.isEmpty) {
        AppLog.warn('plugin', '[qs-import] 未能从输入提取歌单 ID');
        return null;
      }
      final detail = await _fetchPlaylistDetail(id);
      if (detail == null || detail.mediaResources.isEmpty) {
        AppLog.warn('plugin', '[qs-import] 歌单详情获取失败 id=$id');
        return null;
      }
      final tracks = <Map<String, dynamic>>[];
      for (final raw in detail.mediaResources) {
        final t = _formatTrack(raw);
        if (t != null) tracks.add(t);
      }
      if (tracks.isEmpty) return null;
      final sheet = _parsePlaylistItem(detail.playlistInfo);
      return HostSheetImportResult(
        tracks: tracks,
        name: sheet['title'] as String,
        cover: sheet['artwork'] as String,
        author: sheet['artist'] as String,
        desc: sheet['description'] as String,
      );
    } catch (e) {
      AppLog.warn('plugin', '[qs-import] 汽水歌单导入失败: $e');
    }
    return null;
  }

  // ==================== ID 提取（抄 extractQishuiId） ====================

  static Future<String?> _extractQishuiId(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final plainId = RegExp(r'^(\d+)$').firstMatch(trimmed)?.group(1);
    if (plainId != null) return plainId;

    final directId = _extractIdFromUrl(trimmed);
    if (directId != null) return directId;

    final longId = RegExp(r'\b\d{10,}\b').firstMatch(trimmed)?.group(0);
    if (longId != null) return longId;

    final urls = RegExp(r'https?://[^\s@]+').allMatches(trimmed);
    for (final m in urls) {
      final url = m.group(0)!;
      final urlId = _extractIdFromUrl(url);
      if (urlId != null) return urlId;
      final lower = url.toLowerCase();
      if (lower.contains('douyin.com/s/') || lower.contains('qishui.douyin.com')) {
        final redirectedId = await _resolveRedirectId(url);
        if (redirectedId != null) return redirectedId;
      }
    }
    return null;
  }

  static String? _extractIdFromUrl(String url) {
    var m = RegExp(r'playlist/([\d]+)').firstMatch(url)?.group(1);
    if (m != null) return m;
    m = RegExp(r'[?&]playlist_id=([\d]+)').firstMatch(url)?.group(1);
    if (m != null) return m;
    m = RegExp(r'[?&]ugc_video_id=([\d]+)').firstMatch(url)?.group(1);
    if (m != null) return m;
    m = RegExp(r'[?&]id=([\d]+)').firstMatch(url)?.group(1);
    if (m != null) return m;
    return null;
  }

  /// 短链 302 解析：关闭自动跟随读 location，仍为短链则递归；
  /// 无重定向直出落地页时从内容提取
  static Future<String?> _resolveRedirectId(String url) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..autoUncompress = true;
      try {
        final req = await client
            .getUrl(Uri.parse(url.trim()))
            .timeout(const Duration(seconds: 15));
        // Dart HttpClient 默认 followRedirects=true，会自动跟到落地页
        // （200、无 location），必须显式关闭
        req.followRedirects = false;
        _webShareHeaders.forEach((k, v) => req.headers.set(k, v));
        final resp = await req.close().timeout(const Duration(seconds: 18));
        final location = resp.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) {
          // 未重定向直出落地页：从内容提取歌单 ID
          final body = await resp.transform(utf8.decoder).join();
          return _extractIdFromText(body);
        }
        final id = _extractIdFromUrl(location);
        if (id != null) return id;
        final lower = location.toLowerCase();
        if (lower.contains('douyin.com/s/') || lower.contains('qishui.douyin.com')) {
          return await _resolveRedirectId(location);
        }
        return null;
      } finally {
        client.close();
      }
    } catch (e) {
      AppLog.warn('plugin', '[qs-import] 短链解析失败: $e');
      return null;
    }
  }

  static String? _extractIdFromText(String body) {
    if (body.isEmpty) return null;
    var m = RegExp(r'playlist/([\d]+)').firstMatch(body)?.group(1);
    if (m != null) return m;
    m = RegExp(r'[?&]playlist_id=([\d]+)').firstMatch(body)?.group(1);
    if (m != null) return m;
    m = RegExp(r'[?&]id=([\d]+)').firstMatch(body)?.group(1);
    if (m != null) return m;
    return null;
  }

  // ==================== 歌单详情（PC API → web 兜底） ====================

  static Future<_QsPlaylistDetail?> _fetchPlaylistDetail(String id) async {
    final apiDetail = await _fetchFromApi(id);
    if (apiDetail != null && apiDetail.mediaResources.isNotEmpty) return apiDetail;

    final webDetail = await _fetchFromWeb(id);
    if (webDetail != null && webDetail.mediaResources.isNotEmpty) {
      final info = webDetail.playlistInfo;
      final infoId = info?['id']?.toString() ?? '';
      if (infoId == id) return webDetail;
    }
    return null;
  }

  static Future<_QsPlaylistDetail?> _fetchFromApi(String id) async {
    var cursor = '';
    Map<String, dynamic>? playlistInfo;
    final resources = <Map<String, dynamic>>[];
    final seenCursors = <String>{};
    for (var page = 0; page < 10000; page++) {
      final data = await _httpJson(
        'GET',
        '$_pcBase/playlist/detail?$_pcQuery&playlist_id=$id'
        '&cursor=${Uri.encodeComponent(cursor)}&count=100',
        headers: _pcHeaders,
      );
      if (data is! Map) {
        if (page == 0) return null;
        throw Exception('[汽水音乐] 歌单分页数据异常');
      }
      if (data['media_resources'] is! List) {
        if (page == 0) return null;
        throw Exception('[汽水音乐] 歌单分页数据异常');
      }
      if (playlistInfo == null && data['playlist'] is Map) {
        playlistInfo = (data['playlist'] as Map).cast<String, dynamic>();
      }
      for (final item in data['media_resources'] as List) {
        if (item is Map) resources.add(item.cast<String, dynamic>());
      }
      final hasMore = data['has_more'] == true ||
          data['has_more'] == 1 ||
          data['has_more'] == '1';
      if (!hasMore) {
        return _QsPlaylistDetail(playlistInfo: playlistInfo, mediaResources: resources);
      }
      final next = data['next_cursor']?.toString() ?? '';
      if (resources.isEmpty || next.isEmpty || next == cursor || seenCursors.contains(next)) {
        throw Exception('[汽水音乐] 歌单分页游标未推进');
      }
      seenCursors.add(next);
      cursor = next;
    }
    return null;
  }

  static Future<_QsPlaylistDetail?> _fetchFromWeb(String id) async {
    try {
      final html = await _httpText(
        'GET',
        '$_webShareUrl?playlist_id=$id',
        headers: _webShareHeaders,
      );
      if (html == null || html.isEmpty) return null;
      final routerData = _extractRouterData(html);
      if (routerData == null) return null;
      final loaderData = routerData['loaderData'];
      final playlistPage =
          loaderData is Map ? loaderData['playlist_page'] : null;
      if (playlistPage is! Map) return null;
      final info = playlistPage['playlistInfo'];
      final medias = playlistPage['medias'];
      return _QsPlaylistDetail(
        playlistInfo: info is Map ? info.cast<String, dynamic>() : null,
        mediaResources: medias is List
            ? medias.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
            : <Map<String, dynamic>>[],
      );
    } catch (e) {
      AppLog.warn('plugin', '[qs-import] web 分享页解析失败: $e');
      return null;
    }
  }

  static Map<String, dynamic>? _extractRouterData(String html) {
    const assignment = '_ROUTER_DATA = ';
    final start = html.indexOf(assignment);
    if (start == -1) return null;
    final jsonStart = start + assignment.length;
    var jsonEnd = html.indexOf(';\nfunction runWindowFn', jsonStart);
    if (jsonEnd == -1) {
      jsonEnd = html.indexOf(';</script>', jsonStart);
    }
    if (jsonEnd == -1) return null;
    try {
      final decoded = jsonDecode(html.substring(jsonStart, jsonEnd));
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  // ==================== 条目格式化（抄 parseTrackItem） ====================

  static Map<String, dynamic>? _normalizeTrack(Map raw) {
    final entity = raw['entity'];
    if (entity is Map) {
      final tw = entity['track_wrapper'];
      if (tw is Map && tw['track'] is Map) {
        return (tw['track'] as Map).cast<String, dynamic>();
      }
      if (entity['track'] is Map) return (entity['track'] as Map).cast<String, dynamic>();
      if (entity['video'] is Map) return (entity['video'] as Map).cast<String, dynamic>();
      if (entity['ugc_video'] is Map) {
        return (entity['ugc_video'] as Map).cast<String, dynamic>();
      }
    }
    if (raw['track'] is Map) return (raw['track'] as Map).cast<String, dynamic>();
    return raw.cast<String, dynamic>();
  }

  static Map<String, dynamic>? _formatTrack(Map<String, dynamic> raw) {
    final track = _normalizeTrack(raw);
    if (track == null) return null;
    final isVideo = _isVideoTrack(raw, track);
    final album = track['album'] is Map ? track['album'] as Map : null;
    final videoId = _firstText(track['video_id'], track['ugc_video_id'],
        track['id'], track['vid']);
    final artwork = _firstNotEmpty([
      _buildImageUrlFromCover(album?['url_cover']),
      _buildImageUrlFromCover(track['cover_url']),
      _firstUrlList(track['image_url']),
      _firstUrlList(track['share_cover_url']),
      track['coverURL']?.toString(),
      track['firstFrameURL']?.toString(),
    ]);
    final artistEntries = _asMapList(track['artists']);
    if (artistEntries.isEmpty && track['author_info'] is Map) {
      artistEntries.add((track['author_info'] as Map).cast<String, dynamic>());
    }
    final singerList = _buildSingerList(artistEntries);
    final primary = singerList.isNotEmpty ? singerList.first : null;
    final labelInfo = track['label_info'] is Map ? track['label_info'] as Map : null;
    final fee = labelInfo?['only_vip_playable'] == true ? 1 : 0;
    final id = track['id']?.toString() ?? '';
    final title = _firstNotEmpty([
      track['name']?.toString(),
      track['title']?.toString(),
      track['videoName']?.toString(),
      track['desc']?.toString(),
      '',
    ]);
    final artist = _firstNotEmpty([
      primary?['name']?.toString(),
      track['artistName']?.toString(),
      track['author']?.toString(),
      '',
    ]);

    return {
      'id': id.isNotEmpty ? id : videoId,
      'title': title,
      'artist': artist,
      'singerList': singerList,
      'album': album?['name']?.toString() ?? '',
      'albumId': album?['id']?.toString() ?? '',
      'artwork': artwork,
      'duration': _normalizeDurationSeconds(track['duration'] ?? track['duration_ms']),
      'qualities': _qualitiesFromBitRates(track['bit_rates']),
      'fee': fee,
      'is_video': isVideo ? true : null,
      'videoId': isVideo ? videoId : null,
      'vid': isVideo ? videoId : _firstText(track['vid'], track['video_id']),
      // 宿主补充键：兼容 mfItemToSearchResult 与 LX 播放链
      'songmid': id.isNotEmpty ? id : videoId,
      'name': title,
      'singer': artist,
      'source': 'qishui',
    };
  }

  static bool _isVideoTrack(Map raw, Map track) {
    final entity = raw['entity'];
    if (entity is Map && (entity['video'] is Map || entity['ugc_video'] is Map)) {
      return true;
    }
    if (raw['type'] == 'video' || raw['media_type'] == 'video') return true;
    if (track['video_id'] != null || track['ugc_video_id'] != null) return true;
    if (track['type'] == 'ugc_video' || track['video_type'] == 'ugc_video') {
      return true;
    }
    if (track['media_type'] == 'ugc_video') return true;
    if (track['videoName'] != null) return true;
    return false;
  }

  static List<Map<String, dynamic>> _buildSingerList(
      List<Map<String, dynamic>> artists) {
    final out = <Map<String, dynamic>>[];
    for (final artist in artists) {
      final userInfo = artist['user_info'] is Map
          ? artist['user_info'] as Map
          : (artist['author_info'] is Map ? artist['author_info'] as Map : artist);
      final avatar = _firstNotEmpty([
        userInfo['avatar']?.toString(),
        _buildImageUrlFromCover(userInfo['url_avatar'], '100:100'),
        _buildImageUrlFromCover(userInfo['medium_avatar_url'], '100:100'),
        _buildImageUrlFromCover(userInfo['thumb_avatar_url'], '100:100'),
        '',
      ]);
      final id = userInfo['id']?.toString() ?? artist['id']?.toString() ?? '';
      final name = _firstNotEmpty([
        userInfo['name']?.toString(),
        userInfo['nickname']?.toString(),
        artist['name']?.toString(),
        '',
      ]);
      if (id.isNotEmpty || name.isNotEmpty) {
        out.add({'id': id, 'name': name, 'avatar': avatar});
      }
    }
    return out;
  }

  static Map<String, dynamic> _qualitiesFromBitRates(Object? bitRatesRaw) {
    final qualities = <String, dynamic>{};
    final spatialEntries = <Map<String, dynamic>>[];
    for (final item in _asMapList(bitRatesRaw)) {
      final qishuiQuality = item['quality']?.toString() ?? '';
      final bitrate = _asInt(item['br']) ?? _fallbackBitrate[qishuiQuality];
      if (qishuiQuality == 'spatial') {
        spatialEntries.add({
          'size': item['size'],
          'bitrate': bitrate,
          'qishuiQuality': qishuiQuality,
        });
        continue;
      }
      final qualityKey = _qualityToBaka[qishuiQuality];
      if (qualityKey == null) continue;
      if (!qualities.containsKey(qualityKey)) {
        qualities[qualityKey] = {
          'size': item['size'],
          'bitrate': bitrate,
          'qishuiQuality': qishuiQuality,
        };
      }
    }
    // spatial（全景声）在导入场景取首个条目映射为 atmos
    if (spatialEntries.isNotEmpty && !qualities.containsKey('atmos')) {
      qualities['atmos'] = spatialEntries.first;
    }
    return qualities;
  }

  // ==================== 歌单信息（抄 parsePlaylistItem） ====================

  static Map<String, dynamic> _parsePlaylistItem(Map<String, dynamic>? raw) {
    if (raw == null) {
      return const {
        'title': '',
        'artist': '',
        'artwork': '',
        'description': '',
      };
    }
    final owner = raw['owner'] is Map ? raw['owner'] as Map : null;
    final userBrief = raw['user_artist_info'] is Map
        ? ((raw['user_artist_info'] as Map)['user_brief'] as Map?)
        : null;
    final worksNum = _asInt(raw['count_tracks']) ??
        (() {
          final cnt = raw['resource_cnt'];
          if (cnt is Map) return _asInt(cnt['track_cnt']);
          return null;
        }()) ??
        0;
    return {
      'title': _firstNotEmpty([
        raw['title']?.toString(),
        raw['public_title']?.toString(),
        raw['name']?.toString(),
        '',
      ]),
      'artist': _firstNotEmpty([
        owner?['nickname']?.toString(),
        userBrief?['nickname']?.toString(),
        '',
      ]),
      'artwork': _buildImageUrlFromCover(raw['url_cover']),
      'description': raw['desc']?.toString() ?? '',
      'worksNum': worksNum,
    };
  }

  // ==================== 工具 ====================

  static String _buildImageUrlFromCover(Object? urlCover,
      [String size = '960:960']) {
    if (urlCover == null) return '';
    if (urlCover is String) return urlCover;
    if (urlCover is! Map) return '';
    final uri = urlCover['uri']?.toString() ?? '';
    final templatePrefix = urlCover['template_prefix']?.toString() ?? '';
    if (uri.isNotEmpty && templatePrefix.isNotEmpty) {
      return '$_douyinImageBase$uri~$templatePrefix-resize:$size.png';
    }
    if (urlCover['urls'] is List) {
      final urls = (urlCover['urls'] as List)
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      if (urls.isNotEmpty) {
        if (uri.isEmpty || urls.first.contains(uri)) return urls.first;
        return '${urls.first}$uri';
      }
    }
    return '';
  }

  static String _firstUrlList(Object? cover) {
    if (cover is Map && cover['urls'] is List) {
      for (final u in cover['urls'] as List) {
        final s = u?.toString() ?? '';
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }

  static String _firstText(Object? a, Object? b, [Object? c, Object? d]) {
    for (final v in [a, b, c, d]) {
      final s = v?.toString() ?? '';
      if (s.isNotEmpty && s != 'null') return s;
    }
    return '';
  }

  static String _firstNotEmpty(List<String?> candidates) {
    for (final c in candidates) {
      if (c != null && c.isNotEmpty) return c;
    }
    return '';
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  static int? _normalizeDurationSeconds(Object? duration) {
    final n = _asInt(duration);
    if (n == null || n <= 0) return null;
    return n > 10000 ? n ~/ 1000 : n;
  }

  static List<Map<String, dynamic>> _asMapList(Object? v) {
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  static Future<String?> _httpText(
    String method,
    String url, {
    Map<String, String>? headers,
    String? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      HttpClientRequest req;
      if (method == 'POST') {
        req = await client.postUrl(Uri.parse(url));
      } else {
        req = await client.getUrl(Uri.parse(url));
      }
      headers?.forEach((k, v) => req.headers.set(k, v));
      if (body != null) req.write(body);
      final resp = await req.close().timeout(const Duration(seconds: 18));
      if (resp.statusCode < 200 || resp.statusCode >= 500) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      AppLog.warn('plugin', '[qs-import] http $method 失败: $e');
      return null;
    } finally {
      client.close();
    }
  }

  static Future<Object?> _httpJson(
    String method,
    String url, {
    Map<String, String>? headers,
    String? body,
  }) async {
    final text = await _httpText(method, url, headers: headers, body: body);
    if (text == null || text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      final s = text.indexOf('{');
      final e = text.lastIndexOf('}');
      if (s >= 0 && e > s) {
        try {
          return jsonDecode(text.substring(s, e + 1));
        } catch (_) {}
      }
      return null;
    }
  }
}

class _QsPlaylistDetail {
  final Map<String, dynamic>? playlistInfo;
  final List<Map<String, dynamic>> mediaResources;

  const _QsPlaylistDetail({
    required this.playlistInfo,
    required this.mediaResources,
  });
}
