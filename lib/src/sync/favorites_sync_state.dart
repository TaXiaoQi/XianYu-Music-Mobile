import 'package:shared_preferences/shared_preferences.dart';

/// 收藏同步状态（SharedPreferences 持久化），与桌面端 favoritesSyncState.ts 语义一致。
///
/// - cloudKeepPaths「仅删本地」墓碑：收藏已从本机移除但云端保留，
///   上传时排除出 delete_paths diff、下载合并时跳过回灌。
///   重新收藏该 path 时清除。
/// - localOnlyPaths「仅保留本地」墓碑：收藏保留本机但已从云端删除，
///   上传时排除出 payload 防复活。取消收藏后自然失效（上传时清理），
///   重新收藏该 path 时也清除。
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
