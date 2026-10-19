// 百度网盘 provider（webviewToken：WebView 打开开放平台 OAuth 授权页，
// 登录授权后重定向到 redirect_uri（URL 带 code），pollScript 读
// location.href 抽取 code，completeLogin 用 code 换 access_token/
// refresh_token。OAuth 通道绕开网页 Cookie 风控（WebView 会话签发的
// BDUSS 被百度服务端降权，任何 API 通道 errno=-6，实测全灭）。
//
// 手填通道语义随 pollScript 变为「填 Token」：可粘贴 refresh_token
// （或完整 token JSON），供从电脑端搬运凭据。
// 分享解析/转存走网页 API（需 Cookie 登录态），rust 侧按凭据形态双轨。

import 'dart:convert';

import '../../core/application_logger.dart';
import '../cloud_credentials_store.dart';
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class BaiduProvider extends CloudProvider {
  const BaiduProvider();

  // 开放平台 OAuth（pan.baidu.com/union 注册的应用）。
  // redirect_uri 无需真实可达——授权完成后 WebView 重定向到
  // `<redirect_uri>?code=xxx`，页面 404 无妨，URL 已带 code，
  // pollScript 从 location.href 抽取。
  static const _clientId = '__BAIDU_APPKEY__';
  static const _clientSecret = '__BAIDU_APPSECRET__';
  static const _redirectUri = 'https://xianyu-music.github.io/oauth/baidu';

  // 统一移动 UA：网页 Cookie 轨（分享/转存）的会话与创建环境 UA 绑定
  // ——WebView（安卓 UA）种的 Cookie 用桌面 UA 请求会判定会话无效；
  // 实测移动 UA 对 WebView 与电脑浏览器种的 Cookie 均兼容。
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; M2102K1C) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  Map<String, String> get _webHeaders => {
    'User-Agent': _ua,
    'Referer': 'https://pan.baidu.com/',
  };

  @override
  String get id => 'baidu';

  @override
  String get displayName => '百度网盘';

  @override
  String get rootPath => '/';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  String get webviewLoginUrl =>
      'https://openapi.baidu.com/oauth/2.0/authorize'
      '?response_type=code'
      '&client_id=$_clientId'
      '&redirect_uri=${Uri.encodeQueryComponent(_redirectUri)}'
      '&scope=basic,netdisk&display=mobile';

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
    // 轮询 location.href 抽 code；兜底抓页面里渲染的 access_token
    // （部分授权形态直出 token，带 at: 前缀与 code 区分）。
    pollScript: '''
(() => {
  try {
    var m = location.href.match(/[?&#]code=([0-9a-zA-Z._-]{10,})/);
    if (m) return m[1];
    var t = document.documentElement.innerHTML
      .match(/access_token[=:&"'\\s]+([0-9a-zA-Z._-]{24,})/);
    if (t) return 'at:' + t[1];
  } catch (e) {}
  return "";
})()''',
    pollIntervalMs: 500,
  );

  /// AppKey 未注入（占位符）时 OAuth 授权页必然报 invalid_client，
  /// WebView 改渲染引导壳页：明示该通道不可用，指引用户走右上角
  /// 「填 Cookie」；壳页是纯静态展示，无需 baseUrl。
  @override
  String? get webviewShellHtml =>
      _clientId == '__BAIDU_APPKEY__' ? _guideShellHtml : null;

  static const _guideShellHtml = '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{margin:0;padding:24px 20px;background:#fff;color:#333;
  font:15px/1.7 -apple-system,'PingFang SC','Microsoft YaHei',sans-serif}
h3{font-size:17px;margin:0 0 12px}
ol{padding-left:20px;margin:0}
li{margin:8px 0}
code{background:#f2f2f2;border-radius:4px;padding:1px 5px;font-size:13px}
.tip{margin-top:16px;padding:10px 12px;background:#fff7e6;border-radius:8px;
  font-size:13px;color:#8a6116}
</style>
</head>
<body>
<h3>网页授权通道未开放</h3>
<p>开放平台 AppKey 尚未配置，OAuth 授权页不可用。</p>
<p>绑定请按以下步骤：</p>
<ol>
  <li>在<b>电脑浏览器</b>登录 <code>pan.baidu.com</code></li>
  <li>回到本页点右上角「<b>填 Cookie</b>」</li>
  <li>粘贴 Cookie（浏览器导出插件的 JSON 或 F12 复制的文本均可，需含 <code>BDUSS</code>）</li>
</ol>
<div class="tip">注意：App 内 WebView 登录种下的 Cookie 会被百度服务端降权（接口全报 -6），必须使用电脑浏览器登录后导出的 Cookie。</div>
</body>
</html>
''';

  @override
  Duration get directLinkTtl => const Duration(hours: 8);

  // 手动填兜底：Cookie（WebView 会话签发的 BDUSS 被降权，但电脑浏览器
  // 登录后复制的 Cookie 实测可用——网页 API 轨）；OAuth 凭据仍兼容
  // token JSON/refresh_token 手填，等 AppKey 注入后走授权页。
  @override
  bool get manualTokenInput => false;

  @override
  String? get manualInputHint =>
      '粘贴网页版 Cookie（电脑浏览器登录百度网盘 → F12 → Application → '
      'Cookies，需含 BDUSS，建议带上 STOKEN）';

  /// 手填 Cookie 解析：优先识别浏览器导出插件的 JSON 形态（数组
  /// [{name,value},…] / {cookies:[…]} / 平面对象 {name:value}），
  /// 再回落 k=v 对文本（分号/换行分隔，兼容 F12 复制的「k: v」形态）；
  /// 无 BDUSS 返回 null（回落 Token/授权码语义）。
  Map<String, String>? _parseCookieInput(String raw) {
    final pairs = _parseCookieJson(raw) ?? _parseCookiePlain(raw);
    if (pairs == null || !pairs.containsKey('BDUSS')) return null;
    return pairs;
  }

  Map<String, String>? _parseCookieJson(String raw) {
    final t = raw.trim();
    if (!t.startsWith('[') && !t.startsWith('{')) return null;
    dynamic dec;
    try {
      dec = jsonDecode(t);
    } catch (_) {
      return null;
    }
    if (dec is Map<String, dynamic> && dec['cookies'] is! List) {
      // 平面对象 {"BDUSS": "...", ...}
      final pairs = <String, String>{};
      dec.forEach((k, v) {
        if (v != null) pairs[k] = v.toString();
      });
      return pairs;
    }
    final List<dynamic> items;
    if (dec is List) {
      items = dec;
    } else {
      items = dec['cookies'] as List<dynamic>;
    }
    final pairs = <String, String>{};
    for (final e in items) {
      if (e is! Map) continue;
      final k = (e['name'] ?? e['key'] ?? '').toString();
      final v = (e['value'] ?? '').toString();
      if (k.isNotEmpty && v.isNotEmpty && v != 'undefined') {
        pairs[k] = v;
      }
    }
    return pairs;
  }

  Map<String, String>? _parseCookiePlain(String raw) {
    final pairs = <String, String>{};
    for (final piece in raw.split(RegExp(r'[;\n\r]'))) {
      final p = piece.trim();
      if (p.isEmpty) continue;
      final eq = p.indexOf('=');
      final i = eq >= 0 ? eq : p.indexOf(':');
      if (i <= 0) continue;
      final k = p.substring(0, i).trim();
      final v = p.substring(i + 1).trim();
      if (RegExp(r'^[A-Za-z0-9_]+$').hasMatch(k) && v.isNotEmpty) {
        pairs[k] = v;
      }
    }
    return pairs;
  }

  // ── 登录（OAuth code 换 token）────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    var raw = captured.token ?? '';
    if (raw.isEmpty) {
      // 手填 Cookie 走 cookies 字段传入（壳页 _manualCookie 的解析产物），
      // 序列化回 k=v; 文本供统一解析；两者皆空才是真没凭据
      final c = captured.cookies;
      if (c.isEmpty) {
        throw const CloudException('未捕获到授权凭据，请重试');
      }
      raw = c.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    // 手填 Cookie：含 BDUSS 的网页 Cookie 直接落库为 Cookie 轨凭据。
    // 昵称/uid 尽力取（网页 getinfo），失败则显示名 + BDUSS 哈希兜底。
    final cookiePairs = _parseCookieInput(raw);
    if (cookiePairs != null) {
      var nickname = displayName;
      var accountId = md5Hex(cookiePairs['BDUSS']!).substring(0, 12);
      try {
        final resp = await cloudGet(
          'https://pan.baidu.com/api/user/getinfo?ref=client&clienttype=0&web=1',
          headers: {
            ..._webHeaders,
            'Referer': 'https://pan.baidu.com/disk/main',
            'Cookie': cookieHeader(cookiePairs),
          },
        );
        if (resp.isOk) {
          final j = jsonDecode(resp.body);
          final info = j is Map<String, dynamic>
              ? (j['user_info'] ?? j['data'])
              : null;
          if (info is Map<String, dynamic>) {
            final name = (info['username'] ?? info['user_name'] ?? '')
                .toString();
            if (name.isNotEmpty) nickname = name;
            final uid = (info['id'] ?? info['user_id'] ?? info['baidu_id'])
                ?.toString();
            if (uid != null && uid.isNotEmpty && uid != '0') accountId = uid;
          }
        }
      } catch (_) {
        // 昵称/uid 拿不到不影响绑定。
      }
      return CloudAccount(
        provider: id,
        accountId: accountId,
        nickname: nickname,
        cred: cookiePairs,
        boundAt: DateTime.now(),
      );
    }

    // 手填兼容：完整 token JSON 直接解析；裸串当 refresh_token。
    Map<String, dynamic>? parsed;
    try {
      final dec = jsonDecode(raw);
      if (dec is Map<String, dynamic>) parsed = dec;
    } catch (_) {}
    String? accessToken = parsed?['access_token']?.toString();
    String? refreshToken = parsed?['refresh_token']?.toString();
    String code = '';
    if (raw.startsWith('at:')) {
      accessToken ??= raw.substring(3);
    } else if (accessToken == null && refreshToken == null) {
      code = raw.trim();
    }

    // code 换 token（或裸 refresh_token 换新 token）。
    if (accessToken == null || accessToken.isEmpty) {
      final body = code.isNotEmpty
          ? {
              'grant_type': 'authorization_code',
              'code': code,
              'client_id': _clientId,
              'client_secret': _clientSecret,
              'redirect_uri': _redirectUri,
            }
          : {
              'grant_type': 'refresh_token',
              'refresh_token': refreshToken ?? raw.trim(),
              'client_id': _clientId,
              'client_secret': _clientSecret,
            };
      final CloudHttpResponse resp;
      try {
        resp = await cloudPostForm(
          'https://openapi.baidu.com/oauth/2.0/token',
          body,
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        );
      } catch (e) {
        AppLog.warn('cloud', '百度OAuth换token请求异常: $e');
        throw const CloudException('授权凭据交换失败，请重试');
      }
      Map<String, dynamic>? j;
      try {
        final dec = jsonDecode(resp.body);
        if (dec is Map<String, dynamic>) j = dec;
      } catch (_) {}
      if (j == null || j['access_token'] == null) {
        AppLog.warn(
          'cloud',
          '百度OAuth换token失败 status=${resp.status} body=${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}',
        );
        throw const CloudException('授权凭据无效或已过期，请重新登录');
      }
      accessToken = j['access_token'].toString();
      refreshToken = (j['refresh_token'] ?? refreshToken)?.toString();
    }

    // uinfo：昵称 + 百度数字 uid（账号标识；refresh_token 每次授权
    // 会轮换，不能当 accountId）。
    String uid = '', nickname = '';
    try {
      final info = await cloudGet(
        'https://pan.baidu.com/rest/2.0/xpan/nas?method=uinfo'
        '&access_token=${Uri.encodeQueryComponent(accessToken)}',
        headers: _webHeaders,
      );
      final j = jsonDecode(info.body);
      if (j is Map<String, dynamic>) {
        uid = (j['baidu_id'] ?? j['uk'] ?? '').toString();
        nickname = (j['netdisk_name'] ?? j['name'] ?? '').toString();
      }
    } catch (e) {
      AppLog.warn('cloud', '百度uinfo获取异常: $e');
    }
    final expiresAt = DateTime.now()
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch;
    return CloudAccount(
      provider: id,
      accountId: uid.isNotEmpty ? uid : md5Hex(accessToken).substring(0, 12),
      nickname: nickname.isNotEmpty ? nickname : displayName,
      cred: {
        'accessToken': accessToken,
        if (refreshToken != null && refreshToken.isNotEmpty)
          'refreshToken': refreshToken,
        'accessExpireMs': expiresAt.toString(),
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
  }) => rustListDir(id, cred, path, cursor: cursor);

  @override
  bool get supportsSearch => true;

  @override
  Future<CloudListResult> searchFiles(
    Map<String, String> cred,
    String keyword, {
    String? cursor,
  }) => rustSearchFiles(id, cred, keyword, cursor: cursor);

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    // 解析需登录态（BDUSS）；未绑定账号时在此抛出，行为与原实现一致。
    final cred = await _soleCredOrThrow();
    return rustParseShare(id, url, pwd, cred: cred);
  }

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) => rustTransferShare(id, cred, share);

  @override
  Future<CloudDirectLink> getDirectLink(
    Map<String, String> cred,
    CloudFile file,
  ) => rustDirectLink(id, cred, file);

  /// 分享列表/转存需要登录态；未绑定直接报。
  Future<Map<String, String>> _soleCredOrThrow() async {
    final cred = await CloudCredentialsStore.instance.soleCredFor(id);
    if (cred == null) throw const CloudException('请先绑定百度网盘');
    return cred;
  }
}
