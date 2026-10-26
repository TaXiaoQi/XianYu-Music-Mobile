// 网盘 Provider 抽象基类。
//
// 每盘一个实现文件（providers/*.dart），声明登录范式与捕获规则，
// 实现「列目录 / 分享解析 / 转存 / 取直链」骨架；直链请求一律带
// UA/Referer 伪装矩阵，多 route 降级 + 限速域名黑名单。

import 'cloud_types.dart';

abstract class CloudProvider {
  const CloudProvider();

  /// 注册 id（cloud:// 与 cloud_registry 一致）。
  String get id;

  /// 显示名。
  String get displayName;

  /// 是否在网盘页提供绑定入口（false = 绑定列表不出现该盘，
  /// 分享链接导入等其余能力不受影响）。
  bool get bindable => true;

  CloudLoginKind get loginKind;

  /// WebView 初始 URL（webview 组；非 WebView 登录盘为空串）。
  String get webviewLoginUrl => '';

  /// WebView 登录页强制 UA（null = 系统默认）。
  /// 夸克/UC/微云的网页端对移动 UA 跳 App 下载/推广页，需桌面 UA 才出登录入口。
  String? get webviewUserAgent => null;

  /// 桌面浏览器 UA（webviewUserAgent 用）。
  static const desktopWebviewUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// WebView 捕获规则（webview 组；非 WebView 登录盘为 null）。
  CloudCaptureRule? get captureRule => null;

  /// 手动填兜底形态：true=填 Token（refresh_token/tokenInfo，凭据不在
  /// Cookie 的盘），false=填 Cookie。默认按有无 pollScript 推断。
  bool get manualTokenInput => captureRule?.pollScript != null;

  /// 手动填弹窗说明文案（null=按形态用默认文案）。
  String? get manualInputHint => null;

  /// WebView 登录壳 HTML（非 null 时登录页 loadHtmlString 渲染本页，
  /// 不再直接 loadRequest(webviewLoginUrl)——供需要 iframe/postMessage
  /// 桥接的盘（阿里）在壳页里完成 OAuth 流程）。
  String? get webviewShellHtml => null;

  /// 壳页 baseUrl（决定壳页 origin；postMessage targetOrigin 需匹配）。
  String? get webviewShellBaseUrl => null;

  /// 每页加载后注入的盘特有 JS（null=不注入）。用于个别盘的页面
  /// 适配（如百度 wap 登录页在宽视口下限宽居中），脚本自身按 host、
  /// 视口宽度与幂等自守卫，通用登录页不感知其内容。
  String? get webviewInjectJs => null;

  // ── webviewFields 组（自绘账密 + WebView 过盾执行）──────────

  /// WebView 加载的 CAS 账密登录页地址（webviewFields；非该组为空串）。
  String get webviewFieldsLoginUrl => '';

  /// 短信验证码辅助模式：自绘表单只收手机号，验证码经收码弹窗输入
  /// 后注入 WebView 页面提交（夸克：官方账密通道已下线，且发码接口
  /// 强制过盾，纯 HTTP 发码不可行——只能页内过盾）。
  bool get webviewFieldsIsSms => false;

  /// WebView 阶段表单说明文案覆盖（短信模式盘告知验证码在弹窗输入）。
  String? get webviewFieldsSmsHint => null;

  /// CAS 页加载后注入的执行脚本：填入账密 → 等盾回调就绪 → 触发
  /// 提交 → hook 成功/失败回传（经 XianYuLogin channel 发
  /// `TICKET:<data>` / `MSG:<message>`，登录页据此接管后续流程）。
  /// 账密以 JSON 字面量嵌入，由实现侧负责转义。
  String webviewFieldsScript(String account, String password) => '';

  /// 登录成功（service_ticket 到手）后的兑换页地址：WebView 导航过去
  /// 服务端 Set-Cookie 种网盘凭据（复用 captureRule 捕获链收尾）。
  String ticketExchangeUrl(String ticket) => '';

  /// CAS 账密登录页判定（登录页据此决定注入执行脚本的时机）。
  /// 默认不识别，webviewFields 实现盘各自 override。
  bool isWebviewFieldsLoginPage(Uri url) => false;

  /// CAS 兑换页判定（TICKET 兑换落地页，Set-Cookie 下发后应跳主站）。
  /// 默认按 [ticketExchangeUrl] 模板的 host+path 匹配，实现盘无需
  /// 单独 override（模板未配置时恒 false）。
  bool isTicketExchangePage(Uri url) {
    final t = Uri.tryParse(ticketExchangeUrl('probe'));
    return t != null &&
        t.host.isNotEmpty &&
        url.host == t.host &&
        url.path == t.path;
  }

  /// 账密/短信表单字段（httpPassword/smsPassword）。
  List<CloudLoginField> get loginFields => const [];

  /// 直链默认 TTL（实现未给 expireAt 时 direct_link_cache 兜底）。
  Duration get directLinkTtl => const Duration(minutes: 30);

  /// 浏览页根目录的 path 表示（各盘语义不同：'/'、'root'、'0'、'-11'…）。
  String get rootPath => '/';

  // ── 登录 ──────────────────────────────────────────────

  /// WebView 捕获结果 → 账号（webviewCookie/webviewToken 必须实现）。
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) =>
      throw UnsupportedError('该盘不支持 WebView 登录');

  /// 表单登录（httpPassword/smsPassword 必须实现）。
  Future<CloudAccount> loginWithFields(Map<String, String> fields) =>
      throw UnsupportedError('该盘不支持账密登录');

  /// 发送短信验证码（smsPassword）。
  Future<void> sendLoginSms(Map<String, String> fields) =>
      throw UnsupportedError('该盘不支持短信验证码');

  /// 提交登录短信验证码（收到 [CloudSmsRequiredException] 后由 UI 调用）。
  Future<CloudAccount> submitSmsCode(String username, String smsCode) =>
      throw UnsupportedError('该盘不支持短信验证码');

  /// 重发设备校验验证码（收到 [CloudSmsRequiredException] 后由 UI 弹窗
  /// 内的「发送验证码」按钮调用；弹窗打开时不自动发码）。
  Future<void> resendDeviceSms(String username) =>
      throw UnsupportedError('该盘不支持短信验证码');

  /// 创建扫码会话（qrCode）。
  Future<CloudQrLoginSession> createQrLogin() =>
      throw UnsupportedError('该盘不支持扫码登录');

  /// 轮询扫码结果：null=未确认；返回=成功；抛 CloudException=过期/取消。
  Future<CloudAccount?> pollQrLogin(CloudQrLoginSession session) =>
      throw UnsupportedError('该盘不支持扫码登录');

  // ── 能力 ──────────────────────────────────────────────

  /// 凭据有效性检查：根目录轻请求。
  Future<bool> validate(Map<String, String> cred);

  /// 列目录。path 为盘内绝对路径（'/' = 根）；cursor 翻页续传。
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  });

  /// 分享链接解析（解析分享列表不需要登录态；需要提取码时 pwd 非空）。
  Future<CloudShareParse> parseShareLink(String url, String? pwd);

  /// 转存分享文件到我的网盘，返回转存后的文件（directPlayable=false 必须实现）。
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) =>
      throw UnsupportedError('该盘不支持分享转存');

  /// 我的网盘文件直链。
  Future<CloudDirectLink> getDirectLink(Map<String, String> cred, CloudFile file);

  /// 分享文件免转存直链（directPlayable=true 的盘实现）。
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) =>
      throw UnsupportedError('该盘分享不支持免转存直链');

  /// 是否支持文件名搜索（支持时搜索来源栏展示该盘）。
  bool get supportsSearch => false;

  /// 全盘文件名搜索（search_files；cursor 翻页续传，语义同 listDir）。
  Future<CloudListResult> searchFiles(
    Map<String, String> cred,
    String keyword, {
    String? cursor,
  }) =>
      throw UnsupportedError('该盘不支持文件搜索');
}
