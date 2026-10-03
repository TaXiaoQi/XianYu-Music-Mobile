import 'dart:convert';
import 'dart:io';

import '../core/application_logger.dart';
import 'kg_sheet_import.dart' show HostSheetImportResult;

/// 宿主侧酷我歌单导入兜底。
///
/// 链路与桌面端 playlistImportKw.ts 逐点对齐：
/// 链接解析（/playlist/ playlistId=）→ nplserver.kuwo.cn pl.svc
/// getlistinfo（Dalvik UA）。曲目条目结构与插件 importMusicSheet
/// 输出一致，播放链路零差异。
class KwSheetImport {
  KwSheetImport._();

  /// 关键词是否酷我特征（链接域）
  static bool isKwKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('kuwo.cn');
  }

  /// 插件是否酷我系（纯数字歌单 ID 导入需要来源限定）
  static bool isKwSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('酷我') || n.contains('kuwo')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'kw' || t == 'kuwo' || t.contains('酷我')) return true;
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
      AppLog.warn('plugin', '[kw-import] 酷我歌单导入失败: $e');
    }
    return null;
  }

  /// 抄 getKwListId：纯数字直接用；digest-xxx__id 取段；链接走正则
  static String? _extractListId(String input) {
    final id = input.trim();
    if (id.isEmpty) return null;
    if (RegExp(r'[?&:/]').hasMatch(id)) {
      var m = RegExp(r'/playlists?(?:_detail)?/(\d+)').firstMatch(id)?.group(1);
      if (m != null) return m;
      m = RegExp(r'playlistId=(\d+)').firstMatch(id)?.group(1);
      if (m != null) return m;
      return null;
    }
    if (id.startsWith('digest-')) {
      final parts = id.split('__');
      if (parts.length >= 2) return parts[1];
    }
    return id;
  }

  // ==================== 歌单详情 ====================

  static Future<HostSheetImportResult?> _importById(String id) async {
    final body = await _httpJson(
      'GET',
      'http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=$id'
      '&pn=0&rn=1000&encode=utf8&keyset=pl2012'
      '&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1',
      headers: {
        'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)',
      },
    );
    if (body is! Map || body['result'] != 'ok') return null;

    final musiclist =
        body['musiclist'] is List ? body['musiclist'] as List : const [];
    final tracks = <Map<String, dynamic>>[];
    for (final item in musiclist) {
      if (item is! Map) continue;
      final t = _parseKwSong(item.cast<String, dynamic>());
      if (t != null) tracks.add(t);
    }
    if (tracks.isEmpty) return null;

    return HostSheetImportResult(
      tracks: tracks,
      name: _decodeName(body['title']?.toString() ?? ''),
      cover: body['pic']?.toString() ?? '',
      author: _decodeName(body['uname']?.toString() ?? ''),
      desc: _decodeName(body['info']?.toString() ?? ''),
    );
  }

  // ==================== 曲目格式化（抄 parseKwSong） ====================

  static Map<String, dynamic>? _parseKwSong(Map<String, dynamic> item) {
    final idStr = item['id']?.toString() ?? '';
    if (idStr.isEmpty) return null;

    final name = _decodeName(item['name']?.toString() ?? '');
    final artist = _decodeName(item['artist']?.toString() ?? '');
    final album = _decodeName(item['album']?.toString() ?? '');
    final durationSec = int.tryParse(item['duration']?.toString() ?? '') ?? 0;

    return {
      'id': idStr,
      'title': name,
      'artist': artist,
      'album': album,
      'artwork': '',
      'duration': durationSec * 1000,
      // 宿主补充键：兼容 mfItemToSearchResult 与 LX 播放链
      'songmid': idStr,
      'name': name,
      'singer': artist,
      'source': 'kw',
      'interval': _formatPlayTime(durationSec),
    };
  }

  // ==================== 工具 ====================

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
      AppLog.warn('plugin', '[kw-import] http $method 失败: $e');
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
