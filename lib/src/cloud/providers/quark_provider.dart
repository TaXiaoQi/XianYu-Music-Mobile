// 夸克网盘：继承 QuarkUcBase，仅声明品牌与登录页常量。
//
// 账密登录走 CAS 逆向（webviewFields，2026-10 实测同构 UC）：主 SPA
// passwordLoginPage 常量即 uop.quark.cn/cas/custom/login
// （client_id=532，sso/next 前端与 UC 同款表单 id/阿里云盾/ticket
// hook）；service_ticket 经 GET pan.quark.cn/account/info?st= 兑换
// 种 Cookie（假票实测返回 AUTH_ERROR:50051 Invalid service ticket，
// 端点在且与 UC 同码同体系）。表单/盾/脚本共享实现见 QuarkUcBase。

import '../cloud_types.dart';
import 'quark_uc_base.dart';

class QuarkProvider extends QuarkUcBase {
  const QuarkProvider();

  @override
  String get id => 'quark';

  @override
  String get displayName => '夸克网盘';

  @override
  String get apiHost => 'drive-pc.quark.cn';

  @override
  String get webHost => 'pan.quark.cn';

  // pr=ucpro 网关通道（pr=quark 客户端通道风控拒 Web Cookie；UC 侧
  // 2026-10-16 起也切 UCBrowser，与夸克通道不再相同）。
  @override
  String get pr => 'ucpro';

  @override
  String get uaBrand => 'quark-cloud-drive';

  @override
  String get webviewLoginUrl => 'https://pan.quark.cn/';

  // 「登录」按钮在右上角，PC 页 1:1 渲染下在屏幕外右侧；WebView 的
  // 视觉视口平移不受 JS scrollTo 控制，无法自动定位，由用户自行滚动。

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        // 2026-10 夸克 Web 端凭据更名：旧 kps/sign → __kps（sign Cookie
        // 已不存在），且 drive-pc 风控依赖完整 Cookie 链（ctoken/b-user-id/
        // __kp 等）——全收非空 Cookie 原样回传，账号兜底校验见 base 类
        // （__kps/__pus/__puus 任一在即有效）。全程 httpOnly，走原生通道。
        cookieNames: [],
        // 种下域覆盖完整登录链：主站 .quark.cn、裸域、登录接口域
        // （pl.quark.cn）——只读 pan.quark.cn 会漏。
        cookieDomains: ['quark.cn', 'pan.quark.cn', 'pl.quark.cn'],
        nativeCookies: true,
        // 同 UC：__puus 由落地页 init 请求后补签发，稳定性轮询等齐再收尾。
        postLoginUrl: 'https://pan.quark.cn/',
      );

  // ── CAS 账密逆向通道（webviewFields）────────────────────

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewFields;

  @override
  String get casPageHost => 'uop.quark.cn';

  /// CAS 账密登录页：主 SPA passwordLoginPage 同款端点（display=pc
  /// 出账密表单，token/key 由页面下发且与 CAS 会话 Cookie 绑定）。
  @override
  String get webviewFieldsLoginUrl =>
      'https://uop.quark.cn/cas/custom/login'
      '?custom_login_type=common&client_id=532&display=pc';

  /// service_ticket 兑换页：GET account/info?st= 服务端校验通过即
  /// Set-Cookie 种网盘凭据。__puus 由随后的主站落地页 init 请求
  /// 签发（captureRule.postLoginUrl 链）。
  @override
  String ticketExchangeUrl(String ticket) =>
      'https://pan.quark.cn/account/info?st=${Uri.encodeComponent(ticket)}';
}
