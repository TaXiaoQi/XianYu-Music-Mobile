import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/application_logger.dart';
import '../rust/api.dart';
import 'kg_sheet_import.dart' show HostSheetImportResult;

/// 宿主侧网易云歌单导入兜底。
///
/// 链路与桌面端 playlistImportWy.ts 逐点对齐：
/// linuxapi forward（AES eparams）取 v3 歌单详情（trackIds + tracks）；
/// tracks 未覆盖的 trackIds 用 weapi v3/song/detail 批量补详情
/// （批 1000、重试 2 次隔 300ms）。
/// 曲目条目结构与插件 importMusicSheet 输出一致，播放链路零差异。
class WySheetImport {
  WySheetImport._();

  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36';

  /// 关键词是否网易云特征（链接域）
  static bool isWyKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('music.163.com') ||
        t.contains('y.music.163.com') ||
        t.contains('163cn.tv');
  }

  /// 插件是否网易云系（纯数字歌单 ID 导入需要来源限定）
  static bool isWySource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('网易') || n.contains('netease')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'wy' || t == 'netease' || t.contains('网易')) return true;
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) async {
    final t = keyword.trim();
    if (t.isEmpty) return null;
    try {
      final id = _extractListId(t);
      if (id == null || id.isEmpty) return null;
      return await _importById(id);
    } catch (e) {
      AppLog.warn('plugin', '[wy-import] 网易云歌单导入失败: $e');
    }
    return null;
  }

  /// 抄 getWyListId：纯数字直接用；链接/带参数走正则
  static String? _extractListId(String input) {
    final id = input.trim();
    if (id.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(id)) return id;
    if (RegExp(r'[?&:/]').hasMatch(id)) {
      var m = RegExp(r'[?&]id=(\d+)').firstMatch(id)?.group(1);
      if (m != null) return m;
      m = RegExp(r'/playlist/(\d+)/\d+/').firstMatch(id)?.group(1);
      if (m != null) return m;
      return null;
    }
    return id;
  }

  // ==================== 歌单详情 ====================

  static Future<HostSheetImportResult?> _importById(String id) async {
    final eparams = await hostLinuxapiEncrypt(
      payload: jsonEncode({
        'method': 'POST',
        'url': 'https://music.163.com/api/v3/playlist/detail',
        'params': {'id': id, 'n': 100000, 's': 8},
      }),
    );
    final body = await _httpJson(
      'POST',
      'https://music.163.com/api/linux/forward',
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': _ua,
        'Cookie': 'MUSIC_U=',
      },
      body: jsonEncode({'eparams': eparams}),
    );
    if (body is! Map || body['code'] != 200) return null;
    final playlist = body['playlist'];
    if (playlist is! Map) return null;

    final trackIds =
        playlist['trackIds'] is List ? playlist['trackIds'] as List : const [];
    final tracks =
        playlist['tracks'] is List ? playlist['tracks'] as List : const [];

    final songs = <Map<String, dynamic>>[];
    final fetchedIds = <String>{};
    for (final track in tracks) {
      if (track is! Map) continue;
      final parsed = _parseWyTrack(track.cast<String, dynamic>());
      if (parsed != null) {
        songs.add(parsed);
        fetchedIds.add(parsed['songmid'].toString());
      }
    }

    final remainingIds = <String>[];
    for (final tid in trackIds) {
      if (tid is! Map) continue;
      final songId = tid['id']?.toString() ?? '';
      if (songId.isNotEmpty && songId != '0' && !fetchedIds.contains(songId)) {
        remainingIds.add(songId);
      }
    }
    for (var i = 0; i < remainingIds.length; i += 1000) {
      final end =
          i + 1000 > remainingIds.length ? remainingIds.length : i + 1000;
      songs.addAll(await _fetchDetailBatch(remainingIds.sublist(i, end)));
    }
    if (songs.isEmpty) return null;

    final creator = playlist['creator'] is Map ? playlist['creator'] as Map : const {};
    return HostSheetImportResult(
      tracks: songs,
      name: _decodeName(playlist['name']?.toString() ?? ''),
      cover: playlist['coverImgUrl']?.toString() ?? '',
      author: _decodeName(creator['nickname']?.toString() ?? ''),
      desc: _decodeName(playlist['description']?.toString() ?? ''),
    );
  }

  /// weapi v3/song/detail 批量补详情（批 1000、重试 2 次隔 300ms）
  static Future<List<Map<String, dynamic>>> _fetchDetailBatch(
      List<String> ids) async {
    const maxRetry = 2;
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetry; attempt++) {
      try {
        final encrypted = jsonDecode(await hostWeapiEncrypt(
          payload: jsonEncode({
            'c': '[${ids.map((id) => '{"id":$id}').join(',')}]',
            'ids': '[${ids.join(',')}]',
          }),
        )) as Map;
        final body = await _httpJson(
          'POST',
          'https://music.163.com/weapi/v3/song/detail',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': _ua,
            'Origin': 'https://music.163.com',
            'Referer': 'https://music.163.com/',
          },
          body:
              'params=${Uri.encodeQueryComponent(encrypted['params']?.toString() ?? '')}'
              '&encSecKey=${Uri.encodeQueryComponent(encrypted['encSecKey']?.toString() ?? '')}',
        );
        if (body is Map && body['code'] == 200 && body['songs'] is List) {
          final list = <Map<String, dynamic>>[];
          for (final track in body['songs'] as List) {
            if (track is! Map) continue;
            final parsed = _parseWyTrack(track.cast<String, dynamic>());
            if (parsed != null) list.add(parsed);
          }
          return list;
        }
        lastError = 'code=${body is Map ? body['code'] : 'unknown'}';
      } catch (e) {
        lastError = e;
      }
      if (attempt < maxRetry) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    throw Exception('网易云歌曲详情获取失败: $lastError');
  }

  // ==================== 曲目格式化（抄 parseWyTrack） ====================

  static Map<String, dynamic>? _parseWyTrack(Map<String, dynamic> track) {
    final id = track['id']?.toString() ?? '';
    if (id.isEmpty || id == '0') return null;
    final name = _decodeName(track['name']?.toString() ?? '');
    final ar = track['ar'] is List
        ? track['ar'] as List
        : (track['artists'] is List ? track['artists'] as List : const []);
    final al = track['al'] is Map
        ? track['al'] as Map
        : (track['album'] is Map ? track['album'] as Map : const {});
    final duration = _asInt(track['dt']) ?? _asInt(track['duration']) ?? 0;
    final singerName = _formatSingerName(ar);

    return {
      'id': id,
      'title': name,
      'artist': singerName,
      'album': _decodeName(al['name']?.toString() ?? ''),
      'artwork': al['picUrl']?.toString() ?? '',
      'duration': duration,
      // 宿主补充键：兼容 mfItemToSearchResult 与 LX 播放链
      'songmid': id,
      'name': name,
      'singer': singerName,
      'source': 'wy',
      'interval': _formatPlayTime(duration > 0 ? duration ~/ 1000 : 0),
    };
  }

  // ==================== 工具 ====================

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  /// 抄 formatSingerName：对象取 name 键，'、' 拼接
  static String _formatSingerName(List singers) {
    final names = <String>[];
    for (final item in singers) {
      if (item is Map) {
        final name = item['name']?.toString() ?? '';
        if (name.trim().isNotEmpty) names.add(_decodeName(name));
      }
    }
    return names.join('、');
  }

  static String _formatPlayTime(int seconds) {
    if (seconds <= 0) return '--/--';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m < 10 ? '0$m' : '$m'}:${s < 10 ? '0$s' : '$s'}';
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
      AppLog.warn('plugin', '[wy-import] http $method 失败: $e');
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
