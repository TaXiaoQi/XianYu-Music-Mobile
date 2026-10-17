// 微云 provider（webviewToken 混合：openid 走 pollScript，会话走
// Cookie）。
//
// 业务（列目录/分享/转存/直链）经 cloud_remote 桥转发内嵌 Rust
// （rust/src/cloud/weiyun.rs）。

import 'dart:convert';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class WeiyunProvider extends CloudProvider {
  const WeiyunProvider();

  @override
  String get id => 'weiyun';

  @override
  String get displayName => '腾讯微云';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  String get webviewLoginUrl => 'https://www.weiyun.com/';

  // 移动 UA 会跳「立即安装」宣传页，桌面 UA 才出登录入口。
  @override
  String? get webviewUserAgent => CloudProvider.desktopWebviewUa;

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 纯 Cookie 范式：登录落地 weiyun.com 即采 Cookie 自动完成。
        // 原 pollScript 读 localStorage 的 weiyun_qq_openid/weiyun_wx_openid
        // 键——该键名系设计稿拍脑袋，微云前端从不写入（恒空），导致
        // Token 范式永不判定完成、登录后卡死不跳绑定（2026-10-17 实测）。
        doneUrlPattern: RegExp(r'weiyun\.com'),
      );

  @override
  String? get manualInputHint =>
      '粘贴网页版 Cookie（电脑浏览器登录微云 → F12 → Application → '
      'Cookies，复制全串；需含 weiyun_session）';

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    var openid = '';
    if (captured.token != null && captured.token!.isNotEmpty) {
      try {
        final j = jsonDecode(captured.token!);
        if (j is Map<String, dynamic>) {
          openid = ((j['qq'] ?? j['wx']) ?? '').toString();
        }
      } catch (_) {}
    }
    final cookie = cookieHeader(captured.cookies);
    if (openid.isEmpty && cookie.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    return CloudAccount(
      provider: id,
      accountId: md5Hex(openid.isEmpty ? cookie : openid).substring(0, 12),
      nickname: '腾讯微云',
      cred: {'cookie': cookie, 'openid': openid},
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
