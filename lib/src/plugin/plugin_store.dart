import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_models.dart';

/// 插件持久化存储：
/// - 插件列表存 SharedPreferences（key: xianyu_plugin_sources_v4）
/// - 插件脚本存应用数据目录 plugins/ 下（按插件 ID 命名）
class PluginStore {
  static const _sourcesKey = 'xianyu_plugin_sources_v4';

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

  /// 保存插件脚本到数据目录，返回文件路径。
  Future<String> saveScript(String pluginId, String script) async {
    final dir = Directory(_pluginsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = p.join(_pluginsDir, '$pluginId.js');
    await File(path).writeAsString(script, flush: true);
    return path;
  }

  /// 读取插件脚本内容。
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

  /// 删除插件脚本文件。
  Future<void> deleteScript(String pluginId) async {
    final path = p.join(_pluginsDir, '$pluginId.js');
    final file = File(path);
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {
        // 忽略删除失败
      }
    }
  }

  /// 删除全部插件脚本与列表。
  Future<void> clearAll() async {
    final dir = Directory(_pluginsDir);
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略
      }
    }
    await saveSources(const []);
  }
}
