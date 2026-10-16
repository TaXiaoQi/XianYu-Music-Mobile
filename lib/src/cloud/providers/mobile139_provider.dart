// 移动云盘（139）provider（webviewCookie + pollScript：页面内轮询
// authorization 凭据自动完成登录）。
//
// 网页版 SPA 登录成功后：① 写 authorization Cookie（enCodeToken =
// "Basic " + btoa("pc:账号:token")）；② Vuex MCloudVM.$store.state.auth
// 维护 accountPhone/token。pollScript 双路取值（Cookie 为主、MCloudVM
// 兜底）并严格校验 token ≥4 段 '|'，命中即自动完成——登录前后 URL 同为
// SPA 首页，无法按 URL 判定，manualDoneOnly 保留挡住「有 Cookie 就算
// 登录」的早采。业务凭据：authorization（裸 base64，无 "Basic " 前缀）
// + cookie（旧转存接口可选留档）。
//
// 分享走 outLink 免转存直链（directPlayable=true）；业务经 cloud_remote
// 桥转发内嵌 Rust（rust/src/cloud/mobile139.rs）。

import 'dart:convert';

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
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

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
    final authorization = auth.substring(6);
    final cookie = cookieHeader(captured.cookies);
    return CloudAccount(
      provider: id,
      accountId: md5Hex(authorization).substring(0, 12),
      nickname: '移动云盘',
      cred: {
        'authorization': authorization,
        if (cookie.isNotEmpty) 'cookie': cookie,
      },
      boundAt: DateTime.now(),
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
