// PikPak provider（httpPassword：signin 账密接口，password 传 md5）。
//
// XCloud 架构（与迅雷同构）；业务（列目录/分享/转存/直链）经
// cloud_remote 桥转发内嵌 Rust（rust/src/cloud/pikpak.rs）。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class PikpakProvider extends CloudProvider {
  const PikpakProvider();

  static const _ua = 'ANDROID-com.pikcloud.pikpak/1.47.1';
  static const _clientId = 'YNxT9w7GMdWvEOKa';

  @override
  String get id => 'pikpak';

  @override
  String get displayName => 'PikPak';

  // 接口域 user.mypikpak.com 直连不可用（需代理），下架绑定入口；
  // 分享链接导入等其余能力保留。
  @override
  bool get bindable => false;

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.httpPassword;

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'username', label: '邮箱'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final email = (fields['username'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (email.isEmpty || password.isEmpty) {
      throw const CloudException('请填写邮箱和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final resp = await cloudPostJson(
        'https://user.mypikpak.com/v1/auth/signin?client_id=$_clientId',
        body: {
          'username': email,
          'password': md5Hex(password),
          'client_id': _clientId,
        },
        headers: {
          'User-Agent': _ua,
          'Content-Type': 'application/json',
          'x-device-id': uuidV4(),
        },
      );
      if (!resp.isOk) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录失败');
      }
      final accessToken = (resp.json['access_token'] ?? '').toString();
      final refreshToken = (resp.json['refresh_token'] ?? '').toString();
      if (accessToken.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException(
            (resp.json['error_description'] ?? resp.json['error'] ?? '账号或密码错误')
                .toString());
      }
      final userId = (resp.json['sub'] ?? '').toString();
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: userId.isEmpty ? md5Hex(email).substring(0, 12) : userId,
        nickname: email,
        cred: {
          'accessToken': accessToken,
          'refreshToken': refreshToken,
          'userId': userId,
        },
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
  bool get supportsSearch => true;

  @override
  Future<CloudListResult> searchFiles(
    Map<String, String> cred,
    String keyword, {
    String? cursor,
  }) =>
      rustSearchFiles(id, cred, keyword, cursor: cursor);

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) =>
      rustParseShare(id, url, pwd);

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
