// 天翼云盘（189）provider（smsPassword：账密 + 短信二次验证）。
//
// logbox RSA 加密登录链；响应要求二次验证时自动发短信并暂存会话，
// 带验证码重登走 submitForSecondAuth → portal 换会话。portal
// loginUrl.action 换会话是 302 跳转链，appRequest 中间跳的 Set-Cookie
// 会被 drain 掉，故此段用逐跳采 Cookie 的 GET 循环自实现。

import 'dart:convert';
import 'dart:io' show HttpHeaders;

import '../../core/app_http.dart' show sharedHttpClient, validateHop;
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
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

  Map<String, String> _h(String cookie) => {
        'User-Agent': _ua,
        'Referer': 'https://cloud.189.cn/',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

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

  @override
  Future<bool> validate(Map<String, String> cred) async {
    try {
      final resp = await cloudGet(
        'https://cloud.189.cn/api/open/file/listFiles.action'
        '?folderId=-11&pageNum=1&pageSize=1',
        headers: _h(cred['cookie'] ?? ''),
      );
      return resp.isOk;
    } catch (_) {
      return false;
    }
  }

  // ── 目录 ──────────────────────────────────────────────

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) async {
    final page = int.tryParse(cursor ?? '') ?? 1;
    final resp = await cloudGet(
      'https://cloud.189.cn/api/open/file/listFiles.action'
      '?folderId=${Uri.encodeQueryComponent(path)}'
      '&pageNum=$page&pageSize=60',
      headers: _h(cred['cookie'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final data = resp.json['data'];
    final ao = data is Map<String, dynamic>
        ? data['fileListAO'] as Map<String, dynamic>?
        : null;
    final list = (ao?['fileList'] as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['id'] ?? '').toString(),
        name: (e['name'] ?? '').toString(),
        isDir: e['dir'] == true || e['isdir'] == true,
        size: (e['size'] as num?)?.toInt() ?? 0,
        parentId: path,
      ));
    }
    final hasNext = files.length >= 60;
    return CloudListResult(
      files: files,
      nextCursor: hasNext ? '${page + 1}' : null,
    );
  }

  // ── 分享 ──────────────────────────────────────────────

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final shareCode = info?.shareId ?? url;
    final headers = {'User-Agent': _ua};
    final infoResp = await cloudGet(
      'https://cloud.189.cn/api/open/share/getShareInfoByCodeV2.action'
      '?shareCode=${Uri.encodeQueryComponent(shareCode)}',
      headers: headers,
    );
    if (!infoResp.isOk) throw const CloudException('分享链接解析失败');
    final data = infoResp.json['data'];
    if (data is! Map<String, dynamic>) throw const CloudException('分享已失效');
    final shareId = (data['shareId'] ?? '').toString();
    var fileId = (data['fileId'] ?? '-1').toString();
    final isDir = data['isDir'] == true || data['isDir'] == 1;
    // 有提取码：checkAccessCode 校验。
    if (pwd != null && pwd.isNotEmpty) {
      final chk = await cloudPostForm(
        'https://cloud.189.cn/api/open/share/checkAccessCode.action',
        {
          'shareCode': shareCode,
          'accessCode': pwd,
        },
        headers: headers,
      );
      if (!chk.isOk) throw const CloudException('提取码错误');
    }
    var files = <CloudFile>[];
    if (!isDir) {
      files = [
        CloudFile(
          id: fileId,
          name: (data['fileName'] ?? '').toString(),
          size: (data['fileSize'] as num?)?.toInt() ?? 0,
        ),
      ];
    } else {
      final listResp = await cloudGet(
        'https://cloud.189.cn/api/open/share/listShareDir.action'
        '?shareId=${Uri.encodeQueryComponent(shareId)}'
        '&fileId=${Uri.encodeQueryComponent(fileId)}'
        '&pageNum=1&pageSize=60',
        headers: headers,
      );
      if (!listResp.isOk) throw const CloudException('分享文件列表获取失败');
      final ldata = listResp.json['data'];
      final entries = ldata is Map<String, dynamic>
          ? (ldata['fileShareResponseInfos'] as List?) ?? const []
          : const [];
      for (final e in entries) {
        if (e is! Map<String, dynamic>) continue;
        files.add(CloudFile(
          id: (e['fileId'] ?? '').toString(),
          name: (e['fileName'] ?? '').toString(),
          isDir: e['isDir'] == true || e['isDir'] == 1,
          size: (e['fileSize'] as num?)?.toInt() ?? 0,
        ));
      }
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: shareId,
      passcode: pwd,
      directPlayable: false,
    );
  }

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    final headers = {
      'User-Agent': _ua,
      'Cookie': cred['cookie'] ?? '',
    };
    final resp = await cloudPostForm(
      'https://cloud.189.cn/api/open/share/createBatchTask.action',
      {
        'type': 'SHARE_SAVE',
        'taskInfos': jsonEncode(share.files
            .map((f) => {
                  'fileId': f.id,
                  'fileName': f.name,
                  'isDir': f.isDir,
                  'shareId': share.shareId,
                })
            .toList()),
        'targetFolderId': '-11',
      },
      headers: headers,
    );
    if (!resp.isOk) throw const CloudException('转存失败');
    final taskId =
        ((resp.json['data'] as Map<String, dynamic>)['taskId'] ?? '')
            .toString();
    if (taskId.isEmpty) throw const CloudException('转存失败');
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final tResp = await cloudGet(
        'https://cloud.189.cn/api/open/batch/checkBatchTask.action'
        '?taskId=${Uri.encodeQueryComponent(taskId)}',
        headers: headers,
      );
      if (!tResp.isOk) continue;
      final state =
          ((tResp.json['data'] as Map<String, dynamic>)['taskStatus'])
              ?.toString();
      if (state == '2') {
        return share.files;
      }
    }
    throw const CloudException('转存失败');
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final resp = await cloudGet(
      'https://cloud.189.cn/api/open/file/getFileDownloadUrl.action'
      '?fileId=${Uri.encodeQueryComponent(file.id)}',
      headers: _h(cred['cookie'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final url =
        ((resp.json['data'] as Map<String, dynamic>)['fileDownloadUrl'] ?? '')
            .toString();
    if (url.isEmpty) throw const CloudException('直链获取失败');
    final finalUrl = await resolveFinalUrl(url, headers: {'User-Agent': _ua});
    return CloudDirectLink(
      url: finalUrl,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }
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
