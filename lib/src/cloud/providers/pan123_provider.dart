// 123 云盘 provider（qrCode 主通道 + 账密兜底；分享免转存直链
// directPlayable=true）。
//
// DownloadUrl 字段实测可能是 JSON 串（{url:...}）或纯 URL，统一防御解析。

import 'dart:convert';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class Pan123Provider extends CloudProvider {
  const Pan123Provider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  Map<String, String> _h(String token) => {
        'User-Agent': _ua,
        'Referer': 'https://www.123pan.com/',
        'Platform': 'web',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  @override
  String get id => 'pan123';

  @override
  String get displayName => '123云盘';

  @override
  String get rootPath => '0';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.qrCode;

  @override
  Duration get directLinkTtl => const Duration(hours: 1);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'passport', label: '手机号 / 邮箱'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudQrLoginSession> createQrLogin() async {
    final resp = await cloudGet(
      'https://login.123pan.com/api/user/qr-code/generate',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) throw const CloudException('二维码获取失败');
    final data = resp.json['data'];
    if (data is! Map<String, dynamic>) throw const CloudException('二维码获取失败');
    final qr = (data['qr'] ?? '').toString();
    final uniId = (data['uniID'] ?? '').toString();
    if (qr.isEmpty || uniId.isEmpty) throw const CloudException('二维码获取失败');
    return CloudQrLoginSession(qrContent: qr, state: uniId);
  }

  @override
  Future<CloudAccount?> pollQrLogin(CloudQrLoginSession session) async {
    final resp = await cloudGet(
      'https://login.123pan.com/api/user/qr-code/result'
      '?uniID=${Uri.encodeQueryComponent(session.state)}',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) return null;
    final data = resp.json['data'];
    if (data is! Map<String, dynamic>) return null;
    final status = (data['status'] as num?)?.toInt() ?? 0;
    if (status != 2) return null; // 未确认。
    final token = (data['token'] ?? data['accessToken'] ?? '').toString();
    if (token.isEmpty) throw const CloudException('二维码已过期，请刷新');
    final user = data['user'];
    final uid = user is Map<String, dynamic>
        ? (user['id'] ?? '').toString()
        : '';
    final nick = user is Map<String, dynamic>
        ? ((user['nickname'] ?? user['Passport'] ?? '').toString())
        : '';
    return CloudAccount(
      provider: id,
      accountId: uid.isEmpty ? md5Hex(token).substring(0, 12) : uid,
      nickname: nick.isEmpty ? '123云盘' : nick,
      cred: {'token': token},
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final passport = (fields['passport'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (passport.isEmpty || password.isEmpty) {
      throw const CloudException('请填写账号和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final resp = await cloudPostJson(
        'https://user.123pan.cn/api/user/sign_in',
        body: {
          'passport': passport,
          'password': password,
          'remember': true,
        },
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
      );
      final code = (resp.json['code'] as num?)?.toInt() ?? -1;
      if (code != 200) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException((resp.json['message'] ?? '账号或密码错误').toString());
      }
      final token =
          ((resp.json['data'] as Map<String, dynamic>)['token'] ?? '')
              .toString();
      if (token.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录失败');
      }
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: md5Hex(token).substring(0, 12),
        nickname: passport,
        cred: {'token': token},
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
    final token = cred['token'] ?? '';
    for (final host in ['https://www.123pan.com', 'https://123pan.com']) {
      try {
        final resp = await cloudGet(
          '$host/b/api/user/info',
          headers: _h(token),
        );
        if (resp.isOk && (resp.json['code'] as num?)?.toInt() == 200) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  // ── 目录 ──────────────────────────────────────────────

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) async {
    final page = int.tryParse(cursor ?? '') ?? 1;
    final resp = await cloudGet(
      'https://www.123pan.com/b/api/file/list/new'
      '?parentFileId=${Uri.encodeQueryComponent(path)}'
      '&page=$page&limit=100&orderBy=file_id&orderDirection=asc'
      '&trashed=false&OnlyAbnormal=false&SearchData=false',
      headers: _h(cred['token'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final data = resp.json['data'];
    final list = data is Map<String, dynamic>
        ? (data['InfoList'] as List?) ?? const []
        : const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['fileId'] ?? '').toString(),
        name: (e['filename'] ?? '').toString(),
        isDir: (e['type'] as num?)?.toInt() == 1,
        size: (e['size'] as num?)?.toInt() ?? 0,
        parentId: (e['parentFileId'] ?? path).toString(),
      ));
    }
    final hasNext = files.length >= 100;
    return CloudListResult(
      files: files,
      nextCursor: hasNext ? '${page + 1}' : null,
    );
  }

  // ── 分享 ──────────────────────────────────────────────

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final shareKey = info?.shareId ?? url;
    final resp = await cloudGet(
      'https://www.123pan.com/b/api/share/get'
      '?shareKey=${Uri.encodeQueryComponent(shareKey)}'
      '&PassCode=${Uri.encodeQueryComponent(pwd ?? '')}'
      '&orderBy=file_id&orderDirection=asc',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) throw const CloudException('分享链接解析失败');
    final code = (resp.json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw CloudException(
          (resp.json['message'] ?? (pwd?.isNotEmpty ?? false ? '提取码错误' : '分享已失效'))
              .toString());
    }
    final data = resp.json['data'];
    final list = data is Map<String, dynamic>
        ? (data['InfoList'] as List?) ?? const []
        : const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['FileId'] ?? e['fileId'] ?? '').toString(),
        name: (e['FileName'] ?? e['filename'] ?? '').toString(),
        isDir: (e['Type'] as num?)?.toInt() == 1,
        size: (e['Size'] as num?)?.toInt() ?? 0,
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: shareKey,
      // 123 分享直链需复用提取码，shareToken 暂存 pwd。
      shareToken: pwd,
      passcode: pwd,
      directPlayable: true,
    );
  }

  /// 分享免转存直链（download/info 批量接口取单个文件）。
  @override
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) async {
    final pwd = share.passcode ?? share.shareToken ?? '';
    final resp = await cloudGet(
      'https://www.123pan.com/b/api/share/download/info'
      '?shareKey=${Uri.encodeQueryComponent(share.shareId ?? '')}'
      '&PassCode=${Uri.encodeQueryComponent(pwd)}'
      '&fileIds=${Uri.encodeQueryComponent(jsonEncode([
        {'FileId': file.id}
      ]))}',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) throw const CloudException('分享直链获取失败');
    final code = (resp.json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) throw const CloudException('分享直链获取失败');
    final data = resp.json['data'];
    final url = _extractDownloadUrl(data);
    if (url.isEmpty) throw const CloudException('分享直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  // directPlayable=true，不支持转存。
  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) {
    throw UnsupportedError('该盘分享不支持转存');
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final resp = await cloudGet(
      'https://www.123pan.com/b/api/file/download_info'
      '?driveId=0&fileId=${Uri.encodeQueryComponent(file.id)}'
      '&Referer=',
      headers: _h(cred['token'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final code = (resp.json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) throw const CloudException('直链获取失败');
    final url = _extractDownloadUrl(resp.json['data']);
    if (url.isEmpty) throw const CloudException('直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  /// DownloadUrl 可能是纯 URL、JSON 串或嵌套 data，统一防御解析。
  String _extractDownloadUrl(dynamic data) {
    if (data is String) {
      final s = data;
      if (s.startsWith('http')) return s;
      try {
        return _extractDownloadUrl(jsonDecode(s));
      } catch (_) {
        return '';
      }
    }
    if (data is Map<String, dynamic>) {
      for (final key in ['DownloadUrl', 'downloadUrl', 'download_url']) {
        final v = data[key];
        if (v is String && v.startsWith('http')) return v;
        if (v is String && v.isNotEmpty) {
          final inner = _extractDownloadUrl(v);
          if (inner.isNotEmpty) return inner;
        }
      }
      final backup = data['backup_download_url'] ?? data['BackupDownloadUrl'];
      if (backup is String && backup.startsWith('http')) {
        return backup;
      }
    }
    return '';
  }
}
