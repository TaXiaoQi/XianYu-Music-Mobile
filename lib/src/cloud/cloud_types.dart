// 网盘播放引擎——公共模型与登录范式定义。
//
// 播放标识：`cloud://<provider>/<accountId>/<urlEncodedFileJson>`，
// 具体 provider/account/分享上下文另存 QueueItem.cloudInfoJson。
// 一期纯客户端；二期服务端同步在本模型上增量（CloudAccount 序列化
// 兼作同步载荷）。

/// 登录范式：决定绑定页把用户路由到哪个登录页面。
enum CloudLoginKind {
  /// WebView 内完成登录后捕获指定 Cookie（微云/139）
  webviewCookie,

  /// WebView 内完成登录 + JS 注入轮询捕获 Token（阿里）
  webviewToken,

  /// HTTP 账密登录（迅雷/PikPak/蓝奏/123 账密通道/天翼）
  httpPassword,

  /// 账密 + 短信验证码（天翼短信通道）
  smsPassword,

  /// 扫码登录（123/百度/夸克/UC）
  qrCode,
}

/// WebView 登录捕获规则（webviewCookie / webviewToken 两范式共用）。
class CloudCaptureRule {
  /// 需要捕获的 Cookie 名（webviewCookie 范式）。
  final List<String> cookieNames;

  /// Cookie 所在域（Cloudflare/WKWebView 按域隔离，逐域读取；
  /// nativeCookies 时首个域作为原生读取地址）。
  final List<String> cookieDomains;

  /// 页面 URL 命中该正则即认为登录流程走完，可读 Cookie。
  /// 为 null 时由轮询脚本自行判断（webviewToken 范式）。
  final RegExp? doneUrlPattern;

  /// webviewToken 范式：页面加载后注入的 JS 片段，返回非空字符串
  /// 即视为 token 出现（如 `localStorage.getItem('refresh_token')`）。
  final String? pollScript;

  /// JS 轮询间隔毫秒数。
  final int pollIntervalMs;

  /// 走原生 CookieManager 通道读 Cookie（可读 httpOnly，如百度 BDUSS；
  /// 上游 webview_flutter getCookies，鸿蒙 fork 无此 API 时由捕获会话
  /// 自动回退 document.cookie）。
  final bool nativeCookies;

  /// 禁用 URL 自动判定登录完成，仅凭用户点「我已登录完成」收 Cookie。
  /// 适用于登录前后 URL 不可区分的盘（如 139：登录后跳回同一个
  /// yun.139.com SPA 首页，doneUrlPattern 从第一秒就命中）。
  final bool manualDoneOnly;

  /// 登录完成后、捕获 Cookie 前补跳的主站页。部分盘的页面侧 Cookie
  /// （风控指纹等）要等主站页加载才种上（如百度 ndut_fmt/PANPSC），登录
  /// 页直接点「我已登录完成」会缺键。非 null 时点手动完成先跳此 URL，
  /// 页面加载后再读 Cookie。
  final String? postLoginUrl;

  const CloudCaptureRule({
    this.cookieNames = const [],
    this.cookieDomains = const [],
    this.doneUrlPattern,
    this.pollScript,
    this.pollIntervalMs = 500,
    this.nativeCookies = false,
    this.manualDoneOnly = false,
    this.postLoginUrl,
  });
}

/// WebView 登录捕获结果。
class CloudCaptureResult {
  const CloudCaptureResult({
    this.cookies = const {},
    this.token,
    this.finalUrl,
  });

  /// 捕获的指定 Cookie（name → value）。
  final Map<String, String> cookies;

  /// webviewToken 范式捕获的 token。
  final String? token;

  /// 结束时的页面 URL。
  final String? finalUrl;
}

/// 动态登录表单字段（cloud_password_login_page 按 provider 声明渲染）。
class CloudLoginField {
  const CloudLoginField({
    required this.key,
    required this.label,
    this.obscure = false,
    this.isPhone = false,
    this.isSmsCode = false,
  });

  final String key;
  final String label;
  final bool obscure;

  /// 手机号键盘。
  final bool isPhone;

  /// 该字段是短信验证码输入框（决定是否显示「发送验证码」按钮）。
  final bool isSmsCode;
}

/// 扫码登录会话。
class CloudQrLoginSession {
  const CloudQrLoginSession({
    required this.qrContent,
    required this.state,
    this.qrImageUrl,
  });

  /// 渲染成二维码的内容。
  final String qrContent;

  /// 服务方直接下发的二维码图片地址（优先于 [qrContent] 渲染）。
  final String? qrImageUrl;

  /// 轮询句柄（qrToken / state；百度为 gid/sign/cookie 的 JSON 串）。
  final String state;
}

/// 已绑定网盘账号。持久化时整体 JSON → AES 加密 → SecureStore。
class CloudAccount {
  const CloudAccount({
    required this.provider,
    required this.accountId,
    required this.nickname,
    required this.cred,
    required this.boundAt,
  });

  /// provider id（cloud_registry 内一致）。
  final String provider;

  /// 该盘内的账号唯一标识（user_id / 密码指纹等）。
  final String accountId;

  final String nickname;

  /// 凭据键值对（cookie / accessToken / refreshToken / sessionId…）。
  final Map<String, String> cred;

  final DateTime boundAt;

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'accountId': accountId,
        'nickname': nickname,
        'cred': cred,
        'boundAt': boundAt.millisecondsSinceEpoch,
      };

  static CloudAccount fromJson(Map<String, dynamic> j) => CloudAccount(
        provider: (j['provider'] ?? '').toString(),
        accountId: (j['accountId'] ?? '').toString(),
        nickname: (j['nickname'] ?? '').toString(),
        cred: (j['cred'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, v.toString()),
            ) ??
            const {},
        boundAt: DateTime.fromMillisecondsSinceEpoch(
          (j['boundAt'] as num?)?.toInt() ?? 0,
        ),
      );
}

/// 网盘文件条目。id/path 语义由各盘自定义（供 getDirectLink 复原）。
/// token 为各盘侧带令牌（夸克 fid_token、蓝奏分享页地址等），可空。
class CloudFile {
  const CloudFile({
    required this.id,
    required this.name,
    this.isDir = false,
    this.size = 0,
    this.parentId,
    this.path,
    this.token,
  });

  final String id;
  final String name;
  final bool isDir;
  final int size;
  final String? parentId;
  final String? path;

  /// 各盘侧带令牌（转存/直链用），跨页传递；无则 null。
  final String? token;

  /// 常见音频扩展名（浏览页识别可播条目用）。
  static const audioExts = {
    'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'ape', 'dsf', 'dff',
    'wma', 'opus', 'aiff', 'aif', 'alac', 'wv', 'tak', 'tta', 'ac3', 'dts',
  };

  bool get isAudio {
    final n = name.toLowerCase();
    final dot = n.lastIndexOf('.');
    if (dot < 0 || dot == n.length - 1) return false;
    return audioExts.contains(n.substring(dot + 1));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isDir': isDir,
        'size': size,
        if (parentId != null) 'parentId': parentId,
        if (path != null) 'path': path,
        if (token != null) 'token': token,
      };

  static CloudFile fromJson(Map<String, dynamic> j) => CloudFile(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        isDir: j['isDir'] == true,
        size: (j['size'] as num?)?.toInt() ?? 0,
        parentId: j['parentId']?.toString(),
        path: j['path']?.toString(),
        token: j['token']?.toString(),
      );
}

/// 目录列表结果。
class CloudListResult {
  const CloudListResult({required this.files, this.nextCursor});

  final List<CloudFile> files;

  /// null = 已到底。
  final String? nextCursor;
}

/// 分享链接解析结果。
class CloudShareParse {
  const CloudShareParse({
    required this.providerId,
    required this.files,
    this.shareId,
    this.shareToken,
    this.passcode,
    this.directPlayable = false,
  });

  final String providerId;

  /// 分享内文件（首层；目录条目转存时递归由 transferShareFiles 处理）。
  final List<CloudFile> files;

  /// 分享标识（surl / pwd_id / shareCode…），转存用。
  final String? shareId;

  /// stoken 类令牌（夸克/阿里转存与免转存直链要用）。
  final String? shareToken;

  final String? passcode;

  /// true = 支持免转存直链（蓝奏/139 outLink/夸克 acquire_dl_token），
  /// 播放走 getShareDirectLink；false = 必须 transferShareFiles 后播放。
  final bool directPlayable;
}

/// 直链（播放用）。headers 必须与 url 一起注册进播放代理。
class CloudDirectLink {
  const CloudDirectLink({
    required this.url,
    this.headers = const {},
    this.fileName,
    this.size,
    this.expireAt,
  });

  final String url;
  final Map<String, String> headers;
  final String? fileName;
  final int? size;

  /// null = 由 direct_link_cache 按默认 TTL 处理。
  final DateTime? expireAt;
}

/// 引擎层异常：文案直接面向用户（简短、只说原因）。
class CloudException implements Exception {
  const CloudException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 登录要求短信二次校验（如天翼 -133 设备校验）。provider 已自动发码并
/// 暂存会话，UI 弹窗收码后调 [CloudProvider.submitSmsCode] 完成绑定。
class CloudSmsRequiredException extends CloudException {
  const CloudSmsRequiredException(this.username) : super('需要短信验证');
  final String username;
}
