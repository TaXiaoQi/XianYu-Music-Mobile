// 夸克 / UC 网盘共用实现（两家同为阿里系 XCloud 架构，接口同构）。
//
// 登录：WebView 捕获 kps/sign Cookie；列目录/分享/转存/直链接口形状
// 一致，仅域名与 UA 品牌串不同。子类只声明常量。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

abstract class QuarkUcBase extends CloudProvider {
  const QuarkUcBase();

  /// API 域（drive-pc.quark.cn / drive-pc.uc.cn）。
  String get apiHost;

  /// Web 域（Referer 用）。
  String get webHost;

  /// 客户端品牌参数（pr=quark / ucpro）。
  String get pr;

  /// UA 品牌串（quark-cloud-drive / uc-cloud-drive）。
  String get uaBrand;

  String get commonQuery => 'pr=$pr&fr=pc&sys=win32&ve=3.23.2';

  /// 带凭据的通用请求头（子类兜底路由也用）。
  Map<String, String> authHeaders(Map<String, String> cred) => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) $uaBrand/2.5.20 Chrome/100.0.4896.160 '
                'Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch',
        'Referer': 'https://$webHost/',
        'Cookie': cookieHeader(cred),
      };

  /// 桌面版浏览器 UA（分享/直链请求用）。
  String get desktopUa =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  @override
  String get rootPath => '0';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  @override
  Duration get directLinkTtl => const Duration(hours: 2);

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final cookies = captured.cookies;
    if (cookies['kps']?.isEmpty ?? true) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    final cookieStr = cookieHeader(cookies);
    var accountId = md5Hex(cookieStr).substring(0, 12);
    var nickname = displayName;
    // member 接口拿昵称/用户 id（防御式：拿不到就用指纹兜底）。
    try {
      final resp = await cloudGet(
        'https://$apiHost/1/clouddrive/member?$commonQuery'
        '&fetch_subscribe=true&fetch_identity=true',
        headers: authHeaders(cookies),
      );
      if (resp.isOk) {
        final data = resp.json['data'];
        if (data is Map<String, dynamic>) {
          final member = data['member'];
          if (member is Map<String, dynamic>) {
            final uid = (member['user_id'] ?? data['user_id'])?.toString();
            final nick = member['nickname']?.toString();
            if (uid != null && uid.isNotEmpty) accountId = uid;
            if (nick != null && nick.isNotEmpty) nickname = nick;
          }
        }
      }
    } catch (_) {}
    return CloudAccount(
      provider: id,
      accountId: accountId,
      nickname: nickname,
      cred: cookies,
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    final remote = await tryRemoteValidate(id, cred);
    if (remote != null) return remote;
    try {
      final resp = await cloudGet(
        'https://$apiHost/1/clouddrive/member?$commonQuery',
        headers: authHeaders(cred),
      );
      return resp.status == 200;
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
      'https://$apiHost/1/clouddrive/file?$commonQuery'
      '&_page=$page&_size=100&pdir_fid=${Uri.encodeQueryComponent(path)}'
      '&_sort=file_type:asc,file_name:asc',
      headers: authHeaders(cred),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final data = resp.json['data'];
    final list = (data is Map<String, dynamic> ? data['list'] : null) as List?;
    final files = <CloudFile>[];
    for (final e in list ?? const []) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['fid'] ?? '').toString(),
        name: (e['file_name'] ?? '').toString(),
        isDir: e['dir'] == true || e['dir'] == 1,
        size: (e['size'] as num?)?.toInt() ?? 0,
        parentId: (e['pdir_fid'] ?? '').toString(),
        path: path,
        token: e['fid_token']?.toString(),
      ));
    }
    final total = data is Map<String, dynamic>
        ? (data['_total'] as num?)?.toInt() ?? 0
        : 0;
    final hasNext = page * 100 < total;
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

  Future<CloudShareParse> _parseShareLinkLocal(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final pwdId = info?.shareId ?? url;
    // 换 stoken（提取码错误时接口直接报）。
    final tokenResp = await cloudPostJson(
      'https://$apiHost/1/clouddrive/share/sharepage/token?$commonQuery',
      body: {'pwd_id': pwdId, 'passcode': pwd ?? ''},
      headers: {'User-Agent': desktopUa, 'Referer': 'https://$webHost/'},
    );
    if (!tokenResp.isOk) {
      throw const CloudException('分享链接解析失败');
    }
    final tj = tokenResp.json;
    final stoken = ((tj['data'] as Map<String, dynamic>?)?['stoken'] ?? '')
        .toString();
    if (stoken.isEmpty) {
      throw CloudException((tj['message'] ?? '提取码错误').toString());
    }
    final resp = await cloudGet(
      'https://$apiHost/1/clouddrive/share/sharepage/detail?$commonQuery'
      '&pwd_id=${Uri.encodeQueryComponent(pwdId)}'
      '&stoken=${Uri.encodeQueryComponent(stoken)}'
      '&pdir_fid=0&_page=1&_size=100'
      '&_sort=file_type:asc,file_name:asc',
      headers: authHeaders(const {}),
    );
    if (!resp.isOk) throw const CloudException('分享文件列表获取失败');
    final data = resp.json['data'];
    final list =
        (data is Map<String, dynamic> ? data['list'] : null) as List?;
    final files = <CloudFile>[];
    for (final e in list ?? const []) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['fid'] ?? e['share_fid'] ?? '').toString(),
        name: (e['file_name'] ?? '').toString(),
        isDir: e['dir'] == true || e['dir'] == 1,
        size: (e['size'] as num?)?.toInt() ?? 0,
        token: e['fid_token']?.toString(),
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: pwdId,
      shareToken: stoken,
      passcode: pwd,
      directPlayable: true,
    );
  }

  /// 分享免转存直链（夸克/UC 分享页下载接口）。
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
    final resp = await cloudPostJson(
      'https://$apiHost/1/clouddrive/share/sharepage/download?$commonQuery',
      body: {
        'pwd_id': share.shareId,
        'stoken': share.shareToken,
        'fids': [file.id],
      },
      headers: authHeaders(cred ?? const {}),
    );
    if (!resp.isOk) throw const CloudException('分享直链获取失败');
    final data = resp.json['data'];
    String? url;
    if (data is List && data.isNotEmpty) {
      url = (data.first as Map<String, dynamic>?)?['download_url']?.toString();
    } else if (data is Map<String, dynamic>) {
      url = data['download_url']?.toString();
    }
    if (url == null || url.isEmpty) throw const CloudException('分享直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': desktopUa, 'Referer': 'https://$webHost/'},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 2)),
    );
  }

  /// 转存 → 轮询任务 → 完成后按文件名回查新 fid（转存后 fid 会变）。
  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    final remote = await tryRemoteTransferShare(id, cred, share);
    if (remote != null) return remote;
    return _transferShareFilesLocal(cred, share);
  }

  Future<List<CloudFile>> _transferShareFilesLocal(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    final saveResp = await cloudPostJson(
      'https://$apiHost/1/clouddrive/share/sharepage/save?$commonQuery',
      body: {
        'to_pdir_fid': '0',
        'fid_list': share.files.map((f) => f.id).toList(),
        'fid_token_list': share.files.map((f) => f.token ?? '').toList(),
        'pwd_id': share.shareId,
        'stoken': share.shareToken,
      },
      headers: authHeaders(cred),
    );
    if (!saveResp.isOk) throw const CloudException('转存请求失败');
    final taskId =
        ((saveResp.json['data'] as Map<String, dynamic>?)?['task_id'] ?? '')
            .toString();
    if (taskId.isEmpty) throw const CloudException('转存失败');
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final tResp = await cloudGet(
        'https://$apiHost/1/clouddrive/task?$commonQuery'
        '&task_id=${Uri.encodeQueryComponent(taskId)}&retry_index=$i',
        headers: authHeaders(cred),
      );
      if (!tResp.isOk) continue;
      final status =
          ((tResp.json['data'] as Map<String, dynamic>?)?['status'] as num?)
              ?.toInt();
      if (status == 2) break;
      if (status != null && status >= 3) throw const CloudException('转存失败');
    }
    // 按文件名回查新 fid。
    final listed = await listDir(cred, '0');
    final byName = {for (final f in listed.files) f.name: f};
    final out = <CloudFile>[];
    for (final f in share.files) {
      final hit = byName[f.name];
      if (hit != null) {
        out.add(CloudFile(
          id: hit.id,
          name: hit.name,
          isDir: hit.isDir,
          size: hit.size,
          parentId: hit.parentId,
          path: hit.path,
          token: hit.token,
        ));
      }
    }
    if (out.isEmpty) throw const CloudException('转存失败');
    return out;
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final remote = await tryRemoteDirectLink(id, cred, file);
    if (remote != null) return remote;
    try {
      return await _directLinkRoute1(cred, file);
    } on CloudException {
      return directLinkRoute2(cred, file);
    }
  }

  Future<CloudDirectLink> _directLinkRoute1(
      Map<String, String> cred, CloudFile file) async {
    final resp = await cloudPostJson(
      'https://$apiHost/1/clouddrive/file/download?$commonQuery',
      body: {
        'fids': [file.id],
      },
      headers: authHeaders(cred),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final data = resp.json['data'];
    String? url;
    if (data is List && data.isNotEmpty) {
      url = (data.first as Map<String, dynamic>?)?['download_url']?.toString();
    } else if (data is Map<String, dynamic>) {
      url = data['download_url']?.toString();
    }
    if (url == null || url.isEmpty) throw const CloudException('直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': desktopUa, 'Referer': 'https://$webHost/'},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 2)),
    );
  }

  /// 免速兜底路由（夸克覆写；UC 无此通道，默认直接抛）。
  Future<CloudDirectLink> directLinkRoute2(
      Map<String, String> cred, CloudFile file) {
    throw const CloudException('直链获取失败');
  }
}
