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
  String get apiHost => 'drive-pc.uc.cn';

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
        cookieNames: ['kps', 'sign'],
        // 覆盖完整登录链（同夸克）：主站、裸域、登录域 passport。
        cookieDomains: ['uc.cn', 'drive.uc.cn', 'pc.uc.cn', 'passport.uc.cn'],
        // kps/sign 已为 httpOnly，document.cookie 读不到，走原生通道。
        nativeCookies: true,
      );
}
