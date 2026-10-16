// 移动云盘（139）provider（webviewCookie：登录页 Cookie 全收）。
//
// 分享走 outLink 免转存直链（directPlayable=true）；业务经 cloud_remote
// 桥转发内嵌 Rust（rust/src/cloud/mobile139.rs）。

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
  String get rootPath => 'root';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  @override
  // 直达网页版网盘应用（未登录会弹登录）。根路径 yun.139.com/ 是
  // 纯营销落地页（装客户端推广），没有登录入口。
  String get webviewLoginUrl => 'https://yun.139.com/w/';

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 全收（cookieNames 空 = 非空即采）。登录前后 URL 同为
        // yun.139.com SPA 首页，无法按 URL 判定完成，等用户点
        // 「我已登录完成」手动收 Cookie；原生通道读 httpOnly 登录态。
        cookieDomains: ['yun.139.com'],
        nativeCookies: true,
        manualDoneOnly: true,
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final cookie = cookieHeader(captured.cookies);
    if (cookie.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    return CloudAccount(
      provider: id,
      accountId: md5Hex(cookie).substring(0, 12),
      nickname: '移动云盘',
      cred: {'cookie': cookie},
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
