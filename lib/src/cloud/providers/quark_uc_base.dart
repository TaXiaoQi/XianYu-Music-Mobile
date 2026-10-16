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

  /// 客户端品牌参数（夸克 pr=ucpro；UC pr=UCBrowser——2026-10-16 起
  /// ucpro 通道对 UC 也收紧拒 Web Cookie，UCBrowser 通道仍宽容）。
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
    // 账号 ID 稳定性：真实 user_id > 昵称哈希 > Cookie 哈希。Cookie 每次
    // 登录都不同，直接哈希 Cookie 会导致重复登录产生重复账号（同用户
    // 出现「昵称 + 回退名」两条），故 Cookie 哈希只作最后兜底。
    var accountId = '';
    var nickname = displayName;

    // member 响应 → (user_id, nickname)。只认老结构 data.member：
    // 2026-10 drive-pc 网关把 member 拆成容量接口（data.member_info
    // 仅剩容量字段，无昵称，真机实测）；网页端昵称走 webHost 自身
    // 网关——先探 web 域，PC 域兜底。探测同时充当会话有效性闸门：
    // 两域都被拒（401 guest）说明捕获到的是死/残 Cookie（如缺 __puus），
    // 必须抛错回登录页重采——静默落库会产生「绑定成功但列目录即过期」
    // 的死账号（2026-10-16 实测）。
    var sessionOk = false;
    Future<void> probe(String url, Map<String, String> headers) async {
      final resp = await cloudGet(url, headers: headers);
      if (!resp.isOk) {
        final body =
            resp.body.length > 120 ? resp.body.substring(0, 120) : resp.body;
        AppLog.debug('cloud',
            '$displayName 昵称探测 status=${resp.status}: $body');
        return;
      }
      // 200 但返回 SPA HTML（web 域对无环境头 API 路径的兜底）或
      // envelope code != 0（guest JSON）都不算过闸。code 归一化：web 域
      // account/info 用 success 布尔 + code 字符串形态的响应壳。
      if (resp.body.trimLeft().startsWith('{')) {
        final code = resp.json['code'];
        final ok = code == null ||
            code == 0 ||
            code == '0' ||
            (code is String && int.tryParse(code) == 0) ||
            resp.json['success'] == true;
        // 只置位不覆盖：任一探过闸即认会话有效，后探被拒不得回拉。
        if (ok) sessionOk = true;
      }
      final data = resp.json['data'];
      if (data is! Map<String, dynamic>) return;
      // member 路径：老结构昵称在 data.member（2026-10 起多返回
      // data.member_info 仅剩容量字段）。
      final member = data['member'];
      if (member is Map<String, dynamic>) {
        final uid = (member['user_id'] ?? data['user_id'])?.toString();
        final nick = member['nickname']?.toString();
        if (uid != null && uid.isNotEmpty) accountId = uid;
        if (nick != null && nick.isNotEmpty) nickname = nick;
      }
      // account/info 路径：昵称/用户 id 在 data 本层。
      final localUid = data['user_id']?.toString();
      if (localUid != null && localUid.isNotEmpty) accountId = localUid;
      final localNick =
          (data['nick_name'] ?? data['nickname'] ?? data['user_name'])
              ?.toString();
      if (localNick != null && localNick.isNotEmpty) nickname = localNick;
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
    // 现役网页昵称接口：pan.quark.cn / drive.uc.cn 的 account/info
    //（先昵称头像后容量的官方前端双接口结构，社区现役实现均以此取
    // 昵称；member 已被 2026-10 拆改只剩容量）。
    if (nickname == displayName) {
      try {
        await probe('https://$webHost/account/info?fr=pc&platform=pc', {
          'User-Agent': CloudProvider.desktopWebviewUa,
          'Referer': 'https://$webHost/',
          'Cookie': cookieStr,
        });
      } catch (e) {
        AppLog.debug('cloud', '$displayName account/info 昵称探测失败: $e');
      }
    }
    if (!sessionOk) {
      throw const CloudException('登录会话未完成，请重新登录');
    }
    accountId = accountId.isNotEmpty
        ? accountId
        : (nickname != displayName
            ? 'u_${md5Hex(nickname).substring(0, 12)}'
            : md5Hex(cookieStr).substring(0, 12));
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
