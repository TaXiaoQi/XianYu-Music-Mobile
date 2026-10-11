part of 'player_provider.dart';

// 网盘曲目播放接入（一期纯客户端）。
//
// QueueItem.path = cloud://<provider>/<accountId>/<urlEncodedFileJson>，
// 是唯一标识兼直链缓存键；cloudInfoJson 为结构化上下文（CloudPlayContext），
// 会话恢复/跨页传递不依赖 path 反解。直链失效（起播超时/内容不符）清缓存
// 重取一次，重试仍失败按普通播放失败处理，不触发插件换源。

/// 网盘播放上下文：QueueItem.cloudInfoJson 的载荷。
class CloudPlayContext {
  const CloudPlayContext({
    required this.provider,
    required this.accountId,
    required this.file,
    this.share,
  });

  /// 网盘注册 id（cloud_registry）。
  final String provider;

  /// 绑定账号 id；分享免登录直链（无需凭据的盘）传 '_'。
  final String accountId;

  final CloudFile file;

  /// 分享上下文：免转存直链（directPlayable）播放时携带。
  final CloudShareParse? share;

  /// 播放标识：`cloud://<provider>/<accountId>/<urlEncodedFileJson>`。
  String get path =>
      'cloud://$provider/$accountId/${Uri.encodeComponent(jsonEncode(file.toJson()))}';

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'accountId': accountId,
        'file': file.toJson(),
        if (share != null)
          'share': {
            'providerId': share!.providerId,
            'shareId': share!.shareId,
            'shareToken': share!.shareToken,
            'passcode': share!.passcode,
            'directPlayable': share!.directPlayable,
            'files': share!.files.map((f) => f.toJson()).toList(),
          },
      };

  static CloudPlayContext? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final shareJson = j['share'];
      return CloudPlayContext(
        provider: (j['provider'] ?? '').toString(),
        accountId: (j['accountId'] ?? '').toString(),
        file: CloudFile.fromJson(
          (j['file'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
        ),
        share: shareJson is Map<String, dynamic>
            ? CloudShareParse(
                providerId: (shareJson['providerId'] ?? '').toString(),
                shareId: shareJson['shareId']?.toString(),
                shareToken: shareJson['shareToken']?.toString(),
                passcode: shareJson['passcode']?.toString(),
                directPlayable: shareJson['directPlayable'] == true,
                files: (shareJson['files'] as List?)
                        ?.whereType<Map<String, dynamic>>()
                        .map(CloudFile.fromJson)
                        .toList() ??
                    const <CloudFile>[],
              )
            : null,
      );
    } catch (e) {
      AppLog.warn('cloud', '网盘播放上下文解析失败: $e');
      return null;
    }
  }
}

/// 网盘浏览页/链接导入页构造可播放队列条目（时长由播放器实测回填）。
QueueItem cloudPlayQueueItem(
  CloudPlayContext ctx, {
  String? title,
  String? artist,
  String? coverUrl,
}) =>
    QueueItem(
      path: ctx.path,
      title: title ?? ctx.file.name,
      artist: artist ?? '',
      album: '',
      coverUrl: coverUrl,
      source: 'cloud:${ctx.provider}',
      cloudInfoJson: jsonEncode(ctx.toJson()),
    );

extension PlayerNotifierCloud on PlayerNotifier {
  /// 网盘曲目播放：直链缓存 → getDirectLink/getShareDirectLink → 在线管线。
  Future<void> _playCloud(
    QueueItem item, {
    double startAtSecs = 0,
    bool startPlayback = true,
  }) async {
    final ctx = CloudPlayContext.tryParse(item.cloudInfoJson);
    if (ctx == null) throw StateError(tr('网盘歌曲信息缺失，请重新添加'));
    final provider = cloudProviderById(ctx.provider);
    if (provider == null) throw StateError(tr('该网盘暂未支持'));

    // 凭据：先按绑定的 accountId 精确取，再退该盘单账号便捷读取
    var cred = ctx.accountId == '_' || ctx.accountId.isEmpty
        ? null
        : await CloudCredentialsStore.instance
            .credFor(provider.id, ctx.accountId);
    cred ??= await CloudCredentialsStore.instance.soleCredFor(provider.id);

    final fromShare = ctx.share != null && ctx.share!.directPlayable;
    if (cred == null && !fromShare) {
      throw StateError(tr('网盘账号未绑定或已失效'));
    }

    Future<CloudDirectLink> resolve() => fromShare
        ? provider.getShareDirectLink(cred, ctx.share!, ctx.file)
        : provider.getDirectLink(cred ?? const <String, String>{}, ctx.file);

    final key = item.path;
    var link = await DirectLinkCache.instance.get(key, provider.directLinkTtl);
    if (link == null) {
      link = await resolve();
      DirectLinkCache.instance.put(key, link);
    }

    try {
      await _startOnlineUrl(
        link.url,
        headers: link.headers,
        item: item,
        startAtSecs: startAtSecs,
        isPlaying: startPlayback,
        cloudSource: true,
      );
    } catch (e) {
      // 直链可能已过期：清缓存重取一次；仍失败交上层按播放失败处理
      AppLog.warn('cloud', '网盘直链起播失败，重取一次: $e');
      DirectLinkCache.instance.invalidate(key);
      final fresh = await resolve();
      DirectLinkCache.instance.put(key, fresh);
      await _startOnlineUrl(
        fresh.url,
        headers: fresh.headers,
        item: item,
        startAtSecs: startAtSecs,
        isPlaying: startPlayback,
        cloudSource: true,
      );
    }
  }
}
