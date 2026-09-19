import 'package:shared_preferences/shared_preferences.dart';

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

  static Future<void> setSyncedIds(Iterable<String> ids) =>
      _write(_syncedKey, ids.toSet());

  static Future<void> addSyncedIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final s = await syncedIds();
    final before = s.length;
    s.addAll(ids);
    if (s.length != before) await _write(_syncedKey, s);
  }

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

  static Future<void> clearTombstones(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await removeDownloadSkipIds(ids);
    final s = await uploadSkipIds();
    final before = s.length;
    s.removeAll(ids);
    if (s.length != before) await _write(_uploadSkipKey, s);
  }
}
