// 蓝奏云 provider（httpPassword；分享免登录免转存直链
// directPlayable=true）。
//
// 业务（列目录/分享/直链）经 cloud_remote 桥转发内嵌 Rust
// （rust/src/cloud/lanzou.rs）。

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
      final resp = await cloudPostForm(
        'https://up.woozooo.com/mlogin.php',
        {
          'task': '3',
          'uid': username,
          'pwd': password,
          'authcode': '',
        },
        headers: {'User-Agent': _ua, 'Referer': 'https://up.woozooo.com/'},
      );
      if (!resp.isOk || !resp.body.contains('登录成功')) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('账号或密码错误');
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
