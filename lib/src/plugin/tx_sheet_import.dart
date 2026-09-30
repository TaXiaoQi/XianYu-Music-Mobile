import 'dart:convert';
import 'dart:io';

import '../core/application_logger.dart';
import 'kg_sheet_import.dart' show HostSheetImportResult;

/// 宿主侧 QQ 音乐歌单导入兜底。
///
/// 链路与桌面端 playlistImportTx.ts 逐点对齐：
/// 链接解析（/playlist/ /playsquare/ id=）→ 分享页兜底解析 →
/// c.y.qq.com fcg_ucc_getcdinfo_byids_cp.fcg 取歌单详情。
/// 曲目条目结构与插件 importMusicSheet 输出一致，播放链路零差异。
class TxSheetImport {
  TxSheetImport._();

  /// 关键词是否 QQ 音乐特征（链接域）
  static bool isTxKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('y.qq.com') ||
        t.contains('i.y.qq.com') ||
        t.contains('c.y.qq.com');
  }

  /// 插件是否 QQ 音乐系（纯数字歌单 ID 导入需要来源限定）
  static bool isTxSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('qq') || n.contains('企鹅') || n.contains('腾讯')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'tx' || t == 'qq' || t.contains('qq')) return true;
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) async {
    final t = keyword.trim();
    if (t.isEmpty) return null;
    try {
      var id = _extractListId(t);
      if ((id == null || id.isEmpty) &&
          (t.startsWith('http://') || t.startsWith('https://'))) {
        id = await _resolveShareUrl(t);
      }
      if (id == null || id.isEmpty) return null;
      return await _importById(id);
    } catch (e) {
      AppLog.warn('plugin', '[tx-import] QQ音乐歌单导入失败: $e');
    }
    return null;
  }

  /// 抄 getTxListId：纯数字直接用；链接/带参数走正则
  static String? _extractListId(String input) {
    final id = input.trim();
    if (id.isEmpty) return null;
    if (RegExp(r'[?&:/]').hasMatch(id)) {
      var m = RegExp(r'/playlist/(\d+)').firstMatch(id)?.group(1);
      if (m != null) return m;
      m = RegExp(r'id=(\d+)').firstMatch(id)?.group(1);
      if (m != null) return m;
      m = RegExp(r'/playsquare/(\d+)').firstMatch(id)?.group(1);
      if (m != null) return m;
      return null;
    }
    return id;
  }

  // ==================== 分享链接兜底解析 ====================

  static Future<String?> _resolveShareUrl(String url) async {
    try {
      final body = await _httpText('GET', url, headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; HLK-AL00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.5112.102 Mobile Safari/537.36 EdgA/104.0.1293.70',
      });
      if (body == null || body.isEmpty) return null;
      var m = RegExp(r'id=(\d+)').firstMatch(body)?.group(1);
      if (m != null) return m;
      m = RegExp(r'/playlist/(\d+)').firstMatch(body)?.group(1);
      if (m != null) return m;
      m = RegExp(r'/playsquare/(\d+)').firstMatch(body)?.group(1);
      if (m != null) return m;
      m = RegExp(r'''"disstid"\s*:\s*"?(\d+)"?''').firstMatch(body)?.group(1);
      if (m != null) return m;
      m = RegExp(r'''"dissid"\s*:\s*"?(\d+)"?''').firstMatch(body)?.group(1);
      if (m != null) return m;
      return null;
    } catch (e) {
      AppLog.warn('plugin', '[tx-import] resolveShareUrl 失败: $e');
      return null;
    }
  }

  // ==================== 歌单详情 ====================

  static Future<HostSheetImportResult?> _importById(String id) async {
    final body = await _httpJson(
      'GET',
      'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg'
      '?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=$id'
      '&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8'
      '&notice=0&platform=yqq.json&needNewCode=0',
      headers: {
        'Origin': 'https://y.qq.com',
        'Referer': 'https://y.qq.com/n/yqq/playsquare/$id.html',
      },
    );
    if (body is! Map || body['code'] != 0) return null;
    final cdlist = body['cdlist'] is List ? body['cdlist'] as List : const [];
    if (cdlist.isEmpty || cdlist.first is! Map) return null;
    final cd = cdlist.first as Map;

    final songlist = cd['songlist'] is List ? cd['songlist'] as List : const [];
    final tracks = <Map<String, dynamic>>[];
    for (final item in songlist) {
      if (item is! Map) continue;
      final t = _parseTxSong(item.cast<String, dynamic>());
      if (t != null) tracks.add(t);
    }
    if (tracks.isEmpty) return null;

    return HostSheetImportResult(
      tracks: tracks,
      name: _decodeName(cd['dissname']?.toString() ?? ''),
      cover: cd['logo']?.toString() ?? '',
      author: cd['nickname']?.toString() ?? '',
      desc: _decodeName(cd['desc']?.toString() ?? '').replaceAll('<br>', '\n'),
    );
  }

  // ==================== 曲目格式化（抄 parseTxSong） ====================

  static Map<String, dynamic>? _parseTxSong(Map<String, dynamic> item) {
    final songmid = item['mid']?.toString() ?? '';
    final songId = item['id']?.toString() ?? '';
    if (songmid.isEmpty && songId.isEmpty) return null;

    final singer = item['singer'] is List ? item['singer'] as List : const [];
    final singerName = _formatSingerName(singer);
    final name = _decodeName(item['title']?.toString() ?? '');
    final album = item['album'] is Map ? item['album'] as Map : const {};
    final albumName = _decodeName(album['name']?.toString() ?? '');
    final albumMid = album['mid']?.toString() ?? '';
    final interval = _asInt(item['interval']) ?? 0;
    final file = item['file'] is Map ? item['file'] as Map : const {};
    final strMediaMid = file['media_mid']?.toString() ?? '';

    var img = '';
    if (albumName.isEmpty || albumName == '空') {
      if (singer.isNotEmpty && singer.first is Map) {
        final firstMid = (singer.first as Map)['mid']?.toString() ?? '';
        img = 'https://y.gtimg.cn/music/photo_new/T001R500x500M000$firstMid.jpg';
      }
    } else {
      img = 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg';
    }

    return {
      'id': songmid.isNotEmpty ? songmid : songId,
      'title': name,
      'artist': singerName,
      'album': albumName,
      'artwork': img,
      'duration': interval * 1000,
      // 宿主补充键：兼容 mfItemToSearchResult 与 LX 播放链
      'songmid': songmid,
      'songId': songId,
      'strMediaMid': strMediaMid,
      'albumMid': albumMid,
      'name': name,
      'singer': singerName,
      'source': 'tx',
      'interval': _formatPlayTime(interval),
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
      AppLog.warn('plugin', '[tx-import] http $method 失败: $e');
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
        } catch (_) {}
      }
      return null;
    }
  }
}
