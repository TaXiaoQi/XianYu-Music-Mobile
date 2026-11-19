import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

abstract final class PluginSyncState {
  static const _syncedKey = 'synced_plugin_ids';
  static const _downloadSkipKey = 'plugin_sync_download_skip_ids';
  static const _uploadSkipKey = 'plugin_sync_upload_skip_ids';
  static const _scriptHashKey = 'plugin_sync_script_hashes';

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

  // ==================== 已上传内容哈希账本 ====================
  // 记录每个插件最近一次成功同步到云端的内容指纹（脚本+用户变量，键排序
  // 联合哈希，算法对齐桌面端 contentHash），自动同步时内容未变化的插件
  // 直接跳过重传，避免全量重传浪费带宽

  static Future<Map<String, String>> uploadedScriptHashes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scriptHashKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      decoded.forEach((k, v) {
        if (v is String && v.isNotEmpty) out[k.toString()] = v;
      });
      return out;
    } catch (_) {
      return <String, String>{};
    }
  }

  static Future<void> recordUploadedScriptHashes(
      Map<String, String> entries) async {
    final valid = <String, String>{
      for (final e in entries.entries)
        if (e.key.isNotEmpty && e.value.isNotEmpty) e.key: e.value,
    };
    if (valid.isEmpty) return;
    final merged = await uploadedScriptHashes()..addAll(valid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scriptHashKey, jsonEncode(merged));
  }
}
