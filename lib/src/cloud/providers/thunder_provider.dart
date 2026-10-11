// 迅雷云盘 provider（httpPassword：v3/login 账密接口，password 传 md5）。
//
// XCloud 架构（与 PikPak 同构）：files/share/restore 接口形状一致。

import 'dart:convert';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class ThunderProvider extends CloudProvider {
  const ThunderProvider();

  static const _ua =
      'ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G '
      'appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC '
      'Oauth2Client/0.9';
  static const _clientId = 'Xq00jqW5m1PrHnV8';

  Map<String, String> _h(String accessToken) => {
        'User-Agent': _ua,
        'Referer': 'https://pan.xunlei.com/',
        if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  @override
  String get id => 'thunder';

  @override
  String get displayName => '迅雷云盘';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.httpPassword;

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'username', label: '手机号 / 邮箱'),
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
      final deviceId = uuidV4();
      final resp = await cloudPostJson(
        'https://xluser-ssl.xunlei.com/xluser.core.login/v3/login',
        body: {
          'client_id': _clientId,
          'action': 'login',
          'username': username,
          'password': md5Hex(password),
          'deviceid': deviceId,
        },
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
      );
      if (!resp.isOk) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录失败');
      }
      final accessToken = (resp.json['access_token'] ?? '').toString();
      final refreshToken = (resp.json['refresh_token'] ?? '').toString();
      if (accessToken.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException(
            (resp.json['error_description'] ?? resp.json['error'] ?? '账号或密码错误')
                .toString());
      }
      final userId = (resp.json['sub'] ?? resp.json['user_id'] ?? '')
          .toString();
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: userId.isEmpty ? md5Hex(username).substring(0, 12) : userId,
        nickname: username,
        cred: {
          'accessToken': accessToken,
          'refreshToken': refreshToken,
          'userId': userId,
        },
        boundAt: DateTime.now(),
      );
    } on CloudException {
      rethrow;
    } catch (_) {
      HttpLoginGate.instance.recordFailure(id);
      throw const CloudException('登录失败，请稍后再试');
    }
  }

  /// refresh 换新 access_token（best-effort；失败抛过期让用户重绑）。
  Future<String?> _refreshToken(Map<String, String> cred) async {
    final refreshToken = cred['refreshToken'];
    if (refreshToken == null || refreshToken.isEmpty) return null;
    try {
      final resp = await cloudPostJson(
        'https://xluser-ssl.xunlei.com/xluser.core.auth.token/v1/auth/token',
        body: {
          'refresh_token': refreshToken,
          'client_id': _clientId,
          'grant_type': 'refresh_token',
        },
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
      );
      if (!resp.isOk) return null;
      final at = (resp.json['access_token'] ?? '').toString();
      return at.isEmpty ? null : at;
    } catch (_) {
      return null;
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
      final at = await _auth(cred);
      final resp = await cloudGet(
        'https://api-pan.xunlei.com/drive/v1/about',
        headers: _h(at),
      );
      return resp.isOk;
    } catch (_) {
      return false;
    }
  }

  /// 带一次静默 refresh 的鉴权头取值（401 时由调用方判断）。
  Future<String> _auth(Map<String, String> cred) async {
    final cached = cred['accessToken'] ?? '';
    if (cached.isNotEmpty) return cached;
    final fresh = await _refreshToken(cred);
    if (fresh == null) throw const CloudException('登录已过期，请重新绑定');
    return fresh;
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
    final at = await _auth(cred);
    final resp = await cloudGet(
      'https://api-pan.xunlei.com/drive/v1/files'
      '?parent_id=${Uri.encodeQueryComponent(path)}&limit=100'
      '&page_token=${Uri.encodeQueryComponent(cursor ?? '')}'
      '&filters=${Uri.encodeQueryComponent(jsonEncode({
        'phase': {'in': ['PHASE_TYPE_COMPLETE']},
        'trashed': {'in': false},
      }))}',
      headers: _h(at),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final files = <CloudFile>[];
    for (final e in (resp.json['files'] as List?) ?? const []) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['id'] ?? '').toString(),
        name: (e['name'] ?? '').toString(),
        isDir: e['kind'] == 'drive#folder',
        size: (e['size'] as num?)?.toInt() ?? 0,
        parentId: path,
      ));
    }
    final next = (resp.json['next_page_token'] ?? '').toString();
    return CloudListResult(
      files: files,
      nextCursor: next.isEmpty ? null : next,
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
    final shareId = info?.shareId ?? url;
    final resp = await cloudGet(
      'https://api-pan.xunlei.com/drive/v1/share/detail'
      '?share_id=${Uri.encodeQueryComponent(shareId)}'
      '&pass_code=${Uri.encodeQueryComponent(pwd ?? '')}',
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    if (!resp.isOk) throw const CloudException('分享链接解析失败');
    final data = resp.json['share'] is Map<String, dynamic>
        ? resp.json
        : {'share': resp.json};
    final share = (data['share'] as Map<String, dynamic>?) ?? const {};
    final passCodeToken = (share['pass_code_token'] ?? '').toString();
    if (passCodeToken.isEmpty && (pwd?.isNotEmpty ?? false)) {
      throw const CloudException('提取码错误');
    }
    final list =
        ((resp.json['list'] ?? resp.json['files']) as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['file_id'] ?? e['id'] ?? '').toString(),
        name: (e['name'] ?? '').toString(),
        isDir: e['kind'] == 'drive#folder',
        size: (e['size'] as num?)?.toInt() ?? 0,
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: shareId,
      shareToken: passCodeToken,
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
    final at = await _auth(cred);
    final token = share.shareToken;
    if (token == null || token.isEmpty) throw const CloudException('请先填写提取码');
    final resp = await cloudPostJson(
      'https://api-pan.xunlei.com/drive/v1/share/restore',
      body: {
        'share_id': share.shareId,
        'pass_code_token': token,
        'file_list': share.files
            .map((f) => {'file_id': f.id, 'name': f.name})
            .toList(),
      },
      headers: _h(at),
    );
    if (!resp.isOk) throw const CloudException('转存失败');
    // 转存后 id 变化：按文件名回查根目录。
    final listed = await listDir(cred, '');
    final byName = {for (final f in listed.files) f.name: f};
    final out = <CloudFile>[];
    for (final f in share.files) {
      final hit = byName[f.name];
      if (hit != null) out.add(hit);
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
    return _getDirectLinkLocal(cred, file);
  }

  Future<CloudDirectLink> _getDirectLinkLocal(
      Map<String, String> cred, CloudFile file) async {
    final at = await _auth(cred);
    final resp = await cloudGet(
      'https://api-pan.xunlei.com/drive/v1/files/${Uri.encodeQueryComponent(file.id)}',
      headers: _h(at),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final url = (resp.json['web_content_link'] ?? '').toString();
    if (url.isEmpty) {
      // 部分文件在 medias[].link.url 兜底。
      final medias = (resp.json['medias'] as List?) ?? const [];
      for (final m in medias) {
        if (m is! Map<String, dynamic>) continue;
        final alt = ((m['link'] as Map<String, dynamic>?)?['url'] ?? '')
            .toString();
        if (alt.isNotEmpty) {
          return CloudDirectLink(
            url: alt,
            headers: {'User-Agent': _ua, 'Referer': 'https://pan.xunlei.com/'},
            fileName: file.name,
            size: file.size,
            expireAt: DateTime.now().add(const Duration(minutes: 30)),
          );
        }
      }
      throw const CloudException('直链获取失败');
    }
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua, 'Referer': 'https://pan.xunlei.com/'},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }
}
