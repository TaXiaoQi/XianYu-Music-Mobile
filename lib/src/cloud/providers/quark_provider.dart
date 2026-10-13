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

  // 主页「登录」按钮在右上角（ice SPA 动态渲染，SSR HTML 里没有），
  // PC 页 1:1 渲染下按钮在屏幕外右侧。页面加载完后把视口滚到页面
  // 右上角，登录入口直接展示，无需手动横向寻找（保持 1:1 渲染不缩放）。
  @override
  String? get webviewPageLoadedScript => r'''
(function(){
  setTimeout(function(){
    try { window.scrollTo(999999, 0); } catch (e) {}
  }, 600);
})();
''';

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        cookieNames: ['kps', 'sign'],
        cookieDomains: ['pan.quark.cn'],
        // kps/sign 已为 httpOnly，document.cookie 读不到，走原生通道。
        nativeCookies: true,
      );
}
