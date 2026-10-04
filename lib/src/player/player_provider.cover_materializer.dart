part of 'player_provider.dart';

/// 通知栏与系统媒体会话封面的统一物化器：把 coverUrl（在线缩略图 URL，
/// 高清升级后经 CoverProxy 落盘）或 coverPath（本地文件）解析成可交给
/// audio_service 的 Uri，并持有各路缓存与去重容器。
class CoverMaterializer {
  // ===== 通知栏单曲同步（XianYuAudioHandler 侧）=====
  final Map<String, String> artFileCache = {};
  final Set<String> artMaterializing = {};

  // ===== 系统媒体会话同步（PlayerNotifier 侧）=====
  final Map<String, String> notifCoverCache = {};
  final Map<String, Future<String>> notifCoverPending = {};
  // 本地歌通知封面高清化：path → 内嵌原图缓存文件（Rust get_song_cover 产物）。
  final Map<String, String> hdCoverCache = {};
  final Set<String> hdCoverPending = {};
  final Set<String> preloadedCovers = {};

  Uri? artUriFor(QueueItem item) {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      final cached = artFileCache[url];
      if (cached != null) {
        if (File(cached).existsSync()) return Uri.file(cached);
        artFileCache.remove(url);
      }
      // 需代理的 CDN 不交 http URL：系统直连下载既无 Referer 易 403，
      // 又可能与随后落盘的高清封面竞态（低清结果后到会覆盖通知）。
      if (!CoverProxy.needsProxy(url)) return Uri.tryParse(url);
      return null;
    }
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    return null;
  }

  Uri? artUriForWithCache(QueueItem item, Map<String, String> artCache) {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      final cached = artCache[url];
      if (cached != null && File(cached).existsSync()) return Uri.file(cached);
      final art = artFileCache[url];
      if (art != null && File(art).existsSync()) return Uri.file(art);
      // 需代理的 CDN 不交 http URL：避免直连低清图与高清物化结果竞态。
      if (!CoverProxy.needsProxy(url)) return Uri.tryParse(url);
      return null;
    }
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    return null;
  }

  /// 把常见 CDN 的缩略图 URL 升级为高清候选；认不出的规则返回 null
  /// （视为已是原图）。只做可安全升级的替换，失败由调用方回退原 URL。
  String? hdCoverUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host;
    // 网易云：?param=200y200 → 1024y1024（官方图片服务参数，超原图上限自动适配）
    if (host.endsWith('126.net') || host.endsWith('163.com')) {
      final param = uri.queryParameters['param'];
      if (param != null && RegExp(r'^\d+y\d+$').hasMatch(param)) {
        return uri
            .replace(queryParameters: <String, String>{
              ...uri.queryParameters,
              'param': '1024y1024',
            })
            .toString();
      }
      return null;
    }
    // 酷我 / 咪咕：路径中的尺寸段（/300x300/、/W300h300/）删掉即为原图
    if (host.endsWith('kuwo.cn') || host.endsWith('migu.cn')) {
      final cleaned = url
          .replaceFirst(RegExp(r'/\d+x\d+/'), '/')
          .replaceFirst(RegExp(r'/[Ww]\d+[Hh]\d+/'), '/');
      return cleaned == url ? null : cleaned;
    }
    // 酷狗：stdmusic/{size}/ 换成 480 大图规格
    if (host.endsWith('kugou.com') || host.endsWith('kgimg.com')) {
      final cleaned =
          url.replaceFirst(RegExp(r'/stdmusic/\d+/'), '/stdmusic/480/');
      return cleaned == url ? null : cleaned;
    }
    return null;
  }

  /// 拉取在线封面并落盘。返回**新落盘**的文件路径供调用方重推通知；
  /// 无需物化（已缓存/物化中/无 URL/非 Android）或失败时返回 null。
  Future<String?> materializeOnlineArt(QueueItem item) async {
    if (!Platform.isAndroid) return null;
    final url = item.coverUrl;
    if (url == null || url.isEmpty) return null;
    final cached = artFileCache[url];
    if (cached != null) {
      if (File(cached).existsSync()) return null;
      artFileCache.remove(url);
    }
    if (!artMaterializing.add(url)) return null;
    try {
      // 优先拉高清候选，失败再回退原 URL；落盘 key 仍用原 URL 的哈希。
      final hd = hdCoverUrl(url);
      var bytes = hd == null ? null : await CoverProxy.fetch(hd);
      bytes ??= await CoverProxy.fetch(url);
      if (bytes == null || bytes.isEmpty) return null;
      final dir = await getTemporaryDirectory();
      final key = md5.convert(utf8.encode(url)).toString();
      final file = File('${dir.path}/media_art_$key.jpg');
      await file.writeAsBytes(bytes, flush: true);
      artFileCache[url] = file.path;
      return file.path;
    } catch (e) {
      AppLog.debug('player', '通知封面物化失败: $e');
      return null;
    } finally {
      artMaterializing.remove(url);
    }
  }
}
