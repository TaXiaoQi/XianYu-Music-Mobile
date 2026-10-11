// 阿里云盘 provider（webviewToken：oauth 页轮询 localStorage 抓
// refresh_token）。
//
// 关键点：refresh_token 单次有效，每次刷新 access_token 后必须把新
// refresh_token 经 updateCred 落盘，否则下次刷新全部失效。

import 'dart:convert';

import '../cloud_credentials_store.dart';
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';

class AliyunProvider extends CloudProvider {
  AliyunProvider();

  static const _clientId = '25dzX3vbYqktVxyX';

  Map<String, String> _h(String accessToken) => {
        'User-Agent': _ua,
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// drive_id 实例内缓存（用户维度不变）。
  final Map<String, String> _driveIdCache = <String, String>{};

  @override
  String get id => 'aliyun';

  @override
  String get displayName => '阿里云盘';

  @override
  String get rootPath => 'root';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  Duration get directLinkTtl => const Duration(hours: 4);

  @override
  String get webviewLoginUrl =>
      'https://auth.aliyundrive.com/v2/oauth/authorize?login_type=custom'
      '&response_type=code'
      '&redirect_uri=${Uri.encodeQueryComponent('https://www.aliyundrive.com/sign/callback')}'
      '&client_id=$_clientId'
      '&state=${Uri.encodeQueryComponent('{"origin":"*"}')}#/login';

  /// 轮询脚本：必须是返回字符串的 JS 表达式（IIFE）。
  /// 遍历 localStorage/sessionStorage 找 refresh_token（键名兼容多种）。
  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        pollScript: '''
(() => {
  var keys = ['token','TOKEN','loginToken','login_token','auth_token',
              'aliyundrive_token','alipan_token','accountToken'];
  var stores = [window.localStorage, window.sessionStorage];
  for (var s = 0; s < stores.length; s++) {
    for (var i = 0; i < keys.length; i++) {
      var raw = null;
      try { raw = stores[s].getItem(keys[i]); } catch (e) {}
      if (!raw) continue;
      var obj = raw;
      try { obj = JSON.parse(raw); } catch (e) {}
      var rt = '', uid = '', nick = '';
      var found = (function scan(o, depth) {
        if (!o || typeof o !== 'object' || depth > 3) return false;
        if (o.refresh_token) {
          rt = String(o.refresh_token);
          uid = o.user_id ? String(o.user_id) : '';
          nick = (o.nick_name || o.name || '').toString();
          return true;
        }
        if (o.data && scan(o.data, depth + 1)) return true;
        if (o.content && scan(o.content, depth + 1)) return true;
        return false;
      })(obj, 0);
      if (found) {
        return JSON.stringify({rt: rt, uid: uid, nick: nick});
      }
    }
  }
  return "";
})()''',
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final raw = captured.token;
    if (raw == null || raw.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw const CloudException('登录凭据解析失败，请重新登录');
    }
    final refreshToken = (parsed['rt'] ?? '').toString();
    if (refreshToken.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    final uid = (parsed['uid'] ?? '').toString();
    final nick = (parsed['nick'] ?? '').toString();
    final accountId = uid.isNotEmpty ? uid : refreshToken.substring(0, 12);
    final cred = <String, String>{
      'refreshToken': refreshToken,
      'userId': uid,
      'nickname': nick,
      // accountId 冗余存一份：refresh 轮换落盘时按它定位账号。
      'accountId': accountId,
    };
    return CloudAccount(
      provider: id,
      accountId: accountId,
      nickname: nick.isNotEmpty ? nick : '阿里云盘',
      cred: cred,
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    final remote = await tryRemoteValidate(id, cred);
    if (remote != null) return remote;
    try {
      final at = await _accessToken(cred, persist: false);
      final resp = await cloudPostJson(
        'https://api.alipan.com/adrive/v2/user/getInfo',
        body: const {},
        headers: _h(at),
      );
      return resp.isOk;
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
    final at = await _accessToken(cred, persist: true);
    final driveId = await _driveId(cred, at);
    final resp = await cloudPostJson(
      'https://api.alipan.com/adrive/v3/file/list',
      body: {
        'drive_id': driveId,
        'parent_file_id': path,
        'limit': 100,
        'marker': cursor ?? '',
        'order_by': 'name',
        'order_direction': 'ASC',
        'fields': '*',
      },
      headers: _h(at),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final items = (resp.json['items'] as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in items) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['file_id'] ?? '').toString(),
        name: (e['name'] ?? '').toString(),
        isDir: e['type'] == 'folder',
        size: (e['size'] as num?)?.toInt() ?? 0,
        parentId: (e['parent_file_id'] ?? '').toString(),
      ));
    }
    final nextMarker = (resp.json['next_marker'] ?? '').toString();
    return CloudListResult(
      files: files,
      nextCursor: nextMarker.isEmpty ? null : nextMarker,
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
    // 免提取码：匿名接口直接拿顶层文件。
    final anonResp = await cloudPostJson(
      'https://api.alipan.com/adrive/v2/share_link/get_share_by_anonymous',
      body: {'share_id': shareId},
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    List<CloudFile> files = [];
    String? shareToken;
    if (anonResp.isOk) {
      final infos = (anonResp.json['file_infos'] as List?) ?? const [];
      for (final e in infos) {
        if (e is! Map<String, dynamic>) continue;
        files.add(_fileFromShareItem(e));
      }
    }
    // 匿名拿不到（目录分享/需提取码）→ share_token → 文件列表。
    if (files.isEmpty) {
      final tokResp = await cloudPostJson(
        'https://api.alipan.com/adrive/v2/share_link/get_share_token',
        body: {'share_id': shareId, 'share_pwd': pwd ?? ''},
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
      );
      if (!tokResp.isOk) throw const CloudException('分享链接解析失败');
      shareToken =
          ((tokResp.json['data'] as Map<String, dynamic>?)?['share_token'] ??
                  '')
              .toString();
      if (shareToken.isEmpty) throw const CloudException('提取码错误');
      final listResp = await cloudPostJson(
        'https://api.alipan.com/adrive/v3/share_link/file/list',
        body: {
          'share_id': shareId,
          'share_token': shareToken,
          'parent_file_id': 'root',
          'limit': 100,
        },
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
      );
      if (!listResp.isOk) throw const CloudException('分享文件列表获取失败');
      final items = (listResp.json['items'] as List?) ?? const [];
      for (final e in items) {
        if (e is! Map<String, dynamic>) continue;
        files.add(_fileFromShareItem(e));
      }
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: shareId,
      shareToken: shareToken,
      passcode: pwd,
      directPlayable: false,
    );
  }

  CloudFile _fileFromShareItem(Map<String, dynamic> e) => CloudFile(
        id: (e['file_id'] ?? e['share_file_id'] ?? '').toString(),
        name: (e['name'] ?? e['file_name'] ?? '').toString(),
        isDir: e['type'] == 'folder',
        size: (e['size'] as num?)?.toInt() ?? 0,
      );

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
    final at = await _accessToken(cred, persist: true);
    final driveId = await _driveId(cred, at);
    final token = share.shareToken;
    if (token == null || token.isEmpty) throw const CloudException('请先填写提取码');
    final resp = await cloudPostJson(
      'https://api.alipan.com/adrive/v2/share_link/save_created',
      body: {
        'share_id': share.shareId,
        'share_token': token,
        'auto_import': true,
        'to_drive_id': driveId,
        'to_parent_file_id': 'root',
        'file_list': share.files
            .map((f) => {'share_file_id': f.id, 'file_name': f.name})
            .toList(),
      },
      headers: _h(at),
    );
    if (!resp.isOk) throw const CloudException('转存失败');
    final list = (resp.json['file_list'] as List?) ?? const [];
    final out = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      out.add(CloudFile(
        id: (e['file_id'] ?? '').toString(),
        name: (e['name'] ?? e['file_name'] ?? '').toString(),
        isDir: e['type'] == 'folder',
        size: (e['size'] as num?)?.toInt() ?? 0,
      ));
    }
    if (out.isEmpty) {
      // 接口不回新 id 时回退原 files（阿里 file_id 转存后不变）。
      return share.files;
    }
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
    final at = await _accessToken(cred, persist: true);
    final driveId = await _driveId(cred, at);
    final resp = await cloudPostJson(
      'https://api.alipan.com/adrive/v2/file/get_download_url',
      body: {'drive_id': driveId, 'file_id': file.id},
      headers: _h(at),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final url =
        ((resp.json['url'] ?? (resp.json['data'] as Map<String, dynamic>?)
            ?['url']) ??
                '')
            .toString();
    if (url.isEmpty) throw const CloudException('直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 4)),
    );
  }

  // ── token 生命周期 ────────────────────────────────────

  /// 换 access_token；refresh_token 轮换后必须落盘（persist=true 时）。
  Future<String> _accessToken(
    Map<String, String> cred, {
    required bool persist,
  }) async {
    final expireMs = int.tryParse(cred['accessExpireMs'] ?? '') ?? 0;
    final cached = cred['accessToken'];
    if (cached != null &&
        cached.isNotEmpty &&
        DateTime.now().millisecondsSinceEpoch < expireMs) {
      return cached;
    }
    final refreshToken = cred['refreshToken'];
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const CloudException('登录凭据缺失，请重新绑定');
    }
    final resp = await cloudPostJson(
      'https://auth.alipan.com/v2/account/token',
      body: {
        'client_id': _clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
      headers: {'Content-Type': 'application/json', 'User-Agent': _ua},
    );
    if (!resp.isOk) throw const CloudException('登录已过期，请重新绑定');
    final data = resp.json;
    final newRefresh = (data['refresh_token'] ?? refreshToken).toString();
    final access = (data['access_token'] ?? '').toString();
    if (access.isEmpty) throw const CloudException('登录已过期，请重新绑定');
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 7200;
    final newCred = <String, String>{
      'refreshToken': newRefresh,
      'userId': cred['userId'] ?? '',
      'nickname': cred['nickname'] ?? '',
      'accountId': cred['accountId'] ?? '',
      'accessToken': access,
      'accessExpireMs':
          '${DateTime.now().millisecondsSinceEpoch + expiresIn * 1000}',
    };
    if (persist) {
      final targetId = cred['accountId'] ?? '';
      if (targetId.isNotEmpty) {
        await CloudCredentialsStore.instance.updateCred(id, targetId, newCred);
      }
    }
    // 本次会话内也同步给调用方持有的 map（persist=false 时至少进程内生效）。
    cred
      ..clear()
      ..addAll(newCred);
    return access;
  }

  Future<String> _driveId(Map<String, String> cred, String at) async {
    final cached = _driveIdCache[cred['userId']];
    if (cached != null) return cached;
    final resp = await cloudPostJson(
      'https://api.alipan.com/adrive/v2/user/getInfo',
      body: const {},
      headers: _h(at),
    );
    final driveId =
        ((resp.json['data'] as Map<String, dynamic>?)?['default_drive_id'] ??
                resp.json['default_drive_id'] ??
                '')
            .toString();
    if (driveId.isEmpty) throw const CloudException('网盘信息获取失败');
    _driveIdCache[cred['userId'] ?? ''] = driveId;
    return driveId;
  }
}
