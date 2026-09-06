import 'package:shared_preferences/shared_preferences.dart';

/// 插件同步状态（SharedPreferences 持久化），与桌面端 pluginSyncState.ts 语义一致。
///
/// - syncedIds「已同步」标记：云端确认存在副本的插件 id 集。
///   上传成功后整集替换为本次上传成功的 id；下载恢复成功后并集追加。
///   删除插件时据此判断是否弹「删除范围」三选一。
/// - downloadSkipIds「仅删本地」墓碑：插件已从本机删除但云端保留，
///   下载恢复时跳过，防止删除后被同步回流。
/// - uploadSkipIds「仅保留本地」墓碑：插件保留本机但已从云端删除，
///   上传时跳过，防止本地独占插件被重新推上云端。
///   重新安装同 id 插件时清除双向墓碑（clearTombstones）。
abstract final class PluginSyncState {
  static const _syncedKey = 'synced_plugin_ids';
  static const _downloadSkipKey = 'plugin_sync_download_skip_ids';
  static const _uploadSkipKey = 'plugin_sync_upload_skip_ids';

  static Future<Set<String>> _read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(key) ?? const <String>[]).toSet();
  }

  static Future<void> _write(String key, Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, ids.toList());
  }

  static Future<Set<String>> syncedIds() => _read(_syncedKey);

  static Future<bool> isSynced(String id) async =>
      (await syncedIds()).contains(id);

  /// 上传成功后整集替换（本次上传即云端权威副本）
  static Future<void> setSyncedIds(Iterable<String> ids) =>
      _write(_syncedKey, ids.toSet());

  /// 下载恢复成功后并集追加
  static Future<void> addSyncedIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final s = await syncedIds();
    final before = s.length;
    s.addAll(ids);
    if (s.length != before) await _write(_syncedKey, s);
  }

  /// 云端删除成功后移除标记
  static Future<void> removeSyncedIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final s = await syncedIds();
    final before = s.length;
    s.removeAll(ids);
    if (s.length != before) await _write(_syncedKey, s);
  }

  static Future<Set<String>> downloadSkipIds() => _read(_downloadSkipKey);

  static Future<void> addDownloadSkipIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final s = await downloadSkipIds();
    final before = s.length;
    s.addAll(ids);
    if (s.length != before) await _write(_downloadSkipKey, s);
  }

  static Future<void> removeDownloadSkipIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final s = await downloadSkipIds();
    final before = s.length;
    s.removeAll(ids);
    if (s.length != before) await _write(_downloadSkipKey, s);
  }

  static Future<Set<String>> uploadSkipIds() => _read(_uploadSkipKey);

  static Future<void> addUploadSkipIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final s = await uploadSkipIds();
    final before = s.length;
    s.addAll(ids);
    if (s.length != before) await _write(_uploadSkipKey, s);
  }

  /// 重新安装/更新同 id 插件：清除双向墓碑，恢复正常同步行为
  static Future<void> clearTombstones(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await removeDownloadSkipIds(ids);
    final s = await uploadSkipIds();
    final before = s.length;
    s.removeAll(ids);
    if (s.length != before) await _write(_uploadSkipKey, s);
  }
}
