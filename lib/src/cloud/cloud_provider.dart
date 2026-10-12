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
}
