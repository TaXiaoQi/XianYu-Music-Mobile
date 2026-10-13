// 蓝奏云 provider（httpPassword；分享免登录免转存直链
// directPlayable=true）。
//
// 业务（列目录/分享/直链）经 cloud_remote 桥转发内嵌 Rust
// （rust/src/cloud/lanzou.rs）。

import 'dart:convert';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class LanzouProvider extends CloudProvider {
  const LanzouProvider();

  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 '
      'Safari/604.1';

  @override
  String get id => 'lanzou';

  @override
  String get displayName => '蓝奏云';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.httpPassword;

  @override
  Duration get directLinkTtl => const Duration(minutes: 20);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'username', label: '用户名'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  // ── 登录 ──────────────────────────────────────────────

  /// up.woozooo.com 前置阿里云盾 acw_sc__v2 挑战：无 Cookie 的请求一律
  /// 返回混淆 JS（含 arg1），算出 Cookie 重放才是真实接口。算法公开：
  /// arg1 按固定重排表换位，再与固定 key 逐字节异或。2026-10 实测。
  static const _acwKey =
      '3000176000856006061501533003690027800375';
  static const _acwOrder = [
    0x0f, 0x23, 0x1d, 0x18, 0x21, 0x10, 0x01, 0x26, 0x0a, 0x09, //
    0x13, 0x1f, 0x28, 0x1b, 0x16, 0x17, 0x19, 0x0d, 0x06, 0x0b, //
    0x27, 0x12, 0x14, 0x08, 0x0e, 0x15, 0x20, 0x1a, 0x02, 0x1e, //
    0x07, 0x04, 0x11, 0x05, 0x03, 0x1c, 0x22, 0x25, 0x0c, 0x24,
  ];

  static String? _acwArg(String body) =>
      RegExp(r"arg1='([0-9A-Fa-f]{30,60})'").firstMatch(body)?.group(1);

  static String _acwSolve(String arg1) {
    final q = List<String>.filled(_acwOrder.length, '');
    for (var x = 0; x < arg1.length; x++) {
      for (var z = 0; z < _acwOrder.length; z++) {
        if (_acwOrder[z] == x + 1) q[z] = arg1[x];
      }
    }
    final u = q.join();
    var v = '';
    for (var i = 0; i < u.length && i < _acwKey.length; i += 2) {
      final a = int.parse(u.substring(i, i + 2), radix: 16);
      final b = int.parse(_acwKey.substring(i, i + 2), radix: 16);
      var h = (a ^ b).toRadixString(16);
      if (h.length == 1) h = '0$h';
      v += h;
    }
    return v;
  }

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final username = (fields['username'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const CloudException('请填写账号和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final fieldsBody = {
        'task': '3',
        'uid': username,
        'pwd': password,
        'authcode': '',
      };
      var resp = await cloudPostForm(
        'https://up.woozooo.com/mlogin.php',
        fieldsBody,
        headers: {'User-Agent': _ua, 'Referer': 'https://up.woozooo.com/'},
      );
      // WAF 挑战页：解 acw_sc__v2 后重放一次。
      final arg1 = resp.isOk ? _acwArg(resp.body) : null;
      if (arg1 != null) {
        resp = await cloudPostForm(
          'https://up.woozooo.com/mlogin.php',
          fieldsBody,
          headers: {
            'User-Agent': _ua,
            'Referer': 'https://up.woozooo.com/',
            'Cookie': 'acw_sc__v2=${_acwSolve(arg1)}',
          },
        );
      }
      // 接口返回 JSON（中文为 \uXXXX 转义，不能 contains('登录成功')）。
      final failMsg = () {
        try {
          final j = jsonDecode(resp.body);
          if (j is Map<String, dynamic> && j['zt'] != 1) {
            final info = j['info']?.toString() ?? '';
            return info.isEmpty ? '登录失败' : info;
          }
        } catch (_) {}
        return null;
      }();
      if (!resp.isOk || failMsg != null) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException(failMsg ?? '登录失败，请稍后再试');
      }
      final ylogin = resp.setCookiePairs['ylogin'] ?? '';
      if (ylogin.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录失败');
      }
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: md5Hex(ylogin).substring(0, 12),
        nickname: username,
        cred: {'cookie': 'ylogin=$ylogin'},
        boundAt: DateTime.now(),
      );
    } on CloudException {
      rethrow;
    } catch (_) {
      HttpLoginGate.instance.recordFailure(id);
      throw const CloudException('登录失败，请稍后再试');
    }
  }

  // ── 业务（rust 桥转发）─────────────────────────────────

  @override
  Future<bool> validate(Map<String, String> cred) => rustValidate(id, cred);

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) =>
      rustListDir(id, cred, path, cursor: cursor);

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) =>
      rustParseShare(id, url, pwd);

  @override
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) =>
      rustShareDirectLink(id, cred, share, file);

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) =>
      rustTransferShare(id, cred, share);

  @override
  Future<CloudDirectLink> getDirectLink(
          Map<String, String> cred, CloudFile file) =>
      rustDirectLink(id, cred, file);
}
