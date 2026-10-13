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
  // 且 PC 页无 viewport meta，WebView 以 1:1 渲染——按钮整个在屏幕外。
  // 处理：先补一个 width=1240 的 viewport 让整页缩放适配屏宽（登录
  // 入口落到屏幕右上），再轮询找到精确文案为「登录」的可见元素自动
  // 点击，弹出登录框（登录框居中，fit 后正好在视野内）。
  @override
  String? get webviewAutoLoginScript => r'''
(function(){
  try {
    if (!document.querySelector('meta[name="viewport"]')) {
      var m = document.createElement('meta');
      m.name = 'viewport';
      m.content = 'width=1240, minimum-scale=0.2, maximum-scale=5, user-scalable=yes';
      (document.head || document.documentElement).appendChild(m);
    }
  } catch (e) {}
  if (window.__xymAutoLogin) return;
  window.__xymAutoLogin = true;
  var tries = 0;
  var t = setInterval(function(){
    try {
      var els = document.querySelectorAll('a,button,div,span');
      for (var i = 0; i < els.length; i++) {
        var e = els[i];
        if ((e.textContent || '').replace(/\s+/g, '') !== '\u767b\u5f55') continue;
        var r = e.getBoundingClientRect();
        if (r.width > 0 && r.height > 0 && r.width < 300 && r.height < 120) {
          e.click();
          clearInterval(t);
          return;
        }
      }
    } catch (err) {}
    if (++tries >= 25) clearInterval(t);
  }, 400);
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
