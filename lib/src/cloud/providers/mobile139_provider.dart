// 移动云盘（139）provider（webviewCookie：登录页 Cookie 全收）。
//
// 分享走 outLink 免转存直链（directPlayable=true）；目录与个人盘
// 接口为 orchestration JSON 形态。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class Mobile139Provider extends CloudProvider {
  const Mobile139Provider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  Map<String, String> _h(String cookie) => {
        'User-Agent': _ua,
        'Referer': 'https://yun.139.com/',
        if (cookie.isNotEmpty) 'Cookie': cookie,
        'Content-Type': 'application/json',
      };

  @override
  String get id => 'mobile139';

  @override
  String get displayName => '移动云盘';

  @override
  String get rootPath => 'root';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  @override
  String get webviewLoginUrl => 'https://yun.139.com/';

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 全收（cookieNames 空 = 非空即采），登录完成由 URL 判定。
        doneUrlPattern: RegExp(r'yun\.139\.com'),
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final cookie = cookieHeader(captured.cookies);
    if (cookie.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    return CloudAccount(
      provider: id,
      accountId: md5Hex(cookie).substring(0, 12),
      nickname: '移动云盘',
      cred: {'cookie': cookie},
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    try {
      final resp = await cloudPostJson(
        'https://personal-kd-njs.yun.139.com/hcy/file/list',
        body: {
          'parentCatalogId': 'root',
          'catalogType': 3,
          'pageBean': {'pageNum': 1, 'pageSize': 1},
        },
        headers: _h(cred['cookie'] ?? ''),
      );
      if (!resp.isOk) return false;
      return (resp.json['status'] as num?)?.toInt() == 0 ||
          resp.json['success'] == true;
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
    final start = int.tryParse(cursor ?? '') ?? 1;
    final resp = await cloudPostJson(
      'https://yun.139.com/orchestration/personalCloud/catalog/listContents',
      body: {
        'parentCatalogId': path,
        'catalogType': 3,
        'contentListType': 1,
        'sortDirection': 1,
        'startNumber': start,
        'endNumber': start + 100,
        'filter': 0,
      },
      headers: _h(cred['cookie'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final data = resp.json['data'];
    final list = data is Map<String, dynamic>
        ? (data['contentList'] as List?) ?? const []
        : const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['contentId'] ?? '').toString(),
        name: (e['contentName'] ?? '').toString(),
        isDir: (e['isCatalog'] as num?)?.toInt() == 1,
        size: (e['contentSize'] as num?)?.toInt() ?? 0,
        parentId: (e['parentCatalogId'] ?? path).toString(),
      ));
    }
    final hasNext = files.length >= 100;
    return CloudListResult(
      files: files,
      nextCursor: hasNext ? '${start + 100}' : null,
    );
  }

  // ── 分享 ──────────────────────────────────────────────

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final guid = info?.shareId ?? url;
    final resp = await cloudPostJson(
      'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/'
      'IOutLink/getOutLinkInfoV6',
      body: {
        'outLinkGUID': guid,
        'passcode': pwd ?? '',
      },
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    if (!resp.isOk) throw const CloudException('分享链接解析失败');
    final data = resp.json['data'];
    final outLink = data is Map<String, dynamic>
        ? data['outLinkInfo'] as Map<String, dynamic>?
        : null;
    final list =
        (outLink?['fileList'] as List?) ?? const [];
    if (list.isEmpty) throw const CloudException('分享已失效');
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['contentId'] ?? '').toString(),
        name: (e['contentName'] ?? '').toString(),
        isDir: (e['isCatalog'] as num?)?.toInt() == 1,
        size: (e['contentSize'] as num?)?.toInt() ?? 0,
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: guid,
      passcode: pwd,
      directPlayable: true,
    );
  }

  /// 分享免转存直链（dlFromOutLinkV3）。
  @override
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) async {
    final resp = await cloudPostJson(
      'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/'
      'IOutLink/dlFromOutLinkV3',
      body: {
        'outLinkGUID': share.shareId,
        'passcode': share.passcode ?? '',
        'fileIds': [file.id],
      },
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    if (!resp.isOk) throw const CloudException('分享直链获取失败');
    final data = resp.json['data'];
    final fileList = data is Map<String, dynamic>
        ? (data['fileList'] as List?) ?? const []
        : const [];
    if (fileList.isEmpty) throw const CloudException('分享直链获取失败');
    final url = ((fileList.first as Map<String, dynamic>)['downloadUrl'] ?? '')
        .toString();
    if (url.isEmpty) throw const CloudException('分享直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }

  /// best-effort 转存（139 分享本可直链，转存作为留档兜底）。
  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    try {
      await cloudPostJson(
        'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/'
        'IBatchOprTask/createOuterLinkBatchOprTask',
        body: {
          'outLinkGUID': share.shareId,
          'passcode': share.passcode ?? '',
          'taskType': 2,
          'fileIds': share.files.map((f) => f.id).toList(),
        },
        headers: _h(cred['cookie'] ?? ''),
      );
    } catch (_) {}
    return share.files;
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final resp = await cloudPostJson(
      'https://personal-kd-njs.yun.139.com/hcy/file/getDownloadUrl',
      body: {
        'contentId': file.id,
        'catalogType': 3,
      },
      headers: _h(cred['cookie'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final url =
        ((resp.json['data'] as Map<String, dynamic>)['downloadUrl'] ?? '')
            .toString();
    if (url.isEmpty) throw const CloudException('直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }
}
