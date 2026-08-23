import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_engine.dart';
import 'plugin_models.dart';

/// 插件用户变量定义（与桌面端 PluginUserVariable / MusicFree IPlugin.IUserVariable 一致）。
class PluginUserVar {
  final String name;
  final String? title;
  final String type; // text | password | select
  final String? defaultValue;
  final List<String> options;
  final String? description;
  final String? placeholder;
  final bool required;

  const PluginUserVar({
    required this.name,
    this.title,
    this.type = 'text',
    this.defaultValue,
    this.options = const [],
    this.description,
    this.placeholder,
    this.required = false,
  });

  bool get isPassword => type == 'password';
  bool get isSelect => type == 'select' && options.isNotEmpty;

  /// 兼容 MusicFree（name/title/defaultValue）与 Baka（key/label/default）两种约定。
  /// key 优先作为变量键（Baka 约定），name 其次（MF 约定）；name≠key 时 name 作为显示名。
  static List<PluginUserVar> normalize(dynamic raw) {
    List<dynamic> list;
    if (raw is List) {
      list = raw;
    } else if (raw is Map) {
      list = raw.entries
          .map((e) =>
              e.value is Map ? {'name': e.key, ...e.value} : {'name': e.key, 'defaultValue': e.value})
          .toList();
    } else {
      return const [];
    }

    final result = <PluginUserVar>[];
    for (final item in list) {
      if (item is! Map) continue;
      final v = item.cast<String, dynamic>();
      final name = _toStr(v['key'] ?? v['name'] ?? v['id']);
      if (name.isEmpty) continue;

      final rawType = _toStr(v['type'] ?? v['inputType']).toLowerCase();
      final type = rawType == 'password'
          ? 'password'
          : rawType == 'select'
              ? 'select'
              : 'text';

      final rawOptions = v['options'] is List
          ? v['options'] as List
          : v['enums'] is List
              ? v['enums'] as List
              : const [];
      final options = <String>[];
      for (final opt in rawOptions) {
        String? value;
        if (opt is String) {
          value = opt.trim();
        } else if (opt is Map) {
          value = _toStr(opt['value'] ?? opt['key'] ?? opt['label'] ?? opt['name']).trim();
        }
        if (value != null && value.isNotEmpty) options.add(value);
      }

      final defaultValue = v['defaultValue'] ?? v['default'] ?? v['value'];
      final titleFromName =
          v['name'] is String && v['name'] != name ? v['name'] as String : null;

      result.add(PluginUserVar(
        name: name,
        title: _firstStr([v['title'], v['label']]) ?? titleFromName,
        type: type,
        defaultValue: defaultValue?.toString(),
        options: options,
        description: _firstStr([v['description'], v['desc'], v['remark']]),
        placeholder: _firstStr([v['placeholder'], v['hint']]),
        required: v['required'] == true,
      ));
    }
    return result;
  }

  static String _toStr(dynamic v) => v?.toString().trim() ?? '';
  static String? _firstStr(List<dynamic> values) {
    for (final v in values) {
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }
}

/// 用户变量值持久化：SharedPreferences，按插件 ID 存储。
/// 键与桌面端 localStorage 规则对齐（`plugin_user_vars.<pluginId>`）。
class PluginUserVarStore {
  static const _prefix = 'plugin_user_vars.';

  Future<Map<String, String>> getValues(String pluginId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$pluginId');
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    } catch (_) {
      return {};
    }
  }

  Future<void> setValues(String pluginId, Map<String, String> values) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefix$pluginId', jsonEncode(values));
    } catch (_) {
      // 忽略写入失败
    }
  }
}

/// 用户变量值缓存（StateNotifier，供引擎懒加载时同步读取）。
class PluginUserVarValuesNotifier extends StateNotifier<Map<String, Map<String, String>>> {
  PluginUserVarValuesNotifier() : super({});

  final store = PluginUserVarStore();

  /// 读取插件的用户变量值（首次访问时从磁盘加载并缓存）。
  Future<Map<String, String>> valuesOf(String pluginId) async {
    final cached = state[pluginId];
    if (cached != null) return cached;
    final values = await store.getValues(pluginId);
    state = {...state, pluginId: values};
    return values;
  }

  /// 同步读取缓存值（引擎懒加载回调使用，无缓存时返回空）。
  Map<String, String> cachedValuesOf(String pluginId) => state[pluginId] ?? {};

  Future<void> save(String pluginId, Map<String, String> values) async {
    state = {...state, pluginId: values};
    await store.setValues(pluginId, values);
  }
}

final pluginUserVarValuesProvider =
    StateNotifierProvider<PluginUserVarValuesNotifier, Map<String, Map<String, String>>>(
        (ref) => PluginUserVarValuesNotifier());

/// 获取插件的用户变量定义（触发插件加载以读取 metadata.userVariables）。
Future<List<PluginUserVar>> getPluginUserVars(PluginEngine engine, PluginSource source) async {
  if (source.format != PluginFormat.musicfree) return const [];
  final metadata = await engine.ensureLoaded(source);
  if (metadata == null) return const [];
  return PluginUserVar.normalize(metadata['userVariables']);
}
