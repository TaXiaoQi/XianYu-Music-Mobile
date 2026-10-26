// 移动云盘（139）provider（smsPassword 自绘短信登录 + webviewCookie
// 网页登录兜底，双通道；收码复用天翼同款公共弹窗）。
//
// 自绘短信通道（auth-rebuild 现役 API，2026-10 实测全链）：
//   ① POST /orchestration/auth-rebuild/key/v1.0/getRsaPublicKey —— 动态
//      RSA 公钥；前端随机 16 位 AESKey 经 RSA-PKCS1(base64) 放 mcloud-skey
//      header，服务端按 skey 无状态解密，会话可逐请求重建；
//   ② 业务 payload JSON → AES-128-ECB/PKCS7(base64) 包 encryptMsg；
//   ③ 短信登录（天翼同构弹窗范式）：表单提交开握手会话抛
//      CloudSmsRequiredException，弹窗内点「发送验证码」才发码
//      （getSmsVerifyCode{account,reqType:"1",mode:0}，服务端回传
//      random）→ 填码 submitSmsCode verifySmsCode{account,random,
//      verifyCode,recordID,reqType:"1",setCookie:0} → data.token；
//   ④ authorization = "Basic " + base64("pc:手机号:token")，与网页登录
//      同构，业务（rust 桥）零改动。
//   公共 headers：mcloud-sign = "ts,msgId,MD5(MD5(b64(encodeURIComponent(
//   body) 字符排序)) + MD5("ts:msgId"))大写"，mcloud-client=10701 等。
//   发码触发风控拼图时（mode != 0）提示走网页登录兜底。
//
// 网页登录通道（保留）：网页版 SPA 登录成功后：① 写 authorization Cookie
// （enCodeToken = "Basic " + btoa("pc:账号:token")）；② Vuex MCloudVM
// $store.state.auth 维护 accountPhone/token。pollScript 双路取值（Cookie
// 为主、MCloudVM 兜底）并严格校验 token ≥4 段 '|'，命中即自动完成——
// 登录前后 URL 同为 SPA 首页，无法按 URL 判定，manualDoneOnly 保留挡住
// 「有 Cookie 就算登录」的早采。业务凭据：authorization（裸 base64，无
// "Basic " 前缀）+ cookie（旧转存接口可选留档）。
//
// 分享走 outLink 免转存直链（directPlayable=true）；业务经 cloud_remote
// 桥转发内嵌 Rust（rust/src/cloud/mobile139.rs）。

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class Mobile139Provider extends CloudProvider {
  const Mobile139Provider();

  @override
  String get id => 'mobile139';

  @override
  String get displayName => '移动云盘';

  @override
  // hcy 根目录约定为 "/"（SPA 同款；传 "root" 实测回空列表）。
  String get rootPath => '/';

  @override
  // 自绘短信登录为主通道（官方网页登录面板第一 tab）；网页版 WebView
  // 登录（webviewCookie 捕获链）保留为兜底：登录页顶栏「网页登录」直达。
  CloudLoginKind get loginKind => CloudLoginKind.smsPassword;

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'phone', label: '手机号', isPhone: true),
        // 默认短信登录（发码+公共弹窗收码）；点切换展开服务密码框走
        // passPwd 通道，可随时切回。
        CloudLoginField(
          key: 'password',
          label: '服务密码',
          obscure: true,
          optional: true,
          switchLabel: '使用服务密码登录',
          collapseLabel: '使用短信验证码登录',
        ),
      ];

  @override
  // 直达网页版登录页：yun.139.com/w/ 的 SPA 路由 / 即登录页
  //（path:"/",name:"login"）。移动 UA 只会得到营销页 + mcloud://
  // 拉端深链接（WebView 报 ERR_UNKNOWN_URL_SCHEME），须用桌面 UA
  // 才出网页版登录。
  String get webviewLoginUrl => 'https://yun.139.com/w/#/';

  @override
  String get webviewUserAgent => CloudProvider.desktopWebviewUa;

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 全收（cookieNames 空 = 非空即采）留档旧转存接口；完成判定全权
        // 交给 pollScript（authorization Cookie 或 MCloudVM auth 状态）。
        cookieDomains: ['yun.139.com'],
        nativeCookies: true,
        manualDoneOnly: true,
        pollScript: r'''
(() => {
  try {
    var m = document.cookie.match(/(?:^|;\s*)authorization=([^;]*)/);
    if (m) {
      var v = String(m[1]);
      if (v.indexOf('Basic ') !== 0) {
        try { v = decodeURIComponent(v); } catch (e0) {}
      }
      if (okBasic(v)) return JSON.stringify({ auth: v });
    }
    var vm = window.MCloudVM;
    if (vm && vm.$store) {
      var a = vm.$store.state.auth || {};
      var ph = String(a.accountPhone || '');
      var tk = String(a.token || '');
      if (ph && tk && tk.split('|').length >= 4) {
        var b = 'Basic ' + btoa('pc:' + ph + ':' + tk);
        if (okBasic(b)) return JSON.stringify({ auth: b });
      }
    }
    return "";
  } catch (e) { return ""; }
  function okBasic(v) {
    if (!v || v.indexOf('Basic ') !== 0) return false;
    try {
      var dec = atob(v.substring(6));
      var seg = dec.split(':');
      return dec.indexOf('pc:') === 0 && seg.length >= 3 &&
             seg[2].split('|').length >= 4;
    } catch (e) { return false; }
  }
})()''',
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  /// 短信登录会话：AESKey + mcloud-skey header + 发码回传 random。
  /// 服务端按 skey 无状态解密（实测），验证码校验复用发码同会话最稳。
  static _SmsLoginSession? _pendingSession;

  /// 天翼同构弹窗范式：表单收手机号 + 服务密码（选填）。密码非空走
  /// passPwd 通道（permission/login，dycPwd = SHA1(密码) 大写）；留空
  /// 抛 [CloudSmsRequiredException] 打开公共收码弹窗，弹窗内点
  /// 「发送验证码」才真正发码（走 [resendDeviceSms]，所有手机号登录
  /// 盘统一交互）。
  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final phone = (fields['phone'] ?? '').trim();
    if (phone.length != 11) {
      throw const CloudException('请输入 11 位手机号');
    }
    final password = (fields['password'] ?? '').trim();
    if (password.isNotEmpty) {
      return _loginByServicePassword(phone, password);
    }
    HttpLoginGate.instance.ensureAllowed(id);
    final sess = await _openSession();
    // 会话先行（加密握手可复用），发码推迟到弹窗「发送验证码」；
    // random 由发码响应回填（submitSmsCode 前必经 resendDeviceSms）。
    _pendingSession = sess..phone = phone;
    throw CloudSmsRequiredException(phone, hint: '验证码将发送至 $phone');
  }

  /// 服务密码登录：auth-rebuild permission/login passPwd 通道
  /// （dycPwd = SHA1(服务密码) 大写，实测参数形态服务端认可）。
  Future<CloudAccount> _loginByServicePassword(
    String phone,
    String password,
  ) async {
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    final sess = await _openSession();
    try {
      final dycPwd = sha1.convert(utf8.encode(password)).toString().toUpperCase();
      final resp = await _postAuth(
        sess,
        'https://yun.139.com/orchestration/auth-rebuild/permission/v1.0/login',
        '{"dycPwd":"$dycPwd","loginStyle":"passPwd","ifOpenAccount":1,'
            '"verType":1,"clientEnv":"3","setCookie":0,"account":"$phone"}',
      );
      final data = (resp['data'] as Map<String, dynamic>?) ?? const {};
      final token = '${data['token'] ?? data['authToken'] ?? ''}';
      if (token.isEmpty) {
        throw const CloudException('登录未返回凭据，请重试');
      }
      HttpLoginGate.instance.recordSuccess(id);
      return _accountFromAuth(
        'Basic ${base64Encode(utf8.encode('pc:$phone:$token'))}',
      );
    } on CloudException {
      HttpLoginGate.instance.recordFailure(id);
      rethrow;
    }
  }

  /// 提交短信验证码（公共收码弹窗「确定」后调用）。
  @override
  Future<CloudAccount> submitSmsCode(String username, String smsCode) async {
    final sess = _pendingSession;
    if (sess == null || username != sess.phone || (sess.random ?? '').isEmpty) {
      throw const CloudException('登录会话已失效，请重新登录');
    }
    final code = smsCode.trim();
    if (code.isEmpty) {
      throw const CloudException('请输入短信验证码');
    }
    try {
      final resp = await _postAuth(
        sess,
        'https://yun.139.com/orchestration/auth-rebuild/sms/v1.0/verifySmsCode',
        '{"account":"$username","random":"${sess.random}","verifyCode":"$code",'
            '"recordID":"","reqType":"1","setCookie":0}',
      );
      final data = (resp['data'] as Map<String, dynamic>?) ?? const {};
      final token = '${data['token'] ?? data['authToken'] ?? ''}';
      if (token.isEmpty) {
        throw const CloudException('登录未返回凭据，请重试');
      }
      _pendingSession = null;
      HttpLoginGate.instance.recordSuccess(id);
      return _accountFromAuth(
        'Basic ${base64Encode(utf8.encode('pc:$username:$token'))}',
      );
    } on CloudException {
      HttpLoginGate.instance.recordFailure(id);
      rethrow;
    }
  }

  /// 弹窗内发送/重发验证码（「发送验证码」按钮调用）：首次发码也从
  /// 这里走（弹窗驱动，表单提交不再自动发码）。
  @override
  Future<void> resendDeviceSms(String username) async {
    final sess = _pendingSession;
    if (sess == null || username != sess.phone) {
      throw const CloudException('登录会话已失效，请重新登录');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    try {
      await _sendSms(sess, username);
      HttpLoginGate.instance.recordAttempt(id);
    } on CloudException {
      HttpLoginGate.instance.recordFailure(id);
      rethrow;
    }
  }

  /// 发码：getSmsVerifyCode；回传 random 暂存进会话（verifySmsCode 必须
  /// 原样回传）。风控拼图（mode != 0）= 免拼图次数用尽，提示走网页兜底。
  Future<void> _sendSms(_SmsLoginSession sess, String phone) async {
    final resp = await _postAuth(
      sess,
      'https://yun.139.com/orchestration/auth-rebuild/sms/v1.0/getSmsVerifyCode',
      '{"account":"$phone","reqType":"1","mode":0}',
    );
    final mode = '${resp['mode'] ?? '0'}';
    if (mode != '0') {
      throw const CloudException('验证码获取过于频繁，请稍后再试或改用网页登录');
    }
    sess.random = '${resp['random'] ?? ''}';
  }

  /// 建加密会话：动态 RSA 公钥 → 随机 16 位 AESKey → RSA-PKCS1(base64)
  /// 作 mcloud-skey（服务端按此还原 AESKey 解 encryptMsg）。
  Future<_SmsLoginSession> _openSession() async {
    final resp = await _postAuth(
      null,
      'https://yun.139.com/orchestration/auth-rebuild/key/v1.0/getRsaPublicKey',
      '{}',
    );
    final data = (resp['data'] as Map<String, dynamic>?) ?? const {};
    final pub = data['publicKey'];
    if (pub is! String || pub.isEmpty) {
      throw const CloudException('登录服务不可用');
    }
    final (mod, exp) = parseSpki(pub);
    final aesKey = _randAlnum(16);
    return _SmsLoginSession(aesKey, rsaPkcs1B64(aesKey, mod, exp));
  }

  /// auth-rebuild 统一请求：encryptMsg 包 payload + 全量公共 headers。
  /// [sess] 为 null 时不带 mcloud-skey（getRsaPublicKey 本身）。
  Future<Map<String, dynamic>> _postAuth(
    _SmsLoginSession? sess,
    String url,
    String payload,
  ) async {
    final body = sess == null
        ? payload
        : '{"encryptMsg":"${aesEcbPkcs7B64(payload, sess.aesKey)}"}';
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final msgId = _randAlnum(16);
    final resp = await cloudRequest(
      'POST',
      url,
      rawBody: body,
      headers: {
        'Content-Type': 'application/json;charset=UTF-8',
        'CMS-DEVICE': 'default',
        'x-yun-channel-source': '10000034',
        'x-huawei-channelSrc': '10000034',
        'x-m4c-caller': 'PC',
        'x-m4c-src': '10002',
        'x-inner-ntwk': '2',
        'mcloud-route': '001',
        'mcloud-version': '7.18.1',
        'mcloud-channel': '1000101',
        'mcloud-client': '10701',
        'mcloud-sign': '$ts,$msgId,${_mcloudSign(body, ts, msgId)}',
        if (sess != null) 'mcloud-skey': sess.skey,
        'Referer': 'https://yun.139.com/w/',
        'Origin': 'https://yun.139.com',
      },
    );
    final j = resp.json;
    if (j['success'] != true) {
      final msg = '${j['message'] ?? ''}';
      throw CloudException(msg.isEmpty ? '登录服务不可用' : msg);
    }
    return j;
  }

  /// mcloud-sign：MD5(MD5(b64(encodeURIComponent(body) 字符排序)) +
  /// MD5("ts:msgId")) 大写（网页端 getNewSign 还原）。
  String _mcloudSign(String body, String ts, String msgId) {
    final sorted = Uri.encodeComponent(body).split('').toList()..sort();
    final r = md5Hex(base64Encode(utf8.encode(sorted.join())));
    final l = md5Hex('$ts:$msgId');
    return md5Hex(r + l).toUpperCase();
  }

  String _randAlnum(int n) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// authorization（"Basic " + base64("pc:手机号:token")）→ 账号。短信
  /// 登录与网页登录捕获同一凭据形态，展示名同用脱敏手机号。
  CloudAccount _accountFromAuth(String auth) {
    final authorization = auth.substring(6);
    var nick = '移动云盘';
    try {
      final seg = utf8.decode(base64.decode(authorization)).split(':');
      if (seg.length >= 2 && seg[1].length >= 7) {
        final p = seg[1];
        nick = '${p.substring(0, 3)}****${p.substring(p.length - 4)}';
      }
    } catch (_) {}
    return CloudAccount(
      provider: id,
      accountId: md5Hex(authorization).substring(0, 12),
      nickname: nick,
      cred: {'authorization': authorization},
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    var auth = '';
    final raw = captured.token ?? '';
    if (raw.isNotEmpty) {
      final parsed = _parseAuthJson(raw);
      auth = (parsed?['auth'] ?? '').toString();
    }
    // 兜底：pollScript 未命中的平台差异下，原生 Cookie 通道可能已拿到
    // authorization（值可能经 escape/encodeURIComponent 转义）。
    if (!_validBasic(auth)) {
      final c = captured.cookies['authorization'] ?? '';
      final dec = c.isEmpty ? '' : Uri.decodeFull(c);
      auth = _validBasic(c) ? c : (_validBasic(dec) ? dec : '');
    }
    if (!_validBasic(auth)) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    final cookie = cookieHeader(captured.cookies);
    final account = _accountFromAuth(auth);
    if (cookie.isEmpty) return account;
    return CloudAccount(
      provider: account.provider,
      accountId: account.accountId,
      nickname: account.nickname,
      cred: {...account.cred, 'cookie': cookie},
      boundAt: account.boundAt,
    );
  }

  /// pollScript 产出解析；平台通道偶发返回转义形态（{\"auth\":...}）：
  /// 包回引号整体解码还原（对齐 thunder）。
  Map<String, dynamic>? _parseAuthJson(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    if (raw.contains(r'\"')) {
      try {
        final dec = jsonDecode('"$raw"');
        if (dec is String) {
          final j = jsonDecode(dec);
          if (j is Map<String, dynamic>) return j;
        }
      } catch (_) {}
    }
    return null;
  }

  /// "Basic " + base64("pc:账号:token") 且 token ≥4 段 '|'（与 pollScript
  /// 校验同口径）。
  bool _validBasic(String v) {
    if (!v.startsWith('Basic ')) return false;
    try {
      final dec = utf8.decode(base64Decode(v.substring(6)));
      if (!dec.startsWith('pc:')) return false;
      final seg = dec.split(':');
      return seg.length >= 3 && seg[2].split('|').length >= 4;
    } catch (_) {
      return false;
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

/// 139 自绘短信登录会话（进程内暂存；发码 → 校验两步共用）。
class _SmsLoginSession {
  _SmsLoginSession(this.aesKey, this.skey);

  /// AES-128-ECB 密钥（16 位随机字母数字，RSA 加密后走 mcloud-skey）。
  final String aesKey;

  /// RSA-PKCS1(aesKey) base64，服务端据此还原 AESKey 解 encryptMsg。
  final String skey;

  /// 发码请求回传的 random（verifySmsCode 必须原样回传）。
  String? random;

  /// 本次会话手机号（防止填码期间改号造成账号错绑）。
  String? phone;
}
