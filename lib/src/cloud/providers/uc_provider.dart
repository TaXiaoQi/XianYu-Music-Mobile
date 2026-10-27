// UC 网盘：继承 QuarkUcBase（接口与夸克同构），账密登录走 CAS 逆向。
//
// CAS 账密通道（2026-10 逆向实测）：drive.uc.cn 登录面板「密码登录」
// tab 的 iframe 即 open.uc.cn/cas/custom/login（client_id=381），
// 表单/盾/ticket hook 与夸克全同（共享实现见 QuarkUcBase），差异仅
// host 与 client_id。service_ticket 经 GET
// drive.uc.cn/account/info?st= 兑换种 __kps 系 Cookie。

import '../cloud_types.dart';
import 'quark_uc_base.dart';

class UcProvider extends QuarkUcBase {
  const UcProvider();

  @override
  String get id => 'uc';

  @override
  String get displayName => 'UC网盘';

  @override
  String get apiHost => 'pc-api.uc.cn';

  @override
  String get webHost => 'drive.uc.cn';

  @override
  // 2026-10-16 起 ucpro 通道收紧拒 Web Cookie（401 guest，PC 实测），
  // UC 切 UCBrowser 通道（对 Web Cookie 宽容，OpenList 同款）。
  String get pr => 'UCBrowser';

  @override
  String get uaBrand => 'uc-cloud-drive';

  @override
  String get webviewLoginUrl => 'https://drive.uc.cn/';

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        // 2026-10 凭据更名同夸克（同一 drive-web 体系）：kps/sign →
        // __kps 系，sign Cookie 已不存在；drive-pc 风控依赖完整 Cookie
        // 链——全收非空 Cookie 原样回传。httpOnly，走原生通道。
        cookieNames: [],
        // 覆盖完整登录链（同夸克）：主站、裸域、登录域 passport。
        cookieDomains: ['uc.cn', 'drive.uc.cn', 'pc.uc.cn', 'passport.uc.cn'],
        nativeCookies: true,
        // __puus（长期鉴权锚）由落地页 init 请求在登录完成后数秒才签发
        // （2026-10-16 实测：URL 命中即捕获拿到 17 键死凭据，jar 里 2s
        // 后才出现 __puus）——postLoginUrl 触发稳定性轮询等齐再收尾。
        postLoginUrl: 'https://drive.uc.cn/',
      );

  // ── CAS 账密逆向通道（webviewFields）────────────────────

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewFields;

  @override
  String get casPageHost => 'open.uc.cn';

  /// CAS 账密登录页（登录面板 iframe 同款端点；display=pc 出账密
  /// 表单，token/key 由页面下发且与 CAS 会话 Cookie 绑定）。
  @override
  String get webviewFieldsLoginUrl =>
      'https://open.uc.cn/cas/custom/login'
      '?custom_login_type=common&client_id=381&display=pc';

  /// service_ticket 兑换页：GET account/info?st= 服务端校验通过即
  /// Set-Cookie 种网盘凭据（boot.js doAuth 同款端点）。__puus 由
  /// 随后的主站落地页 init 请求签发（captureRule.postLoginUrl 链）。
  @override
  String ticketExchangeUrl(String ticket) =>
      'https://drive.uc.cn/account/info?st=${Uri.encodeComponent(ticket)}';
}
