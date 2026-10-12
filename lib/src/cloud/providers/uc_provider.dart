// UC 网盘：继承 QuarkUcBase，仅声明品牌常量（接口与夸克同构）。

import '../cloud_provider.dart';
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
  String? get webviewUserAgent => CloudProvider.desktopWebviewUa;

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        cookieNames: ['kps', 'sign'],
        cookieDomains: ['drive.uc.cn', 'pc.uc.cn'],
        pollIntervalMs: 500,
      );
}
