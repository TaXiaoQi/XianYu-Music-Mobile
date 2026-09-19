import 'package:shared_preferences/shared_preferences.dart';

class PluginPreferences {
  static const _autoUpdateKey = 'plugin_auto_update_on_startup';
  static const _skipUpdatePrefix = 'plugin_skip_update_check_';

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
      (await SharedPreferences.getInstance())
          .setBool('$_skipUpdatePrefix$pluginId', value);
}