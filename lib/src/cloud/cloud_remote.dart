// 网盘业务云端代理（二期服务端上移）。
//
// 各盘 provider 在业务方法内「远程优先」调用本文件的 try 函数：
// 登录态可用且 Server 可达时返回云端结果（非 null），否则返回 null
// 由 provider 静默回退本地直连实现（独立模式功能不受影响）。
//
// 凭据轮换：Server 刷新的凭据（如阿里 refresh_token）经响应顶层
// rotated_cred 带回，本文件负责 updateCred 回写本地存储。
// 请求走 AuthNotifier.requestAction 既有加密通道（token 自动注入）。

import 'cloud_credentials_store.dart';
import 'cloud_types.dart';

/// 云端网关注入点：由应用装配（SyncNotifier 构造时绑定 authProvider）。
/// 返回 null = 未登录或请求失败（调用方回退本地直连）。
typedef CloudProxyCall = Future<Map<String, dynamic>?> Function(
  String provider,
  String op,
  Map<String, String> cred,
  Map<String, dynamic> params,
);

class CloudRemote {
  CloudRemote._();

  static CloudProxyCall? gateway;

  static Future<Map<String, dynamic>?> call(
    String provider,
    String op,
    Map<String, String> cred,
    Map<String, dynamic> params,
  ) async =>
      await gateway?.call(provider, op, cred, params);
}

/// rotated_cred 回写：云端刷新的凭据落盘（按 accountId 定位账号）。
Future<void> _applyRotatedCred(
  String provider,
  String accountId,
  Map<String, dynamic> data,
) async {
  final rotated = data['rotated_cred'];
  if (rotated is! Map<String, dynamic> || rotated.isEmpty) return;
  if (accountId.isEmpty || accountId == '_') return;
  final cred = rotated.map((k, v) => MapEntry(k, v.toString()));
  await CloudCredentialsStore.instance.updateCred(provider, accountId, cred);
}

CloudFile _fileFromJson(Map<String, dynamic> j) => CloudFile.fromJson(j);

/// 凭据有效性检查。null = 远程不可用；true/false = 云端判定。
Future<bool?> tryRemoteValidate(
  String provider,
  String accountId,
  Map<String, String> cred,
) async {
  try {
    final data = await CloudRemote.call(
        provider, 'validate', cred, const <String, dynamic>{});
    if (data == null) return null;
    await _applyRotatedCred(provider, accountId, data);
    final result = data['result'];
    return result is Map<String, dynamic> && result['valid'] == true;
  } catch (_) {
    return null;
  }
}

/// 列目录。null = 远程不可用（调用方走本地直连）。
Future<CloudListResult?> tryRemoteListDir(
  String provider,
  String accountId,
  Map<String, String> cred,
  String path, {
  String? cursor,
}) async {
  try {
    final data = await CloudRemote.call(provider, 'list_dir', cred, {
      'path': path,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    });
    if (data == null) return null;
    await _applyRotatedCred(provider, accountId, data);
    final result = data['result'];
    if (result is! Map<String, dynamic>) return null;
    final files = ((result['files'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_fileFromJson)
        .toList();
    final cursor2 = result['nextCursor']?.toString();
    return CloudListResult(
      files: files,
      nextCursor: (cursor2 == null || cursor2.isEmpty) ? null : cursor2,
    );
  } catch (_) {
    return null;
  }
}

/// 分享链接解析（不需要登录态；服务端同样免凭据）。
Future<CloudShareParse?> tryRemoteParseShare(
  String provider,
  String url,
  String? pwd,
) async {
  try {
    final data = await CloudRemote.call(
        provider, 'parse_share', const <String, String>{}, {
      'url': url,
      if (pwd != null && pwd.isNotEmpty) 'pwd': pwd,
    });
    if (data == null) return null;
    final result = data['result'];
    if (result is! Map<String, dynamic>) return null;
    final files = ((result['files'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_fileFromJson)
        .toList();
    return CloudShareParse(
      providerId: (result['providerId'] ?? '').toString(),
      files: files,
      shareId: result['shareId']?.toString(),
      shareToken: result['shareToken']?.toString(),
      passcode: result['passcode']?.toString(),
      directPlayable: result['directPlayable'] == true,
    );
  } catch (_) {
    return null;
  }
}

/// 转存分享文件。null = 远程不可用。
Future<List<CloudFile>?> tryRemoteTransferShare(
  String provider,
  String accountId,
  Map<String, String> cred,
  CloudShareParse share,
) async {
  try {
    final data = await CloudRemote.call(provider, 'transfer_share', cred, {
      'share': {
        'shareId': share.shareId,
        'shareToken': share.shareToken,
        'passcode': share.passcode,
        'files': share.files.map((f) => f.toJson()).toList(),
      },
    });
    if (data == null) return null;
    await _applyRotatedCred(provider, accountId, data);
    final result = data['result'];
    if (result is! Map<String, dynamic>) return null;
    final files = ((result['files'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_fileFromJson)
        .toList();
    if (files.isEmpty) return null; // 交回退路径按本地语义处理
    return files;
  } catch (_) {
    return null;
  }
}

/// 我的网盘文件直链。null = 远程不可用。
Future<CloudDirectLink?> tryRemoteDirectLink(
  String provider,
  String accountId,
  Map<String, String> cred,
  CloudFile file,
) async {
  try {
    final data = await CloudRemote.call(provider, 'direct_link', cred, {
      'file': file.toJson(),
    });
    if (data == null) return null;
    await _applyRotatedCred(provider, accountId, data);
    final result = data['result'];
    if (result is! Map<String, dynamic>) return null;
    final headers = ((result['headers'] as Map<String, dynamic>?) ?? const {})
        .map((k, v) => MapEntry(k, v.toString()));
    final expireMs = (result['expireAt'] as num?)?.toInt();
    final link = CloudDirectLink(
      url: (result['url'] ?? '').toString(),
      headers: headers,
      fileName: result['fileName']?.toString(),
      size: (result['size'] as num?)?.toInt(),
      expireAt:
          expireMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expireMs),
    );
    if (link.url.isEmpty) return null;
    return link;
  } catch (_) {
    return null;
  }
}

/// 分享文件免转存直链。null = 远程不可用。
Future<CloudDirectLink?> tryRemoteShareDirectLink(
  String provider,
  String accountId,
  Map<String, String>? cred,
  CloudShareParse share,
  CloudFile file,
) async {
  try {
    final data = await CloudRemote.call(
        provider, 'share_direct_link', cred ?? const <String, String>{}, {
      'share': {
        'shareId': share.shareId,
        'shareToken': share.shareToken,
        'passcode': share.passcode,
        'files': share.files.map((f) => f.toJson()).toList(),
      },
      'file': file.toJson(),
    });
    if (data == null) return null;
    await _applyRotatedCred(provider, accountId, data);
    final result = data['result'];
    if (result is! Map<String, dynamic>) return null;
    final headers = ((result['headers'] as Map<String, dynamic>?) ?? const {})
        .map((k, v) => MapEntry(k, v.toString()));
    final expireMs = (result['expireAt'] as num?)?.toInt();
    final link = CloudDirectLink(
      url: (result['url'] ?? '').toString(),
      headers: headers,
      fileName: result['fileName']?.toString(),
      size: (result['size'] as num?)?.toInt(),
      expireAt:
          expireMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expireMs),
    );
    if (link.url.isEmpty) return null;
    return link;
  } catch (_) {
    return null;
  }
}

/// 供调试/日志：确认云端代理是否可用（未注入网关 = 不可用）。
bool get cloudRemoteEnabled => CloudRemote.gateway != null;
