import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/application_logger.dart';
import 'plugin_models.dart';

/// 在线歌单详情缓存：仅服务收藏歌单的「缓存优先、后台刷新」与离线兜底。
/// 文件名用 base64Url(key) 规避非法字符与长度问题。
class SheetCache {
  static const _dirName = 'sheet_cache';

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// LX 歌单按「源+歌单 id」建 key（与插件实例解耦，插件被删/换 id 后仍可命中），
  /// 插件歌单按「插件 id+标题」建 key。
  static String keyFor({
    required String pluginId,
    required String title,
    required Map<String, dynamic> raw,
  }) {
    final lxSource = raw['_lxSource'];
    final lxPlaylistId = raw['_lxPlaylistId'];
    if (lxSource is String &&
        lxSource.isNotEmpty &&
        lxPlaylistId is String &&
        lxPlaylistId.isNotEmpty) {
      return 'playlist|lx|$lxSource|$lxPlaylistId|$title';
    }
    return 'playlist|$pluginId|$title';
  }

  static File? _fileFor(Directory dir, String key) {
    if (key.isEmpty) return null;
    final name = base64Url.encode(utf8.encode(key));
    return File('${dir.path}/$name.json');
  }

  static Future<List<PluginSearchResult>?> load(String key) async {
    try {
      final dir = await _dir();
      final file = _fileFor(dir, key);
      if (file == null || !file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final list = decoded['songs'];
      if (list is! List || list.isEmpty) return null;
      return list
          .whereType<Map>()
          .map((e) =>
              PluginSearchResult.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (e) {
      AppLog.warn('plugin', '[sheetCache] load $key failed: $e');
      return null;
    }
  }

  static Future<void> save(
      String key, List<PluginSearchResult> songs) async {
    if (key.isEmpty || songs.isEmpty) return;
    try {
      final dir = await _dir();
      final file = _fileFor(dir, key);
      if (file == null) return;
      final body = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'songs': songs.map((e) => e.toJson()).toList(),
      });
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body);
      await tmp.rename(file.path);
    } catch (e) {
      AppLog.warn('plugin', '[sheetCache] save $key failed: $e');
    }
  }

  static Future<void> deleteFor({
    required String pluginId,
    required String title,
    required Map<String, dynamic> raw,
  }) async {
    try {
      final dir = await _dir();
      final file = _fileFor(
          dir, keyFor(pluginId: pluginId, title: title, raw: raw));
      if (file != null && file.existsSync()) await file.delete();
    } catch (e) {
      AppLog.warn('plugin', '[sheetCache] delete failed: $e');
    }
  }
}
