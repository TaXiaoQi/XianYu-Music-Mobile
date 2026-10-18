import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';
import 'plugin_models.dart';

class PluginStore {
  static const _sourcesKey = 'xianyu_plugin_sources_v4';
  static const _aliasesKey = 'xianyu_plugin_id_aliases_v1';

  final String dataDir;

  PluginStore(this.dataDir);

  String get _pluginsDir => p.join(dataDir, 'plugins');

  Future<List<PluginSource>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sourcesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => PluginSource.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveSources(List<PluginSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _sourcesKey, jsonEncode(sources.map((e) => e.toJson()).toList()));
  }

  /// 插件 id 别名表（旧 id → 现行 id）：插件更新即换 sha256 id（脚本内容
  /// 哈希），收藏/播放队列里存的旧 pluginId 靠这张表换算，避免来源标签
  /// 降级「在线」、播放解析走失效分支
  Future<Map<String, String>> loadAliases() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_aliasesKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveAliases(Map<String, String> aliases) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_aliasesKey, jsonEncode(aliases));
  }

  Future<String> saveScript(String pluginId, String script) async {
    final dir = Directory(_pluginsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = p.join(_pluginsDir, '$pluginId.js');
    await File(path).writeAsString(script, flush: true);
    return path;
  }

  Future<String?> readScript(String pluginId) async {
    final path = p.join(_pluginsDir, '$pluginId.js');
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteScript(String pluginId) async {
    final path = p.join(_pluginsDir, '$pluginId.js');
    final file = File(path);
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (e) {
        AppLog.warn('plugin', '删除插件脚本失败($pluginId): $e');
      }
    }
  }

  Future<void> clearAll() async {
    final dir = Directory(_pluginsDir);
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        AppLog.warn('plugin', '清空插件脚本目录失败: $e');
      }
    }
    await saveSources(const []);
  }
}
