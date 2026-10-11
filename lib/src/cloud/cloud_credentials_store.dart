// 网盘凭据本地加密存储。
//
// 复刻 secure_store.dart 的 sealToken 模式：凭据 JSON → AES-256-CBC
// 加密（`xy1:<iv>:<密文>` 前缀格式）→ SecureStore。AES 密钥独立于登录
// token 密钥（`xianyu.cloud.aes_key.v1`），密钥丢失时按未绑定处理。
//
// 结构 `{providerId: [CloudAccount]}`（每盘多账号，为二期服务端同步留位）。
// exportForSync/importFromSync 供二期增量接入。

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';

import '../core/application_logger.dart';
import '../core/secure_store.dart';
import 'cloud_types.dart';

const String _kCloudCredsKey = 'xianyu.cloud.creds.v1';
const String _kCloudAesKey = 'xianyu.cloud.aes_key.v1';
const String _kCloudSealPrefix = 'xy1:';

class CloudCredentialsStore {
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
    _cache = map;
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
  Future<void> saveAccount(CloudAccount account) async {
    final map = await _ensureLoaded();
    final list = [...?map[account.provider]];
    final idx = list.indexWhere((a) => a.accountId == account.accountId);
    if (idx >= 0) {
      list[idx] = account;
    } else {
      list.add(account);
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
  Future<String?> exportForSync(String ciyuanxiId) async {
    final map = await _ensureLoaded();
    if (map.isEmpty) return null;
    final json =
        jsonEncode(map.map((k, v) => MapEntry(k, v.map((a) => a.toJson()).toList())));
    return _sealWithKey(json, _syncKey(ciyuanxiId));
  }

  /// 二期同步：导入跨设备密封串（与导出格式一致，指纹去重合并）。
  Future<void> importFromSync(String sealed, String ciyuanxiId) async {
    final plain = _unsealWithKey(sealed, _syncKey(ciyuanxiId));
    if (plain == null) throw const CloudException('同步凭据解密失败');
    final raw = jsonDecode(plain) as Map<String, dynamic>;
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
