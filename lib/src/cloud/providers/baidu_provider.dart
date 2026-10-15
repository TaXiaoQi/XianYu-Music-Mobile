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

  @override
  Duration get directLinkTtl => const Duration(hours: 8);

  // ── 登录（OAuth code 换 token）────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    var raw = captured.token ?? '';
    if (raw.isEmpty) {
      throw const CloudException('未捕获到授权凭据，请重试');
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
          headers: const {
            'Content-Type': 'application/x-www-form-urlencoded'
          },
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
        AppLog.warn('cloud',
            '百度OAuth换token失败 status=${resp.status} body=${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}');
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
    final expiresAt =
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
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
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    // 解析需登录态（BDUSS）；未绑定账号时在此抛出，行为与原实现一致。
    final cred = await _soleCredOrThrow();
    return rustParseShare(id, url, pwd, cred: cred);
  }

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

  /// 分享列表/转存需要登录态；未绑定直接报。
  Future<Map<String, String>> _soleCredOrThrow() async {
    final cred = await CloudCredentialsStore.instance.soleCredFor(id);
    if (cred == null) throw const CloudException('请先绑定百度网盘');
    return cred;
  }
}
