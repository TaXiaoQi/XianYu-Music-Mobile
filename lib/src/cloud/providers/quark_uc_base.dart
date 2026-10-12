// 夸克 / UC 网盘共用实现（两家同为阿里系 XCloud 架构，接口同构）。
//
// 登录：原生扫码——CAS 下发 token → 轮询 service ticket → st 兑换
// 登录 Cookie（kps/sign）；业务（列目录/分享/转存/直链）一律经
// cloud_remote 桥转发内嵌 Rust（rust/src/cloud/quark_uc.rs）。
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

  /// CAS 扫码域（uop.quark.cn / api.open.uc.cn）。
  String get casHost;

  /// 扫码内容模板（{token} 占位；品牌 App 扫码后跳确认页）。
  String get qrContentTemplate;

  String get commonQuery => 'pr=$pr&fr=pc&sys=win32&ve=3.23.2';

  String get _ua =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) $uaBrand/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch';

  /// 带凭据的通用请求头（登录态探测用）。
  Map<String, String> authHeaders(Map<String, String> cred) => {
        'User-Agent': _ua,
        'Referer': 'https://$webHost/',
        'Cookie': cookieHeader(cred),
      };

  /// 未带登录态的 Web 请求头（扫码链路用）。
  Map<String, String> get _webHeaders => {
        'User-Agent': _ua,
        'Referer': 'https://$webHost/',
      };

  @override
  String get rootPath => '0';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.qrCode;

  @override
  Duration get directLinkTtl => const Duration(hours: 2);

  // ── 登录（原生扫码）───────────────────────────────────

  @override
  Future<CloudQrLoginSession> createQrLogin() async {
    final resp = await cloudGet(
      'https://$casHost/cas/ajax/getTokenForQrcodeLogin',
      headers: _webHeaders,
    );
    if (!resp.isOk) throw const CloudException('二维码获取失败');
    final data = resp.json['data'];
    final members =
        data is Map<String, dynamic> ? data['members'] : null;
    final token = members is Map<String, dynamic>
        ? (members['token'] ?? '').toString()
        : '';
    if (token.isEmpty) throw const CloudException('二维码获取失败');
    return CloudQrLoginSession(
      qrContent: qrContentTemplate.replaceFirst('{token}', token),
      state: token,
    );
  }

  @override
  Future<CloudAccount?> pollQrLogin(CloudQrLoginSession session) async {
    final resp = await cloudGet(
      'https://$casHost/cas/ajax/getServiceTicketByQrcodeToken'
      '?token=${Uri.encodeQueryComponent(session.state)}',
      headers: _webHeaders,
    );
    if (!resp.isOk) return null; // 瞬时错误，保持轮询
    final j = resp.json;
    // 2000000=已确认（携带 service_ticket）；50004001=待扫码/待确认。
    final status = (j['status'] as num?)?.toInt() ?? 0;
    if (status == 50004001) return null;
    if (status != 2000000) throw const CloudException('二维码已失效，请刷新');
    final data = j['data'];
    final members = data is Map<String, dynamic> ? data['members'] : null;
    final st = members is Map<String, dynamic>
        ? (members['service_ticket'] ?? '').toString()
        : '';
    if (st.isEmpty) throw const CloudException('二维码已失效，请刷新');
    // st 兑换登录 Cookie（Set-Cookie 全收，含 kps/sign）。
    final resp2 = await cloudGet(
      'https://$apiHost/1/clouddrive/login?$commonQuery'
      '&st=${Uri.encodeQueryComponent(st)}',
      headers: _webHeaders,
    );
    return buildAccountFromCookies(resp2.setCookiePairs);
  }

  /// 登录 Cookie → 账号（member 接口拿昵称/用户 id，防御式兜底指纹）。
  Future<CloudAccount> buildAccountFromCookies(Map<String, String> cookies) async {
    if (cookies['kps']?.isEmpty ?? true) {
      throw const CloudException('登录凭据获取失败，请重试');
    }
    final cookieStr = cookieHeader(cookies);
    var accountId = md5Hex(cookieStr).substring(0, 12);
    var nickname = displayName;
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
