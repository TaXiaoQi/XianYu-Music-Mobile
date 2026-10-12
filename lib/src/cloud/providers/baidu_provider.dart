// 百度网盘 provider（原生扫码：passport 下发二维码图 → unicast 轮询 →
// BDUSS/STOKEN 兑换）。
//
// 注意：分享列表/转存接口必须带登录态（BDUSS），故 parseShareLink 内
// 直接读本地绑定凭据；业务一律经 cloud_remote 桥转发内嵌 Rust。

import 'dart:convert';
import 'dart:math';

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
  CloudLoginKind get loginKind => CloudLoginKind.qrCode;

  @override
  Duration get directLinkTtl => const Duration(hours: 8);

  // ── 登录（原生扫码）───────────────────────────────────

  @override
  Future<CloudQrLoginSession> createQrLogin() async {
    final gid = _randomHex(32);
    final tt = DateTime.now().millisecondsSinceEpoch;
    final resp = await cloudGet(
      'https://passport.baidu.com/v2/api/getqrcode'
      '?lp=pc&qrloginfrom=pc&gid=$gid&clienttype=web&apiver=v3&tt=$tt'
      '&tpl=netdisk',
      headers: _webHeaders,
    );
    if (!resp.isOk) throw const CloudException('二维码获取失败');
    final j = resp.json;
    if ((j['errno'] as num?)?.toInt() != 0) {
      throw const CloudException('二维码获取失败');
    }
    final imgurl = (j['imgurl'] ?? '').toString();
    final sign = (j['sign'] ?? '').toString();
    if (imgurl.isEmpty || sign.isEmpty) {
      throw const CloudException('二维码获取失败');
    }
    // getqrcode 响应的 Cookie（BAIDUID 等）须串联进后续轮询/兑换请求。
    final state = jsonEncode({
      'gid': gid,
      'sign': sign,
      'ck': cookieHeader(resp.setCookiePairs),
    });
    return CloudQrLoginSession(
      qrContent: '',
      qrImageUrl: imgurl.startsWith('http') ? imgurl : 'https://$imgurl',
      state: state,
    );
  }

  @override
  Future<CloudAccount?> pollQrLogin(CloudQrLoginSession session) async {
    final Map<String, dynamic> info;
    try {
      info = jsonDecode(session.state) as Map<String, dynamic>;
    } catch (_) {
      throw const CloudException('二维码已失效，请刷新');
    }
    final ck = (info['ck'] ?? '').toString();
    final headers = {
      ..._webHeaders,
      if (ck.isNotEmpty) 'Cookie': ck,
    };
    final tt = DateTime.now().millisecondsSinceEpoch;
    final resp = await cloudGet(
      'https://passport.baidu.com/channel/unicast'
      '?channel_id=${Uri.encodeQueryComponent((info['sign'] ?? '').toString())}'
      '&gid=${Uri.encodeQueryComponent((info['gid'] ?? '').toString())}'
      '&tpl=netdisk&_sdkFrom=1&apiver=v3&tt=$tt',
      headers: headers,
    );
    if (!resp.isOk) return null; // 瞬时错误，保持轮询
    final j = resp.json;
    final errno = (j['errno'] as num?)?.toInt() ?? -1;
    if (errno == 1) return null; // 待扫码/待确认
    if (errno != 0) throw const CloudException('二维码已失效，请刷新');
    // channel_v 为 JSON 字符串；status=0 表示已在手机端确认。
    final cvRaw = j['channel_v'];
    final cv = cvRaw is String
        ? jsonDecode(cvRaw) as Map<String, dynamic>?
        : cvRaw as Map<String, dynamic>?;
    if (cv == null || (cv['status'] as num?)?.toInt() != 0) return null;
    final v = (cv['v'] ?? '').toString();
    final u = (cv['u'] ?? '').toString();
    if (v.isEmpty) throw const CloudException('二维码已失效，请刷新');
    // 兑换 BDUSS/STOKEN（Set-Cookie 下发）。
    final ts = DateTime.now().millisecondsSinceEpoch;
    final resp2 = await cloudGet(
      'https://passport.baidu.com/v3/login/main/qrbdusslogin?v=$ts'
      '&bduss=${Uri.encodeQueryComponent(v)}'
      '&u=${Uri.encodeQueryComponent(u)}'
      '&loginVersion=v5&qrcode=1&tpl=netdisk',
      headers: headers,
    );
    final cookies = resp2.setCookiePairs;
    final bduss = cookies['BDUSS'] ?? '';
    if (bduss.isEmpty) throw const CloudException('登录失败，请重试');
    return CloudAccount(
      provider: id,
      accountId: md5Hex(bduss).substring(0, 12),
      nickname: u.isEmpty ? '百度账号' : u,
      cred: {
        'BDUSS': bduss,
        if ((cookies['STOKEN'] ?? '').isNotEmpty) 'STOKEN': cookies['STOKEN']!,
      },
      boundAt: DateTime.now(),
    );
  }

  static String _randomHex(int len) {
    final r = Random.secure();
    return List.generate(len, (_) => r.nextInt(16).toRadixString(16)).join();
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
