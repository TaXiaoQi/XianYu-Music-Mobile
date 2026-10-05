// 平台安全存储（Android Keystore / iOS Keychain / 鸿蒙 HUKS）轻封装。
// 敏感凭据（登录 token 加密密钥、桌面联动 token）不再明文落盘：
// 三平台均走真安全存储——鸿蒙由 vendored 插件
// third_party/flutter_secure_storage_ohos 提供原生实现（官方主包经同名
// MethodChannel 直连）；仅在安全存储不可用（插件缺失等异常场景）时
// 回退 SharedPreferences 同名键（安全等级降为混淆）。

import 'dart:convert';

import 'package:encrypt/encrypt.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecureStore {
  SecureStore._();

  static const _storage = FlutterSecureStorage();

  /// 读取。安全存储不可用时回退 SharedPreferences 同名键。
  ///
  /// [legacyPrefsKey] 非空时执行一次性迁移：读取旧键值写入安全存储后
  /// 删除旧键（仅安全存储可用时执行）。
  static Future<String?> read(String key, {String? legacyPrefsKey}) async {
    var secureBroken = false;
    try {
      final value = await _storage.read(key: key);
      if (value != null) return value;
    } catch (_) {
      secureBroken = true;
    }
    // 安全存储无值或不可用：读回退键。此前 write 失败可能已把值落到
    // prefs（如 Keystore 偶发故障），读取侧必须同样回退，否则该值
    // 永远读不出来——表现为密钥每次启动重新生成、加密凭据解不开。
    final prefs = await SharedPreferences.getInstance();
    final fallback = prefs.getString(key);
    if (fallback != null && fallback.isNotEmpty) {
      if (!secureBroken) {
        // 安全存储可用：迁回安全存储后清掉明文回退键
        try {
          await _storage.write(key: key, value: fallback);
          await prefs.remove(key);
        } catch (_) {
          return fallback;
        }
      }
      return fallback;
    }
    if (legacyPrefsKey != null) {
      final legacy = prefs.getString(legacyPrefsKey);
      if (legacy != null && legacy.isNotEmpty) {
        if (!secureBroken) {
          try {
            await _storage.write(key: key, value: legacy);
            await prefs.remove(legacyPrefsKey);
          } catch (_) {
            return legacy;
          }
        }
        return legacy;
      }
    }
    return null;
  }

  /// 写入。安全存储不可用时回退 SharedPreferences 同名键。
  static Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  /// 删除（同时清理安全存储与回退/旧键位置）。
  static Future<void> delete(String key, {String? legacyPrefsKey}) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    if (legacyPrefsKey != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(legacyPrefsKey);
    }
  }
}

// ── 登录 token 加密落盘 ─────────────────────────────────
//
// Rust 侧凭据文件（auth-token.txt）里不再存明文 token：写入前先以
// 安全存储保管的 AES-256 密钥加密（`xy1:<iv>:<密文>` 前缀格式），
// 密钥在 Keystore/Keychain 中，文件泄露无法直接还原 token。

const String kTokenSealPrefix = 'xy1:';
const String _kTokenAesKey = 'xianyu.auth.token_aes_key.v1';

/// 加密 token，返回 `xy1:<iv>:<密文>`。
Future<String> sealToken(String plain) async {
  final key = await _loadTokenAesKey();
  final iv = IV.fromSecureRandom(16);
  final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
  final cipher = encrypter.encryptBytes(utf8.encode(plain), iv: iv);
  return '$kTokenSealPrefix${iv.base64}:${cipher.base64}';
}

/// 解开 [sealToken] 的密文。
///
/// - 无 `xy1:` 前缀：旧版明文 token，原样返回（调用方负责重新加密迁移）。
/// - 前缀格式但解密失败（密钥丢失/密文损坏）：返回 null，按未登录处理。
Future<String?> unsealToken(String stored) async {
  if (!stored.startsWith(kTokenSealPrefix)) return stored;
  final parts = stored.substring(kTokenSealPrefix.length).split(':');
  if (parts.length != 2) return null;
  try {
    final key = await _loadTokenAesKey();
    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
    return encrypter
        .decrypt(Encrypted.fromBase64(parts[1]), iv: IV.fromBase64(parts[0]));
  } catch (_) {
    return null;
  }
}

Future<Key> _loadTokenAesKey() async {
  final stored = await SecureStore.read(_kTokenAesKey);
  if (stored != null && stored.isNotEmpty) return Key.fromBase64(stored);
  final key = Key.fromSecureRandom(32);
  await SecureStore.write(_kTokenAesKey, key.base64);
  return key;
}
