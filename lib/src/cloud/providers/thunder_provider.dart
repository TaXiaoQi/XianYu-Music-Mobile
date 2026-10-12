// 迅雷云盘 provider（httpPassword：v3/login 账密接口，password 传 md5）。
//
// XCloud 架构（与 PikPak 同构）；业务（列目录/分享/转存/直链）经
// cloud_remote 桥转发内嵌 Rust（rust/src/cloud/thunder.rs）。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class ThunderProvider extends CloudProvider {
  const ThunderProvider();

  static const _ua =
      'ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G '
      'appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC '
      'Oauth2Client/0.9';
  static const _clientId = 'Xq00jqW5m1PrHnV8';

  @override
  String get id => 'thunder';

  @override
  String get displayName => '迅雷云盘';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.httpPassword;

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'username', label: '手机号 / 邮箱'),
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
      final deviceId = uuidV4();
      final resp = await cloudPostJson(
        'https://xluser-ssl.xunlei.com/xluser.core.login/v3/login',
        body: {
          'client_id': _clientId,
          'action': 'login',
          'username': username,
          'password': md5Hex(password),
          'deviceid': deviceId,
        },
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
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
      final userId = (resp.json['sub'] ?? resp.json['user_id'] ?? '')
          .toString();
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: userId.isEmpty ? md5Hex(username).substring(0, 12) : userId,
        nickname: username,
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
