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

/// 本地同步时钟（changeAt/syncedAt，epoch ms）。凭据与目录选择同载荷同步，
/// 两者的本地变更统一记在这里。
const String _kCloudSyncMetaKey = 'xianyu.cloud.creds.sync_meta.v1';

/// 密封串保留键：本地变更时刻。云端较新才应用（整体替换），本地较新跳过
/// 下发——防止轮换类盘（阿里 refresh_token 单次有效）新凭据被旧包打回。
/// 旧版客户端只认 List 值会自动忽略该键，新旧双向兼容。
const String _kTsSyncKey = '__ts__';

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

  /// 是否已绑定任意网盘账号（同步缓存：凭据首读后有效，绑定/解绑即刷新）。
  /// 识曲入口等同步 UI 判定用；监听本 store 变更即可跟随刷新。
  bool get hasAnyBound => _hasAnyBound ?? false;
  bool? _hasAnyBound;

  /// 同步时钟：本地最近变更时刻（null = 安装后从未变更）。
  int? _changeAt;

  /// 同步时钟：最近一次与云端对齐的时刻（上传成功或下载应用后写入）。
  int? _syncedAt;

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
    _hasAnyBound = map.isNotEmpty;
    await _loadMeta();
    // 首读广播：识曲入口等同步判定 UI 在凭据异步就绪后即时刷新
    notifyListeners();
    if (removed > 0) {
      AppLog.debug('cloud', '清理遗留兜底账号 $removed 条');
      await _persist();
    }
    return map;
  }

  Future<void> _loadMeta() async {
    if (_changeAt != null) return;
    try {
      final raw = await SecureStore.read(_kCloudSyncMetaKey);
      if (raw == null || raw.isEmpty) return;
      final meta = jsonDecode(raw) as Map<String, dynamic>;
      _changeAt = meta['changeAt'] is int ? meta['changeAt'] as int : null;
      _syncedAt = meta['syncedAt'] is int ? meta['syncedAt'] as int : null;
    } catch (e) {
      AppLog.warn('cloud', '同步时钟读取失败: $e');
    }
  }

  Future<void> _writeMeta() async {
    try {
      await SecureStore.write(
          _kCloudSyncMetaKey,
          jsonEncode({
            if (_changeAt != null) 'changeAt': _changeAt,
            if (_syncedAt != null) 'syncedAt': _syncedAt,
          }));
    } catch (e) {
      AppLog.warn('cloud', '同步时钟写入失败: $e');
    }
  }

  Future<void> _persist() async {
    final map = _cache;
    if (map == null) return;
    _hasAnyBound = map.isNotEmpty;
    _changeAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final json =
          jsonEncode(map.map((k, v) => MapEntry(k, v.map((a) => a.toJson()).toList())));
      await SecureStore.write(_kCloudCredsKey, await _seal(json));
    } catch (e) {
      AppLog.warn('cloud', '网盘凭据写入失败: $e');
    }
    await _writeMeta();
    // 本地状态已变化，无论写盘成败都通知 sync 层（由其决定是否上传）
    onPersisted?.call();
    // 变更通知（绑定页等监听者自动刷新；登录同步落盘后 UI 即时跟随）
    notifyListeners();
  }

  // ---- 同步时钟 API（sync 层专用）----

  /// 预热缓存与时钟（上传/下载判断前调用）。
  Future<void> ensureLoaded() => _ensureLoaded();

  /// 本地是否有待上传的变更（发生过变更且尚未与云端对齐）。
  bool get needsUpload => _changeAt != null && _changeAt != _syncedAt;

  /// 上传成功后对齐时钟。
  Future<void> markSynced() async {
    _syncedAt = _changeAt;
    await _writeMeta();
  }

  /// 目录选择等外部数据并入同一载荷：其本地变更统一记到本 store 时钟。
  Future<void> noteLocalChange() async {
    await _ensureLoaded();
    _changeAt = DateTime.now().millisecondsSinceEpoch;
    await _writeMeta();
  }

  /// 下载应用完成后对齐时钟（内容与云端一致，changeAt 不推到 now，
  /// 防止"拉取→上传→对端拉取"的同步风暴）。
  Future<void> alignSynced(int? cloudTs) async {
    if (cloudTs != null) _changeAt = cloudTs;
    _syncedAt = cloudTs;
    await _writeMeta();
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

  /// 导出跨设备密封串。
  ///
  /// 账号派生密钥（三端可互解，服务端无明文）重新密封本地凭据 JSON，
  /// 密文不出本类、本地落盘仍用设备密钥。密封明文顶层带 `__ts__` 变更
  /// 时刻，并附带保留键 `__fsel__` 携带目录选择，跨设备一并同步。
  ///
  /// 返回 null 仅限：从未变更过且无任何绑定（无话可说）。解绑全部后
  /// （changeAt 存在但无账号）会导出只含 `__ts__` 的空包，让解绑传播。
  Future<String?> exportForSync(String ciyuanxiId) async {
    final map = await _ensureLoaded();
    if (map.isEmpty && _changeAt == null) return null;
    final payload = <String, Object>{
      _kTsSyncKey: _changeAt ?? DateTime.now().millisecondsSinceEpoch,
      for (final e in map.entries)
        e.key: e.value.map((a) => a.toJson()).toList(),
    };
    final folderSel = await CloudFolderSelectionStore.instance.allPaths();
    if (folderSel.isNotEmpty) {
      payload[_kFolderSelSyncKey] = folderSel;
    }
    return _sealWithKey(jsonEncode(payload), _syncKey(ciyuanxiId));
  }

  /// 导入跨设备密封串（与导出格式一致）。
  ///
  /// 带时间戳的串（v2）：云端较新 → 账号与目录选择**整体替换**（解绑/
  /// 取消勾选可传播；无变化不落盘）；本地较新 → 跳过，返回 applied=false，
  /// 留给上传把本地推上去。不带时间戳的旧格式串回退并集合并（旧行为）。
  ///
  /// 返回 `(applied, changed)`：applied=是否应用了云端；changed=本地内容
  /// 是否实际变化。
  Future<({bool applied, bool changed})> importFromSync(
      String sealed, String ciyuanxiId) async {
    final plain = _unsealWithKey(sealed, _syncKey(ciyuanxiId));
    if (plain == null) throw const CloudException('同步凭据解密失败');
    final raw = jsonDecode(plain) as Map<String, dynamic>;
    final tsRaw = raw.remove(_kTsSyncKey);
    final cloudTs = tsRaw is int ? tsRaw : null;
    await _ensureLoaded();
    // 本地较新：跳过下发，防止云端旧包覆盖本地新凭据（轮换类盘致命）
    if (cloudTs != null && _changeAt != null && cloudTs < _changeAt!) {
      AppLog.debug('cloud', '网盘同步：本地较新($_changeAt)，跳过云端下发');
      return (applied: false, changed: false);
    }
    // 解析目录选择保留键
    final folderSelRaw = raw.remove(_kFolderSelSyncKey);
    var sel = const <String, List<String>>{};
    if (folderSelRaw is Map) {
      final parsed = <String, List<String>>{};
      folderSelRaw.forEach((k, v) {
        if (k is! String || k.isEmpty || v is! List) return;
        final paths = v.whereType<String>().where((p) => p.isNotEmpty).toList();
        if (paths.isNotEmpty) parsed[k] = paths;
      });
      sel = parsed;
    }
    // 解析账号表
    final incomingAccounts = <String, List<CloudAccount>>{};
    raw.forEach((k, v) {
      if (v is! List) return;
      incomingAccounts[k] = v
          .whereType<Map<String, dynamic>>()
          .map(CloudAccount.fromJson)
          .toList();
    });
    if (cloudTs != null) {
      // v2：整体替换，无变化不落盘
      final accountsChanged = _accountsJson(_cache ?? const {}) !=
          _accountsJson(incomingAccounts);
      final foldersChanged =
          await CloudFolderSelectionStore.instance.replaceAllPaths(sel);
      if (accountsChanged || foldersChanged) {
        _cache = incomingAccounts;
        _hasAnyBound = incomingAccounts.isNotEmpty;
        await _persist(); // 会把 changeAt 推到 now，下面立刻对齐回云端时钟
        await alignSynced(cloudTs);
      } else {
        await alignSynced(cloudTs);
      }
      AppLog.debug('cloud',
          '网盘同步：已应用云端(v2) 变更=${accountsChanged || foldersChanged}');
      return (applied: true, changed: accountsChanged || foldersChanged);
    }
    // 旧格式：并集合并（旧行为）；有变化留给上传推 v2，无变化视为已对齐
    var changed = false;
    if (sel.isNotEmpty) {
      changed = await CloudFolderSelectionStore.instance.mergePaths(sel);
    }
    final merged = _cache!;
    final before = _accountsJson(merged);
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
    final accountsChanged = before != _accountsJson(merged);
    if (accountsChanged || changed) {
      _cache = merged;
      _hasAnyBound = merged.isNotEmpty;
      await _persist();
    } else {
      await alignSynced(DateTime.now().millisecondsSinceEpoch);
    }
    return (applied: true, changed: accountsChanged || changed);
  }

  String _accountsJson(Map<String, List<CloudAccount>> map) => jsonEncode(
      Map.fromEntries(map.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key))
      ).map((k, v) => MapEntry(k, v.map((a) => a.toJson()).toList())));
}

// ── 账密登录提示（记住账号 / 记住密码）────────────────────────
//
// 会话失效重登场景：账号默认记住；密码仅在用户勾选「记住密码」后
// 保存，未勾选登录时顺带清除旧密码。数据经 sealToken 密封后入
// SecureStore，与网盘凭据同级别的本机加密落盘。

/// 单盘登录提示：account 恒存；password 非空 = 用户勾选了记住密码。
class CloudLoginHint {
  const CloudLoginHint({required this.account, this.password = ''});

  final String account;
  final String password;

  bool get rememberPassword => password.isNotEmpty;

  factory CloudLoginHint.fromJson(Map<String, dynamic> json) => CloudLoginHint(
        account: (json['account'] ?? '').toString(),
        password: (json['password'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'account': account, 'password': password};
}

class CloudLoginHintStore {
  CloudLoginHintStore._();

  static final CloudLoginHintStore instance = CloudLoginHintStore._();

  static const String _kHintKey = 'xianyu.cloud.login_hint.v1';

  Map<String, CloudLoginHint>? _cache;

  Future<Map<String, CloudLoginHint>> _ensureLoaded() async {
    final cached = _cache;
    if (cached != null) return cached;
    final map = <String, CloudLoginHint>{};
    try {
      final stored = await SecureStore.read(_kHintKey);
      final plain = stored == null ? null : await unsealToken(stored);
      if (plain != null && plain.isNotEmpty) {
        final raw = jsonDecode(plain) as Map<String, dynamic>;
        raw.forEach((k, v) {
          if (v is Map<String, dynamic>) map[k] = CloudLoginHint.fromJson(v);
        });
      }
    } catch (e) {
      AppLog.warn('cloud', '登录提示读取失败: $e');
    }
    return _cache = map;
  }

  /// 读取某盘登录提示（无则 null）。
  Future<CloudLoginHint?> hintFor(String providerId) async =>
      (await _ensureLoaded())[providerId];

  /// 登录成功后保存：账号恒记；勾选「记住密码」才存密码，未勾选则清空
  /// 已存密码（换号或取消勾选后不残留）。
  Future<void> save(String providerId, String account, String password,
      bool rememberPassword) async {
    final map = await _ensureLoaded();
    map[providerId] = CloudLoginHint(
      account: account,
      password: rememberPassword ? password : '',
    );
    try {
      final json = jsonEncode(map.map((k, v) => MapEntry(k, v.toJson())));
      await SecureStore.write(_kHintKey, await sealToken(json));
    } catch (e) {
      AppLog.warn('cloud', '登录提示写入失败: $e');
    }
  }
}
