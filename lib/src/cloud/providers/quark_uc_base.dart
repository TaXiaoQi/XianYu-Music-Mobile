// 夸克 / UC 网盘共用实现（两家同为阿里系 XCloud 架构，接口同构）。
//
// 登录：WebView 捕获 kps/sign Cookie；业务（列目录/分享/转存/直链）
// 一律经 cloud_remote 桥转发内嵌 Rust（rust/src/cloud/quark_uc.rs）。
// 子类只声明常量。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

abstract class QuarkUcBase extends CloudProvider {
  const QuarkUcBase();

  /// API 域（drive-pc.quark.cn / drive-pc.uc.cn）。
  String get apiHost;

  /// Web 域（Referer 用）。
  String get webHost;

  /// 客户端品牌参数（pr=quark / ucpro）。
  String get pr;

  /// UA 品牌串（quark-cloud-drive / uc-cloud-drive）。
  String get uaBrand;

  String get commonQuery => 'pr=$pr&fr=pc&sys=win32&ve=3.23.2';

  /// 带凭据的通用请求头（登录态探测用）。
  Map<String, String> authHeaders(Map<String, String> cred) => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) $uaBrand/2.5.20 Chrome/100.0.4896.160 '
                'Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch',
        'Referer': 'https://$webHost/',
        'Cookie': cookieHeader(cred),
      };

  @override
  String get rootPath => '0';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  @override
  Duration get directLinkTtl => const Duration(hours: 2);

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final cookies = captured.cookies;
    if (cookies['kps']?.isEmpty ?? true) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    final cookieStr = cookieHeader(cookies);
    var accountId = md5Hex(cookieStr).substring(0, 12);
    var nickname = displayName;
    // member 接口拿昵称/用户 id（防御式：拿不到就用指纹兜底）。
    try {
      final resp = await cloudGet(
        'https://$apiHost/1/clouddrive/member?$commonQuery'
        '&fetch_subscribe=true&fetch_identity=true',
        headers: authHeaders(cookies),
      );
      if (resp.isOk) {
        final data = resp.json['data'];
        if (data is Map<String, dynamic>) {
          final member = data['member'];
          if (member is Map<String, dynamic>) {
            final uid = (member['user_id'] ?? data['user_id'])?.toString();
            final nick = member['nickname']?.toString();
            if (uid != null && uid.isNotEmpty) accountId = uid;
            if (nick != null && nick.isNotEmpty) nickname = nick;
          }
        }
      }
    } catch (_) {}
    return CloudAccount(
      provider: id,
      accountId: accountId,
      nickname: nickname,
      cred: cookies,
      boundAt: DateTime.now(),
    );
  }

  // ── 业务（rust 桥转发）─────────────────────────────────

  @override
  Future<bool> validate(Map<String, String> cred) =>
      rustValidate(id, cred);

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

  /// 分享免转存直链（夸克/UC 分享页下载接口）。
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
