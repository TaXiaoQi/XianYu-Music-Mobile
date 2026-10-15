// 夸克 / UC 网盘共用实现（两家同为阿里系 XCloud 架构，接口同构）。
//
// 登录：WebView 打开官方网盘页（桌面 UA），脚本上下文读登录 Cookie
//（kps/sign 非 httpOnly）——原原生扫码链路的 st 兑换接口
// /1/clouddrive/login 已被官方下线（404），无替代兑换端点；
// 业务（列目录/分享/转存/直链）一律经 cloud_remote 桥转发内嵌
// Rust（rust/src/cloud/quark_uc.rs）。子类声明品牌与登录页常量。

import '../../core/application_logger.dart';
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

abstract class QuarkUcBase extends CloudProvider {
  const QuarkUcBase();

  /// API 域（drive-pc.quark.cn / pc-api.uc.cn）。
  String get apiHost;

  /// Web 域（Referer 用）。
  String get webHost;

  /// 客户端品牌参数（pr=ucpro：两家同为 UC 专业版网关，对 Web Cookie
  /// 宽容；pr=quark 客户端通道 2026-10 起风控拒绝 Web Cookie）。
  String get pr;

  String get commonQuery => 'pr=$pr&fr=pc&sys=win32&ve=3.23.2';

  String get _ua =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) $uaBrand/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch';

  /// UA 品牌串（quark-cloud-drive / uc-cloud-drive）。
  String get uaBrand;

  /// 带凭据的通用请求头（登录态探测用）。
  Map<String, String> authHeaders(Map<String, String> cred) => {
        'User-Agent': _ua,
        'Referer': 'https://$webHost/',
        'Cookie': cookieHeader(cred),
      };

  @override
  String get rootPath => '0';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  // 必须强制桌面 UA：移动 UA 下 pan.quark.cn / drive.uc.cn 一律
  // 302 到 h5.sm.cn / broccoli.uc.cn 的 H5 下载宣传页（无任何登录
  // 入口，实测确认）；桌面 UA 才出登录面板（UC 主站直接渲染账密/
  // 短信 tab，夸克点页面上「登录」弹窗），PC 排版缩放但可用。

  @override
  String? get webviewUserAgent => CloudProvider.desktopWebviewUa;

  @override
  Duration get directLinkTtl => const Duration(hours: 2);

  // ── 登录（WebView 捕获 Cookie）─────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) =>
      buildAccountFromCookies(captured.cookies);

  /// 登录 Cookie → 账号（member 接口拿昵称/用户 id，防御式兜底指纹）。
  Future<CloudAccount> buildAccountFromCookies(Map<String, String> cookies) async {
    // 2026-10 Web 端凭据更名：__kps / __pus / __puus 任一在即有效
    // （旧 kps/sign 名已不存在）。
    if ((cookies['__kps'] ?? cookies['__pus'] ?? cookies['__puus'])?.isEmpty ??
        true) {
      throw const CloudException('登录凭据获取失败，请重试');
    }
    final cookieStr = cookieHeader(cookies);
    var accountId = md5Hex(cookieStr).substring(0, 12);
    var nickname = displayName;

    // member 响应 → (user_id, nickname)。只认老结构 data.member：
    // 2026-10 drive-pc 网关把 member 拆成容量接口（data.member_info
    // 仅剩容量字段，无昵称，真机实测）；网页端昵称走 webHost 自身
    // 网关——先探 web 域，PC 域兜底（拿不到也不阻塞绑定）。
    Future<void> probe(String url, Map<String, String> headers) async {
      final resp = await cloudGet(url, headers: headers);
      if (!resp.isOk) {
        final body =
            resp.body.length > 120 ? resp.body.substring(0, 120) : resp.body;
        AppLog.debug('cloud',
            '$displayName 昵称探测 status=${resp.status}: $body');
        return;
      }
      final data = resp.json['data'];
      if (data is! Map<String, dynamic>) return;
      final member = data['member'];
      if (member is! Map<String, dynamic>) return;
      final uid = (member['user_id'] ?? data['user_id'])?.toString();
      final nick = member['nickname']?.toString();
      if (uid != null && uid.isNotEmpty) accountId = uid;
      if (nick != null && nick.isNotEmpty) nickname = nick;
    }

    try {
      await probe('https://$webHost/1/clouddrive/member', {
        'User-Agent': CloudProvider.desktopWebviewUa,
        'Referer': 'https://$webHost/',
        'Cookie': cookieStr,
      });
    } catch (e) {
      AppLog.debug('cloud', '$displayName web 域昵称探测失败: $e');
    }
    if (nickname == displayName) {
      try {
        await probe(
          'https://$apiHost/1/clouddrive/member?$commonQuery'
          '&fetch_subscribe=true&fetch_identity=true',
          authHeaders(cookies),
        );
      } catch (e) {
        AppLog.debug('cloud', '$displayName PC 域昵称探测失败: $e');
      }
    }
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
