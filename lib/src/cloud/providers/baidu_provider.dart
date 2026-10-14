// 百度网盘 provider（webviewCookie：WebView 打开网页登录页，输账密/
// 短信验证码；BDUSS 为 httpOnly，凭捕获规则的原生 CookieManager 通道
// 读取，平台无 getCookies 时回退 document.cookie——BDUSS 场景即失效）。
//
// 注意：分享列表/转存接口必须带登录态（BDUSS），故 parseShareLink 内
// 直接读本地绑定凭据；业务一律经 cloud_remote 桥转发内嵌 Rust。

import '../cloud_credentials_store.dart';
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class BaiduProvider extends CloudProvider {
  const BaiduProvider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

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
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  // wappass = 百度移动端统一登录页（百度系 App 内嵌 WebView 同款），
  // 全屏账密/短信表单。pan.baidu.com/login 旧 SPA 在手机上默认落
  // 「扫码登录」tab（passLoginType 强制 qrcode），无法在手机上自扫，
  // 弃用；保持移动 UA（wappass 本身就是移动页）。
  @override
  String get webviewLoginUrl =>
      'https://wappass.baidu.com/passport/?login&tpl=netdisk'
      '&u=https%3A%2F%2Fpan.baidu.com%2F';

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 收域内全量 Cookie（BDUSS/STOKEN 均 httpOnly 走原生通道；网页
        // 接口风控校验完整浏览器 Cookie 指纹，只带 BDUSS+STOKEN 会
        // errno=-6——手填时代粘贴整串 Cookie 能用正说明这点）。
        cookieDomains: ['baidu.com', 'pan.baidu.com'],
        doneUrlPattern: RegExp(r'pan\.baidu\.com/(?!login)'),
        nativeCookies: true,
        // ndut_fmt/PANPSC 等风控指纹由主站页 JS 种下，登录页直接捕获
        // 会缺键（errno=-6）——手动完成前先跳主站让页面种齐。
        postLoginUrl: 'https://pan.baidu.com/disk/main',
      );

  @override
  Duration get directLinkTtl => const Duration(hours: 8);

  // ── 登录（WebView 捕获 Cookie）────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final cookies = captured.cookies;
    final bduss = cookies['BDUSS'] ?? '';
    if (bduss.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重试');
    }
    var nickname = displayName;
    var accountId = md5Hex(bduss).substring(0, 12);
    try {
      final resp = await cloudGet(
        'https://pan.baidu.com/api/user/getinfo?ref=client&clienttype=0&web=1',
        headers: {..._webHeaders, 'Cookie': cookieHeader(cookies)},
      );
      if (resp.isOk) {
        final info = resp.json['user_info'] ?? resp.json['data'];
        if (info is Map<String, dynamic>) {
          final name = (info['username'] ?? info['user_name'] ?? '').toString();
          if (name.isNotEmpty) nickname = name;
          // 账号标识用百度 uid：BDUSS 每次网页登录都会轮换，指纹当
          // accountId 会把同一账号的重复登录当成新账号（绑出多条）。
          final uid = (info['id'] ?? info['user_id'] ?? info['baidu_id'])
              ?.toString();
          if (uid != null && uid.isNotEmpty && uid != '0') accountId = uid;
        }
      }
    } catch (_) {
      // 拿不到昵称就用显示名兜底。
    }
    return CloudAccount(
      provider: id,
      accountId: accountId,
      nickname: nickname,
      // 全量保留捕获到的 Cookie（BDUSS/STOKEN/PANWEB/BAIDUID 等）——
      // 网页接口风控校验完整指纹，逐键白名单会 errno=-6。
      cred: {
        for (final e in cookies.entries)
          if (e.value.isNotEmpty) e.key: e.value,
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
