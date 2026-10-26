// 夸克 / UC 网盘共用实现（两家同为阿里系 XCloud 架构，接口同构）。
//
// 登录：WebView 打开官方网盘页（桌面 UA），脚本上下文读登录 Cookie
//（kps/sign 非 httpOnly）——原原生扫码链路的 st 兑换接口
// /1/clouddrive/login 已被官方下线（404），无替代兑换端点；
// 业务（列目录/分享/转存/直链）一律经 cloud_remote 桥转发内嵌
// Rust（rust/src/cloud/quark_uc.rs）。子类声明品牌与登录页常量。

import 'dart:convert';

import '../../core/application_logger.dart';
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

abstract class QuarkUcBase extends CloudProvider {
  const QuarkUcBase();

  /// API 域（drive-pc.quark.cn / pc-api.uc.cn）。
  String get apiHost;

  /// Web 域（Referer 用）。
  String get webHost;

  /// 客户端品牌参数（夸克 pr=ucpro；UC pr=UCBrowser——2026-10-16 起
  /// ucpro 通道对 UC 也收紧拒 Web Cookie，UCBrowser 通道仍宽容）。
  String get pr;

  String get commonQuery => 'pr=$pr&fr=pc&sys=win32&ve=3.23.2';

  String get _ua =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) $uaBrand/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch';

  /// UA 品牌串（quark-cloud-drive / uc-cloud-drive）。
  String get uaBrand;

  /// 带凭据的通用请求头（登录态探测用）。
  Map<String, String> authHeaders(Map<String, String> cred) => {
        'User-Agent': _ua,
        'Referer': 'https://$webHost/',
        'Cookie': cookieHeader(cred),
      };

  @override
  String get rootPath => '0';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  // ── CAS 账密逆向通道（webviewFields，UC/夸克同构共享）───────
  //
  // 两家登录面板 iframe 同为阿里 open 平台 CAS（sso/next 前端）：
  // 表单 id（login_name/password/submit_btn/captcha_data）、阿里云盾
  // （AliyunCaptchaV2）、ticket 回传 hook（postMessagePrivate）与
  // 兑换端点（{webHost}/account/info?st=）完全一致，差异仅 host 与
  // client_id。提交/发码强制过盾（离线伪造不可行）——自绘表单收账
  // 密，WebView 加载 CAS 页注入脚本自动填表过盾抓 ticket，兑换后
  // 复用捕获链收尾。

  /// CAS 登录页 host（open.uc.cn / uop.quark.cn）。
  String get casPageHost => '';

  @override
  bool isWebviewFieldsLoginPage(Uri url) =>
      url.host == casPageHost &&
      url.path.startsWith('/cas/custom/login');

  /// 账密表单字段（两家同款：手机号/邮箱 + 密码）。
  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'account', label: '手机号 / 邮箱'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  /// CAS 页执行脚本 v3（真机逆向结论：CAS SSR 页按钮 onclick 的验证
  /// 类型参数为空串，前端不做盾拦截；服务端风控要求图形验证码时报
  /// 「验证码错误」且老版 zepto 页面成功响应因 transmission_mode 为空
  /// 被静默丢弃）：
  /// ① hook $.ajax 抓 status=20000 的 service_ticket（夸克老版页面）；
  /// ② hook postMessagePrivate（UC 新版页面 pm 模式回调）；
  /// ③ 填账密 → 5 秒后自动提交（UC 新版页面若有无感盾，就绪即提前提交）；
  /// ④ 服务端报验证码错误 → 自动调 getCaptcha 拉图注入底部输入区，
  ///    用户填码点确定后携带 captcha_id/captcha_val 重提交。
  @override
  String webviewFieldsScript(String account, String password) {
    final acc = jsonEncode(account);
    final pwd = jsonEncode(password);
    // raw 字符串：JS 里的 $（zepto 选择器）不能被 dart 当插值解析，
    // 账密经占位符替换注入。
    return r'''
(function(){
  try {
    if (window.__xyCasHooked) return;
    window.__xyCasHooked = true;
    var post = function(m){ try { window.XianYuLogin.postMessage(m); } catch(e){} };
    var emitTicket = function(d){
      post('TICKET:' + (typeof d === 'string' ? d : JSON.stringify(d)));
    };
    window.postMessagePrivate = function(data){ emitTicket(data); };
    // zepto $.ajax hook：老版 SSR 页 transmission_mode 为空，成功响应
    // 在页面回调里被静默丢弃——拦截 success 直接抓 ticket。
    try {
      if (window.$ && window.$.ajax && !window.$.__xyAjax) {
        var _ajax = window.$.ajax;
        window.$.__xyAjax = true;
        window.$.ajax = function(o){
          try {
            if (o && o.success && !o.__xy) {
              o.__xy = true;
              var ok = o.success;
              o.success = function(r){
                try { if (r && r.status === 20000 && r.data) emitTicket(r.data); } catch(e){}
                ok(r);
              };
            }
          } catch(e){}
          return _ajax.apply(window.$, arguments);
        };
      }
    } catch(e){}
    var ACC = __XY_ACC__, PWD = __XY_PWD__;
    // 环境诊断（DIAG 由 App 落日志，不弹提示）。
    var diag = function(tag){
      var d = {t: tag, ready: document.readyState,
               css: document.querySelectorAll('link[rel=stylesheet]').length,
               js: document.querySelectorAll('script').length,
               sdk: (typeof AliyunCaptchaV2 !== 'undefined') ? 1 : 0,
               form: document.getElementById('login_name') ? 1 : 0};
      post('DIAG:' + JSON.stringify(d));
    };
    var fill = function(){
      var a = document.getElementById('login_name');
      var p = document.getElementById('password');
      if (a) a.value = ACC;
      if (p) p.value = PWD;
    };
    var submit = function(){
      var b = document.getElementById('submit_btn');
      if (b) { b.click(); return true; }
      post('MSG:提交入口缺失，请改用网页登录');
      return false;
    };
    // 图形验证码自闭合：服务端要求时响应报「验证码错误」而 SSR 页无
    // 验证码 UI——自动拉图注入底部输入区，填码确定后重提交（4 秒节流
    // 防连点；点图刷新）。
    var capBusy = 0;
    var drawCaptcha = function(){
      if (!window.$ || !window.$.ajax) return;
      var now = (new Date).getTime();
      if (now - capBusy < 4000) return;
      capBusy = now;
      var base = (document.getElementById('base_uri')||{}).value || '';
      window.$.ajax({
        type: 'POST',
        url: base + 'getCaptcha',
        data: {
          client_id: (document.getElementById('client_id')||{}).value || '',
          display: (document.getElementById('display')||{}).value || '',
          t: now
        },
        success: function(r){
          if (!r || !r.data || !r.data.captchaImage) return;
          var img = 'data:image/png;base64,' + r.data.captchaImage;
          var f = document.querySelector('#u_form form') ||
                  document.getElementById('u_form');
          if (!f) return;
          var idInp = document.getElementById('captcha_id');
          if (idInp) { idInp.value = r.data.captchaId; }
          else {
            var mk = function(i, nm){
              var el = document.createElement('input');
              el.type = 'hidden'; el.id = i; el.name = nm;
              f.appendChild(el); return el;
            };
            mk('captcha_id','captcha_id').value = r.data.captchaId;
            mk('captcha_val','captcha_val').value = '';
          }
          var imgEl = document.getElementById('xy_cap_img');
          if (imgEl) { imgEl.src = img; return; }
          var box = document.createElement('div');
          box.id = 'xy_cap';
          box.style.cssText = 'position:fixed;left:0;right:0;bottom:0;'
            + 'background:#fff;padding:12px;border-top:1px solid #ddd;'
            + 'z-index:99999;';
          box.innerHTML = '<div style="font-size:13px;color:#333;'
            + 'margin-bottom:8px;">请输入图形验证码</div>'
            + '<img id="xy_cap_img" src="' + img
            + '" style="width:110px;height:40px;vertical-align:middle;">'
            + '<input id="xy_cap_val" type="text" maxlength="6" '
            + 'placeholder="验证码" style="width:90px;height:38px;'
            + 'margin-left:10px;padding:0 8px;vertical-align:middle;'
            + 'border:1px solid #ccc;border-radius:4px;">'
            + '<button id="xy_cap_ok" type="button" style="height:38px;'
            + 'margin-left:10px;padding:0 14px;">确定</button>';
          document.body.appendChild(box);
          document.getElementById('xy_cap_img').onclick = function(){
            capBusy = 0; drawCaptcha();
          };
          document.getElementById('xy_cap_ok').onclick = function(){
            var v = (document.getElementById('xy_cap_val')||{}).value || '';
            if (!v) { post('MSG:请输入图形验证码'); return; }
            document.getElementById('captcha_val').value = v;
            submit();
          };
          post('MSG:请输入图形验证码');
        }
      });
    };
    var _sem = window.showErrorMessage;
    window.showErrorMessage = function(m){
      post('MSG:' + (m || ''));
      try {
        if (String(m || '').indexOf('验证码') >= 0) drawCaptcha();
      } catch(e){}
      if (_sem) _sem(m);
    };
    diag('init');
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
        submit();
      } else if (n === 5) {
        // 无感验证形态：盾参数在提交瞬间由 SDK 内部生成、不暴露全局，
        // 等是等不到的——给 SDK 5 秒初始化后直接点提交（需滑块时会
        // 弹出，用户页内拖动；服务端要求图形验证码时报「验证码错误」
        // 触发底部注入的填码区）。
        submit();
        post('MSG:已提交，若出现滑块请在页面内拖动');
      } else if (n >= 25) {
        clearInterval(t);
        diag('timeout');
        post('MSG:安全验证未就绪，请重试或改用网页登录');
      }
    }, 1000);
  } catch(e) {
    try { window.XianYuLogin.postMessage('MSG:' + e); } catch(_){}
  }
})();
'''.replaceAll('__XY_ACC__', acc).replaceAll('__XY_PWD__', pwd);
  }

  // 必须强制桌面 UA：移动 UA 下 pan.quark.cn / drive.uc.cn 一律
  // 302 到 h5.sm.cn / broccoli.uc.cn 的 H5 下载宣传页（无任何登录
  // 入口，实测确认）；桌面 UA 才出登录面板（UC 主站直接渲染账密/
  // 短信 tab，夸克点页面上「登录」弹窗），PC 排版缩放但可用。

  @override
  String? get webviewUserAgent => CloudProvider.desktopWebviewUa;

  @override
  Duration get directLinkTtl => const Duration(hours: 2);

  // ── 登录（WebView 捕获 Cookie）─────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) =>
      buildAccountFromCookies(captured.cookies);

  /// 登录 Cookie → 账号（member 接口拿昵称/用户 id，防御式兜底指纹）。
  Future<CloudAccount> buildAccountFromCookies(Map<String, String> cookies) async {
    // 2026-10 Web 端凭据更名：__kps / __pus / __puus 任一在即有效
    // （旧 kps/sign 名已不存在）。
    if ((cookies['__kps'] ?? cookies['__pus'] ?? cookies['__puus'])?.isEmpty ??
        true) {
      throw const CloudException('登录凭据获取失败，请重试');
    }
    final cookieStr = cookieHeader(cookies);
    // 账号 ID 稳定性：真实 user_id > 昵称哈希 > Cookie 哈希。Cookie 每次
    // 登录都不同，直接哈希 Cookie 会导致重复登录产生重复账号（同用户
    // 出现「昵称 + 回退名」两条），故 Cookie 哈希只作最后兜底。
    var accountId = '';
    var nickname = displayName;

    // member 响应 → (user_id, nickname)。只认老结构 data.member：
    // 2026-10 drive-pc 网关把 member 拆成容量接口（data.member_info
    // 仅剩容量字段，无昵称，真机实测）；网页端昵称走 webHost 自身
    // 网关——先探 web 域，PC 域兜底。探测同时充当会话有效性闸门：
    // 两域都被拒（401 guest）说明捕获到的是死/残 Cookie（如缺 __puus），
    // 必须抛错回登录页重采——静默落库会产生「绑定成功但列目录即过期」
    // 的死账号（2026-10-16 实测）。
    var sessionOk = false;
    Future<void> probe(String url, Map<String, String> headers) async {
      final resp = await cloudGet(url, headers: headers);
      if (!resp.isOk) {
        final body =
            resp.body.length > 120 ? resp.body.substring(0, 120) : resp.body;
        AppLog.debug('cloud',
            '$displayName 昵称探测 status=${resp.status}: $body');
        return;
      }
      // 200 但返回 SPA HTML（web 域对无环境头 API 路径的兜底）或
      // envelope code != 0（guest JSON）都不算过闸。code 归一化：web 域
      // account/info 用 success 布尔 + code 字符串形态的响应壳。
      if (resp.body.trimLeft().startsWith('{')) {
        final code = resp.json['code'];
        final ok = code == null ||
            code == 0 ||
            code == '0' ||
            (code is String && int.tryParse(code) == 0) ||
            resp.json['success'] == true;
        // 只置位不覆盖：任一探过闸即认会话有效，后探被拒不得回拉。
        if (ok) sessionOk = true;
      }
      final data = resp.json['data'];
      if (data is! Map<String, dynamic>) return;
      // member 路径：老结构昵称在 data.member（2026-10 起多返回
      // data.member_info 仅剩容量字段）。
      final member = data['member'];
      if (member is Map<String, dynamic>) {
        final uid = (member['user_id'] ?? data['user_id'])?.toString();
        final nick = member['nickname']?.toString();
        if (uid != null && uid.isNotEmpty) accountId = uid;
        if (nick != null && nick.isNotEmpty) nickname = nick;
      }
      // account/info 路径：昵称/用户 id 在 data 本层。
      final localUid = data['user_id']?.toString();
      if (localUid != null && localUid.isNotEmpty) accountId = localUid;
      final localNick =
          (data['nick_name'] ?? data['nickname'] ?? data['user_name'])
              ?.toString();
      if (localNick != null && localNick.isNotEmpty) nickname = localNick;
    }

    try {
      await probe('https://$webHost/1/clouddrive/member', {
        'User-Agent': CloudProvider.desktopWebviewUa,
        'Referer': 'https://$webHost/',
        'Cookie': cookieStr,
      });
    } catch (e) {
      AppLog.debug('cloud', '$displayName web 域昵称探测失败: $e');
    }
    if (nickname == displayName) {
      try {
        await probe(
          'https://$apiHost/1/clouddrive/member?$commonQuery'
          '&fetch_subscribe=true&fetch_identity=true',
          authHeaders(cookies),
        );
      } catch (e) {
        AppLog.debug('cloud', '$displayName PC 域昵称探测失败: $e');
      }
    }
    // 现役网页昵称接口：pan.quark.cn / drive.uc.cn 的 account/info
    //（先昵称头像后容量的官方前端双接口结构，社区现役实现均以此取
    // 昵称；member 已被 2026-10 拆改只剩容量）。
    if (nickname == displayName) {
      try {
        await probe('https://$webHost/account/info?fr=pc&platform=pc', {
          'User-Agent': CloudProvider.desktopWebviewUa,
          'Referer': 'https://$webHost/',
          'Cookie': cookieStr,
        });
      } catch (e) {
        AppLog.debug('cloud', '$displayName account/info 昵称探测失败: $e');
      }
    }
    if (!sessionOk) {
      throw const CloudException('登录会话未完成，请重新登录');
    }
    accountId = accountId.isNotEmpty
        ? accountId
        : (nickname != displayName
            ? 'u_${md5Hex(nickname).substring(0, 12)}'
            : md5Hex(cookieStr).substring(0, 12));
    return CloudAccount(
      provider: id,
      accountId: accountId,
      nickname: nickname,
      cred: cookies,
      boundAt: DateTime.now(),
    );
  }

  // ── 业务（rust 桥转发）─────────────────────────────────

  @override
  Future<bool> validate(Map<String, String> cred) =>
      rustValidate(id, cred);

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) =>
      rustListDir(id, cred, path, cursor: cursor);

  @override
  bool get supportsSearch => true;

  @override
  Future<CloudListResult> searchFiles(
    Map<String, String> cred,
    String keyword, {
    String? cursor,
  }) =>
      rustSearchFiles(id, cred, keyword, cursor: cursor);

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) =>
      rustParseShare(id, url, pwd);

  /// 分享免转存直链（夸克/UC 分享页下载接口）。
  @override
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) =>
      rustShareDirectLink(id, cred, share, file);

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) =>
      rustTransferShare(id, cred, share);

  @override
  Future<CloudDirectLink> getDirectLink(
          Map<String, String> cred, CloudFile file) =>
      rustDirectLink(id, cred, file);
}
