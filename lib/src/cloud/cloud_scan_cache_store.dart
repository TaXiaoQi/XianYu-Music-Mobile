// 网盘页全量扫描结果落盘缓存（每 provider|account 一条），对应移动端
// 反馈「网盘第一次扫完之后关闭软件再次进入就空了，需要重新扫」——全量
// 遍历是几十上百次 listDir 往返，重启即丢不可接受。路径/文件 JSON 非敏感
// （不含凭据），明文 SecureStore：key `xianyu.cloud.scan_cache.v1`，
// 结构 `{"<providerId>|<accountId>": {"savedAt": ..., "files": [...]}}`，
// TTL 24h，超时或文件夹勾选变更后重扫。单条目超限截断，写盘失败降级内存。

import 'dart:convert';

import '../core/application_logger.dart';
import '../core/secure_store.dart';
import 'cloud_types.dart';

const String _kScanCacheKey = 'xianyu.cloud.scan_cache.v1';

/// 缓存有效期：超过后视为过期，重新全量扫描。
const Duration _scanCacheTtl = Duration(hours: 24);

/// 单条目最多缓存文件数：防极端大网盘撑爆存储。
const int _scanCacheMaxFiles = 8000;

String cloudScanCacheEntryKey(String providerId, String accountId) =>
    '$providerId|$accountId';

class CachedScan {
  CachedScan(this.savedAt, this.files);

  final DateTime savedAt;
  final List<CloudFile> files;
}

class CloudScanCacheStore {
  CloudScanCacheStore._();

  static final CloudScanCacheStore instance = CloudScanCacheStore._();

  Map<String, CachedScan>? _cache;

  Future<Map<String, CachedScan>> _ensureLoaded() async {
    if (_cache != null) return _cache!;
    final map = <String, CachedScan>{};
    try {
      final stored = await SecureStore.read(_kScanCacheKey);
      if (stored != null && stored.isNotEmpty) {
        final raw = jsonDecode(stored) as Map<String, dynamic>;
        raw.forEach((k, v) {
          if (v is! Map) return;
          final savedAtMs = v['savedAt'];
          final filesRaw = v['files'];
          if (savedAtMs is! num || filesRaw is! List) return;
          final files = filesRaw
              .whereType<Map>()
              .map((f) => CloudFile.fromJson(Map<String, dynamic>.from(f)))
              .toList();
          map[k] = CachedScan(
            DateTime.fromMillisecondsSinceEpoch(savedAtMs.toInt()),
            files,
          );
        });
      }
    } catch (e) {
      AppLog.warn('cloud', '网盘扫描缓存读取失败: $e');
    }
    _cache = map;
    return map;
  }

  Future<void> _persist() async {
    final map = _cache;
    if (map == null) return;
    try {
      final json = jsonEncode({
        for (final e in map.entries)
          e.key: {
            'savedAt': e.value.savedAt.millisecondsSinceEpoch,
            'files': e.value.files.map((f) => f.toJson()).toList(),
          },
      });
      await SecureStore.write(_kScanCacheKey, json);
    } catch (e) {
      // 超出存储限额：丢弃 savedAt 最旧的条目后重试一次
      final keys = map.keys.toList();
      if (keys.length > 1) {
        var oldestKey = keys.first;
        for (final k in keys) {
          if (map[k]!.savedAt.isBefore(map[oldestKey]!.savedAt)) {
            oldestKey = k;
          }
        }
        map.remove(oldestKey);
        await _persist();
      }
    }
  }

  /// 读取未过期的缓存；过期/缺失返回 null（并顺手清掉过期条目）。
  Future<CachedScan?> loadFresh(String providerId, String accountId) async {
    final map = await _ensureLoaded();
    final hit = map[cloudScanCacheEntryKey(providerId, accountId)];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.savedAt) > _scanCacheTtl) {
      map.remove(cloudScanCacheEntryKey(providerId, accountId));
      await _persist();
      return null;
    }
    return hit;
  }

  /// 保存扫描结果（超过单条上限时截断）。
  Future<void> save(
    String providerId,
    String accountId,
    List<CloudFile> files,
  ) async {
    final map = await _ensureLoaded();
    map[cloudScanCacheEntryKey(providerId, accountId)] = CachedScan(
      DateTime.now(),
      files.length > _scanCacheMaxFiles
          ? files.sublist(0, _scanCacheMaxFiles)
          : files,
    );
    await _persist();
  }

  /// 文件夹勾选变更/解绑后清理对应条目；accountId 为空时清该盘全部账号。
  Future<void> invalidate(String providerId, {String? accountId}) async {
    final map = await _ensureLoaded();
    final prefix = '$providerId|';
    if (accountId != null) {
      map.remove(cloudScanCacheEntryKey(providerId, accountId));
    } else {
      map.removeWhere((k, _) => k.startsWith(prefix));
    }
    await _persist();
  }
}
