// UC 网盘：继承 QuarkUcBase，仅声明品牌与登录页常量（接口与夸克同构）。

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
  String get pr => 'ucpro';

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
