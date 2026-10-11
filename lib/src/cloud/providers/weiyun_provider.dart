// 微云 provider（webviewToken 混合：openid 走 pollScript，会话走
// Cookie）。
//
// goapi 接口字段防御式解析（接口形状不确定度高）；失败文案简短。

import 'dart:convert';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class WeiyunProvider extends CloudProvider {
  const WeiyunProvider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// goapi 统一请求头。
  Map<String, String> _h(Map<String, String> cred) => {
        'User-Agent': _ua,
        'Referer': 'https://www.weiyun.com/',
        'Content-Type': 'application/json',
        if (cred['cookie']?.isNotEmpty ?? false)
          'Cookie': cred['cookie'] ?? '',
      };

  Map<String, dynamic> _reqHeader() => {
        'cmd': 12001,
        'appid': '30013',
        'version': '3.9.9',
        'major_version': '3',
        'minor_version': '9',
        'fix_version': '9',
      };

  @override
  String get id => 'weiyun';

  @override
  String get displayName => '腾讯微云';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  String get webviewLoginUrl => 'https://www.weiyun.com/';

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        doneUrlPattern: RegExp(r'weiyun\.com'),
        pollScript: '''
(() => {
  var qq = null, wx = null;
  try { qq = localStorage.getItem('weiyun_qq_openid'); } catch (e) {}
  try { wx = localStorage.getItem('weiyun_wx_openid'); } catch (e) {}
  if ((qq && qq.length) || (wx && wx.length)) {
    return JSON.stringify({qq: qq, wx: wx});
  }
  return "";
})()''',
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    var openid = '';
    if (captured.token != null && captured.token!.isNotEmpty) {
      try {
        final j = jsonDecode(captured.token!);
        if (j is Map<String, dynamic>) {
          openid = ((j['qq'] ?? j['wx']) ?? '').toString();
        }
      } catch (_) {}
    }
    final cookie = cookieHeader(captured.cookies);
    if (openid.isEmpty && cookie.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    return CloudAccount(
      provider: id,
      accountId: md5Hex(openid.isEmpty ? cookie : openid).substring(0, 12),
      nickname: '腾讯微云',
      cred: {'cookie': cookie, 'openid': openid},
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    final remote = await tryRemoteValidate(id, cred);
    if (remote != null) return remote;
    return _validateLocal(cred);
  }

  Future<bool> _validateLocal(Map<String, String> cred) async {
    try {
      final resp = await cloudPostJson(
        'https://weiyun.com/webapp/json/weiyunShareNetdisk/WeiyunNetdiskDirList',
        body: {
          'req_header': _reqHeader(),
          'req_body': {
            'dir_key': '',
            'page_index': 0,
            'sort_field': 'create_time',
            'reverse_order': true,
            'filter': 0,
            'get_abstract_url': true,
          },
        },
        headers: _h(cred),
      );
      if (!resp.isOk) return false;
      final header =
          (resp.json['resp_header'] as Map<String, dynamic>?) ?? const {};
      return (header['retcode'] as num?)?.toInt() == 0 ||
          resp.json['resp_body'] != null;
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
    final page = int.tryParse(cursor ?? '') ?? 0;
    final resp = await cloudPostJson(
      'https://weiyun.com/webapp/json/weiyunShareNetdisk/WeiyunNetdiskDirList',
      body: {
        'req_header': _reqHeader(),
        'req_body': {
          'dir_key': path,
          'page_index': page,
          'sort_field': 'create_time',
          'reverse_order': true,
          'filter': 0,
          'get_abstract_url': true,
        },
      },
      headers: _h(cred),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final body = (resp.json['resp_body'] as Map<String, dynamic>?) ?? const {};
    final dirList = (body['dir_list'] as List?) ?? const [];
    final fileList = (body['file_list'] as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in dirList) {
      if (e is! Map<String, dynamic>) continue;
      // 目录 id：dir_key 优先，file_id 兜底。
      final id = (e['dir_key'] ?? e['file_id'] ?? '').toString();
      files.add(CloudFile(
        id: id,
        name: (e['file_name'] ?? e['dir_name'] ?? '').toString(),
        isDir: true,
        parentId: path,
      ));
    }
    for (final e in fileList) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['file_id'] ?? '').toString(),
        name: (e['file_name'] ?? '').toString(),
        isDir: false,
        size: (e['file_size'] as num?)?.toInt() ?? 0,
        parentId: path,
      ));
    }
    final hasNext = dirList.length + fileList.length >= 60;
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
    final shareKey = info?.shareId ?? url;
    // 分享页提取 shareKey 兜底（页面 JS 变量，脆弱）。
    var key = shareKey;
    try {
      final page = await cloudGet(
        'https://share.weiyun.com/${Uri.encodeQueryComponent(shareKey)}',
        headers: {'User-Agent': _ua},
      );
      if (page.isOk) {
        final m = RegExp(r'"share_key"\s*:\s*"([^"]+)"')
            .firstMatch(page.body);
        if (m != null) key = m.group(1)!;
      }
    } catch (_) {}
    final resp = await cloudPostJson(
      'https://weiyun.com/webapp/json/weiyunShare/WeiyunShareQuery',
      body: {
        'req_header': _reqHeader(),
        'req_body': {'share_key': key, 'pwd': pwd ?? ''},
      },
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    if (!resp.isOk) throw const CloudException('微云分享解析失败，请转存后播放');
    final body = (resp.json['resp_body'] as Map<String, dynamic>?) ?? const {};
    final list = (body['list'] as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['file_id'] ?? '').toString(),
        name: (e['file_name'] ?? '').toString(),
        isDir: e['is_dir'] == true,
        size: (e['file_size'] as num?)?.toInt() ?? 0,
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: key,
      passcode: pwd,
      directPlayable: false,
    );
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

  Future<List<CloudFile>> _transferShareFilesLocal(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    final resp = await cloudPostJson(
      'https://weiyun.com/webapp/json/weiyunNetdiskClient/CopySaveFile',
      body: {
        'req_header': _reqHeader(),
        'req_body': {
          'share_key': share.shareId,
          'pwd': share.passcode ?? '',
          'file_list': share.files
              .map((f) => {
                    'file_id': f.id,
                    'file_name': f.name,
                    'is_dir': f.isDir,
                  })
              .toList(),
        },
      },
      headers: _h(cred),
    );
    if (!resp.isOk) throw const CloudException('转存失败');
    // 接口不保证回新 id；返回原 files（防御式兜底）。
    return share.files;
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final remote = await tryRemoteDirectLink(id, cred, file);
    if (remote != null) return remote;
    return _getDirectLinkLocal(cred, file);
  }

  Future<CloudDirectLink> _getDirectLinkLocal(
      Map<String, String> cred, CloudFile file) async {
    final resp = await cloudPostJson(
      'https://weiyun.com/webapp/json/weiyunNetdiskClient/WebdiskDownloadRedirect',
      body: {
        'req_header': _reqHeader(),
        'req_body': {'file_id': file.id},
      },
      headers: _h(cred),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final body = (resp.json['resp_body'] as Map<String, dynamic>?) ?? const {};
    final url = (body['download_url'] ?? '').toString();
    if (url.isEmpty) throw const CloudException('直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua, 'Cookie': cred['cookie'] ?? ''},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }
}
