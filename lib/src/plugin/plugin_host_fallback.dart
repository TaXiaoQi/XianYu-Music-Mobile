import 'dart:convert';

import '../rust/api.dart' as frb;
import 'plugin_models.dart';

/// QQ 音乐插件搜索/专辑的宿主兜底（移植自桌面端 qqHostSearchFallback.ts + 落雪
/// tx 签名接口，仅功能性兜底）。
///
/// QQ 的 MusicFree 插件搜索普遍依赖无签名的 u.y.qq.com/musicu.fcg
/// （DoSearchForQQMusicDesktop/Album），该端点已被腾讯按请求来源累积风控（reqCode
/// 2001，列表恒为空），插件侧表现为「搜索容易空结果」。宿主复用 Rust 侧已验证的
/// 落雪签名接口（tx 搜索 → 专辑搜索 → 专辑曲目 → 批量时长）代取，映射回
/// MusicFree 歌曲/专辑结构（songmid/qualities / albumMID）；播放仍走插件自身的
/// getMediaSource / getAlbumInfo，不受影响。
final RegExp _qqPattern = RegExp(r'qq', caseSensitive: false);

/// 判断插件是否为 QQ 音乐平台（插件名或 platform 字段含 "qq"，兼容
/// "QQ音乐(赞助版)" 等变体）。
bool isQqMusicPluginSource(PluginSource source, [String? platform]) {
  final haystack = '${source.name}|${platform ?? ''}';
  return _qqPattern.hasMatch(haystack);
}

/// QQ 音乐 MF 插件 getMediaSource 做音质门禁时识别的键（128k/320k/flac/hires）。
const List<String> _qqPluginQualityKeys = ['128k', '320k', 'flac', 'hires'];

/// 把落雪 tx 搜索结果条目映射为 QQ 音乐 MF 插件可消费的歌曲对象。
///
/// 插件 getMediaSource 取 musicItem.songmid || musicItem.id 作为 songId，
/// 门禁读取 qualities[key]；列表展示读取 title/artist/album/artwork/interval。
Map<String, dynamic> _lxItemToQqMusicFreeItem(Map<String, dynamic> item) {
  final qualities = <String, dynamic>{};
  final types = item['lx_types'];
  if (types is Map) {
    for (final key in _qqPluginQualityKeys) {
      final t = types[key];
      if (t is Map) {
        final size = t['size'];
        qualities[key] = {'size': size is String ? size : null};
      }
    }
  }
  final songmid = (item['songmid'] ?? '').toString();
  final albumId = item['album_id'];
  final albumMid = item['album_mid'] ?? item['album_id'];
  return {
    'id': (item['song_id'] ?? songmid).toString(),
    'songmid': songmid,
    'title': item['name'] ?? '',
    'artist': item['singer'] ?? '',
    'album': item['album_name'] ?? '',
    'albumid': albumId,
    'albummid': albumMid,
    'artwork': item['img'],
    'interval': item['interval'] ?? '',
    'qualities': qualities,
    '_hostLxFallback': true,
  };
}

/// 把落雪 tx 搜索/专辑曲目条目数组映射为插件歌曲搜索结果。
List<PluginSearchResult> _hostFbResultsFromLxItems(
    PluginSource source, List list) {
  return list
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .where((m) => (m['songmid'] ?? '').toString().isNotEmpty)
      .map((m) {
        final item = _lxItemToQqMusicFreeItem(m);
        return PluginSearchResult(
          name: (item['title'] ?? '').toString(),
          singer: (item['artist'] ?? '').toString(),
          albumName: (item['album'] ?? '').toString(),
          songmid: item['songmid'].toString(),
          source: source.name,
          interval: (item['interval'] ?? '').toString(),
          img: item['artwork'],
          rawData: item,
        );
      })
      .toList();
}

/// 宿主代取 QQ 插件歌曲搜索：插件搜索被风控返回空时，用落雪签名 tx 接口代取。
/// 任何异常都吞掉返回空数组——兜底失败不应掩盖插件自身的空结果语义。
Future<List<PluginSearchResult>> qqHostSearchFallback(
  PluginSource source,
  String keyword, {
  int limit = 30,
}) async {
  try {
    final json = await frb.lxSearch(source: 'tx', keyword: keyword, limit: limit);
    final list = jsonDecode(json);
    if (list is! List || list.isEmpty) return const [];
    return _hostFbResultsFromLxItems(source, list);
  } catch (_) {
    return const [];
  }
}

/// 把腾讯原始专辑条目映射为 QQ 音乐 MF 插件可消费的专辑对象。
/// 插件 getAlbumInfo 读 albumItem.albumMID（大写），字段名必须精确一致。
Map<String, dynamic> qqRawAlbumToMusicFreeItem(Map<String, dynamic> album) {
  final albumMid = (album['albumMID'] ?? album['album_mid'] ?? '').toString();
  final id = album['albumID'] ?? album['albumid'];
  final albumName = album['albumName'] ?? album['album_name'];
  return {
    'id': id,
    'albumId': id,
    'albumMID': albumMid,
    'title': albumName,
    'name': albumName,
    'artwork': album['albumPic'] ??
        (albumMid.isNotEmpty
            ? 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albumMid.jpg'
            : null),
    'date': album['publicTime'] ?? album['pub_time'],
    'singerID': album['singerID'] ?? album['singer_id'],
    'artist': album['singerName'] ?? album['singer_name'],
    'singerMID': album['singerMID'] ?? album['singer_mid'],
    'description': album['desc'],
  };
}

/// 宿主代取 QQ 专辑搜索（签名 Desktop 接口 search_type=2，随机 guid/wid）。
/// 兜底结果携带插件原生的 albumMID，后续 getAlbumInfo 可正常解析曲目。
/// 返回 MF 专辑对象数组（交由调用方 _toAlbum 转换），异常吞掉返回空。
Future<List<Map<String, dynamic>>> qqHostAlbumSearchFallback(
  PluginSource source,
  String keyword, {
  int page = 1,
  int limit = 30,
}) async {
  try {
    final json =
        await frb.txSearchAlbums(keyword: keyword, page: page, limit: limit);
    final list = jsonDecode(json);
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => qqRawAlbumToMusicFreeItem(e.cast<String, dynamic>()))
        .where((m) => (m['albumMID'] ?? '').toString().isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// 宿主代取 QQ 专辑曲目（签名 AlbumSongList 接口，按 albumMid）。
/// 结果经 _lxItemToQqMusicFreeItem 映射回插件歌曲结构（songmid/qualities）。
/// 异常吞掉返回空数组。
Future<List<PluginSearchResult>> qqHostAlbumSongsFallback(
  PluginSource source,
  String albumMid, {
  int page = 1,
  int limit = 30,
}) async {
  try {
    final json =
        await frb.txAlbumSongs(albumMid: albumMid, page: page, limit: limit);
    final list = jsonDecode(json);
    if (list is! List || list.isEmpty) return const [];
    return _hostFbResultsFromLxItems(source, list);
  } catch (_) {
    return const [];
  }
}

/// 为 QQ 插件歌曲结果批量补齐时长（返回新列表，来源结果不被修改）。
///
/// 移动端 PluginSearchResult 唯一带时长信息的是 interval（String，m:ss，由
/// _parseIntervalMs 解析为 ms）。这里仅当条目缺 interval 且 rawData 有 songid
/// 时才发批量请求（UniformRuleCtrl，每批≤50）；非 QQ 插件或全部已带时长时原样
/// 返回，不发请求。rawData 是可变 Map，同步写入 duration（秒）供重映射不丢。
Future<List<PluginSearchResult>> qqFillSongDurations(
  PluginSource source,
  String? platform,
  List<PluginSearchResult> results,
) async {
  if (!isQqMusicPluginSource(source, platform)) return results;
  if (results.isEmpty) return results;
  final missing = results
      .where((r) =>
          r.interval.trim().isEmpty &&
          r.rawData != null &&
          r.rawData!['id'] != null &&
          (r.rawData!['id'] as String?)?.isNotEmpty != false)
      .toList();
  if (missing.isEmpty) return results;
  try {
    final ids = missing.map((r) => r.rawData!['id'].toString()).toList();
    final mapJson =
        await frb.txBatchTrackInterval(songIdsJson: jsonEncode(ids));
    final map = jsonDecode(mapJson);
    if (map is! Map || map.isEmpty) return results;
    return results.map((r) {
      if (r.interval.trim().isNotEmpty) return r;
      final id = r.rawData?['id'];
      final secs = id == null ? null : map[id.toString()];
      if (secs is! num || secs <= 0) return r;
      r.rawData!['duration'] = secs;
      return r.copyWith(interval: _formatSeconds(secs.toInt()));
    }).toList();
  } catch (_) {
    return results;
  }
}

/// 秒 → "m:ss"，与移动端 interval 展示格式一致。
String _formatSeconds(int secs) {
  if (secs < 0) secs = 0;
  final m = (secs ~/ 60).toString();
  final s = (secs % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 判定是否为 QQ 60 秒试听直链（移植桌面端 isQqTrialMediaUrl）。
///
/// 腾讯试听文件名以 RS02/RS03 等前缀命名（如 RS02003Qui1q2u1Zho.mp3），完整版是
/// M500/M800/F000/C400。走免费公共中转（vkeys.cn 等）的 QQ 插件游客模式只会拿到
/// 这种试听链，且各音质档返回同一文件。
final RegExp _qqTrialUrlRe =
    RegExp(r'/RS0\d[A-Za-z0-9]{8,}\.(mp3|m4a|flac)(?:[?#]|$)', caseSensitive: false);
bool isQqTrialMediaUrl(String? url) =>
    url != null && _qqTrialUrlRe.hasMatch(url);

/// 宿主代取 LX 插件歌曲搜索（对齐桌面端 Search.vue 的 lx 分支）。
///
/// 桌面端 LX 插件不实现 search（仅 musicUrl/lyric/pic），歌曲搜索全部由宿主
/// 落雪签名接口（lxSearch）代取，按插件声明的音源 key 分发到 kw/kg/tx/wy/mg
/// 对应平台。这里映射回 LX 结构（songmid/types/lx_types），source 用插件声明的
/// 音源 key，保证 `lx://{source}/{songmid}` 路径与播放一致；播放仍走插件自身的
/// musicUrl（读 musicInfo.songmid），不受影响。
/// 任何异常都吞掉返回空数组——宿主失败不应抛出到调用方。
Future<List<PluginSearchResult>> lxHostSearchFallback(
  PluginSource source,
  String sourceKey,
  String keyword, {
  int limit = 30,
}) async {
  try {
    final json =
        await frb.lxSearch(source: sourceKey, keyword: keyword, limit: limit);
    final list = jsonDecode(json);
    debugPrint('[lxHostSearch] source=$sourceKey keyword=$keyword '
        'list=${(list is List) ? list.length : 'nonList'}');
    if (list is! List || list.isEmpty) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((m) => (m['songmid'] ?? '').toString().isNotEmpty)
        .map((m) {
          final raw = Map<String, dynamic>.from(m)
            ..['source'] = sourceKey
            ..['_hostLxFallback'] = true;
          final types = <Map<String, dynamic>>[];
          final rawTypes = m['types'];
          if (rawTypes is List) {
            for (final t in rawTypes) {
              if (t is Map) types.add(t.cast<String, dynamic>());
            }
          }
          final lxTypes = <String, dynamic>{};
          final rawLxTypes = m['lx_types'];
          if (rawLxTypes is Map) {
            lxTypes.addAll(rawLxTypes.cast<String, dynamic>());
          }
          return PluginSearchResult(
            name: (m['name'] ?? '').toString(),
            singer: (m['singer'] ?? '').toString(),
            albumName: (m['album_name'] ?? '').toString(),
            albumId: m['album_id'],
            songmid: (m['songmid'] ?? '').toString(),
            source: sourceKey,
            interval: (m['interval'] ?? '').toString(),
            img: m['img']?.toString(),
            hash: m['hash']?.toString(),
            strMediaMid: m['str_media_mid']?.toString(),
            songId: m['song_id'],
            albumMid: m['album_mid']?.toString(),
            copyrightId: m['copyright_id']?.toString(),
            types: types,
            lxTypes: lxTypes.isEmpty ? null : lxTypes,
            rawData: raw,
          );
        })
        .toList();
  } catch (e, st) {
    debugPrint('[lxHostSearch] source=$sourceKey EXCEPTION: $e\n$st');
    return const [];
  }
}