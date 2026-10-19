// 网盘已选文件夹存储（每账号多路径）。
//
// 路径不是敏感数据，直接明文 SecureStore JSON：
// key `xianyu.cloud.folder_sel.v1`，结构
// `{"<providerId>|<accountId>": [path, ...]}`。
//
// 路径语义与浏览页一致：path 型盘存绝对路径，id 型盘存目录 id
//（取「条目 path 非空且异于当前目录时用 path，否则用 id」）。

import 'dart:convert';

import 'package:collection/collection.dart';

import '../core/application_logger.dart';
import '../core/secure_store.dart';
import 'cloud_credentials_store.dart';

const String _kFolderSelKey = 'xianyu.cloud.folder_sel.v1';

String cloudFolderSelKey(String providerId, String accountId) =>
    '$providerId|$accountId';

/// 已选目录的名称缓存（纯展示用）：id 型盘的存储键是目录 id 串，重进
/// 选择器或浏览到其他目录时无法从键还原可读名，chip 只能显示原始 id
///（观感即乱码）。勾选/浏览命中时写入，展示按面包屑栈 → 当前列表 →
/// 此缓存 回退。随凭据密封串跨设备同步（`__fnames__` 保留键，不参与
/// 变更时钟，仅随勾选变更的载荷顺带上传）；本地浏览命中仍会回填，
/// 兜住旧版设备发来的无名称同步串。
class CloudFolderNameCache {
  CloudFolderNameCache._();

  static final CloudFolderNameCache instance = CloudFolderNameCache._();

  static const String _kNamesKey = 'xianyu.cloud.folder_names.v1';

  Map<String, Map<String, String>>? _cache;

  Future<Map<String, Map<String, String>>> _ensureLoaded() async {
    if (_cache != null) return _cache!;
    final map = <String, Map<String, String>>{};
    try {
      final stored = await SecureStore.read(_kNamesKey);
      if (stored != null && stored.isNotEmpty) {
        final raw = jsonDecode(stored) as Map<String, dynamic>;
        raw.forEach((k, v) {
          if (v is Map) {
            map[k] = v.map((kk, vv) => MapEntry('$kk', '$vv'));
          }
        });
      }
    } catch (e) {
      AppLog.warn('cloud', '网盘已选目录名称缓存读取失败: $e');
    }
    _cache = map;
    return map;
  }

  Future<void> _persist() async {
    final map = _cache;
    if (map == null) return;
    try {
      await SecureStore.write(_kNamesKey, jsonEncode(map));
    } catch (e) {
      AppLog.warn('cloud', '网盘已选目录名称缓存写入失败: $e');
    }
  }

  /// 某账号的已选目录名称表（未记录返回空）。
  Future<Map<String, String>> namesFor(
    String providerId,
    String accountId,
  ) async {
    final map = await _ensureLoaded();
    return map[cloudFolderSelKey(providerId, accountId)] ?? const {};
  }

  /// 合并写入（覆盖同名键，跳过无变化），有新条目才落盘。
  Future<void> remember(
    String providerId,
    String accountId,
    Map<String, String> entries,
  ) async {
    if (entries.isEmpty) return;
    final map = await _ensureLoaded();
    final k = cloudFolderSelKey(providerId, accountId);
    final bucket = map[k] ??= <String, String>{};
    var added = false;
    entries.forEach((key, name) {
      if (key.isEmpty || name.isEmpty) return;
      if (bucket[key] != name) {
        bucket[key] = name;
        added = true;
      }
    });
    if (!added) return;
    await _persist();
  }

  /// 全量导出（跨设备同步随凭据密封串携带）。
  Future<Map<String, Map<String, String>>> allNames() async {
    final map = await _ensureLoaded();
    if (map.isEmpty) return const {};
    return map.map((k, v) => MapEntry(k, Map<String, String>.of(v)));
  }

  /// 云端较新时的整体替换（v2 同步专用），与目录选择同生命周期：
  /// 设备侧取消勾选传播时名称一并清理。返回是否发生变化。
  Future<bool> replaceAllNames(
    Map<String, Map<String, String>> incoming,
  ) async {
    final map = await _ensureLoaded();
    final normalized = <String, Map<String, String>>{
      for (final e in incoming.entries)
        if (e.key.isNotEmpty)
          e.key: {
            for (final f in e.value.entries)
              if (f.key.isNotEmpty && f.value.isNotEmpty) f.key: f.value,
          },
    }..removeWhere((k, v) => v.isEmpty);
    final same = map.length == normalized.length &&
        map.entries.every((e) => const MapEquality<String, String>()
            .equals(normalized[e.key] ?? const {}, e.value));
    if (same) return false;
    _cache = normalized;
    await _persist();
    return true;
  }

  /// 旧格式同步串（无时间戳）回退：并集合并。返回是否发生变化。
  Future<bool> mergeNames(Map<String, Map<String, String>> incoming) async {
    if (incoming.isEmpty) return false;
    final map = await _ensureLoaded();
    var changed = false;
    incoming.forEach((k, v) {
      if (k.isEmpty || v.isEmpty) return;
      final bucket = map[k] ??= <String, String>{};
      v.forEach((key, name) {
        if (key.isEmpty || name.isEmpty) return;
        if (bucket[key] != name) {
          bucket[key] = name;
          changed = true;
        }
      });
    });
    if (!changed) return false;
    await _persist();
    return true;
  }
}

class CloudFolderSelectionStore {
  CloudFolderSelectionStore._();

  static final CloudFolderSelectionStore instance =
      CloudFolderSelectionStore._();

  /// 目录选择落盘后的变更通知（sync 层注册做云端自动上传；未注册时为
  /// no-op）。勾选/取消勾选/同步合并都会触发，回调内自行处理防抖。
  static void Function()? onPersisted;

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

  /// 全量导出（跨设备同步随凭据密封串携带）。
  Future<Map<String, List<String>>> allPaths() async {
    final map = await _ensureLoaded();
    return map.map((k, v) => MapEntry(k, List<String>.of(v)));
  }

  /// 合并云端目录选择（并集去重，不动本地已有条目）。
  /// 返回是否发生变化。旧格式同步串（无时间戳）回退用。
  /// 注意：空串路径是合法条目（id 型盘如迅雷/PikPak 根目录 id 为空串）。
  Future<bool> mergePaths(Map<String, List<String>> incoming) async {
    if (incoming.isEmpty) return false;
    final map = await _ensureLoaded();
    var changed = false;
    incoming.forEach((k, v) {
      final paths = v.whereType<String>().toList();
      if (paths.isEmpty) return;
      final merged = [...?map[k]];
      final before = merged.length;
      for (final p in paths) {
        if (!merged.contains(p)) merged.add(p);
      }
      if (merged.length != before) {
        map[k] = merged;
        changed = true;
      }
    });
    if (!changed) return false;
    await _persist();
    onPersisted?.call();
    return true;
  }

  /// 云端较新时的整体替换（v2 同步专用）。
  ///
  /// 取消勾选/清空要能跨设备传播，必须覆盖而非并集。返回是否发生变化；
  /// 无变化不落盘不通知（防止拉取→上传的同步风暴）。
  Future<bool> replaceAllPaths(Map<String, List<String>> incoming) async {
    final map = await _ensureLoaded();
    final normalized = <String, List<String>>{
      for (final e in incoming.entries)
        if (e.key.isNotEmpty) e.key: e.value.toSet().toList(),
    }..removeWhere((k, v) => v.isEmpty);
    final same = map.length == normalized.length &&
        map.entries.every((e) =>
            normalized.containsKey(e.key) &&
            const ListEquality<String>()
                .equals(normalized[e.key] ?? const [], e.value));
    if (same) return false;
    _cache = normalized;
    await _persist();
    onPersisted?.call();
    return true;
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
      if (!map.containsKey(k)) return;
      map.remove(k);
    } else {
      // 空串路径合法：id 型盘（迅雷/PikPak）根目录 id 为空串，
      // 消费方 listDir('') 即列根目录。仅全部为空才视为清空。
      final next = paths;
      if (const ListEquality<String>().equals(map[k] ?? const [], next)) {
        return;
      }
      if (next.isEmpty) {
        map.remove(k);
      } else {
        map[k] = next;
      }
    }
    await _persist();
    // 用户勾选变更并入共享同步时钟（凭据与目录选择同载荷上传）
    await CloudCredentialsStore.instance.noteLocalChange();
    onPersisted?.call();
  }
}
