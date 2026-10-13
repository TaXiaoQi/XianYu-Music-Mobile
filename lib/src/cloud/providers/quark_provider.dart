// 夸克网盘：继承 QuarkUcBase，仅声明品牌与登录页常量。

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

  @override
  String get pr => 'quark';

  @override
  String get uaBrand => 'quark-cloud-drive';

  @override
  String get webviewLoginUrl => 'https://pan.quark.cn/';

  // 「登录」按钮在右上角，PC 页 1:1 渲染下在屏幕外右侧；WebView 的
  // 视觉视口平移不受 JS scrollTo 控制，无法自动定位，由用户自行滚动。

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        cookieNames: ['kps', 'sign'],
        cookieDomains: ['pan.quark.cn'],
        // kps/sign 已为 httpOnly，document.cookie 读不到，走原生通道。
        nativeCookies: true,
      );
}
