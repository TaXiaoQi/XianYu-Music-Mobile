import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_models.dart';

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
      } catch (_) {
      }
    }
  }

  Future<void> clearAll() async {
    final dir = Directory(_pluginsDir);
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
      }
    }
    await saveSources(const []);
  }
}
