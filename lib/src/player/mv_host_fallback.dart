library;

import 'dart:convert';
import 'dart:io';

import 'mv_source.dart';

String _firstString(List<dynamic Function()> getters) {
  for (final g in getters) {
    final v = g();
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return '';
}

Map<String, dynamic>? _strMap(dynamic v) {
  if (v is! Map) return null;
  return Map<String, dynamic>.from(v);
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
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final req = await client.getUrl(Uri.parse(url));
    headers.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    final text = await resp.transform(utf8.decoder).join();
    return _strMap(jsonDecode(text));
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}

final RegExp _kugouPattern = RegExp(r'kugou|酷狗', caseSensitive: false);

bool isKugouSong(Map<String, dynamic> song) {
  final identity = [
    song['source'],
    song['platform'],
    song['pluginId'],
    song['platformId'],
  ]
      .whereType<String>()
      .join(' ');
  return _kugouPattern.hasMatch(identity);
}

String? extractKugouMvHash(Map<String, dynamic> song) {
  final mvValue = song['mvHash'] ?? song['mv'] ?? song['mvdata'];
  String hash = '';
  if (mvValue is String) {
    hash = mvValue;
  } else if (mvValue is Map) {
    hash = (mvValue['hash'] ?? mvValue['mvHash'] ?? '').toString();
  }
  hash = hash.trim();
  if (!RegExp(r'^[a-f\d]{32}$', caseSensitive: false).hasMatch(hash)) return null;
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
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
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

  final backupVal = stream['backupdownurl'] ??
      stream['backupDownUrl'] ??
      stream['backupurl'];
  final backupUrls = <String>[];
  final list = backupVal is List
      ? backupVal
      : (backupVal is String && backupVal.isNotEmpty ? [backupVal] : const <dynamic>[]);
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
      .map((e) => MvQuality(
            key: e.$1,
            label: e.$1,
            height: e.$2.$1,
            bitrate: e.$2.$2['bitrate'] is num
                ? (e.$2.$2['bitrate'] as num).toInt()
                : null,
            size: _streamSize(e.$2.$2),
            codec: codecOf(e.$2.$2),
          ))
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

final RegExp _bilibiliPattern =
    RegExp(r'bilibili|哔哩哔哩|哔哩|b站', caseSensitive: false);

bool isBilibiliSong(Map<String, dynamic> song) {
  if ((song['bvid']?.toString() ?? '').isNotEmpty ||
      (song['aid']?.toString() ?? '').isNotEmpty) {
    return true;
  }
  final identity = [
    song['bvid'],
    song['aid'],
    song['source'],
    song['platform'],
    song['pluginId'],
    song['platformId'],
  ]
      .whereType<String>()
      .join(' ');
  return _bilibiliPattern.hasMatch(identity);
}

Map<String, String> extractBilibiliIdentity(Map<String, dynamic> song) {
  String bvid = song['bvid']?.toString() ?? '';
  String aid = song['aid']?.toString() ?? '';
  final cid = song['cid']?.toString() ?? '';
  final id = song['id']?.toString() ?? '';
  final identityText = [bvid, id, aid].join(' ');
  final bvidMatch =
      RegExp(r'BV[0-9A-Za-z]{10,}', caseSensitive: false).firstMatch(identityText);
  if (bvidMatch != null) bvid = bvidMatch.group(0)!;
  if (aid.isEmpty) {
    final avMatch = RegExp(r'(?:^|\W)av(\d+)(?:\W|$)', caseSensitive: false)
        .firstMatch(identityText);
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

  final qn = _biliQualityId(quality);
  final refPage = bvid.isNotEmpty
      ? 'https://www.bilibili.com/video/$bvid'
      : 'https://www.bilibili.com/video/av$aid';
  final play = await _httpGetJson(
    'https://api.bilibili.com/x/player/playurl?$identityQuery'
        '&cid=${Uri.encodeComponent(cid)}&qn=$qn&fnval=16&fourk=1',
    {'Referer': refPage},
  );
  if (play == null) return null;
  final data = _strMap(play['data']);
  if (data == null) return null;

  final dash = _strMap(data['dash']);
  final dashVideos = <Map<String, dynamic>>[];
  if (dash != null && dash['video'] is List) {
    for (final e in dash['video'] as List) {
      final v = _strMap(e);
      if (v != null) dashVideos.add(v);
    }
  }
  final durls = <Map<String, dynamic>>[];
  if (data['durl'] is List) {
    for (final e in data['durl'] as List) {
      final v = _strMap(e);
      if (v != null) durls.add(v);
    }
  }

  bool isAvc(Map<String, dynamic> v) => (v['codecs']?.toString() ?? '').startsWith('avc1');
  int qid(Map<String, dynamic> v) => (v['id'] as num?)?.toInt() ?? 0;
  final compatible = dashVideos.where((v) => qid(v) <= qn).toList()
    ..sort((a, b) => qid(b).compareTo(qid(a)));

  Map<String, dynamic>? video = _firstStrMapWhere(dashVideos, (v) => qid(v) == qn && isAvc(v));
  video ??= _firstStrMapWhere(dashVideos, (v) => qid(v) == qn);
  video ??= _firstStrMapWhere(compatible, isAvc);
  video ??= _firstStrMapWhere(compatible, (_) => true);
  video ??= _firstStrMapWhere(dashVideos, isAvc);
  video ??= _firstStrMapWhere(dashVideos, (_) => true);

  final directUrl = _firstString([
    () => video?['baseUrl']?.toString() ?? '',
    () => video?['base_url']?.toString() ?? '',
    () => durls.isNotEmpty ? durls.first['url']?.toString() ?? '' : '',
  ]);
  if (directUrl.isEmpty || !directUrl.toLowerCase().startsWith('http')) return null;

  final backupUrls = <String>[];
  void addBackup(dynamic val) {
    if (val is String && val.toLowerCase().startsWith('http')) {
      backupUrls.add(val);
    } else if (val is List) {
      for (final b in val) {
        final s = b?.toString() ?? '';
        if (s.toLowerCase().startsWith('http')) backupUrls.add(s);
      }
    }
  }

  addBackup(video?['backupUrl']);
  addBackup(video?['backup_url']);
  if (durls.isNotEmpty) addBackup(durls.first['backup_url']);

  final qualityLabel =
      video != null ? _biliQualityLabels[qid(video)] ?? quality : quality;
  final lv = video;
  String mimeType = 'video/mp4';
  if (lv != null) {
    mimeType = _firstString([
      () => lv['mimeType']?.toString() ?? '',
      () => lv['mime_type']?.toString() ?? '',
    ]);
    if (mimeType.isEmpty) mimeType = 'video/mp4';
  }

  return MvSource(
    url: directUrl,
    headers: const {'Referer': 'https://www.bilibili.com/'},
    videoQuality: qualityLabel,
    mimeType: mimeType,
    width: video?['width'] is num ? (video?['width'] as num).toInt() : null,
    height: video?['height'] is num ? (video?['height'] as num).toInt() : null,
    availableVideoQualities: _biliQualityPresets
        .map((p) => MvQuality(key: p.key, label: p.label))
        .toList(),
    backupUrls: backupUrls,
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