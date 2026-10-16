// 网盘已选文件夹存储（每账号多路径）。
//
// 路径不是敏感数据，直接明文 SecureStore JSON：
// key `xianyu.cloud.folder_sel.v1`，结构
// `{"<providerId>|<accountId>": [path, ...]}`。
//
// 路径语义与浏览页一致：path 型盘存绝对路径，id 型盘存目录 id
//（取「条目 path 非空且异于当前目录时用 path，否则用 id」）。

import 'dart:convert';

import '../core/application_logger.dart';
import '../core/secure_store.dart';

const String _kFolderSelKey = 'xianyu.cloud.folder_sel.v1';

String cloudFolderSelKey(String providerId, String accountId) =>
    '$providerId|$accountId';

class CloudFolderSelectionStore {
  CloudFolderSelectionStore._();

  static final CloudFolderSelectionStore instance =
      CloudFolderSelectionStore._();

  Map<String, List<String>>? _cache;

  Future<Map<String, List<String>>> _ensureLoaded() async {
    if (_cache != null) return _cache!;
    final map = <String, List<String>>{};
    try {
      final stored = await SecureStore.read(_kFolderSelKey);
      if (stored != null && stored.isNotEmpty) {
        final raw = jsonDecode(stored) as Map<String, dynamic>;
        raw.forEach((k, v) {
          if (v is List) {
            map[k] = v.whereType<String>().toList();
          }
        });
      }
    } catch (e) {
      AppLog.warn('cloud', '网盘已选文件夹读取失败: $e');
    }
    _cache = map;
    return map;
  }

  Future<void> _persist() async {
    final map = _cache;
    if (map == null) return;
    try {
      await SecureStore.write(_kFolderSelKey, jsonEncode(map));
    } catch (e) {
      AppLog.warn('cloud', '网盘已选文件夹写入失败: $e');
    }
  }

  /// 某账号已选文件夹路径列表（未选过返回空）。
  Future<List<String>> pathsFor(String providerId, String accountId) async {
    final map = await _ensureLoaded();
    return map[cloudFolderSelKey(providerId, accountId)] ?? const [];
  }

  /// 覆盖写入某账号的已选列表（空列表 = 清空，键也会移除）。
  Future<void> setPaths(
    String providerId,
    String accountId,
    List<String> paths,
  ) async {
    final map = await _ensureLoaded();
    final k = cloudFolderSelKey(providerId, accountId);
    if (paths.isEmpty) {
      map.remove(k);
    } else {
      map[k] = paths.toList();
    }
    await _persist();
  }
}
