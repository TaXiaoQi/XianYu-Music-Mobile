// UC 网盘：继承 QuarkUcBase（接口与夸克同构），登录走 WebView 官方页
// 读 Cookie——captureRule 全收登录链非空 Cookie（2026-10 凭据更名
// kps/sign → __kps 系，同夸克 drive-web 体系），postLoginUrl 等齐
// __puus 再收尾。

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
}
