// 迅雷云盘 provider（webviewToken：WebView 打开 pan.xunlei.com 官方页，
// 登录完成后轮询 localStorage 捕获 credentials + deviceid）。
//
// 2026-10-16 迁移：X App 账密通道（thunderx 参数 + BuildCustomUserAgent
// 定制串）与网页版用户表按 client 维度隔离（X 参数报 not_found(5)），且
// API 直调 auth/signin 有 IP/账号维度风控（review 4002，6h 不冷却），
// 而浏览器登录正常——登录整体走 WebView 网页通道。
// 捕获物：localStorage['credentials_Xqp0kJBXWhwaTpB6']（access_token/
// refresh_token/user_id）+ localStorage['deviceid']（wdi10.<64hex>，
// 签名/x-device-id 用前 32 位 hex）。
// cred 存 accessToken/refreshToken/userId/deviceId(32hex)/ua（浏览器串，
// 与 Rust 端 BROWSER_UA 保持同一串）；refresh 轮换后的凭据经响应
// rotated_cred 带回、由 cloud_remote 统一回写本地凭据存储。
//
// XCloud 架构（与 PikPak 同构）；业务（列目录/分享/转存/直链）经
// cloud_remote 桥转发内嵌 Rust（rust/src/cloud/thunder.rs）。

import 'dart:convert';

import '../../core/application_logger.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class ThunderProvider extends CloudProvider {
  const ThunderProvider();

  // 网页版 client（pan.xunlei.com）：用户表按 client 维度隔离。
  static const _clientId = 'Xqp0kJBXWhwaTpB6';

  @override
  String get id => 'thunder';

  @override
  String get displayName => '迅雷云盘';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewFields;

  // ── 自绘账密/短信双通道（webviewFields 预填辅助型）────────
  //
  // 纯 HTTP 账密已实测被风控封死（auth/signin review 4002，IP/账号
  // 维度 6h 不冷却，见 2026-10-16 迁移记录），短信发码亦依赖图形验证
  // 码（VERIFY_KEY）。落地为预填辅助：自绘表单（139 同款双通道切换）
  // 收凭据并记住，WebView 打开官方登录页注入脚本自动切 tab/填表/
  // 点提交（找不到输入框时提示用户手填），风控滑块用户在 WebView 内
  // 处理；登录成功回主站由 captureRule.pollScript 捕获 credentials。

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'phone', label: '手机号', isPhone: true),
        CloudLoginField(
          key: 'password',
          label: '密码',
          obscure: true,
          optional: true,
          switchLabel: '使用账号密码登录',
          collapseLabel: '使用短信验证码登录',
        ),
      ];

  /// 官方独立登录页（手机验证登录 / 账号密码登录双 tab，与主站同域
  /// 故脚本可直接填表；登录成功回主站由 pollScript 收尾）。
  @override
  String get webviewFieldsLoginUrl => 'https://pan.xunlei.com/login/';

  @override
  bool isWebviewFieldsLoginPage(Uri url) =>
      url.host == 'pan.xunlei.com' && url.path == '/login/';

  /// 执行脚本：密码非空走账号密码通道（切 tab + 填账密 + 点登录），
  /// 留空走短信通道（默认 tab + 填手机号 + 自动点「获取验证码」，
  /// 用户在页面内收码填码）。React 受控输入用原生 setter 触发。
  @override
  String webviewFieldsScript(String account, String password) {
    final acc = jsonEncode(account);
    final pwd = jsonEncode(password);
    return '''
(function(){
  try {
    if (window.__xyXlHooked) return;
    window.__xyXlHooked = true;
    var post = function(m){ try { window.XianYuLogin.postMessage(m); } catch(e){} };
    var ACC = $acc, PWD = $pwd;
    var manual = function(why){ post('MSG:' + why + '，请直接在页面内完成登录'); };
    function setVal(el, v){
      if (!el) return;
      try {
        var d = Object.getOwnPropertyDescriptor(el.__proto__, 'value');
        if (d && d.set) d.set.call(el, v); else el.value = v;
      } catch (e0) { el.value = v; }
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
    }
    function txt(el){ return ((el && (el.textContent || el.innerText)) || '').trim(); }
    function visible(el){ return el && el.offsetParent !== null; }
    function findBtn(t){
      var es = document.querySelectorAll('button,a,span,div');
      for (var i = 0; i < es.length; i++) {
        if (visible(es[i]) && txt(es[i]).indexOf(t) >= 0 && txt(es[i]).length <= 12) return es[i];
      }
      return null;
    }
    function findInput(pred){
      var es = document.querySelectorAll('input');
      for (var i = 0; i < es.length; i++) {
        if (visible(es[i]) && pred(es[i])) return es[i];
      }
      return null;
    }
    // 登录框若在跨域 iframe 内则无法自动填表，直接引导手填。
    var fr = document.querySelectorAll('iframe');
    for (var i = 0; i < fr.length; i++) {
      if (visible(fr[i])) {
        try { if (fr[i].contentDocument === null) { manual('登录框为独立面板'); return; } } catch (e2) {}
      }
    }
    if (PWD) {
      var tab = findBtn('账号密码登录') || findBtn('密码登录');
      if (tab) tab.click();
    }
    setTimeout(function(){
      var phone = findInput(function(el){
        return el.type === 'tel' || /手机/.test(el.placeholder || el.getAttribute('aria-label') || '');
      }) || findInput(function(el){ return el.type === 'text' || el.type === 'tel'; });
      if (!phone) { manual('未找到手机号输入框'); return; }
      setVal(phone, ACC);
      if (PWD) {
        var pwd = findInput(function(el){ return el.type === 'password'; });
        if (!pwd) { manual('未找到密码输入框'); return; }
        setVal(pwd, PWD);
        setTimeout(function(){ var b = findBtn('登录'); if (b) b.click(); }, 400);
        post('MSG:已自动填入账密，若有滑块请在页面内拖动');
      } else {
        setTimeout(function(){
          var b = findBtn('获取验证码') || findBtn('获取短信验证码');
          if (b) b.click();
          post('MSG:请在页面内输入收到的短信验证码并点击登录');
        }, 400);
      }
    }, 600);
  } catch (e) {
    try { window.XianYuLogin.postMessage('MSG:' + e); } catch (_e) {}
  }
})();
''';
  }

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  @override
  String get webviewLoginUrl => 'https://pan.xunlei.com/';

  /// 轮询脚本：必须是返回字符串的 JS 表达式（IIFE）。
  /// credentials（含 refresh_token）出现即认为登录完成；deviceid 缺失时
  /// 由 completeLogin 回退 md5(refresh_token)。
  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 自绘通道登录成功回主站后按此判定落地并轮询收尾（webviewToken
        // 网页兜底通道不读此字段，不受影响）。
        postLoginUrl: 'https://pan.xunlei.com/',
        pollScript: '''
(() => {
  try {
    var raw = window.localStorage.getItem('credentials_$_clientId');
    if (!raw) return "";
    var o = JSON.parse(raw);
    var rt = String(o.refresh_token || '');
    if (!rt) return "";
    var dev = '';
    try { dev = String(window.localStorage.getItem('deviceid') || ''); } catch (e2) {}
    var nick = String(o.user_name || o.nick_name || '');
    if (!nick) {
      // 网页版 credentials 无昵称字段，用户特权 token 的 JWT payload 亦
      // 无用户名（实测仅 UID/vip 等）——本地无昵称数据，兜底在页面上下文
      // 内带最新 access_token + captcha token 同步调认证域用户信息接口，
      // 失败不阻断捕获（回退盘名）。
      try {
        var at = String(o.access_token || '');
        var cap = '';
        try {
          var ck = JSON.parse(window.localStorage.getItem('captcha_$_clientId') || 'null');
          cap = ck && ck.token ? String(ck.token) : '';
        } catch (e4) {}
        if (at) {
          var xhr = new XMLHttpRequest();
          xhr.open('GET', 'https://xluser-ssl.xunlei.com/v1/user/me?client_id=$_clientId', false);
          xhr.setRequestHeader('Accept', 'application/json;charset=UTF-8');
          xhr.setRequestHeader('x-client-id', '$_clientId');
          xhr.setRequestHeader('x-client-version', '1.93.10');
          if (dev) { xhr.setRequestHeader('x-device-id', dev.substring(0, 32)); }
          if (cap) { xhr.setRequestHeader('X-Captcha-Token', cap); }
          xhr.setRequestHeader('Authorization', 'Bearer ' + at);
          xhr.send(null);
          var dbg = 'status=' + xhr.status;
          if (xhr.status === 200) {
            var u = JSON.parse(xhr.responseText);
            var scopes = [u, u.User, u.data, u.user, u.result];
            var n = '';
            for (var si = 0; si < scopes.length && !n; si++) {
              var x = scopes[si];
              if (x && typeof x === 'object') {
                n = String(x.username || x.nick_name || x.nickname ||
                  x.userName || x.name || '');
              }
            }
            if (n) {
              nick = n;
            } else {
              dbg += ' body=' + String(xhr.responseText || '')
                .substring(0, 240);
            }
          } else {
            dbg += ' body=' + String(xhr.responseText || '').substring(0, 160);
          }
          window.localStorage.setItem('__xysdk_nick_dbg', dbg);
        }
      } catch (e3) {}
    }
    var dbg = '';
    try { dbg = String(window.localStorage.getItem('__xysdk_nick_dbg') || ''); } catch (e5) {}
    return JSON.stringify({
      at: String(o.access_token || ''),
      rt: rt,
      uid: String(o.user_id || o.sub || ''),
      nick: nick,
      dev: dev,
      dbg: dbg
    });
  } catch (e) { return ""; }
})()''',
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final raw = captured.token;
    if (raw == null || raw.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      // 平台通道偶发返回转义形态（{\"rt\":...}）：包回引号整体解码还原。
      Map<String, dynamic>? retry;
      if (raw.contains(r'\"')) {
        try {
          final dec = jsonDecode('"$raw"');
          if (dec is String) {
            retry = jsonDecode(dec) as Map<String, dynamic>;
          }
        } catch (_) {}
      }
      if (retry == null) {
        throw const CloudException('登录凭据解析失败，请重新登录');
      }
      parsed = retry;
    }
    final refreshToken = (parsed['rt'] ?? '').toString();
    if (refreshToken.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    final uid = (parsed['uid'] ?? '').toString();
    final nick = (parsed['nick'] ?? '').toString();
    // deviceid（wdi10.<64hex>）取前 32 位 hex；缺失回退 md5(refresh_token)。
    var dev = (parsed['dev'] ?? '').toString();
    if (dev.startsWith('wdi10.')) dev = dev.substring(6);
    if (dev.length >= 32) dev = dev.substring(0, 32);
    if (dev.length != 32 || !RegExp(r'^[0-9a-f]{32}$').hasMatch(dev)) {
      dev = md5Hex(refreshToken);
    }
    final accountId = uid.isNotEmpty ? uid : md5Hex(refreshToken).substring(0, 12);
    final dbg = (parsed['dbg'] ?? '').toString();
    AppLog.debug('cloud', '迅雷昵称捕获 nick=$nick dbg=$dbg');
    return CloudAccount(
      provider: id,
      accountId: accountId,
      nickname: nick.isNotEmpty ? nick : '迅雷云盘',
      cred: {
        'accessToken': (parsed['at'] ?? '').toString(),
        'refreshToken': refreshToken,
        'userId': uid,
        'deviceId': dev,
        'ua': CloudProvider.desktopWebviewUa,
      },
      boundAt: DateTime.now(),
    );
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
