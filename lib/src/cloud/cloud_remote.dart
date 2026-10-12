// 网盘业务执行桥：Dart 经 flutter_rust_bridge 调内嵌 Rust 实现
// （rust/src/cloud 十盘业务）。
//
// 各盘 provider 的业务方法经本文件的 rust* 函数一行转发，rust 是唯一
// 实现：失败直接抛 CloudException（文案来自 Rust 错误通道，中文面向
// 用户），无本地回退。请求/响应沿用 Server 版契约：
// reqJson = {provider, op, cred, params}；响应 = {result, rotated_cred?}。
//
// 凭据轮换：rust 刷新的凭据（如阿里 refresh_token）经响应顶层
// rotated_cred 带回，本文件负责回写本地凭据存储。

import 'dart:convert';

import '../rust/api.dart' as rust;
import 'cloud_credentials_store.dart';
import 'cloud_types.dart';

/// rotated_cred 回写：rust 刷新的凭据落盘。
/// accountId 定位规则：cred 内冗余的 accountId 键（阿里登录时存入）；
/// 免登录分享直链无凭据，跳过回写。
Future<void> _applyRotatedCred(
  String provider,
  Map<String, String> cred,
  Map<String, dynamic> data,
) async {
  final rotated = data['rotated_cred'];
  if (rotated is! Map<String, dynamic> || rotated.isEmpty) return;
  final accountId = cred['accountId'] ?? '';
  if (accountId.isEmpty || accountId == '_') return;
  await CloudCredentialsStore.instance
      .updateCred(provider, accountId, rotated.map((k, v) => MapEntry(k, v.toString())));
}

/// 公共执行器：构造 reqJson → rust cloud_proxy → 解包出顶层载荷。
/// cred 可空（免登录分享链路），空时传 {}。
Future<Map<String, dynamic>> _callRust(
  String provider,
  String op,
  Map<String, String>? cred,
  Map<String, dynamic> params,
) async {
  final reqJson = jsonEncode({
    'provider': provider,
    'op': op,
    'cred': cred ?? const <String, String>{},
    'params': params,
  });
  String out;
  try {
    out = await rust.cloudProxy(reqJson: reqJson);
  } catch (e) {
    // frb 对 Result<_, String> 错误通道直接 throw String（即 rust 中文文案）；
    // 其余异常（FFI 内部错误等）取 toString。
    throw CloudException(e is String ? e : e.toString());
  }
  final data = jsonDecode(out);
  if (data is! Map<String, dynamic>) {
    throw const CloudException('网盘数据解析失败');
  }
  await _applyRotatedCred(provider, cred ?? const {}, data);
  return data;
}

CloudFile _fileFromJson(Map<String, dynamic> j) => CloudFile.fromJson(j);

CloudListResult _listResultFromJson(Map<String, dynamic> result) {
  final files = ((result['files'] as List?) ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(_fileFromJson)
      .toList();
  final cursor = result['nextCursor']?.toString();
  return CloudListResult(
    files: files,
    nextCursor: (cursor == null || cursor.isEmpty) ? null : cursor,
  );
}

CloudShareParse _shareParseFromJson(Map<String, dynamic> result) {
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
}

CloudDirectLink _directLinkFromJson(Map<String, dynamic> result) {
  final headers = ((result['headers'] as Map<String, dynamic>?) ?? const {})
      .map((k, v) => MapEntry(k, v.toString()));
  final expireMs = (result['expireAt'] as num?)?.toInt();
  return CloudDirectLink(
    url: (result['url'] ?? '').toString(),
    headers: headers,
    fileName: result['fileName']?.toString(),
    size: (result['size'] as num?)?.toInt(),
    expireAt:
        expireMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expireMs),
  );
}

/// 凭据有效性检查。
Future<bool> rustValidate(
  String provider,
  Map<String, String> cred,
) async {
  final data =
      await _callRust(provider, 'validate', cred, const <String, dynamic>{});
  final result = data['result'];
  return result is Map<String, dynamic> && result['valid'] == true;
}

/// 列目录。
Future<CloudListResult> rustListDir(
  String provider,
  Map<String, String> cred,
  String path, {
  String? cursor,
}) async {
  final data = await _callRust(provider, 'list_dir', cred, {
    'path': path,
    if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
  });
  final result = data['result'];
  if (result is! Map<String, dynamic>) {
    throw const CloudException('网盘数据解析失败');
  }
  return _listResultFromJson(result);
}

/// 全盘文件名搜索（仅 supportsSearch 的盘转发）。
Future<CloudListResult> rustSearchFiles(
  String provider,
  Map<String, String> cred,
  String keyword, {
  String? cursor,
}) async {
  final data = await _callRust(provider, 'search_files', cred, {
    'keyword': keyword,
    if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
  });
  final result = data['result'];
  if (result is! Map<String, dynamic>) {
    throw const CloudException('网盘数据解析失败');
  }
  return _listResultFromJson(result);
}

/// 分享链接解析。绝大多数盘免凭据；需登录态的盘（如百度）经 [cred] 携带。
Future<CloudShareParse> rustParseShare(
  String provider,
  String url,
  String? pwd, {
  Map<String, String>? cred,
}) async {
  final data = await _callRust(provider, 'parse_share', cred, {
    'url': url,
    if (pwd != null && pwd.isNotEmpty) 'pwd': pwd,
  });
  final result = data['result'];
  if (result is! Map<String, dynamic>) {
    throw const CloudException('网盘数据解析失败');
  }
  return _shareParseFromJson(result);
}

/// 转存分享文件。
Future<List<CloudFile>> rustTransferShare(
  String provider,
  Map<String, String> cred,
  CloudShareParse share,
) async {
  final data = await _callRust(provider, 'transfer_share', cred, {
    'share': {
      'shareId': share.shareId,
      'shareToken': share.shareToken,
      'passcode': share.passcode,
      'files': share.files.map((f) => f.toJson()).toList(),
    },
  });
  final result = data['result'];
  if (result is! Map<String, dynamic>) {
    throw const CloudException('网盘数据解析失败');
  }
  return ((result['files'] as List?) ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(_fileFromJson)
      .toList();
}

/// 我的网盘文件直链。
Future<CloudDirectLink> rustDirectLink(
  String provider,
  Map<String, String> cred,
  CloudFile file,
) async {
  final data = await _callRust(provider, 'direct_link', cred, {
    'file': file.toJson(),
  });
  final result = data['result'];
  if (result is! Map<String, dynamic>) {
    throw const CloudException('网盘数据解析失败');
  }
  return _directLinkFromJson(result);
}

/// 分享文件免转存直链。
Future<CloudDirectLink> rustShareDirectLink(
  String provider,
  Map<String, String>? cred,
  CloudShareParse share,
  CloudFile file,
) async {
  final data = await _callRust(provider, 'share_direct_link', cred, {
    'share': {
      'shareId': share.shareId,
      'shareToken': share.shareToken,
      'passcode': share.passcode,
      'files': share.files.map((f) => f.toJson()).toList(),
    },
    'file': file.toJson(),
  });
  final result = data['result'];
  if (result is! Map<String, dynamic>) {
    throw const CloudException('网盘数据解析失败');
  }
  return _directLinkFromJson(result);
}
