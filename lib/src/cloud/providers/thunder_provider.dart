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
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  @override
  String get webviewLoginUrl => 'https://pan.xunlei.com/';

  /// 轮询脚本：必须是返回字符串的 JS 表达式（IIFE）。
  /// credentials（含 refresh_token）出现即认为登录完成；deviceid 缺失时
  /// 由 completeLogin 回退 md5(refresh_token)。
  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
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
            var n = String(u.username || u.nick_name || u.nickname ||
              (u.User && u.User.username) || '');
            if (n) nick = n;
          } else { dbg += ' body=' + String(xhr.responseText || '').substring(0, 160); }
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
