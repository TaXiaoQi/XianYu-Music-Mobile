// 天翼云盘（189）provider（smsPassword：账密 + 短信二次验证）。
//
// 登录链：logbox RSA 加密登录；响应要求二次验证时自动发短信并暂存
// 会话，带验证码重登走 submitForSecondAuth → portal 换会话。portal
// loginUrl.action 换会话是 302 跳转链，appRequest 中间跳的 Set-Cookie
// 会被 drain 掉，故此段用逐跳采 Cookie 的 GET 循环自实现。
// 业务（列目录/分享/转存/直链）经 cloud_remote 桥转发内嵌 Rust。

import 'dart:io' show HttpHeaders;

import '../../core/app_http.dart' show sharedHttpClient, validateHop;
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class Ecloud189Provider extends CloudProvider {
  const Ecloud189Provider();

  /// 二次验证暂存：username → 会话（cookies + ssKey）。
  static final Map<String, _SmsSession> _pendingSms = {};

  @override
  String get id => 'ecloud189';

  @override
  String get displayName => '天翼云盘';

  @override
  String get rootPath => '-11';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.smsPassword;

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'username', label: '手机号', isPhone: true),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
        CloudLoginField(key: 'smsCode', label: '短信验证码', isSmsCode: true),
      ];

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final username = (fields['username'] ?? '').trim();
    final password = fields['password'] ?? '';
    final smsCode = (fields['smsCode'] ?? '').trim();
    if (username.isEmpty || password.isEmpty) {
      throw const CloudException('请填写手机号和密码');
    }
    // 带验证码的第二次尝试：走二次验证通道。
    final pending = _pendingSms[username];
    if (pending != null) {
      if (smsCode.isEmpty) {
        throw const CloudException('请填写短信验证码');
      }
      return _submitSmsSecondAuth(pending, smsCode);
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final account = await _passwordLogin(username, password);
      HttpLoginGate.instance.recordSuccess(id);
      return account;
    } on _NeedSmsException {
      // 自动发短信验证码，等待用户填码重试（不计入失败退避）。
      throw const CloudException('短信验证码已发送，请填写后重试');
    } on CloudException {
      HttpLoginGate.instance.recordFailure(id);
      rethrow;
    } catch (_) {
      HttpLoginGate.instance.recordFailure(id);
      throw const CloudException('账号或密码错误');
    }
  }

  Future<CloudAccount> _passwordLogin(
      String username, String password) async {
    // 1. 取 RSA 公钥参数。
    final confResp = await cloudGet(
      'https://open.e.189.cn/api/logbox/config/encryptConf.do',
      headers: {'User-Agent': _ua},
    );
    if (!confResp.isOk) throw const CloudException('登录服务不可用');
    final conf = confResp.json['data'];
    if (conf is! Map<String, dynamic>) throw const CloudException('登录服务不可用');
    final pubKey = (conf['pubKey'] ?? '').toString();
    final pre = (conf['pre'] ?? '').toString();
    if (pubKey.isEmpty) throw const CloudException('登录服务不可用');
    // 2. RSA 加密账密提交。
    final jar = <String, String>{...confResp.setCookiePairs};
    final loginResp = await cloudPostForm(
      'https://open.e.189.cn/api/logbox/oauth2/loginSubmit.do',
      {
        'version': '2.0',
        'appKey': 'cloud',
        'accountType': '01',
        'userName': rsaPkcs1Hex(pre + username, pubKey, '10001'),
        'password': rsaPkcs1Hex(pre + password, pubKey, '10001'),
        'paramId': '',
        'returnUrl': '',
        'mailSuffix': '@189.cn',
      },
      headers: {
        'User-Agent': _ua,
        'Referer': 'https://open.e.189.cn/',
        'Cookie': cookieHeader(jar),
      },
    );
    _mergeSetCookies(jar, loginResp);
    if (!loginResp.isOk) throw const CloudException('登录失败');
    final body = loginResp.json;
    final result = (body['result'] as num?)?.toInt() ?? -1;
    // 需要短信二次验证：自动发码并暂存会话。
    final ssKey = (body['data'] is Map<String, dynamic>
            ? (body['data'] as Map<String, dynamic>)['setToken']
            : null)
        ?.toString();
    if (result == 1001 || result == 1002) {
      final session = _SmsSession(cookies: jar, ssKey: ssKey ?? '');
      _pendingSms[username] = session;
      await _sendSms(session);
      throw _NeedSmsException();
    }
    if (result != 0) {
      throw CloudException(
          (body['msg'] ?? '账号或密码错误').toString());
    }
    // 3. 换 PC 会话（302 跳转链，逐跳采 Cookie）。
    final returnUrl = (body['toUrl'] ?? '').toString();
    final cookie = await _exchangePortalSession(jar, returnUrl);
    final userId = (body['userId'] ?? username).toString();
    return CloudAccount(
      provider: id,
      accountId: userId,
      nickname: username,
      cred: {'cookie': cookie},
      boundAt: DateTime.now(),
    );
  }

  Future<void> _sendSms(_SmsSession session) async {
    await cloudPostForm(
      'https://open.e.189.cn/api/logbox/oauth2/sendSmsCodeForSecondAuth.do',
      {'ssKey': session.ssKey},
      headers: {
        'User-Agent': _ua,
        'Referer': 'https://open.e.189.cn/',
        'Cookie': cookieHeader(session.cookies),
      },
    );
  }

  Future<CloudAccount> _submitSmsSecondAuth(
      _SmsSession session, String smsCode) async {
    final resp = await cloudPostForm(
      'https://open.e.189.cn/api/logbox/oauth2/submitForSecondAuth.do',
      {'ssKey': session.ssKey, 'smsCode': smsCode},
      headers: {
        'User-Agent': _ua,
        'Referer': 'https://open.e.189.cn/',
        'Cookie': cookieHeader(session.cookies),
      },
    );
    if (!resp.isOk) throw const CloudException('验证码校验失败');
    final body = resp.json;
    final result = (body['result'] as num?)?.toInt() ?? -1;
    if (result != 0) {
      throw CloudException((body['msg'] ?? '验证码错误').toString());
    }
    _mergeSetCookies(session.cookies, resp);
    final returnUrl = (body['toUrl'] ?? '').toString();
    final cookie = await _exchangePortalSession(session.cookies, returnUrl);
    return CloudAccount(
      provider: id,
      accountId: '189',
      nickname: '天翼账号',
      cred: {'cookie': cookie},
      boundAt: DateTime.now(),
    );
  }

  /// portal 会话交换：302 跳转链上每跳都可能下发新 Cookie，
  /// appRequest 手动重定向只暴露最终跳的响应头，这里逐跳采。
  Future<String> _exchangePortalSession(
      Map<String, String> jar, String returnUrl) async {
    if (returnUrl.isEmpty) return cookieHeader(jar);
    var url = returnUrl;
    final client = sharedHttpClient;
    for (var hop = 0; hop < 8; hop++) {
      final uri = Uri.parse(url);
      await validateHop(uri, false);
      final req = await client.openUrl('GET', uri);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      req.headers.set(HttpHeaders.refererHeader, 'https://cloud.189.cn/');
      final cookieStr = cookieHeader(jar);
      if (cookieStr.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, cookieStr);
      }
      req.followRedirects = false;
      final resp = await req.close();
      resp.headers.forEach((name, values) {
        if (name.toLowerCase() == 'set-cookie') {
          for (final raw in values) {
            final head = raw.split(';').first;
            final eq = head.indexOf('=');
            if (eq <= 0) continue;
            jar[head.substring(0, eq).trim()] = head.substring(eq + 1).trim();
          }
        }
      });
      await resp.drain<void>().catchError((_) {});
      final loc = resp.headers.value(HttpHeaders.locationHeader);
      if (loc == null || loc.isEmpty) break;
      url = uri.resolve(loc).toString();
    }
    return cookieHeader(jar);
  }

  void _mergeSetCookies(Map<String, String> jar, CloudHttpResponse resp) {
    jar.addAll(resp.setCookiePairs);
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

/// 登录响应要求二次验证的内部信号。
class _NeedSmsException implements Exception {
  const _NeedSmsException();
}

class _SmsSession {
  const _SmsSession({required this.cookies, required this.ssKey});

  final Map<String, String> cookies;
  final String ssKey;
}
