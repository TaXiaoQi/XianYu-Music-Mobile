// 蓝奏云 provider（httpPassword；分享免登录免转存直链
// directPlayable=true）。
//
// 接口为 HTML 页面形态，靠正则解析（域名常变，页面结构自适应尽力
// 而为）；解析出的直链直接塞 file.token，跨页传递。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class LanzouProvider extends CloudProvider {
  const LanzouProvider();

  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 '
      'Safari/604.1';

  Map<String, String> _h(String cookie) => {
        'User-Agent': _ua,
        'Referer': 'https://pc.woozooo.com/',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

  @override
  String get id => 'lanzou';

  @override
  String get displayName => '蓝奏云';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.httpPassword;

  @override
  Duration get directLinkTtl => const Duration(minutes: 20);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'username', label: '用户名'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final username = (fields['username'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const CloudException('请填写账号和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final resp = await cloudPostForm(
        'https://up.woozooo.com/mlogin.php',
        {
          'task': '3',
          'uid': username,
          'pwd': password,
          'authcode': '',
        },
        headers: {'User-Agent': _ua, 'Referer': 'https://up.woozooo.com/'},
      );
      if (!resp.isOk || !resp.body.contains('登录成功')) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('账号或密码错误');
      }
      final ylogin = resp.setCookiePairs['ylogin'] ?? '';
      if (ylogin.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录失败');
      }
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: md5Hex(ylogin).substring(0, 12),
        nickname: username,
        cred: {'cookie': 'ylogin=$ylogin'},
        boundAt: DateTime.now(),
      );
    } on CloudException {
      rethrow;
    } catch (_) {
      HttpLoginGate.instance.recordFailure(id);
      throw const CloudException('登录失败，请稍后再试');
    }
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    final remote = await tryRemoteValidate(id, cred);
    if (remote != null) return remote;
    return _validateLocal(cred);
  }

  Future<bool> _validateLocal(Map<String, String> cred) async {
    try {
      final resp = await cloudGet(
        'https://pc.woozooo.com/mydisk.php?item=files&action=index',
        headers: _h(cred['cookie'] ?? ''),
      );
      return resp.isOk && !resp.body.contains('mlogin');
    } catch (_) {
      return false;
    }
  }

  // ── 目录 ──────────────────────────────────────────────

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) async {
    final remote = await tryRemoteListDir(id, cred, path, cursor: cursor);
    if (remote != null) return remote;
    return _listDirLocal(cred, path, cursor: cursor);
  }

  Future<CloudListResult> _listDirLocal(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) async {
    final page = int.tryParse(cursor ?? '') ?? 1;
    final resp = await cloudGet(
      'https://pc.woozooo.com/mydisk.php?item=files&action=index'
      '${path.isEmpty ? '' : '&f_id=${Uri.encodeQueryComponent(path)}'}'
      '&page=$page',
      headers: _h(cred['cookie'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final body = resp.body;
    final files = <CloudFile>[];
    // 文件夹行：f_id=(\d+) 与名称就近配对（HTML 脆弱，尽力而为）。
    final folderRe = RegExp(r"f_id='?(\d+)'?[^>]*>[\s\S]{0,400}?class='t'>([^<]+)");
    for (final m in folderRe.allMatches(body)) {
      files.add(CloudFile(
        id: m.group(1)!,
        name: _htmlUnescape(m.group(2)!).trim(),
        isDir: true,
        parentId: path,
      ));
    }
    // 文件行：文件页链接作为 token（后续直链复用）。
    final fileRe = RegExp(
        r"(?:https?://[a-z0-9]+\.lanzou[a-z]?\.com/|/fn\?)[A-Za-z0-9_.-]+",
        caseSensitive: false);
    final nameRe = RegExp(r"class='t'[^>]*>([^<]{1,120})</a>");
    final names = nameRe.allMatches(body).map((m) => m.group(1)!).toList();
    final links = <String>{};
    for (final m in fileRe.allMatches(body)) {
      final raw = m.group(0)!;
      if (raw.contains('mydisk') || raw.contains('u.php')) continue;
      links.add(raw.startsWith('/') ? 'https://pc.woozooo.com$raw' : raw);
    }
    var i = 0;
    for (final link in links) {
      if (i >= names.length) break;
      final n = _htmlUnescape(names[i]).trim();
      i++;
      // 只收音频扩展名；名称判后缀。
      final dot = n.lastIndexOf('.');
      if (dot < 0 ||
          !CloudFile.audioExts.contains(n.substring(dot + 1).toLowerCase())) {
        continue;
      }
      files.add(CloudFile(
        id: link,
        name: n,
        token: link, // 分享页地址，getDirectLink 复用。
        parentId: path,
      ));
    }
    final hasNext = files.length >= 30;
    return CloudListResult(
      files: files,
      nextCursor: hasNext ? '${page + 1}' : null,
    );
  }

  // ── 分享 ──────────────────────────────────────────────

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    final remote = await tryRemoteParseShare(id, url, pwd);
    if (remote != null) return remote;
    return _parseShareLinkLocal(url, pwd);
  }

  /// 免登录免转存：每个文件解析出直链塞 token。
  Future<CloudShareParse> _parseShareLinkLocal(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final shareUrl = info?.url ?? url;
    final files = await _resolveSharePageFiles(shareUrl);
    if (files.isEmpty) throw const CloudException('分享已失效');
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: info?.shareId ?? shareUrl,
      passcode: pwd,
      directPlayable: true,
    );
  }

  @override
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) async {
    final remote = await tryRemoteShareDirectLink(id, cred, share, file);
    if (remote != null) return remote;
    return _getShareDirectLinkLocal(cred, share, file);
  }

  Future<CloudDirectLink> _getShareDirectLinkLocal(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) async {
    // parseShareLink 时直链已塞 file.token；直接回。
    final token = file.token ?? '';
    if (token.startsWith('http')) {
      return CloudDirectLink(
        url: token,
        headers: {'User-Agent': _ua},
        fileName: file.name,
        size: file.size,
        expireAt: DateTime.now().add(const Duration(minutes: 20)),
      );
    }
    // token 是分享页地址 → 重新解析。
    final url = token.isNotEmpty ? token : (share.shareId ?? '');
    final files = await _resolveSharePageFiles(url);
    for (final f in files) {
      if (f.name == file.name && (f.token ?? '').startsWith('http')) {
        return CloudDirectLink(
          url: f.token!,
          headers: {'User-Agent': _ua},
          fileName: file.name,
          size: file.size,
          expireAt: DateTime.now().add(const Duration(minutes: 20)),
        );
      }
    }
    throw const CloudException('分享已失效');
  }

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    final remote = await tryRemoteTransferShare(id, cred, share);
    if (remote != null) return remote;
    return _transferShareFilesLocal(cred, share);
  }

  // directPlayable=true，不支持转存。
  Future<List<CloudFile>> _transferShareFilesLocal(
    Map<String, String> cred,
    CloudShareParse share,
  ) {
    throw UnsupportedError('该盘分享不支持转存');
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final remote = await tryRemoteDirectLink(id, cred, file);
    if (remote != null) return remote;
    return _getDirectLinkLocal(cred, file);
  }

  /// 我的网盘文件：file.token 为分享页地址（浏览页入口解析时写入）。
  Future<CloudDirectLink> _getDirectLinkLocal(
      Map<String, String> cred, CloudFile file) async {
    final link = file.token ?? '';
    if (link.startsWith('http')) {
      return _directFromSharePage(link, file.name, file.size);
    }
    throw const CloudException('直链获取失败');
  }

  // ── 内部 ──────────────────────────────────────────────

  /// 分享页 → 子页（iframe）→ 隐含表单 → /ajaxm.php → 直链。
  Future<List<CloudFile>> _resolveSharePageFiles(String shareUrl) async {
    final page = await _get(shareUrl);
    if (page.isEmpty) throw const CloudException('分享已失效');
    // 顶层可能是多文件页（iframe 列表）或单文件页。
    final iframeRe =
        RegExp(r'<iframe[^>]+src="([^"]+)"', caseSensitive: false);
    final subLinks = <String>[];
    for (final m in iframeRe.allMatches(page)) {
      final src = m.group(1)!;
      if (src.contains('file')) {
        subLinks.add(src.startsWith('//') ? 'https:$src' : src);
      }
    }
    if (subLinks.isEmpty) {
      // 单文件页：直接解析出直链。
      final direct = await _directFromPage(page, Uri.parse(shareUrl).host);
      return [
        CloudFile(
          id: shareUrl,
          name: _pageTitle(page) ?? '蓝奏云文件',
          token: direct ?? shareUrl,
        ),
      ];
    }
    final files = <CloudFile>[];
    for (final sub in subLinks.take(30)) {
      final subPage = await _get(sub);
      if (subPage.isEmpty) continue;
      final host = Uri.tryParse(sub)?.host ?? '';
      final direct = await _directFromPage(subPage, host);
      files.add(CloudFile(
        id: sub,
        name: _pageTitle(subPage) ?? '蓝奏云文件',
        token: direct ?? sub,
      ));
    }
    return files;
  }

  /// 子页隐含表单参数 → POST /ajaxm.php → dom+url 直链。
  Future<String?> _directFromPage(String page, String host) async {
    // 隐含 input（name/value 顺序可反，双向匹配）。
    final pairs = <String, String>{};
    final inputRe = RegExp(
        r'<input[^>]+(?:name="([^"]*)"[^>]+value="([^"]*)"'
        r'|value="([^"]*)"[^>]+name="([^"]*)")',
        caseSensitive: false);
    for (final m in inputRe.allMatches(page)) {
      final name = (m.group(1) ?? m.group(4) ?? '').trim();
      final value = (m.group(2) ?? m.group(3) ?? '').trim();
      if (name.isEmpty) continue;
      pairs[name] = _htmlUnescape(value);
    }
    if (pairs.isEmpty) return null;
    final resp = await cloudPostForm(
      'https://$host/ajaxm.php',
      pairs,
      headers: {'User-Agent': _ua, 'Referer': 'https://$host/'},
    );
    if (!resp.isOk) return null;
    try {
      final j = resp.json;
      final zt = (j['zt'] as num?)?.toInt() ?? 0;
      if (zt != 1) return null; // 分享已失效等。
      final dom = (j['dom'] ?? '').toString();
      final url = (j['url'] ?? '').toString();
      if (url.startsWith('http')) return url;
      if (dom.isNotEmpty && url.isNotEmpty) return '$dom$url';
    } catch (_) {}
    return null;
  }

  Future<CloudDirectLink> _directFromSharePage(
      String url, String name, int size) async {
    final page = await _get(url);
    if (page.isEmpty) throw const CloudException('分享已失效');
    final host = Uri.tryParse(url)?.host ?? '';
    // 单文件页直接出直链；多文件页先找 iframe。
    final iframeRe =
        RegExp(r'<iframe[^>]+src="([^"]+)"', caseSensitive: false);
    var target = page;
    var targetHost = host;
    final m = iframeRe.firstMatch(page);
    if (m != null) {
      final src = m.group(1)!;
      final sub = src.startsWith('//') ? 'https:$src' : src;
      target = await _get(sub);
      targetHost = Uri.tryParse(sub)?.host ?? host;
    }
    final direct = await _directFromPage(target, targetHost);
    if (direct == null) throw const CloudException('分享已失效');
    return CloudDirectLink(
      url: direct,
      headers: {'User-Agent': _ua},
      fileName: name,
      size: size,
      expireAt: DateTime.now().add(const Duration(minutes: 20)),
    );
  }

  Future<String> _get(String url) async {
    try {
      final resp = await cloudGet(url, headers: {'User-Agent': _ua});
      return resp.isOk ? resp.body : '';
    } catch (_) {
      return '';
    }
  }

  String? _pageTitle(String page) {
    final m = RegExp(
      r"<title>([^<]{1,120})</title>",
      caseSensitive: false,
    ).firstMatch(page);
    if (m == null) return null;
    var t = _htmlUnescape(m.group(1)!).trim();
    // 常见尾缀「xxx - 蓝奏云」。
    t = t.replaceFirst(RegExp(r'\s*[-–]\s*蓝奏云\s*$'), '');
    return t.isEmpty ? null : t;
  }

  String _htmlUnescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
}
