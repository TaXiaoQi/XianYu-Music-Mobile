import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 网盘伪音源的按盘覆盖配置：enabled 关闭后搜索不展示、不拉取该盘；
/// sortIndex 为前方插件数（与插件 sortOrder 同一坐标系），null=固定末尾。
class CloudSourcePref {
  const CloudSourcePref({this.enabled = true, this.sortIndex});

  final bool enabled;
  final int? sortIndex;
}

class PluginPreferences {
  static const _autoUpdateKey = 'plugin_auto_update_on_startup';
  static const _skipUpdatePrefix = 'plugin_skip_update_check_';
  static const _cloudSourcesKey = 'plugin_cloud_sources';

  static Future<bool> getAutoUpdateOnStartup() async =>
      (await SharedPreferences.getInstance())
          .getBool(_autoUpdateKey) ??
      false;

  static Future<void> setAutoUpdateOnStartup(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_autoUpdateKey, value);

  static Future<bool> getSkipUpdateCheck(String pluginId) async =>
      (await SharedPreferences.getInstance())
          .getBool('$_skipUpdatePrefix$pluginId') ??
      false;

  static Future<void> setSkipUpdateCheck(String pluginId, bool value) async =>
      (await SharedPreferences.getInstance()).setBool('$_skipUpdatePrefix$pluginId', value);

  static Future<Map<String, CloudSourcePref>> getCloudSources() async {
    final raw =
        (await SharedPreferences.getInstance()).getString(_cloudSourcesKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final out = <String, CloudSourcePref>{};
      decoded.forEach((k, v) {
        if (k is! String || v is! Map) return;
        out[k] = CloudSourcePref(
          enabled: v['enabled'] is bool ? v['enabled'] as bool : true,
          sortIndex: v['sortIndex'] is int ? v['sortIndex'] as int : null,
        );
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// 局部更新单盘配置：未传字段沿用现值。
  static Future<void> setCloudSourcePref(
    String providerId, {
    bool? enabled,
    int? sortIndex,
  }) async {
    final prefs = await getCloudSources();
    final prev = prefs[providerId] ?? const CloudSourcePref();
    final next = <String, CloudSourcePref>{
      ...prefs,
      providerId: CloudSourcePref(
        enabled: enabled ?? prev.enabled,
        sortIndex: sortIndex ?? prev.sortIndex,
      ),
    };
    final encoded = jsonEncode(<String, Object?>{
      for (final e in next.entries)
        e.key: {'enabled': e.value.enabled, 'sortIndex': e.value.sortIndex},
    });
    await (await SharedPreferences.getInstance())
        .setString(_cloudSourcesKey, encoded);
  }
}
