// 123 云盘 provider（qrCode 主通道 + 账密兜底；分享免转存直链
// directPlayable=true）。
//
// 业务（列目录/分享/直链）经 cloud_remote 桥转发内嵌 Rust
// （rust/src/cloud/pan123.rs）。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class Pan123Provider extends CloudProvider {
  const Pan123Provider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  @override
  String get id => 'pan123';

  @override
  String get displayName => '123云盘';

  @override
  String get rootPath => '0';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.qrCode;

  @override
  Duration get directLinkTtl => const Duration(hours: 1);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'passport', label: '手机号 / 邮箱'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudQrLoginSession> createQrLogin() async {
    final resp = await cloudGet(
      'https://login.123pan.com/api/user/qr-code/generate',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) throw const CloudException('二维码获取失败');
    final data = resp.json['data'];
    if (data is! Map<String, dynamic>) throw const CloudException('二维码获取失败');
    final qr = (data['qr'] ?? '').toString();
    final uniId = (data['uniID'] ?? '').toString();
    if (qr.isEmpty || uniId.isEmpty) throw const CloudException('二维码获取失败');
    return CloudQrLoginSession(qrContent: qr, state: uniId);
  }

  @override
  Future<CloudAccount?> pollQrLogin(CloudQrLoginSession session) async {
    final resp = await cloudGet(
      'https://login.123pan.com/api/user/qr-code/result'
      '?uniID=${Uri.encodeQueryComponent(session.state)}',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) return null;
    final data = resp.json['data'];
    if (data is! Map<String, dynamic>) return null;
    final status = (data['status'] as num?)?.toInt() ?? 0;
    if (status != 2) return null; // 未确认。
    final token = (data['token'] ?? data['accessToken'] ?? '').toString();
    if (token.isEmpty) throw const CloudException('二维码已过期，请刷新');
    final user = data['user'];
    final uid = user is Map<String, dynamic>
        ? (user['id'] ?? '').toString()
        : '';
    final nick = user is Map<String, dynamic>
        ? ((user['nickname'] ?? user['Passport'] ?? '').toString())
        : '';
    return CloudAccount(
      provider: id,
      accountId: uid.isEmpty ? md5Hex(token).substring(0, 12) : uid,
      nickname: nick.isEmpty ? '123云盘' : nick,
      cred: {'token': token},
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final passport = (fields['passport'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (passport.isEmpty || password.isEmpty) {
      throw const CloudException('请填写账号和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final resp = await cloudPostJson(
        'https://user.123pan.cn/api/user/sign_in',
        body: {
          'passport': passport,
          'password': password,
          'remember': true,
        },
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
      );
      final code = (resp.json['code'] as num?)?.toInt() ?? -1;
      if (code != 200) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException((resp.json['message'] ?? '账号或密码错误').toString());
      }
      final token =
          ((resp.json['data'] as Map<String, dynamic>)['token'] ?? '')
              .toString();
      if (token.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录失败');
      }
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: md5Hex(token).substring(0, 12),
        nickname: passport,
        cred: {'token': token},
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
