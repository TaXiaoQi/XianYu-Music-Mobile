import 'package:shared_preferences/shared_preferences.dart';

abstract final class FavoritesSyncState {
  static const _cloudKeepKey = 'favorites_cloud_keep_paths';
  static const _localOnlyKey = 'favorites_local_only_paths';

  static Future<Set<String>> _read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(key) ?? const <String>[]).toSet();
  }

  static Future<void> _write(String key, Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, ids.toList());
  }

  static Future<Set<String>> cloudKeepPaths() => _read(_cloudKeepKey);

  static Future<void> addCloudKeepPaths(Iterable<String> paths) async {
    final s = await cloudKeepPaths();
    final before = s.length;
    s.addAll(paths);
    if (s.length != before) await _write(_cloudKeepKey, s);
  }

  static Future<void> removeCloudKeepPaths(Iterable<String> paths) async {
    final s = await cloudKeepPaths();
    final before = s.length;
    s.removeAll(paths);
    if (s.length != before) await _write(_cloudKeepKey, s);
  }

  static Future<Set<String>> localOnlyPaths() => _read(_localOnlyKey);

  static Future<void> addLocalOnlyPaths(Iterable<String> paths) async {
    final s = await localOnlyPaths();
    final before = s.length;
    s.addAll(paths);
    if (s.length != before) await _write(_localOnlyKey, s);
  }

  static Future<void> removeLocalOnlyPaths(Iterable<String> paths) async {
    final s = await localOnlyPaths();
    final before = s.length;
    s.removeAll(paths);
    if (s.length != before) await _write(_localOnlyKey, s);
  }
}
