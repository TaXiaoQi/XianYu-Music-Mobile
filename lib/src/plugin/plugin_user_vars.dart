import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_engine.dart';
import 'plugin_models.dart';

class PluginUserVar {
  final String name;
  final String? title;
  final String type;
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
    }
  }
}

class PluginUserVarValuesNotifier extends StateNotifier<Map<String, Map<String, String>>> {
  PluginUserVarValuesNotifier() : super({});

  final store = PluginUserVarStore();

  Future<Map<String, String>> valuesOf(String pluginId) async {
    final cached = state[pluginId];
    if (cached != null) return cached;
    final values = await store.getValues(pluginId);
    state = {...state, pluginId: values};
    return values;
  }

  Map<String, String> cachedValuesOf(String pluginId) => state[pluginId] ?? {};

  Future<void> save(String pluginId, Map<String, String> values) async {
    state = {...state, pluginId: values};
    await store.setValues(pluginId, values);
  }
}

final pluginUserVarValuesProvider =
    StateNotifierProvider<PluginUserVarValuesNotifier, Map<String, Map<String, String>>>(
        (ref) => PluginUserVarValuesNotifier());

Future<List<PluginUserVar>> getPluginUserVars(PluginEngine engine, PluginSource source) async {
  if (source.format != PluginFormat.musicfree) return const [];
  final metadata = await engine.ensureLoaded(source);
  if (metadata == null) return const [];
  return PluginUserVar.normalize(metadata['userVariables']);
}
