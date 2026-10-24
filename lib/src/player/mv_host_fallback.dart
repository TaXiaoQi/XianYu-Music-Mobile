library;

import 'dart:convert';
import '../core/app_http.dart';
import '../core/application_logger.dart';
import 'mv_source.dart';

String _firstString(List<dynamic Function()> getters) {
  for (final g in getters) {
    final v = g();
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return '';
}

Object? _nestedValue(Object? value, String key) {
  if (value is! Map) return null;
  final v = value[key];
  if (v != null && v.toString().trim().isNotEmpty) return v;
  final raw = value['rawData'];
  if (raw is Map) return raw[key];
  return null;
}

Iterable<String> _identityStrings(Map<String, dynamic> song) sync* {
  final raw = song['rawData'];
  final rawMap = raw is Map ? raw : null;
  for (final m in [song, rawMap]) {
    if (m == null) continue;
    for (final k in const ['source', 'platform', 'pluginId', 'platformId']) {
      final v = m[k];
      if (v is String && v.trim().isNotEmpty) yield v.trim();
    }
  }
}

Map<String, dynamic>? _strMap(dynamic v) {
  if (v is! Map) return null;
  return Map<String, dynamic>.from(v);
}

/// 把 String / List 形态的备用地址里的 http(s) 链接收集进 [out]
void _addHttpUrls(dynamic val, List<String> out) {
  if (val is String && val.toLowerCase().startsWith('http')) {
    out.add(val);
  } else if (val is List) {
    for (final b in val) {
      final s = b?.toString() ?? '';
      if (s.toLowerCase().startsWith('http')) out.add(s);
    }
  }
}

Map<String, dynamic>? _firstStrMapWhere(
  Iterable<Map<String, dynamic>> it,
  bool Function(Map<String, dynamic>) test,
) {
  for (final e in it) {
    if (test(e)) return e;
  }
  return null;
}

Future<Map<String, dynamic>?> _httpGetJson(
  String url,
  Map<String, String> headers,
) async {
  try {
    final resp = await appGet(
      Uri.parse(url),
      headers: headers,
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    final text = await resp.transform(utf8.decoder).join();
    return _strMap(jsonDecode(text));
  } catch (_) {
    return null;
  }
}

final RegExp _kugouPattern = RegExp(r'kugou|酷狗', caseSensitive: false);

bool isKugouSong(Map<String, dynamic> song) {
  return _kugouPattern.hasMatch(_identityStrings(song).join(' '));
}

String? extractKugouMvHash(Map<String, dynamic> song) {
  final mvValue =
      _nestedValue(song, 'mvHash') ??
      _nestedValue(song, 'mv') ??
      _nestedValue(song, 'mvdata');
  String hash = '';
  if (mvValue is String) {
    hash = mvValue;
  } else if (mvValue is List && mvValue.isNotEmpty) {
    final first = mvValue.first;
    if (first is Map) {
      hash = (first['hash'] ?? first['mvHash'] ?? '').toString();
    }
  } else if (mvValue is Map) {
    hash = (mvValue['hash'] ?? mvValue['mvHash'] ?? '').toString();
  }
  hash = hash.trim();
  if (!RegExp(r'^[a-f\d]{32}$', caseSensitive: false).hasMatch(hash))
    return null;
  return hash.toLowerCase();
}

const List<(String, String, int)> _kugouLevels = [
  ('le', '480P', 480),
  ('sd', '720P', 720),
  ('hd', '1080P', 1080),
  ('sq', '1080P', 1080),
  ('rq', '4K', 2160),
];

String _kugouLevelQuality(String key) {
  for (final l in _kugouLevels) {
    if (l.$1 == key) return l.$2;
  }
  return '';
}

int _streamSize(Map<String, dynamic> stream) {
  final v = stream['filesize'] ?? stream['fileSize'] ?? stream['size'];
  return v is num ? v.toInt() : 0;
}

Future<MvSource?> resolveKugouMvSource(String mvHash, String quality) async {
  const ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36';
  final json = await _httpGetJson(
    'https://m.kugou.com/app/i/mv.php?cmd=100&ext=mp4&hash='
    '${Uri.encodeComponent(mvHash)}',
    {'User-Agent': ua, 'Referer': 'https://www.kugou.com/'},
  );
  final status = json?['status'];
  if (status is! num || status.toInt() != 1) return null;
  final mvdata = _strMap(json?['mvdata']);
  if (mvdata == null) return null;

  final raw = <(String, int, Map<String, dynamic>)>[];
  for (final (key, _, height) in _kugouLevels) {
    final stream = _strMap(mvdata[key]);
    if (stream == null) continue;
    final url = _firstString([() => stream['downurl']?.toString()]);
    if (url.isEmpty) continue;
    raw.add((key, height, stream));
  }
  if (raw.isEmpty) return null;

  final byQuality = <String, (int, Map<String, dynamic>)>{};
  for (final (key, height, stream) in raw) {
    final q = _kugouLevelQuality(key);
    final prev = byQuality[q];
    if (prev == null || _streamSize(stream) >= _streamSize(prev.$2)) {
      byQuality[q] = (height, stream);
    }
  }
  final entries = byQuality.entries.map((e) => (e.key, e.value)).toList();

  final lower = quality.toLowerCase();
  final target = lower == '4k'
      ? 2160
      : (int.tryParse(lower.replaceAll(RegExp(r'p$'), '')) ?? 1080);

  (String, (int, Map<String, dynamic>))? selected;
  for (final e in entries) {
    if (e.$2.$1 == target) {
      selected = e;
      break;
    }
  }
  if (selected == null) {
    for (final e in entries) {
      if (e.$2.$1 <= target) selected = e;
    }
  }
  selected ??= entries.first;

  final stream = selected.$2.$2;
  final url = _firstString([() => stream['downurl']?.toString()]);
  if (url.isEmpty || !url.toLowerCase().startsWith('http')) return null;

  final backupVal =
      stream['backupdownurl'] ?? stream['backupDownUrl'] ?? stream['backupurl'];
  final backupUrls = <String>[];
  final list = backupVal is List
      ? backupVal
      : (backupVal is String && backupVal.isNotEmpty
            ? [backupVal]
            : const <dynamic>[]);
  for (final b in list) {
    final s = b?.toString() ?? '';
    if (s.toLowerCase().startsWith('http')) backupUrls.add(s);
    if (backupUrls.length >= 4) break;
  }

  String? codecOf(Map<String, dynamic> st) {
    final c = st['codec']?.toString() ?? st['codecs']?.toString() ?? '';
    return c.isEmpty ? null : c;
  }

  final qualities = entries
      .map(
        (e) => MvQuality(
          key: e.$1,
          label: e.$1,
          height: e.$2.$1,
          bitrate: e.$2.$2['bitrate'] is num
              ? (e.$2.$2['bitrate'] as num).toInt()
              : null,
          size: _streamSize(e.$2.$2),
          codec: codecOf(e.$2.$2),
        ),
      )
      .toList();

  return MvSource(
    url: url,
    headers: const {'Referer': 'https://www.kugou.com/', 'User-Agent': ua},
    videoQuality: selected.$1,
    mimeType: 'video/mp4',
    height: stream['height'] is num
        ? (stream['height'] as num).toInt()
        : selected.$2.$1,
    availableVideoQualities: qualities,
    backupUrls: backupUrls,
  );
}

final RegExp _bilibiliPattern = RegExp(
  r'bilibili|哔哩哔哩|哔哩|b站',
  caseSensitive: false,
);

bool isBilibiliSong(Map<String, dynamic> song) {
  if (_nestedValue(song, 'bvid') != null || _nestedValue(song, 'aid') != null) {
    return true;
  }
  return _bilibiliPattern.hasMatch(_identityStrings(song).join(' '));
}

Map<String, String> extractBilibiliIdentity(Map<String, dynamic> song) {
  String bvid = _nestedValue(song, 'bvid')?.toString() ?? '';
  String aid = _nestedValue(song, 'aid')?.toString() ?? '';
  final cid = _nestedValue(song, 'cid')?.toString() ?? '';
  final id = song['id']?.toString() ?? '';
  final identityText = [bvid, id, aid].join(' ');
  final bvidMatch = RegExp(
    r'BV[0-9A-Za-z]{10,}',
    caseSensitive: false,
  ).firstMatch(identityText);
  if (bvidMatch != null) bvid = bvidMatch.group(0)!;
  if (aid.isEmpty) {
    final avMatch = RegExp(
      r'(?:^|\W)av(\d+)(?:\W|$)',
      caseSensitive: false,
    ).firstMatch(identityText);
    aid = avMatch?.group(1) ?? '';
  }
  if (aid.isEmpty && bvid.isEmpty && RegExp(r'^\d+$').hasMatch(id)) {
    aid = id;
  }
  if (aid.isNotEmpty && aid.toLowerCase().startsWith('av')) {
    aid = aid.substring(2);
  }
  return {'bvid': bvid, 'aid': aid, 'cid': cid};
}

const List<({String key, String label, int qn})> _biliQualityPresets = [
  (key: '360P', label: '360P 流畅', qn: 16),
  (key: '480P', label: '480P 清晰', qn: 32),
  (key: '720P', label: '720P 高清', qn: 64),
  (key: '1080P', label: '1080P 全高清', qn: 80),
];

const Map<int, String> _biliQualityLabels = {
  16: '360P',
  32: '480P',
  64: '720P',
  74: '720P60',
  80: '1080P',
  112: '1080P+',
  116: '1080P60',
  120: '4K',
};

int _biliQualityId(String quality) {
  for (final p in _biliQualityPresets) {
    if (p.key == quality) return p.qn;
  }
  return 64;
}

Future<MvSource?> resolveBilibiliVideoSource(
  Map<String, dynamic> song,
  String quality,
) async {
  final id = extractBilibiliIdentity(song);
  final bvid = id['bvid'] ?? '';
  final aid = id['aid'] ?? '';
  if (bvid.isEmpty && aid.isEmpty) return null;
  final identityQuery = bvid.isNotEmpty
      ? 'bvid=${Uri.encodeComponent(bvid)}'
      : 'aid=${Uri.encodeComponent(aid)}';

  String cid = id['cid'] ?? '';
  if (cid.isEmpty) {
    final view = await _httpGetJson(
      'https://api.bilibili.com/x/web-interface/view?$identityQuery',
      {'Referer': 'https://www.bilibili.com/'},
    );
    final data = _strMap(view?['data']);
    if (data != null) {
      cid = (data['cid'] ?? '').toString();
      if (cid.isEmpty && data['pages'] is List && data['pages'].isNotEmpty) {
        final p0 = (data['pages'] as List).first;
        final page = _strMap(p0);
        if (page != null) cid = (page['cid'] ?? '').toString();
      }
    }
  }
  if (cid.isEmpty) return null;

  // 主路：html5 端点直接要 durl 合流 MP4——音视频同一文件，单控制器天然
  // 音画同步；fnval=16 的 dash 分离流单控制器用不上音轨（选它必然「歌曲
  // 出声 + 画面跟时间轴」，且 CDN 常落 PCDN 慢节点）。html5 失败再走
  // fnval=16（durl 优先，dash 仅最后画面兜底）。
  final qn = _biliQualityId(quality);
  final refPage = bvid.isNotEmpty
      ? 'https://www.bilibili.com/video/$bvid'
      : 'https://www.bilibili.com/video/av$aid';
  final merged = await _resolveBiliMergedFallback(
    identityQuery,
    cid,
    qn,
    quality,
    refPage,
  );
  if (merged != null) return merged;

  final play = await _httpGetJson(
    'https://api.bilibili.com/x/player/playurl?$identityQuery'
    '&cid=${Uri.encodeComponent(cid)}&qn=$qn&fnval=16&fourk=1&try_look=1',
    {'Referer': refPage},
  );
  final data = _strMap(play?['data']);
  // 服务端实授档位（try_look 未登录上限 720P）
  final dashGrantedQn = (data?['quality'] as num?)?.toInt() ?? qn;

  final durls = <Map<String, dynamic>>[];
  if (data?['durl'] is List) {
    for (final e in data?['durl'] as List) {
      final v = _strMap(e);
      if (v != null) durls.add(v);
    }
  }
  if (durls.isNotEmpty) {
    final d0 = durls.first;
    final url = _firstString([() => d0['url']?.toString() ?? '']);
    if (url.toLowerCase().startsWith('http')) {
      final backupUrls = <String>[];
      _addHttpUrls(d0['backup_url'], backupUrls);
      _addHttpUrls(d0['backupUrl'], backupUrls);
      if (durls.length > 1) {
        final u2 = _firstString([() => durls[1]['url']?.toString() ?? '']);
        if (u2.toLowerCase().startsWith('http')) backupUrls.add(u2);
      }
      final grantedQn = (data?['quality'] as num?)?.toInt() ?? qn;
      AppLog.debug('mv', 'bili durl 合流 qn=$grantedQn');
      return MvSource(
        url: url,
        headers: const {'Referer': 'https://www.bilibili.com/'},
        videoQuality: _biliQualityLabels[grantedQn] ?? quality,
        mimeType: 'video/mp4',
        // 未登录 B 站上限 480P：只标实得能力档，虚标高档会让画质
        // 菜单「切不动」（点高档仍返回低档源）
        availableVideoQualities: _biliQualityPresets
            .where((p) => p.qn <= (grantedQn > 32 ? 32 : grantedQn))
            .map((p) => MvQuality(key: p.key, label: p.label))
            .toList(),
        backupUrls: backupUrls.take(4).toList(),
      );
    }
  }

  final dash = _strMap(data?['dash']);
  final dashVideos = <Map<String, dynamic>>[];
  if (dash != null && dash['video'] is List) {
    for (final e in dash['video'] as List) {
      final v = _strMap(e);
      if (v != null) dashVideos.add(v);
    }
  }
  bool isAvc(Map<String, dynamic> v) =>
      (v['codecs']?.toString() ?? '').startsWith('avc1');
  int qid(Map<String, dynamic> v) => (v['id'] as num?)?.toInt() ?? 0;
  // 海思等硬解对宽度非 16 对齐的流（B站 480P=852 典型中招）init 会失败，
  // 优先取对齐流；width 缺失按对齐处理
  bool aligned(Map<String, dynamic> v) =>
      ((v['width'] as num?)?.toInt() ?? 0) % 16 == 0;
  final compatible = dashVideos.where((v) => qid(v) <= qn).toList()
    ..sort((a, b) => qid(b).compareTo(qid(a)));

  Map<String, dynamic>? video = _firstStrMapWhere(
    dashVideos,
    (v) => qid(v) == qn && isAvc(v) && aligned(v),
  );
  video ??= _firstStrMapWhere(dashVideos, (v) => qid(v) == qn && aligned(v));
  video ??= _firstStrMapWhere(compatible, (v) => isAvc(v) && aligned(v));
  video ??= _firstStrMapWhere(compatible, aligned);
  video ??= _firstStrMapWhere(dashVideos, isAvc);
  video ??= _firstStrMapWhere(dashVideos, (_) => true);

  final directUrl = video == null
      ? ''
      : _firstString([
          () => video?['baseUrl']?.toString() ?? '',
          () => video?['base_url']?.toString() ?? '',
        ]);
  if (directUrl.toLowerCase().startsWith('http')) {
    final backupUrls = <String>[];
    _addHttpUrls(video?['backupUrl'], backupUrls);
    _addHttpUrls(video?['backup_url'], backupUrls);
    final mimeType =
        _firstString([
          () => video?['mimeType']?.toString() ?? '',
          () => video?['mime_type']?.toString() ?? '',
        ]).isEmpty
        ? 'video/mp4'
        : _firstString([
            () => video?['mimeType']?.toString() ?? '',
            () => video?['mime_type']?.toString() ?? '',
          ]);
    AppLog.debug('mv', 'bili dash 视频流 qn=${qid(video!)}（无音轨）');
    return MvSource(
      url: directUrl,
      headers: const {'Referer': 'https://www.bilibili.com/'},
      videoQuality: _biliQualityLabels[qid(video)] ?? quality,
      mimeType: mimeType,
      width: video['width'] is num ? (video['width'] as num).toInt() : null,
      height: video['height'] is num ? (video['height'] as num).toInt() : null,
      // dash 兜底同样按实得能力档标注（try_look 后 dash 也可上 720P）
      availableVideoQualities: _biliQualityPresets
          .where((p) => p.qn <= (dashGrantedQn > 64 ? 64 : dashGrantedQn))
          .map((p) => MvQuality(key: p.key, label: p.label))
          .toList(),
      backupUrls: backupUrls.take(4).toList(),
      hasAudioTrack: false,
    );
  }

  // fnval=16 请求整个失败/字段全空：退 html5 端点合流（estg 池慢但可用）
  return _resolveBiliMergedFallback(identityQuery, cid, qn, quality, refPage);
}

/// B站 MV 主路径（与桌面端一致）：html5 端点要 durl 合流 MP4
/// （音视频同一文件，单控制器接管出声）；estg CDN 池首字节偏慢，
/// 由初始化限时判负 + 备用候选兜住；未登录上限 480P 但自带音轨。
Future<MvSource?> _resolveBiliMergedFallback(
  String identityQuery,
  String cid,
  int qn,
  String quality,
  String refPage,
) async {
  final merged = await _httpGetJson(
    'https://api.bilibili.com/x/player/playurl?$identityQuery'
    // try_look=1：未登录试看，实测可拿 720P durl 合流（qn=80/116 服务端
    // 自动降回 64，qn 原样传即可；不带头部 UA 伪造）
    '&cid=${Uri.encodeComponent(cid)}&qn=$qn'
    '&platform=html5&high_quality=1&try_look=1',
    {'Referer': refPage},
  );
  final mergedData = merged == null ? null : _strMap(merged['data']);
  final mergedDurls = <Map<String, dynamic>>[];
  if (mergedData?['durl'] is List) {
    for (final e in mergedData!['durl'] as List) {
      final v = _strMap(e);
      if (v != null) mergedDurls.add(v);
    }
  }
  if (mergedDurls.isEmpty) return null;
  final d0 = mergedDurls.first;
  final mergedUrl = _firstString([
    () => d0['url']?.toString() ?? '',
    () => d0['baseUrl']?.toString() ?? '',
  ]);
  if (!mergedUrl.toLowerCase().startsWith('http')) return null;
  final mergedBackups = <String>[];
  _addHttpUrls(d0['backup_url'], mergedBackups);
  _addHttpUrls(d0['backupUrl'], mergedBackups);
  final grantedQn = (mergedData?['quality'] as num?)?.toInt() ?? qn;
  AppLog.debug('mv', 'bili merged durl fallback qn=$grantedQn');
  return MvSource(
    url: mergedUrl,
    headers: const {'Referer': 'https://www.bilibili.com/'},
    videoQuality: _biliQualityLabels[grantedQn] ?? quality,
    mimeType: 'video/mp4',
    // 菜单按实得档位标注（未登录 try_look 上限 720P），虚标高档
    // 会「切不动」：点高档仍返回低档源
    availableVideoQualities: _biliQualityPresets
        .where((p) => p.qn <= grantedQn)
        .map((p) => MvQuality(key: p.key, label: p.label))
        .toList(),
    backupUrls: mergedBackups,
  );
}

Future<MvSource?> resolveHostMvFallback({
  required Map<String, dynamic> song,
  required String quality,
}) async {
  if (isKugouSong(song)) {
    final mvHash = extractKugouMvHash(song);
    if (mvHash != null) {
      final src = await resolveKugouMvSource(mvHash, quality);
      if (src != null) return src;
    }
  }
  if (isBilibiliSong(song)) {
    final id = extractBilibiliIdentity(song);
    if ((id['bvid'] ?? '').isNotEmpty || (id['aid'] ?? '').isNotEmpty) {
      final src = await resolveBilibiliVideoSource(song, quality);
      if (src != null) return src;
    }
  }
  return null;
}
