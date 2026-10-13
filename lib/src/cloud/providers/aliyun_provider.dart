// 阿里云盘 provider（webviewToken：壳页 iframe 嵌官方 OAuth 授权页，
// 登录完成后官方 callback 页在 iframe 内 postMessage 回 tokenInfo，
// 壳页桥接存入 window 变量，pollScript 轮询读取）。
//
// 关键点：官方 callback（www.aliyundrive.com/sign/callback）只在
// iframe 环境（top != self）下用 code 兑换 token 并 postMessage 给
// state.origin 指定的父页 origin——直接顶层打开会报「Invalid stated」
// 且 token 永不落 localStorage。因此壳页必须：
//   1. iframe src 的 state 带 {"origin": <壳页 origin>}（官方校验
//      要求真实 https origin，"*" 会被拒）；
//   2. 壳页经 loadHtmlString(baseUrl: 同一 origin) 渲染，保证父页
//      origin 与 postMessage targetOrigin 匹配。
// refresh_token 单次有效，rust 刷新后的轮换凭据经响应 rotated_cred
// 带回、由 cloud_remote 统一回写本地凭据存储。

import 'dart:convert';

import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';

class AliyunProvider extends CloudProvider {
  AliyunProvider();

  static const _clientId = '25dzX3vbYqktVxyX';

  /// 壳页 origin（postMessage 桥两端约定，须为真实 https origin）：
  /// 必须与 OAuth 页（auth.aliyundrive.com）同主域 aliyundrive.com——
  /// Android WebView 默认拒收第三方 Cookie，壳页用 alipan.com 时 iframe
  /// 里的 SESSIONID 存不上，登录永远失败；同主域即第一方。redirect_uri/
  /// callback/postMessage 同域对齐官方 App 形态。
  static const _shellOrigin = 'https://www.aliyundrive.com';

  @override
  String get id => 'aliyun';

  @override
  String get displayName => '阿里云盘';

  @override
  String get rootPath => 'root';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  Duration get directLinkTtl => const Duration(hours: 4);

  @override
  String get webviewLoginUrl =>
      'https://auth.aliyundrive.com/v2/oauth/authorize?login_type=custom'
      '&response_type=code'
      '&redirect_uri=${Uri.encodeQueryComponent('https://www.aliyundrive.com/sign/callback')}'
      '&client_id=$_clientId'
      '&state=${Uri.encodeQueryComponent('{"origin":"*"}')}#/login';

  /// OAuth 授权页（iframe 用）：state.origin 指向壳页 origin。
  static String get _oauthIframeUrl =>
      'https://auth.aliyundrive.com/v2/oauth/authorize?login_type=custom'
      '&response_type=code'
      '&redirect_uri=${Uri.encodeQueryComponent('https://www.aliyundrive.com/sign/callback')}'
      '&client_id=$_clientId'
      '&state=${Uri.encodeQueryComponent('{"origin":"$_shellOrigin"}')}#/login';

  @override
  String? get webviewShellBaseUrl => _shellOrigin;

  @override
  String? get webviewShellHtml => '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:#fff}
iframe{border:0;width:100%;height:100%;display:block}
</style>
</head>
<body>
<iframe src="$_oauthIframeUrl"></iframe>
<script>
window.__XYM_ALI_TOKEN__ = '';
window.addEventListener('message', function (e) {
  try {
    var d = e.data;
    if (d && d.type === 'loginSuccess' && d.tokenInfo) {
      window.__XYM_ALI_TOKEN__ = JSON.stringify(d.tokenInfo);
    }
  } catch (err) {}
});
</script>
</body>
</html>
''';

  /// 轮询脚本：必须是返回字符串的 JS 表达式（IIFE）。
  /// 优先读壳页 postMessage 桥存的 tokenInfo；回退遍历
  /// localStorage/sessionStorage 找 refresh_token（键名兼容多种）。
  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        pollScript: '''
(() => {
  try {
    var s = window.__XYM_ALI_TOKEN__;
    if (s && s.length > 2) return s;
  } catch (e) {}
  var keys = ['token','TOKEN','loginToken','login_token','auth_token',
              'aliyundrive_token','alipan_token','accountToken'];
  var stores = [window.localStorage, window.sessionStorage];
  for (var s = 0; s < stores.length; s++) {
    for (var i = 0; i < keys.length; i++) {
      var raw = null;
      try { raw = stores[s].getItem(keys[i]); } catch (e) {}
      if (!raw) continue;
      var obj = raw;
      try { obj = JSON.parse(raw); } catch (e) {}
      var rt = '', uid = '', nick = '';
      var found = (function scan(o, depth) {
        if (!o || typeof o !== 'object' || depth > 3) return false;
        if (o.refresh_token) {
          rt = String(o.refresh_token);
          uid = o.user_id ? String(o.user_id) : '';
          nick = (o.nick_name || o.name || '').toString();
          return true;
        }
        if (o.data && scan(o.data, depth + 1)) return true;
        if (o.content && scan(o.content, depth + 1)) return true;
        return false;
      })(obj, 0);
      if (found) {
        return JSON.stringify({rt: rt, uid: uid, nick: nick});
      }
    }
  }
  return "";
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
      throw const CloudException('登录凭据解析失败，请重新登录');
    }
    // 新通道：官方 callback postMessage 的 tokenInfo（/token/get 响应，
    // 字段在顶层，data 里可能有包裹）；旧通道：pollScript 打包的
    // {rt, uid, nick}。两者兼容解析。
    final data = parsed['data'] is Map<String, dynamic>
        ? parsed['data'] as Map<String, dynamic>
        : const <String, dynamic>{};
    String fieldOf(List<String> keys) {
      for (final k in keys) {
        final v = parsed[k] ?? data[k];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
      return '';
    }

    final refreshToken = fieldOf(['rt', 'refresh_token']);
    if (refreshToken.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    final uid = fieldOf(['uid', 'user_id']);
    final nick = fieldOf(['nick', 'nick_name', 'user_name', 'name']);
    final accountId = uid.isNotEmpty ? uid : refreshToken.substring(0, 12);
    final cred = <String, String>{
      'refreshToken': refreshToken,
      'userId': uid,
      'nickname': nick,
      // accountId 冗余存一份：refresh 轮换落盘时按它定位账号。
      'accountId': accountId,
    };
    return CloudAccount(
      provider: id,
      accountId: accountId,
      nickname: nick.isNotEmpty ? nick : '阿里云盘',
      cred: cred,
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
