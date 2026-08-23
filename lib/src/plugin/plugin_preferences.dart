import 'package:shared_preferences/shared_preferences.dart';

/// 插件偏好设置：全局（启动自动更新）+ 单插件（跳过版本检查）。
class PluginPreferences {
  static const _autoUpdateKey = 'plugin_auto_update_on_startup';
  static const _skipUpdatePrefix = 'plugin_skip_update_check_';

  // ─── 全局：启动自动更新 ─────────────────────────────

  static Future<bool> getAutoUpdateOnStartup() async =>
      (await SharedPreferences.getInstance())
          .getBool(_autoUpdateKey) ??
      false;

  static Future<void> setAutoUpdateOnStartup(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_autoUpdateKey, value);

  // ─── 单插件：跳过版本检查 ──────────────────────────

  static Future<bool> getSkipUpdateCheck(String pluginId) async =>
      (await SharedPreferences.getInstance())
          .getBool('$_skipUpdatePrefix$pluginId') ??
      false;

  static Future<void> setSkipUpdateCheck(String pluginId, bool value) async =>
      (await SharedPreferences.getInstance())
          .setBool('$_skipUpdatePrefix$pluginId', value);
}