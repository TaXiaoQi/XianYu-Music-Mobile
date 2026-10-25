// UC 网盘：继承 QuarkUcBase（接口与夸克同构），账密登录走 CAS 逆向。
//
// CAS 账密通道（2026-10 逆向实测）：drive.uc.cn 登录面板「密码登录」
// tab 的 iframe 即 api.open.uc.cn/cas/custom/login（client_id=381），
// 表单明文账密 POST /cas/custom/login/commit，成功 status=20000 返回
// service_ticket（pm 模式 postMessage 给父页）；父页以
// GET drive.uc.cn/account/info?st=<ticket> 兑换种 __kps 系 Cookie。
// 提交/发码均强制阿里云盾（CaptchaV2 captcha_data / NC sig，离线
// 伪造不可行，实测 50058/20180001 硬拒）——自绘表单收账密，WebView
// 加载 CAS 页注入 JS 自动填表过盾抓 ticket，兑换后复用捕获链收尾。

import 'dart:convert';

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
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'account', label: '手机号 / 邮箱'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  /// CAS 账密登录页（登录面板 iframe 同款端点；display=pc 出账密
  /// 表单，token/key 由页面下发且与 CAS 会话 Cookie 绑定）。
  @override
  String get webviewFieldsLoginUrl =>
      'https://api.open.uc.cn/cas/custom/login'
      '?custom_login_type=common&client_id=381&display=pc';

  /// CAS 页执行脚本：hook 成功/失败回传 → 填账密 → 轮询盾回调
  /// （无痕自动通过约数秒；触发滑块时用户在 WebView 里拖动）→
  /// 就绪后点击原生提交按钮。60 秒未就绪放弃（防僵尸轮询）。
  @override
  String webviewFieldsScript(String account, String password) {
    final acc = jsonEncode(account);
    final pwd = jsonEncode(password);
    return '''
(function(){
  try {
    if (window.__xyCasHooked) return;
    window.__xyCasHooked = true;
    var post = function(m){ try { window.XianYuLogin.postMessage(m); } catch(e){} };
    window.postMessagePrivate = function(data){
      post('TICKET:' + (typeof data === 'string' ? data : JSON.stringify(data)));
    };
    var _sem = window.showErrorMessage;
    window.showErrorMessage = function(m){ post('MSG:' + (m || '')); if (_sem) _sem(m); };
    var ACC = $acc, PWD = $pwd;
    var fill = function(){
      var a = document.getElementById('login_name');
      var p = document.getElementById('password');
      if (a) a.value = ACC;
      if (p) p.value = PWD;
    };
    fill();
    var n = 0;
    var t = setInterval(function(){
      n++;
      fill();
      var ready = '';
      try {
        if (typeof AliyunCaptchaV2 !== 'undefined' && AliyunCaptchaV2.captchaVerifyParam) {
          ready = AliyunCaptchaV2.captchaVerifyParam;
          var cd = document.getElementById('captcha_data');
          if (cd && !cd.value) cd.value = ready;
        }
      } catch(e){}
      if (!ready) {
        var cd2 = document.getElementById('captcha_data');
        if (cd2 && cd2.value) ready = cd2.value;
      }
      if (ready) {
        clearInterval(t);
        var b = document.getElementById('submit_btn');
        if (b) b.click(); else post('MSG:提交入口缺失，请改用网页登录');
      } else if (n >= 60) {
        clearInterval(t);
        post('MSG:安全验证未就绪，请重试或改用网页登录');
      }
    }, 1000);
  } catch(e) {
    try { window.XianYuLogin.postMessage('MSG:' + e); } catch(_){}
  }
})();
''';
  }

  /// service_ticket 兑换页：GET account/info?st= 服务端校验通过即
  /// Set-Cookie 种网盘凭据（boot.js doAuth 同款端点）。__puus 由
  /// 随后的主站落地页 init 请求签发（captureRule.postLoginUrl 链）。
  @override
  String ticketExchangeUrl(String ticket) =>
      'https://drive.uc.cn/account/info?st=${Uri.encodeComponent(ticket)}';
}
