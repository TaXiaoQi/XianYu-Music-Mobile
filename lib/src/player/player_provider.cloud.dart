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
                files:
                    (shareJson['files'] as List?)
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
}) => QueueItem(
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
        : await CloudCredentialsStore.instance.credFor(
            provider.id,
            ctx.accountId,
          );
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
      // 封面异步补齐：不阻塞起播（歌词由 LyricsRepository 按
      // 同一文件名关键词走插件搜索，无需在此处理）
      unawaited(_enrichCloudCover(item));
      unawaited(_probeCloudSourceFormat(link, item));
      unawaited(_probeCloudHeadMeta(link, item));
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
      unawaited(_enrichCloudCover(item));
      unawaited(_probeCloudSourceFormat(fresh, item));
      unawaited(_probeCloudHeadMeta(fresh, item));
    }
  }

  /// 网盘源格式探测结果：rate=采样率 bits=位深 kbps=有损码率（未知为 0）。
  /// 网盘文件本就是本地上传的原文件，探测直链头部即可拿到与本地曲库
  /// 同源的采样率/位深，徽标就能像本地一样显示完整（如 FLAC 24bit/44.1kHz）。
  Future<void> _probeCloudSourceFormat(
    CloudDirectLink link,
    QueueItem item,
  ) async {
    final path = item.path;
    state = state.copyWith(
      cloudSourceRate: 0,
      cloudSourceBits: 0,
      cloudSourceKbps: 0,
    );
    try {
      final req = await sharedHttpClient
          .openUrl('GET', Uri.parse(link.url))
          .timeout(const Duration(seconds: 8));
      link.headers.forEach(req.headers.set);
      req.headers.set('Range', 'bytes=0-65535');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        AppLog.debug('cloud', '网盘源格式探测失败: HTTP ${resp.statusCode}');
        return;
      }
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
        if (bytes.length >= 65536) break;
      }
      final fmt = _parseAudioHeaderFormat(bytes);
      if (fmt == null) {
        AppLog.debug('cloud', '网盘源格式探测: 无法识别的音频头');
        return;
      }
      // 慢网探测期间可能已切歌：只在仍是这首时回填，避免串台
      if (state.current?.path != path) return;
      state = state.copyWith(
        cloudSourceRate: fmt.rate,
        cloudSourceBits: fmt.bits,
        cloudSourceKbps: fmt.kbps,
      );
      AppLog.info(
        'cloud',
        '网盘源格式: rate=${fmt.rate} bits=${fmt.bits} kbps=${fmt.kbps}',
      );
    } catch (e) {
      AppLog.debug('cloud', '网盘源格式探测失败: $e');
    }
  }

  /// 网盘曲目封面补齐：文件名反解 {artist,title} → 插件搜索 →
  /// 命中项封面 URL 回填当前队列条目（标题全等优先，否则取首条带封面项）。
  Future<void> _enrichCloudCover(QueueItem item) async {
    if (item.coverUrl?.isNotEmpty == true) return;
    try {
      final artist = item.artist.trim();
      final parts = artist.isEmpty
          ? parseCloudFileName(item.title)
          : CloudNameParts(title: item.title, artist: artist);
      if (parts.title.trim().isEmpty) return;
      final keyword = (parts.artist ?? '').trim().isEmpty
          ? parts.title
          : '${parts.title} ${parts.artist}';
      final manager = _ref.read(pluginManagerProvider);
      final engine = await _ref.read(pluginEngineProvider.future);
      final service = PluginSearchService(engine, manager.sources);
      final all = await service.searchAll(keyword, limit: 10);
      QueueItem? fallback;
      for (final (ps, items) in all) {
        for (final r in items) {
          final qi = service.toQueueItem(ps, r);
          if (qi.coverUrl?.isNotEmpty != true) continue;
          fallback ??= qi;
          if (qi.title.trim().toLowerCase() ==
              parts.title.trim().toLowerCase()) {
            _patchCloudCover(item.path, qi.coverUrl!);
            return;
          }
        }
      }
      if (fallback != null) {
        _patchCloudCover(item.path, fallback.coverUrl!);
      } else {
        AppLog.debug('cloud', '网盘封面补齐: 无插件命中 keyword=$keyword');
      }
    } catch (e) {
      AppLog.warn('cloud', '网盘封面补齐失败: $e');
    }
  }

  /// 把补齐的封面写回队列与当前曲目（按 path 定位，刷新播放页与媒体会话）。
  void _patchCloudCover(String path, String coverUrl) {
    final idx = state.queue.indexWhere((e) => e.path == path);
    if (idx < 0) return;
    final patched = state.queue[idx].copyWithCloudCover(coverUrl);
    final queue = [...state.queue]..[idx] = patched;
    state = state.copyWith(
      queue: queue,
      current: state.current?.path == path ? patched : state.current,
    );
    _syncToSystemMediaSession();
  }

  /// 播放期头部元数据兜底（复用起播直链，省一次直链解析）：探测结果
  /// 与列表期共享索引；内嵌封面命中时回填当前条目，coverPath 在展示层
  /// 优先于 coverUrl，媒体会话/手表/状态栏同步随之带上。
  Future<void> _probeCloudHeadMeta(CloudDirectLink link, QueueItem item) async {
    try {
      final entry = await _ref
          .read(cloudHeadMetaProvider.notifier)
          .probeWithDirectLink(link.url, link.headers, item.path);
      final cover = entry?.coverPath;
      AppLog.debug('cloud',
          '[head-meta] 兜底结果 cover=${cover != null ? '有' : '无'} len=${cover?.length ?? 0}');
      if (cover != null && cover.isNotEmpty) {
        _patchCloudCoverPath(item.path, cover);
      }
    } catch (e) {
      AppLog.debug('cloud', '网盘头部元数据兜底失败: $e');
    }
  }

  /// 把内嵌封面落盘路径写回队列与当前曲目（按 path 定位，刷新播放页与媒体会话）。
  void _patchCloudCoverPath(String path, String coverPath) {
    final idx = state.queue.indexWhere((e) => e.path == path);
    if (idx < 0) return;
    final patched = state.queue[idx].copyWith(coverPath: coverPath);
    final queue = [...state.queue]..[idx] = patched;
    state = state.copyWith(
      queue: queue,
      current: state.current?.path == path ? patched : state.current,
    );
    _syncToSystemMediaSession();
  }
}

/// 网盘源格式探测结果：rate=采样率 bits=位深 kbps=有损码率（未知为 0）。
typedef _CloudStreamFormat = ({int rate, int bits, int kbps});

/// 从音频文件头部字节（≤64KB）解析源格式。覆盖网盘上传最常见的
/// FLAC / WAV / MP3；其余容器（M4A/APE/OGG 等）返回 null，徽标退化为
/// 仅扩展名。纯解析无 IO，方便单测。
_CloudStreamFormat? _parseAudioHeaderFormat(List<int> b) {
  if (b.length < 16) return null;
  String tag(int off, int len) =>
      String.fromCharCodes(b.sublist(off, off + len));

  // FLAC：'fLaC' + STREAMINFO（类型 0，必为首元数据块）
  if (tag(0, 4) == 'fLaC' && b.length >= 42 && (b[4] & 0x7F) == 0) {
    var v = 0;
    for (var i = 18; i < 26; i++) {
      v = (v << 8) | b[i];
    }
    // 打包字段：[20b 采样率][3b 声道-1][5b 位深-1][36b 总样本数]
    final rate = v >> 44;
    final bits = ((v >> 36) & 0x1F) + 1;
    if (rate > 0) return (rate: rate, bits: bits, kbps: 0);
  }

  // WAV：RIFF/WAVE，遍历块找 'fmt '
  if (tag(0, 4) == 'RIFF' && tag(8, 4) == 'WAVE') {
    var off = 12;
    while (off + 8 <= b.length) {
      final id = tag(off, 4);
      final size =
          b[off + 4] |
          (b[off + 5] << 8) |
          (b[off + 6] << 16) |
          (b[off + 7] << 24);
      if (size <= 0) break;
      if (id == 'fmt ' && off + 8 + 16 <= b.length) {
        final d = off + 8;
        final rate =
            b[d + 4] | (b[d + 5] << 8) | (b[d + 6] << 16) | (b[d + 7] << 24);
        final bits = b[d + 14] | (b[d + 15] << 8);
        if (rate > 0) return (rate: rate, bits: bits, kbps: 0);
      }
      off += 8 + size + (size & 1); // 块按字对齐
    }
  }

  // MP3：跳过 ID3v2，扫描首个合法 Layer III 帧头
  var start = 0;
  if (tag(0, 3) == 'ID3' && b.length >= 10) {
    final size =
        ((b[6] & 0x7F) << 21) |
        ((b[7] & 0x7F) << 14) |
        ((b[8] & 0x7F) << 7) |
        (b[9] & 0x7F);
    start = 10 + size;
  }
  const br1 = [
    0,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
    256,
    320,
    0,
  ];
  const br2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
  const sr1 = [44100, 48000, 32000, 0];
  const sr2 = [22050, 24000, 16000, 0];
  const sr25 = [11025, 12000, 8000, 0];
  for (var i = start; i + 4 <= b.length; i++) {
    if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
    final ver = (b[i + 1] >> 3) & 3; // 3=MPEG1 2=MPEG2 0=MPEG2.5
    final layer = (b[i + 1] >> 1) & 3; // 1=Layer III
    if (ver == 1 || layer != 1) continue;
    final bIdx = b[i + 2] >> 4;
    final sIdx = (b[i + 2] >> 2) & 3;
    if (bIdx == 0 || bIdx == 15 || sIdx == 3) continue;
    final kbps = ver == 3 ? br1[bIdx] : br2[bIdx];
    final rate = ver == 3 ? sr1[sIdx] : (ver == 2 ? sr2[sIdx] : sr25[sIdx]);
    if (kbps > 0 && rate > 0) return (rate: rate, bits: 0, kbps: kbps);
  }
  return null;
}
