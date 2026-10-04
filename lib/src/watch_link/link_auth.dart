// 蓝牙链路应用层鉴权（两端同构）：
// 蓝牙层认证的是配对设备的 MAC，同一手机上任意持 BLUETOOTH_CONNECT
// 权限的应用都可连本服务的 RFCOMM 通道——链路建立后先用共享密钥做
// HMAC-SHA256 挑战-应答，未通过前丢弃全部业务帧（fail-closed）。
// 密钥 32B base64 存 SecureStore；手表是密钥唯一授予方（授予仅限
// 用户手动发起），手机端只采纳 grant、从不生成。

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/secure_store.dart';

const String kLinkPairSecretKey = 'link.pairSecret.v1';

/// 鉴权超时：链路建立后 10s 内未完成挑战-应答即判死。
const Duration kLinkAuthTimeout = Duration(seconds: 10);

/// 生成 32B 配对密钥（base64）。
String generatePairSecret() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  return base64Encode(bytes);
}

/// 生成 16B 随机 nonce（hex）。
String randomNonceHex() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 计算 HMAC-SHA256(key=密钥原始字节, msg=nonceHex) 的 hex 证明。
String authProofHex({
  required String nonceHex,
  required String secretBase64,
}) {
  final key = base64Decode(secretBase64);
  final msg = utf8.encode(nonceHex);
  return Hmac(sha256, key).convert(msg).toString();
}

/// 常数时间比较校验证明；密钥/nonce 为空或密钥长度异常返回 false。
bool verifyAuthProof({
  required String nonceHex,
  required String secretBase64,
  required String proofHex,
}) {
  if (nonceHex.isEmpty || proofHex.isEmpty) return false;
  List<int> key;
  try {
    key = base64Decode(secretBase64);
  } catch (_) {
    return false;
  }
  if (key.length != 32) return false;
  final expect = authProofHex(nonceHex: nonceHex, secretBase64: secretBase64);
  if (expect.length != proofHex.length) return false;
  var diff = 0;
  for (var i = 0; i < expect.length; i++) {
    diff |= expect.codeUnitAt(i) ^ proofHex.codeUnitAt(i);
  }
  return diff == 0;
}

/// 读取配对密钥；缺失或损坏（非 32B）按无密钥处理。
Future<String?> readPairSecret() async {
  final raw = await SecureStore.read(kLinkPairSecretKey);
  if (raw == null || raw.isEmpty) return null;
  try {
    if (base64Decode(raw).length != 32) return null;
  } catch (_) {
    return null;
  }
  return raw;
}

/// 覆盖写入配对密钥。
Future<void> writePairSecret(String secretBase64) =>
    SecureStore.write(kLinkPairSecretKey, secretBase64);
