import 'dart:convert';
import 'dart:io';

import '../core/application_logger.dart';
import '../rust/api.dart';

/// 宿主侧酷狗歌单导入兜底。
///
/// 链路与公开 kg 插件（BakaMusic 生态 kg.js）逐点对齐：
/// 数字酷狗码 → t.kugou.com/command 反查（gcid 或直出歌单）；
/// gcid_ 分享链接 → batch_decode 解码；
/// global_collection_id → gateway 分页（get_other_list_file_nofilt，
/// android 签名）；老歌单走 get_res_privilege/lite 详情批。
/// 曲目条目结构与插件 importMusicSheet 输出一致，播放链路零差异。
class KgSheetImport {
  KgSheetImport._();

  static const _gatewayPageHeaders = <String, String>{
    'User-Agent': 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
    'kg-rc': '1',
    'kg-thash': '5d816a0',
    'kg-rec': '1',
    'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
  };

  static const _privilegeUrl =
      'https://gateway.kugou.com/v2/get_res_privilege/lite?appid=1001&clienttime=1668883879&clientver=10112&dfid=2O3jKa20Gdks0LWojP3ly7ck&mid=70a02aad1ce4648e7dca77f2afa7b182&userid=390523108&uuid=92691C6246F86F28B149BAA1FD370DF1';

  /// 关键词是否酷狗特征（链接/gcid/global_collection_id）
  static bool isKgKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('kugou.com') ||
        t.contains('gcid_') ||
        t.contains('global_collection_id');
  }

  /// 插件是否酷狗系（数字酷狗码导入需要来源限定，避免误伤网易/QQ 数字 ID）
  static bool isKgSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('酷狗') || n.contains('kugou')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'kg' || t == 'kugou' || t.contains('酷狗')) return true;
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) async {
    final t = keyword.trim();
    if (t.isEmpty) return null;
    try {
      // 1. gcid_ 分享链接（编码 gcid，需 batch_decode）
      final gcidMatch = RegExp(r'gcid_(\w+)').firstMatch(t);
      if (gcidMatch != null) {
        final gcol = await _decodeGcid('gcid_${gcidMatch.group(1)}');
        if (gcol != null && gcol.isNotEmpty) {
          return await _importByGcid(gcol);
        }
        return null;
      }
      // 2. 明文 global_collection_id
      final gcolMatch =
          RegExp(r'global_collection_id[=:]\s*"?(\w+)"?').firstMatch(t);
      if (gcolMatch != null) {
        return await _importByGcid(gcolMatch.group(1)!);
      }
      // 3. 分享短链/网页链接 → 解析 gcid 或数字码
      final lower = t.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        return await _importFromUrl(t);
      }
      // 4. 纯数字酷狗码 → command 反查
      if (RegExp(r'^\d{1,32}$').hasMatch(t)) {
        return await _importByCode(t);
      }
    } catch (e) {
      AppLog.warn('plugin', '[kg-import] 酷狗歌单导入失败: $e');
    }
    return null;
  }

  // ==================== 数字酷狗码 → command 反查 ====================

  static Future<HostSheetImportResult?> _importByCode(String code) async {
    final body = await _httpJson('POST', 'http://t.kugou.com/command/',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'appid': 1001,
          'clientver': 9020,
          'mid': '21511157a05844bd085308bc76ef3343',
          'clienttime': 640612895,
          'key': '36164c4015e704673c588ee202b9ecb8',
          'data': code,
        }));
    if (body is! Map) return null;
    if (_statusCode(body) != 1) return null;
    final data = body['data'];
    if (data is! Map) return null;
    final info = data['info'];
    if (info is! Map) return null;
    final name = _decodeName(info['name']?.toString() ?? '');
    final gcol = info['global_collection_id']?.toString() ?? '';
    if (gcol.isNotEmpty) {
      final result = await _importByGcid(gcol);
      if (result != null && result.name.isEmpty) {
        return HostSheetImportResult(
          tracks: result.tracks,
          name: name,
          cover: result.cover,
          author: result.author,
          desc: result.desc,
        );
      }
      return result;
    }
    // 老歌单：command 直出歌曲列表
    final list = _asList(data['list']);
    if (list.isEmpty) return null;
    final tracks = await _importFromPlainList(list);
    if (tracks.isEmpty) return null;
    return HostSheetImportResult(
      tracks: tracks,
      name: name,
      cover: '',
      author: '',
      desc: '',
    );
  }

  /// 老歌单：get_res_privilege/lite 详情批（抄插件 list 直取分支）
  static Future<List<Map<String, dynamic>>> _importFromPlainList(
      List list) async {
    final resource = <Map<String, dynamic>>[];
    for (final song in list) {
      if (song is! Map) continue;
      final hash = song['hash']?.toString() ?? '';
      if (hash.isEmpty) continue;
      final filename = song['filename']?.toString() ?? '';
      resource.add({
        'album_audio_id': 0,
        'album_id': '0',
        'hash': hash,
        'id': 0,
        'name': filename.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), ''),
        'page_id': 0,
        'type': 'audio',
      });
    }
    final details = await _fetchResPrivileges(resource);
    final tracks = <Map<String, dynamic>>[];
    for (final item in details) {
      final t = _formatPlainItem(item);
      if (t != null) tracks.add(t);
    }
    return tracks;
  }

  static Future<List<Map<String, dynamic>>> _fetchResPrivileges(
      List<Map<String, dynamic>> resource) async {
    const batchSize = 200;
    final batches = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < resource.length; i += batchSize) {
      batches.add(resource.sublist(
          i, i + batchSize > resource.length ? resource.length : i + batchSize));
    }
    final results = await Future.wait(batches.map((batch) async {
      try {
        final body = await _httpJson(
          'POST',
          _privilegeUrl,
          headers: {
            'x-router': 'media.store.kugou.com',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'appid': 1001,
            'area_code': '1',
            'behavior': 'play',
            'clientver': '10112',
            'dfid': '2O3jKa20Gdks0LWojP3ly7ck',
            'mid': '70a02aad1ce4648e7dca77f2afa7b182',
            'need_hash_offset': 1,
            'relate': 1,
            'resource': batch,
            'token': '',
            'userid': '0',
            'vip': 0,
          }),
        );
        if (body is! Map || _statusCode(body) != 1) return const <Map>[];
        return _asList(body['data']).whereType<Map>().toList();
      } catch (e) {
        AppLog.warn('plugin', '[kg-import] 歌曲详情批次失败: $e');
        return const <Map>[];
      }
    }));
    return results.expand((e) => e).map((e) => e.cast<String, dynamic>()).toList();
  }

  // ==================== global_collection_id 分页导入 ====================

  static Future<HostSheetImportResult?> _importByGcid(String gcol) async {
    if (gcol.length > 1000) return null;
    final songs = <Map<String, dynamic>>[];
    final seen = <String>{};
    var beginIdx = 0;
    var totalCount = -1;
    var page = 0;
    String name = '';
    String cover = '';
    String author = '';

    while (totalCount < 0 || beginIdx < totalCount) {
      page += 1;
      if (page > 10000) return null; // 歌单分页超出合理范围
      final clienttimeSec =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      final params =
          'area_code=1&appid=1005&begin_idx=$beginIdx&clienttime=$clienttimeSec'
          '&clientver=20489&extend_fields=abtags,hot_cmt,popularization'
          '&global_collection_id=$gcol&mode=1&pagesize=300&personal_switch=1'
          '&plat=1&type=1&uuid=-';
      final signature = await hostKugouSign(params: params, platform: 'android');
      final body = await _httpJson(
        'GET',
        'https://gateway.kugou.com/pubsongs/v2/get_other_list_file_nofilt'
        '?$params&signature=$signature',
        headers: _gatewayPageHeaders,
      );
      if (body is! Map || _statusCode(body) != 1) return null;
      final data = body['data'];
      if (data is! Map) return null;
      final pageSongs = _asList(data['songs']);
      if (data['list_info'] is Map) {
        final li = data['list_info'] as Map;
        name = name.isEmpty ? _decodeName(li['name']?.toString() ?? '') : name;
        cover = cover.isEmpty
            ? (li['pic']?.toString() ?? '').replaceFirst('{size}', '400')
            : cover;
        author = author.isEmpty
            ? _decodeName(li['list_create_username']?.toString() ?? '')
            : author;
      }
      if (pageSongs.isEmpty) {
        if (totalCount > 0 && beginIdx < totalCount) return null; // 分页提前结束
        break;
      }
      final reported = (data['count'] as num?)?.toInt() ?? 0;
      if (reported > 0 && reported > totalCount) totalCount = reported;
      var added = 0;
      for (final song in pageSongs) {
        if (song is! Map) continue;
        final s = song.cast<String, dynamic>();
        final hash = s['hash']?.toString() ?? '';
        if (hash.isEmpty) continue;
        final key =
            '$hash|${s['audio_id'] ?? s['album_audio_id'] ?? 0}|${s['name'] ?? ''}';
        if (seen.contains(key)) continue;
        seen.add(key);
        songs.add(s);
        added++;
      }
      if (added <= 0) return null; // 分页重复
      beginIdx += pageSongs.length;
      if (totalCount < 0 && pageSongs.length < 300) break;
    }

    final tracks = <Map<String, dynamic>>[];
    for (final song in songs) {
      final t = _formatGatewayItem(song);
      if (t != null) tracks.add(t);
    }
    if (tracks.isEmpty) return null;
    return HostSheetImportResult(
      tracks: tracks,
      name: name,
      cover: cover,
      author: author,
      desc: '',
    );
  }

  // ==================== 分享链接解析 ====================

  static Future<HostSheetImportResult?> _importFromUrl(String url) async {
    try {
      final body = await _httpText('GET', url, headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1',
        'Referer': url,
      });
      if (body == null || body.isEmpty) return null;
      final gcolMatch =
          RegExp(r'''global_collection_id['"]?\s*[:=]\s*['"]?(\w+)''')
              .firstMatch(body);
      if (gcolMatch != null) return await _importByGcid(gcolMatch.group(1)!);
      final gcid = RegExp(r'"encode_gic"\s*:\s*"(\w+)"').firstMatch(body)?.group(1) ??
          RegExp(r'"encode_src_gid"\s*:\s*"(\w+)"').firstMatch(body)?.group(1) ??
          RegExp(r'''encode_gic['"]?\s*[:=]\s*['"]?(\w+)''').firstMatch(body)?.group(1) ??
          RegExp(r'''encode_src_gid['"]?\s*[:=]\s*['"]?(\w+)''').firstMatch(body)?.group(1);
      if (gcid != null) {
        final gcol = await _decodeGcid('gcid_$gcid');
        if (gcol != null && gcol.isNotEmpty) return await _importByGcid(gcol);
      }
      return null;
    } catch (e) {
      AppLog.warn('plugin', '[kg-import] resolveShareUrl 失败: $e');
      return null;
    }
  }

  static Future<String?> _decodeGcid(String gcid) async {
    const params =
        'dfid=-&appid=1005&mid=0&clientver=20109&clienttime=640612895&uuid=-';
    final bodyStr = '{"ret_info":1,"data":[{"id":"$gcid","id_type":2}]}';
    final signature =
        await hostKugouSign(params: params, platform: 'android', body: bodyStr);
    final url =
        'https://t.kugou.com/v1/songlist/batch_decode?$params&signature=$signature';
    final body = await _httpJson('POST', url,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 10; HUAWEI HMA-AL00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Mobile Safari/537.36',
          'Referer': 'https://m.kugou.com/',
          'Content-Type': 'application/json',
        },
        body: bodyStr);
    if (body is! Map) return null;
    var list = const <dynamic>[];
    final data = body['data'];
    if (data is Map) {
      list = _asList(data['list']);
      if (list.isEmpty) list = _asList(data['info']);
    }
    if (list.isEmpty) list = _asList(body['list']);
    if (list.isEmpty && body['info'] is Map) {
      list = _asList((body['info'] as Map)['list']);
    }
    if (list.isEmpty || list.first is! Map) return null;
    final first = list.first as Map;
    final gcol = first['global_collection_id']?.toString() ??
        first['global_specialid']?.toString() ??
        '';
    return gcol.isEmpty ? null : gcol;
  }

  // ==================== 曲目格式化（抄插件） ====================

  /// 抄 formatGatewayImportMusicItem：对象为分页 song 本体
  static Map<String, dynamic>? _formatGatewayItem(Map<String, dynamic> s) {
    final hash = s['hash']?.toString() ?? '';
    if (hash.isEmpty) return null;
    final name = s['name']?.toString() ?? '';
    var artist = s['singername']?.toString() ?? '';
    var title = name;
    if (name.contains(' - ')) {
      final parts = name.split(' - ');
      if (artist.isEmpty) artist = parts.first.trim();
      title = parts.skip(1).join(' - ').trim();
    }
    if (title.isEmpty) {
      final songname = s['songname']?.toString() ?? '';
      title = songname.isNotEmpty ? songname : name;
    }

    final trans = s['trans_param'] is Map ? s['trans_param'] as Map : null;
    final relate = (s['relate_goods'] is List
            ? (s['relate_goods'] as List).whereType<Map>().toList()
            : <Map>[])
        .cast<Map>();

    final audioId = _asInt(s['audio_id']) ?? _asInt(s['album_audio_id']) ?? 0;
    final timelen = _asInt(s['timelen']) ?? 0;
    var artwork = (trans?['union_cover'] ?? s['cover'])?.toString() ?? '';
    artwork = artwork.replaceFirst('{size}', '400');
    final ogg320 = trans?['ogg_320_hash']?.toString() ?? '';
    final hashMultitrack = trans?['hash_multitrack']?.toString() ?? '';

    final albumInfo =
        s['albuminfo'] is Map ? (s['albuminfo'] as Map)['name'] : null;

    return {
      'id': hash,
      'title': title,
      'artist': artist.isNotEmpty ? artist : '未知歌手',
      'album': _firstText(albumInfo, s['remark']),
      'album_id': s['album_id']?.toString() ?? '0',
      'album_audio_id': audioId,
      'artwork': artwork.isNotEmpty ? artwork : null,
      'duration': timelen > 0 ? timelen ~/ 1000 : null,
      '320hash': ogg320.isNotEmpty
          ? ogg320
          : (relate.length > 1 ? relate[1]['hash'] : null),
      'sqhash': _firstRelateHashByBitrate(relate, 500),
      'origin_hash':
          hashMultitrack.isNotEmpty ? hashMultitrack : hash,
      'qualities': _qualitiesFromRelateGoods(relate),
      // 宿主补充键：兼容 mfItemToSearchResult 与 LX 播放链
      'songmid': audioId > 0 ? audioId.toString() : hash,
      'name': title,
      'singer': artist.isNotEmpty ? artist : '未知歌手',
      'hash': hash,
      'audioId': audioId.toString(),
      'source': 'kg',
    };
  }

  /// 抄 formatImportMusicItem：对象为 get_res_privilege 详情 item（老歌单）
  static Map<String, dynamic>? _formatPlainItem(Map<String, dynamic> item) {
    final hash = item['hash']?.toString() ?? '';
    if (hash.isEmpty) return null;
    var title = item['name']?.toString() ?? '';
    final singerName = item['singername']?.toString() ?? '';
    if (singerName.isNotEmpty && title.isNotEmpty) {
      final index = title.indexOf(singerName);
      if (index != -1) {
        final cut = title.substring(index + singerName.length + 2).trim();
        title = cut.isNotEmpty ? cut : singerName;
      }
      if (title.isEmpty) title = singerName;
    }
    final relate = (item['relate_goods'] is List
            ? (item['relate_goods'] as List).whereType<Map>().toList()
            : <Map>[])
        .cast<Map>();
    final info = item['info'] is Map ? item['info'] as Map : null;
    var artwork = info?['image']?.toString() ?? '';
    artwork = artwork.replaceFirst('{size}', '400');

    return {
      'id': hash,
      'title': title,
      'artist': singerName,
      'album': item['albumname']?.toString() ?? '',
      'album_id': item['album_id']?.toString() ?? '',
      'album_audio_id': item['album_audio_id'],
      'artwork': artwork.isNotEmpty ? artwork : null,
      '320hash': relate.length > 1 ? relate[1]['hash'] : null,
      'sqhash': relate.length > 2 ? relate[2]['hash'] : null,
      'origin_hash': relate.length > 3 ? relate[3]['hash'] : null,
      // 宿主补充键
      'songmid': hash,
      'name': title,
      'singer': singerName,
      'hash': hash,
      'source': 'kg',
    };
  }

  /// 抄插件 relate_goods 分档：master/flac/320k/128k，各取首个命中
  static Map<String, dynamic> _qualitiesFromRelateGoods(List<Map> relate) {
    final qualities = <String, Map<String, dynamic>>{};
    for (final item in relate) {
      final h = item['hash']?.toString() ?? '';
      if (h.isEmpty) continue;
      final bitrate = _asInt(item['bitrate']) ?? 0;
      final level = _asInt(item['level']) ?? 0;
      String key;
      if (bitrate >= 999 || level >= 8) {
        key = 'master';
      } else if (bitrate >= 500 || level >= 5) {
        key = 'flac';
      } else if (bitrate >= 320 || level >= 4) {
        key = '320k';
      } else {
        key = '128k';
      }
      if (!qualities.containsKey(key)) {
        qualities[key] = {
          'size': _formatFileSize(_asInt(item['size'])),
          'bitrate': bitrate > 0 ? bitrate * 1000 : null,
          'hash': h,
        };
      }
    }
    if (qualities.isEmpty) {
      qualities['128k'] = {};
      qualities['320k'] = {};
      qualities['flac'] = {};
    }
    return qualities;
  }

  static String? _firstRelateHashByBitrate(List<Map> relate, int minBitrate) {
    for (final item in relate) {
      final bitrate = _asInt(item['bitrate']) ?? 0;
      if (bitrate >= minBitrate) return item['hash']?.toString();
    }
    return null;
  }

  // ==================== 工具 ====================

  static String _firstText(Object? a, Object? b) {
    final sa = a?.toString() ?? '';
    if (sa.isNotEmpty) return sa;
    return b?.toString() ?? '';
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  static int _statusCode(Map body) {
    final v = body['status'] ?? body['error_code'] ?? body['errcode'] ??
        body['err_code'];
    return v is num ? v.toInt() : -1;
  }

  static List _asList(Object? v) => v is List ? v : const [];

  static String _formatFileSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  static String _decodeName(String s) {
    var out = s.replaceAll(r'\/', '/');
    out = out
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final v = int.tryParse(m.group(1)!, radix: 16);
      return v == null ? m.group(0)! : String.fromCharCode(v);
    });
    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final v = int.tryParse(m.group(1)!);
      return v == null ? m.group(0)! : String.fromCharCode(v);
    });
    return out;
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
      if (resp.statusCode < 200 || resp.statusCode >= 400) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      AppLog.warn('plugin', '[kg-import] http $method 失败: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// JSON 解析（兼容 JSONP 包装）
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
        } catch (_) { /* 去 JSONP 包装后仍解析失败，按无数据处理 */ }
      }
      return null;
    }
  }
}

class HostSheetImportResult {
  final List<Map<String, dynamic>> tracks;
  final String name;
  final String cover;
  final String author;
  final String desc;

  const HostSheetImportResult({
    required this.tracks,
    required this.name,
    required this.cover,
    required this.author,
    required this.desc,
  });
}
