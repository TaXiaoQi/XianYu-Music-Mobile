// HTTP 账密登录支撑：登录限频 + 失败指数退避（风控），以及各盘通用
// 加密小工具（md5 / uuid / 天翼 RSA-PKCS1）。
//
// 使用约定：loginWithFields 实现入口先 `gate.ensureAllowed(id)`，请求
// 前后 `recordAttempt` / `recordSuccess|recordFailure`。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../cloud_types.dart';

class HttpLoginGate {
  HttpLoginGate._();

  static final HttpLoginGate instance = HttpLoginGate._();

  /// 同盘两次登录尝试最小间隔。
  static const _minInterval = Duration(seconds: 30);

  /// 失败退避上限。
  static const _maxBackoff = Duration(minutes: 10);

  final _lastAttempt = <String, DateTime>{};
  final _failCount = <String, int>{};

  /// 登录尝试前调用；处于限频/退避期直接抛 CloudException。
  void ensureAllowed(String providerId) {
    final last = _lastAttempt[providerId];
    if (last == null) return;
    final wait = _waitDuration(providerId, last);
    if (wait > Duration.zero) {
      throw CloudException('操作过于频繁，请 ${wait.inSeconds + 1} 秒后再试');
    }
  }

  void recordAttempt(String providerId) =>
      _lastAttempt[providerId] = DateTime.now();

  void recordFailure(String providerId) =>
      _failCount[providerId] = (_failCount[providerId] ?? 0) + 1;

  void recordSuccess(String providerId) {
    _failCount.remove(providerId);
    _lastAttempt.remove(providerId);
  }

  Duration _waitDuration(String providerId, DateTime last) {
    final fails = _failCount[providerId] ?? 0;
    final shift = fails > 4 ? 4 : fails; // 30s * 2^n，封顶 10 分钟
    var backoff = _minInterval * (1 << shift);
    if (backoff > _maxBackoff) backoff = _maxBackoff;
    final elapsed = DateTime.now().difference(last);
    final remain = backoff - elapsed;
    return remain.isNegative ? Duration.zero : remain;
  }
}

String md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

/// 随机 UUID v4（小写，带连字符）。多盘设备指纹/请求 id 用。
String uuidV4() {
  final r = Random.secure();
  String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${hex(8)}-${hex(4)}-4${hex(3)}-'
      '${['8', '9', 'a', 'b'][r.nextInt(4)]}${hex(3)}-${hex(12)}';
}

/// 天翼 logbox RSA 公钥加密（PKCS#1 v1.5，hex 输出）。
String rsaPkcs1Hex(String plain, String modulusHex, String exponentHex) {
  final n = BigInt.parse(modulusHex, radix: 16);
  final e = BigInt.parse(exponentHex, radix: 16);
  final cipher = PKCS1Encoding(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(RSAPublicKey(n, e)));
  final out = cipher.process(Uint8List.fromList(utf8.encode(plain)));
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
