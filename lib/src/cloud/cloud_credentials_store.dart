// 网盘凭据本地加密存储。
//
// 复刻 secure_store.dart 的 sealToken 模式：凭据 JSON → AES-256-CBC
// 加密（`xy1:<iv>:<密文>` 前缀格式）→ SecureStore。AES 密钥独立于登录
// token 密钥（`xianyu.cloud.aes_key.v1`），密钥丢失时按未绑定处理。
//
// 结构 `{providerId: [CloudAccount]}`（每盘多账号，为二期服务端同步留位）。
// exportForSync/importFromSync 供二期增量接入。

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' hide Key;

import '../core/application_logger.dart';
import '../core/secure_store.dart';
import 'cloud_folder_selection_store.dart';
import 'cloud_types.dart';

const String _kCloudCredsKey = 'xianyu.cloud.creds.v1';
const String _kCloudAesKey = 'xianyu.cloud.aes_key.v1';
const String _kCloudSealPrefix = 'xy1:';

/// 同步串保留键：随凭据密封串携带的目录选择（`providerId|accountId → [path]`）。
/// 旧版客户端导入时只认 List 值会自动忽略该键，新旧双向兼容。
const String _kFolderSelSyncKey = '__fsel__';

/// 遗留兜底账号 ID 形态：早期版本 accountId 取 md5(cookie/refreshToken)
/// 前 12 位 hex（每次登录都变，重复登录即产生重复账号）。现役账号 ID 均
/// 为服务端 uid 或昵称哈希（u_ 前缀）。
final RegExp _legacyIdRe = RegExp(r'^[0-9a-f]{12}$');

class CloudCredentialsStore extends ChangeNotifier {
  CloudCredentialsStore._();

  static final CloudCredentialsStore instance = CloudCredentialsStore._();

  /// 内存缓存；首读后有效。改动即回写落盘。
  Map<String, List<CloudAccount>>? _cache;
  Key? _key;

  /// 凭据落盘后的变更通知（sync 层注册做云端自动上传；未注册时为 no-op）。
  /// 绑定/解绑/凭据轮换都会触发，回调内自行处理登录态与防抖。
  static void Function()? onPersisted;

  Future<Key> _aesKey() async {
    final cached = _key;
    if (cached != null) return cached;
    final stored = await SecureStore.read(_kCloudAesKey);
    if (stored != null && stored.isNotEmpty) {
      return _key = Key.fromBase64(stored);
    }
    final key = Key.fromSecureRandom(32);
    await SecureStore.write(_kCloudAesKey, key.base64);
    return _key = key;
  }

  /// 跨设备同步密钥：sha256(`cloud_creds.v1:<ciyuanxiId>`)，与插件用户
  /// 变量同步（PluginUserVarCrypto）同款账号派生方式，同账号三端可互解。
  static Key _syncKey(String ciyuanxiId) => Key(Uint8List.fromList(
      sha256.convert(utf8.encode('cloud_creds.v1:$ciyuanxiId')).bytes));

  Future<String> _sealWithKey(String plain, Key key) async {
    final iv = IV.fromSecureRandom(16);
    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
    final cipher = encrypter.encryptBytes(utf8.encode(plain), iv: iv);
    return '$_kCloudSealPrefix${iv.base64}:${cipher.base64}';
  }

  Future<String> _seal(String plain) async =>
      _sealWithKey(plain, await _aesKey());

  /// 密钥就绪后同步解密；密文损坏/密钥不匹配返回 null。
  String? _unsealWithKey(String stored, Key key) {
    if (!stored.startsWith(_kCloudSealPrefix)) return null;
    final parts = stored.substring(_kCloudSealPrefix.length).split(':');
    if (parts.length != 2) return null;
    try {
      final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
      return encrypter.decrypt(
        Encrypted.fromBase64(parts[1]),
        iv: IV.fromBase64(parts[0]),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _unseal(String stored) async =>
      _unsealWithKey(stored, await _aesKey());

  Future<Map<String, List<CloudAccount>>> _ensureLoaded() async {
    if (_cache != null) return _cache!;
    final map = <String, List<CloudAccount>>{};
    try {
      final stored = await SecureStore.read(_kCloudCredsKey);
      final plain = stored == null ? null : await _unseal(stored);
      if (plain != null) {
        final raw = jsonDecode(plain) as Map<String, dynamic>;
        raw.forEach((k, v) {
          if (v is List) {
            map[k] = v
                .whereType<Map<String, dynamic>>()
                .map(CloudAccount.fromJson)
                .toList();
          }
        });
      }
    } catch (e) {
      AppLog.warn('cloud', '网盘凭据读取失败: $e');
    }
    // 遗留兜底账号清理：同盘存在稳定 ID 账号时，清除遗留 12 位裸 hex 条目
    //（旧版重复登录产生的重复账号）。只剩单条遗留时不清理（仍是有效绑定）。
    var removed = 0;
    map.forEach((k, list) {
      if (list.length <= 1) return;
      if (!list.any((a) => !_legacyIdRe.hasMatch(a.accountId))) return;
      final before = list.length;
      list.removeWhere((a) => _legacyIdRe.hasMatch(a.accountId));
      removed += before - list.length;
    });
    _cache = map;
    if (removed > 0) {
      AppLog.debug('cloud', '清理遗留兜底账号 $removed 条');
      await _persist();
    }
    return map;
  }

  Future<void> _persist() async {
    final map = _cache;
    if (map == null) return;
    try {
      final json =
          jsonEncode(map.map((k, v) => MapEntry(k, v.map((a) => a.toJson()).toList())));
      await SecureStore.write(_kCloudCredsKey, await _seal(json));
    } catch (e) {
      AppLog.warn('cloud', '网盘凭据写入失败: $e');
    }
    // 本地状态已变化，无论写盘成败都通知 sync 层（由其决定是否上传）
    onPersisted?.call();
    // 变更通知（绑定页等监听者自动刷新；登录同步落盘后 UI 即时跟随）
    notifyListeners();
  }

  Future<List<CloudAccount>> accountsFor(String providerId) async {
    final map = await _ensureLoaded();
    return map[providerId] ?? const [];
  }

  /// 按 accountId 取凭据；未绑定返回 null。
  Future<Map<String, String>?> credFor(
      String providerId, String accountId) async {
    final list = await accountsFor(providerId);
    for (final a in list) {
      if (a.accountId == accountId) return a.cred;
    }
    return null;
  }

  /// 单账号凭据便捷读取：该盘只绑了一个账号时直接用。
  Future<Map<String, String>?> soleCredFor(String providerId) async {
    final list = await accountsFor(providerId);
    if (list.isEmpty) return null;
    return list.first.cred;
  }

  /// 新增/更新账号（按 provider+accountId upsert）。
  ///
  /// 新账号为稳定 ID 时，顺带清除同盘遗留 12 位裸 hex 条目（旧版
  /// Cookie/refreshToken 哈希 ID，重复登录产生的重复账号）。
  Future<void> saveAccount(CloudAccount account) async {
    final map = await _ensureLoaded();
    final list = [...?map[account.provider]];
    final idx = list.indexWhere((a) => a.accountId == account.accountId);
    if (idx >= 0) {
      list[idx] = account;
    } else {
      list.add(account);
    }
    if (!_legacyIdRe.hasMatch(account.accountId)) {
      final before = list.length;
      list.removeWhere(
          (a) => a.accountId != account.accountId && _legacyIdRe.hasMatch(a.accountId));
      if (list.length != before) {
        AppLog.debug('cloud', '清理遗留兜底账号 ${before - list.length} 条');
      }
    }
    map[account.provider] = list;
    await _persist();
  }

  Future<void> removeAccount(String providerId, String accountId) async {
    final map = await _ensureLoaded();
    final list = [...?map[providerId]];
    list.removeWhere((a) => a.accountId == accountId);
    if (list.isEmpty) {
      map.remove(providerId);
    } else {
      map[providerId] = list;
    }
    await _persist();
  }

  /// 刷新已绑定账号的凭据（token 轮换类盘用，如阿里 refresh_token 单次有效）。
  Future<void> updateCred(
      String providerId, String accountId, Map<String, String> cred) async {
    final map = await _ensureLoaded();
    final list = [...?map[providerId]];
    final idx = list.indexWhere((a) => a.accountId == accountId);
    if (idx < 0) return;
    list[idx] = CloudAccount(
      provider: list[idx].provider,
      accountId: list[idx].accountId,
      nickname: list[idx].nickname,
      cred: cred,
      boundAt: list[idx].boundAt,
    );
    map[providerId] = list;
    await _persist();
  }

  /// 二期同步：导出跨设备密封串。
  ///
  /// 账号派生密钥（三端可互解，服务端无明文）重新密封本地凭据 JSON，
  /// 密文不出本类、本地落盘仍用设备密钥。未绑定任何盘返回 null。
  /// 密封明文附带保留键 `__fsel__` 携带目录选择，跨设备一并同步。
  Future<String?> exportForSync(String ciyuanxiId) async {
    final map = await _ensureLoaded();
    if (map.isEmpty) return null;
    final payload = <String, Object>{
      for (final e in map.entries)
        e.key: e.value.map((a) => a.toJson()).toList(),
    };
    final folderSel = await CloudFolderSelectionStore.instance.allPaths();
    if (folderSel.isNotEmpty) {
      payload[_kFolderSelSyncKey] = folderSel;
    }
    return _sealWithKey(jsonEncode(payload), _syncKey(ciyuanxiId));
  }

  /// 二期同步：导入跨设备密封串（与导出格式一致，指纹去重合并）。
  /// 保留键 `__fsel__` 的目录选择合并进本地目录选择存储。
  Future<void> importFromSync(String sealed, String ciyuanxiId) async {
    final plain = _unsealWithKey(sealed, _syncKey(ciyuanxiId));
    if (plain == null) throw const CloudException('同步凭据解密失败');
    final raw = jsonDecode(plain) as Map<String, dynamic>;
    final folderSelRaw = raw.remove(_kFolderSelSyncKey);
    if (folderSelRaw is Map) {
      final sel = <String, List<String>>{};
      folderSelRaw.forEach((k, v) {
        if (k is! String || k.isEmpty || v is! List) return;
        final paths = v.whereType<String>().where((p) => p.isNotEmpty).toList();
        if (paths.isNotEmpty) sel[k] = paths;
      });
      if (sel.isNotEmpty) {
        await CloudFolderSelectionStore.instance.mergePaths(sel);
      }
    }
    final merged = await _ensureLoaded();
    raw.forEach((k, v) {
      if (v is! List) return;
      final incoming = v
          .whereType<Map<String, dynamic>>()
          .map(CloudAccount.fromJson)
          .toList();
      final local = [...?merged[k]];
      for (final a in incoming) {
        final idx = local.indexWhere((x) => x.accountId == a.accountId);
        if (idx >= 0) {
          local[idx] = a;
        } else {
          local.add(a);
        }
      }
      merged[k] = local;
    });
    _cache = merged;
    await _persist();
  }
}
