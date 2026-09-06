import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// 插件用户变量 AES 加解密。
///
/// 与桌面端 `pluginSync.ts` 保持完全一致：
/// - AES-256-CBC + PKCS7
/// - 密钥 = SHA-256(弦予号)，任意端登录同一账号即可互相解密
/// - 明文为 `Map<String,String>` 的 JSON 串
/// - 密文块结构 `{iv, data}` 均为 Base64，服务端仅作密文存储载体不解密。
abstract class PluginUserVarCrypto {
  static List<int> _key(String ciyuanxiId) =>
      sha256.convert(utf8.encode(ciyuanxiId)).bytes;

  /// 加密用户变量；失败返回 null（调用方选择跳过，不影响插件本身上传）。
  static Map<String, dynamic>? encrypt(
      String ciyuanxiId, Map<String, String> values) {
    try {
      final key = enc.Key(Uint8List.fromList(_key(ciyuanxiId)));
      final iv = enc.IV.fromSecureRandom(16);
      final encrypter =
          enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      final ct = encrypter.encrypt(jsonEncode(values), iv: iv);
      return {'iv': iv.base64, 'data': ct.base64};
    } catch (_) {
      return null;
    }
  }

  /// 解密用户变量；block 缺失或解密失败返回 null。
  static Map<String, String>? decrypt(
      String ciyuanxiId, Map<String, dynamic>? block) {
    if (block == null) return null;
    try {
      final ivB64 = block['iv'] as String?;
      final dataB64 = block['data'] as String?;
      if (ivB64 == null || dataB64 == null) return null;
      final key = enc.Key(Uint8List.fromList(_key(ciyuanxiId)));
      final iv = enc.IV.fromBase64(ivB64);
      final encrypter =
          enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      final pt = encrypter.decrypt(enc.Encrypted.fromBase64(dataB64), iv: iv);
      final json = jsonDecode(pt);
      if (json is Map) {
        return json.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }
    } catch (_) {}
    return null;
  }
}