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
  // PC 页 1:1 渲染下按钮在屏幕外右侧。内容异步渲染，单次 scrollTo
  // 时机不稳——持续轮询：一旦出现横向溢出立即滚到页面右上角露出
  // 登录入口；用户一触摸屏幕就停止，不抢手势。
  @override
  String? get webviewPageLoadedScript => r'''
(function(){
  if (window.__xymPosRight) return;
  window.__xymPosRight = true;
  var n = 0;
  var t = setInterval(function(){
    try {
      var de = document.documentElement;
      var max = Math.max(0, (de.scrollWidth || 0) - window.innerWidth);
      if (max > 0) {
        window.scrollTo(max, 0);
        if (de.scrollWidth > de.clientWidth) de.scrollLeft = max;
        var b = document.body;
        if (b && b.scrollWidth > b.clientWidth) b.scrollLeft = max;
      }
    } catch (e) {}
    if (++n >= 20) clearInterval(t);
  }, 500);
  document.addEventListener('touchstart', function(){ clearInterval(t); },
    { passive: true });
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
