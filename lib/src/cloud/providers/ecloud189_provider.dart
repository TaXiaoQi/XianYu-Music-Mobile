// 天翼云盘（189）provider（smsPassword：账密 + 设备短信二次校验）。
//
// 现役登录链（2026-10 实测，对齐 web 前端 v5.0）：
//   1. GET cloud.189.cn/api/portal/loginUrl.action —— 302 跳链逐跳采
//      Cookie，落点 open.e.189.cn 登录页 URL 携带 lt / reqId / appId；
//   2. POST appConf.do（version 2.0 + appKey）→ pageKey/paramId/returnUrl
//      等页面参数（initData）；
//   3. POST encryptConf.do（appId）→ pre 前缀 + pubKey（base64 SPKI）；
//   4. POST loginSubmit.do —— 账密 RSA-PKCS1（hex）+ pre 前缀，密码字段
//      名为 epd，returnUrl 需 encodeURIComponent；result 0 直接过，
//      result -133「设备ID不存在」为新客户端强制设备短信二次校验：
//      用响应里的加密 mobile 调 sendSmsCodeForSecondAuth.do 发码，用户
//      填码后 submitForSecondAuth.do（验证码放 epd 字段）→ toUrl 换会话。
// 老协议（paramId 空 + password 字段 + ssKey）已全面失效（-20099/-149）。
// 业务（列目录/分享/转存/直链）经 cloud_remote 桥转发内嵌 Rust。

import 'dart:convert' show jsonEncode;
import 'dart:io' show HttpHeaders;

import '../../core/app_http.dart' show sharedHttpClient, validateHop;
import '../../core/application_logger.dart';
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class Ecloud189Provider extends CloudProvider {
  const Ecloud189Provider();

  /// 设备二次校验暂存：username → 会话（cookie jar + 会话参数）。
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
      ];

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final username = (fields['username'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const CloudException('请填写手机号和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final account = await _passwordLogin(username, password);
      HttpLoginGate.instance.recordSuccess(id);
      return account;
    } on CloudSmsRequiredException {
      // 已自动发码并暂存会话；UI 弹窗收码后走 submitSmsCode。
      rethrow;
    } on CloudException {
      HttpLoginGate.instance.recordFailure(id);
      rethrow;
    } catch (_) {
      HttpLoginGate.instance.recordFailure(id);
      throw const CloudException('账号或密码错误');
    }
  }

  /// 提交设备二次校验验证码（UI 收到 [CloudSmsRequiredException] 后调用）。
  @override
  Future<CloudAccount> submitSmsCode(String username, String smsCode) async {
    final pending = _pendingSms[username];
    if (pending == null) {
      throw const CloudException('登录会话已失效，请重新登录');
    }
    try {
      final account = await _submitDeviceAuth(pending, smsCode);
      HttpLoginGate.instance.recordSuccess(id);
      return account;
    } on CloudException {
      HttpLoginGate.instance.recordFailure(id);
      rethrow;
    }
  }

  /// 重发设备校验验证码（UI 弹窗「发送验证码」按钮调用）。
  @override
  Future<void> resendDeviceSms(String username) async {
    final pending = _pendingSms[username];
    if (pending == null) {
      throw const CloudException('登录会话已失效，请重新登录');
    }
    await _sendDeviceSms(pending);
  }

  /// 现役账密登录全链；要求设备短信二次校验时暂存会话，发码由 UI 手动触发。
  Future<CloudAccount> _passwordLogin(
      String username, String password) async {
    // 1. loginUrl.action：302 跳链逐跳采 Cookie，落点取 lt/reqId/appId。
    final entry = await _openLoginPage();
    final jar = entry.jar;
    final hdr = _sessionHeaders(entry);
    // 2. appConf → 页面参数（initData）。
    final confResp = await cloudPostForm(
      'https://open.e.189.cn/api/logbox/oauth2/appConf.do',
      {'version': '2.0', 'appKey': entry.appId},
      headers: {...hdr, 'Cookie': cookieHeader(jar)},
    );
    if (!confResp.isOk) throw const CloudException('登录服务不可用');
    final acd = (confResp.json['data'] as Map<String, dynamic>?) ?? const {};
    if (acd.isEmpty) throw const CloudException('登录服务不可用');
    jar.addAll(confResp.setCookiePairs);
    // 3. encryptConf → pre 前缀 + pubKey（base64 SPKI）。
    final ecResp = await cloudPostForm(
      'https://open.e.189.cn/api/logbox/config/encryptConf.do',
      {'appId': entry.appId},
      headers: {...hdr, 'Cookie': cookieHeader(jar)},
    );
    if (!ecResp.isOk) throw const CloudException('登录服务不可用');
    final ecd = (ecResp.json['data'] as Map<String, dynamic>?) ?? const {};
    final pre = (ecd['pre'] ?? '{RSA}').toString();
    final pubKey = (ecd['pubKey'] ?? '').toString();
    if (pubKey.isEmpty) throw const CloudException('登录服务不可用');
    jar.addAll(ecResp.setCookiePairs);
    final (modHex, expHex) = parseSpki(pubKey);
    // 4. loginSubmit（现役字段：密码字段名 epd，RSA hex，returnUrl 编码）。
    final resp = await cloudPostForm(
      'https://open.e.189.cn/api/logbox/oauth2/loginSubmit.do',
      {
        'version': 'v2.0',
        'apToken': '',
        'appKey': (acd['appKey'] ?? entry.appId).toString(),
        'pageKey': (acd['pageKey'] ?? '').toString(),
        'accountType': (acd['accountType'] ?? '01').toString(),
        'userName': pre + rsaPkcs1Hex(username, modHex, expHex),
        'epd': pre + rsaPkcs1Hex(password, modHex, expHex),
        'captchaType': '',
        'validateCode': '',
        'smsValidateCode': '',
        'captchaToken': '',
        'returnUrl': Uri.encodeComponent((acd['returnUrl'] ?? '').toString()),
        'mailSuffix': (acd['mailSuffix'] ?? '@189.cn').toString(),
        'dynamicCheck': 'FALSE',
        'clientType': (acd['clientType'] ?? 100).toString(),
        'cb_SaveName': '3',
        'isOauth2': (acd['isOauth2'] ?? true).toString().toLowerCase(),
        'state': (acd['state'] ?? '').toString(),
        'paramId': (acd['paramId'] ?? '').toString(),
      },
      headers: {...hdr, 'Cookie': cookieHeader(jar)},
    );
    jar.addAll(resp.setCookiePairs);
    if (!resp.isOk) throw const CloudException('登录失败');
    final body = resp.json;
    // 临时诊断：登录提交响应（含 lt/落点/会话摘要，便于对齐风控差异）。
    AppLog.debug('cloud',
        'ecloud189 loginSubmit status=${resp.status} body=${jsonEncode(body).substring(0, body.toString().length < 400 ? jsonEncode(body).length : 400)} lt=${entry.lt.length} cookies=${jar.keys.join(',')}');
    final result = (body['result'] as num?)?.toInt() ?? -1;
    final toUrl = (body['toUrl'] ?? '').toString();
    // 新客户端强制设备短信二次校验：用加密 mobile 发码并暂存会话。
    if (result == -133) {
      final mobileEnc = (body['mobile'] ?? '').toString();
      if (mobileEnc.isEmpty) {
        throw CloudException((body['msg'] ?? '需要设备验证').toString());
      }
      final session = _SmsSession(
        jar: jar,
        loginUrl: entry.loginUrl,
        lt: entry.lt,
        reqId: entry.reqId,
        appId: entry.appId,
        mobileEnc: mobileEnc,
        appKey: (acd['appKey'] ?? entry.appId).toString(),
        accountType: (acd['accountType'] ?? '01').toString(),
        returnUrl: (acd['returnUrl'] ?? '').toString(),
        isOauth2: (acd['isOauth2'] ?? true).toString().toLowerCase(),
        state: (acd['state'] ?? '').toString(),
        paramId: (acd['paramId'] ?? '').toString(),
        pre: pre,
        modHex: modHex,
        expHex: expHex,
        username: username,
      );
      _pendingSms[username] = session;
      // 不自动发码：由 UI 弹窗内的「发送验证码」按钮手动触发 resendDeviceSms。
      throw CloudSmsRequiredException(username);
    }
    if (result != 0) {
      throw CloudException((body['msg'] ?? '账号或密码错误').toString());
    }
    // 5. toUrl 换 PC 会话（302 跳转链，逐跳采 Cookie）。
    final cookie = await _exchangePortalSession(jar, toUrl);
    // accountId 固定取手机号：userId 仅部分响应携带，导致同号重复建账。
    return CloudAccount(
      provider: id,
      accountId: username,
      nickname: username,
      cred: {'cookie': cookie},
      boundAt: DateTime.now(),
    );
  }

  /// loginUrl.action 跳链：逐跳 GET 采 Cookie，落点 URL 带 lt/reqId/appId。
  Future<_LoginEntry> _openLoginPage() async {
    var url = 'https://cloud.189.cn/api/portal/loginUrl.action'
        '?redirectURL=https%3A%2F%2Fcloud.189.cn%2Fmain.action';
    final jar = <String, String>{};
    var last = url;
    for (var hop = 0; hop < 8; hop++) {
      last = url;
      final loc = await _hopGet(url, jar, 'https://cloud.189.cn/');
      if (loc == null || loc.isEmpty) break;
      url = Uri.parse(url).resolve(loc).toString();
    }
    final uri = Uri.parse(last);
    final lt = uri.queryParameters['lt'] ?? '';
    final reqId = uri.queryParameters['reqId'] ?? '';
    final appId = uri.queryParameters['appId'] ?? '';
    if (lt.isEmpty || reqId.isEmpty) {
      throw const CloudException('登录服务不可用');
    }
    // 临时诊断：跳链落点与采集到的会话 Cookie。
    AppLog.debug('cloud',
        'ecloud189 openLogin final=${last.length > 120 ? last.substring(0, 120) : last} cookies=${jar.keys.join(',')}');
    return _LoginEntry(
      jar: jar,
      loginUrl: last,
      lt: lt,
      reqId: reqId,
      appId: appId,
    );
  }

  Map<String, String> _sessionHeaders(_LoginEntry entry) => {
        'User-Agent': _ua,
        'lt': entry.lt,
        'reqid': entry.reqId,
        'Referer': entry.loginUrl,
        'Origin': 'https://open.e.189.cn',
      };

  /// 设备二次校验发码：mobile 用登录响应返回的加密串。
  Future<void> _sendDeviceSms(_SmsSession s) async {
    final resp = await cloudPostForm(
      'https://open.e.189.cn/api/logbox/oauth2/sendSmsCodeForSecondAuth.do',
      {'mobile': s.mobileEnc, 'appKey': s.appKey},
      headers: {
        ..._sessionHeadersOf(s),
        'Cookie': cookieHeader(s.jar),
      },
    );
    if (!resp.isOk) throw const CloudException('验证码发送失败');
    final result = (resp.json['result'] as num?)?.toInt() ?? -1;
    // 临时诊断：发码响应。
    AppLog.debug('cloud',
        'ecloud189 sendSms result=$result body=${jsonEncode(resp.json).length > 200 ? jsonEncode(resp.json).substring(0, 200) : jsonEncode(resp.json)} mobileLen=${s.mobileEnc.length} ltLen=${s.lt.length}');
    if (result != 0) {
      throw CloudException(
          (resp.json['msg'] ?? '验证码发送失败').toString());
    }
  }

  /// 设备二次校验提交：验证码放 epd（RSA hex + pre 前缀）。
  Future<CloudAccount> _submitDeviceAuth(
      _SmsSession s, String smsCode) async {
    final resp = await cloudPostForm(
      'https://open.e.189.cn/api/logbox/oauth2/submitForSecondAuth.do',
      {
        'mobile': s.mobileEnc,
        'appKey': s.appKey,
        'userName': s.pre + rsaPkcs1Hex(s.username, s.modHex, s.expHex),
        'epd': s.pre + rsaPkcs1Hex(smsCode, s.modHex, s.expHex),
        'accountType': s.accountType,
        'returnUrl': Uri.encodeComponent(s.returnUrl),
        'isOauth2': s.isOauth2,
        'cb_SaveName': '3',
        'state': s.state,
        'paramId': s.paramId,
      },
      headers: {
        ..._sessionHeadersOf(s),
        'Cookie': cookieHeader(s.jar),
      },
    );
    if (!resp.isOk) throw const CloudException('验证码校验失败');
    final body = resp.json;
    final result = (body['result'] as num?)?.toInt() ?? -1;
    if (result != 0) {
      throw CloudException((body['msg'] ?? '验证码错误').toString());
    }
    _pendingSms.remove(s.username);
    final toUrl = (body['toUrl'] ?? '').toString();
    final cookie = await _exchangePortalSession(s.jar, toUrl);
    // accountId 固定取手机号，与账密直登路径保持一致（防重复建账）。
    return CloudAccount(
      provider: id,
      accountId: s.username,
      nickname: s.username,
      cred: {'cookie': cookie},
      boundAt: DateTime.now(),
    );
  }

  Map<String, String> _sessionHeadersOf(_SmsSession s) => {
        'User-Agent': _ua,
        'lt': s.lt,
        'reqid': s.reqId,
        'Referer': s.loginUrl,
        'Origin': 'https://open.e.189.cn',
      };

  /// 逐跳 GET：只采 Set-Cookie 与 Location，不跟随。
  Future<String?> _hopGet(
      String url, Map<String, String> jar, String referer) async {
    final uri = Uri.parse(url);
    await validateHop(uri, false);
    final client = sharedHttpClient;
    final req = await client.openUrl('GET', uri);
    req.headers.set(HttpHeaders.userAgentHeader, _ua);
    req.headers.set(HttpHeaders.refererHeader, referer);
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
    return resp.headers.value(HttpHeaders.locationHeader);
  }

  /// portal 会话交换：302 跳转链上每跳都可能下发新 Cookie，
  /// appRequest 手动重定向只暴露最终跳的响应头，这里逐跳采。
  Future<String> _exchangePortalSession(
      Map<String, String> jar, String returnUrl) async {
    if (returnUrl.isEmpty) return cookieHeader(jar);
    var url = returnUrl;
    for (var hop = 0; hop < 8; hop++) {
      final loc = await _hopGet(url, jar, 'https://cloud.189.cn/');
      if (loc == null || loc.isEmpty) break;
      url = Uri.parse(url).resolve(loc).toString();
    }
    return cookieHeader(jar);
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

class _LoginEntry {
  const _LoginEntry({
    required this.jar,
    required this.loginUrl,
    required this.lt,
    required this.reqId,
    required this.appId,
  });

  final Map<String, String> jar;
  final String loginUrl;
  final String lt;
  final String reqId;
  final String appId;
}

class _SmsSession {
  const _SmsSession({
    required this.jar,
    required this.loginUrl,
    required this.lt,
    required this.reqId,
    required this.appId,
    required this.mobileEnc,
    required this.appKey,
    required this.accountType,
    required this.returnUrl,
    required this.isOauth2,
    required this.state,
    required this.paramId,
    required this.pre,
    required this.modHex,
    required this.expHex,
    required this.username,
  });

  final Map<String, String> jar;
  final String loginUrl;
  final String lt;
  final String reqId;
  final String appId;
  final String mobileEnc;
  final String appKey;
  final String accountType;
  final String returnUrl;
  final String isOauth2;
  final String state;
  final String paramId;
  final String pre;
  final String modHex;
  final String expHex;
  final String username;
}
