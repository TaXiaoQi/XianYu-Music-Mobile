import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'plugin_comments.dart';

/// 宿主直连平台评论服务（LX/落雪插件评论区兜底）。
///
/// 落雪协议没有标准评论接口，但歌曲 id 全平台通用——宿主按歌曲平台直接
/// 调用平台公开评论接口（与桌面端 platformComments.ts 逐一对齐），统一返回
/// [CommentPage] 结构，[CommentSheet] 无需感知来源差异。
///
/// 返回 null 表示平台不受支持或缺少歌曲 id（调用方据此展示"不支持"）；
/// 网络失败等一律返回空 [CommentPage]（展示"暂无评论"）。

const _pageSize = 20;

/// 识别歌曲所属评论平台（按 lx 源 key / 平台字段 / 插件名正则，顺序决定优先级）。
String? detectCommentPlatform({
  String? pluginName,
  Map<String, dynamic>? musicInfo,
}) {
  if (musicInfo == null && (pluginName == null || pluginName.isEmpty)) {
    return null;
  }

  // LX 源 key 即平台码
  const lxCodes = {
    'wy': 'wy',
    'tx': 'tx',
    'kg': 'kg',
    'kw': 'kw',
    'mg': 'mg',
  };
  final sourceKey = musicInfo?['source'];
  if (sourceKey is String && lxCodes.containsKey(sourceKey)) {
    return lxCodes[sourceKey];
  }

  String haystack = pluginName ?? '';
  void append(Object? v) {
    if (v is String && v.isNotEmpty) haystack = '$haystack|$v';
  }
  append(musicInfo?['platform']);
  final raw = musicInfo?['rawData'];
  if (raw is Map) {
    append(raw['platform']);
    append(raw['source']);
  }
  append(musicInfo?['source']);

  final patterns = <(String, RegExp)>[
    ('wy', RegExp(r'网易|netease|\bwy\b', caseSensitive: false)),
    ('tx', RegExp(r'qq', caseSensitive: false)),
    ('kg', RegExp(r'酷狗|kugou|\bkg\b', caseSensitive: false)),
    ('kw', RegExp(r'酷我|kuwo|\bkw\b', caseSensitive: false)),
    ('mg', RegExp(r'咪咕|migu|\bmg\b', caseSensitive: false)),
    ('qishui', RegExp(r'汽水|qishui', caseSensitive: false)),
  ];
  for (final (platform, pattern) in patterns) {
    if (pattern.hasMatch(haystack)) return platform;
  }
  return null;
}

/// 获取平台评论。平台不支持或缺少歌曲 id 时返回 null。
Future<CommentPage?> fetchPlatformComments({
  required String platform,
  required Map<String, dynamic> musicInfo,
  int page = 1,
}) async {
  try {
    return switch (platform) {
      'wy' => await _fetchWy(musicInfo, page),
      'tx' => await _fetchTx(musicInfo, page),
      'kg' => await _fetchKg(musicInfo, page),
      'kw' => await _fetchKw(musicInfo, page),
      'mg' => await _fetchMg(musicInfo, page),
      'qishui' => await _fetchQishui(musicInfo, page),
      _ => null,
    };
  } catch (_) {
    return const CommentPage(items: [], isEnd: true);
  }
}

// ==================== 网络 ====================

Future<Object?> _httpJson(
  String method,
  String url, {
  Map<String, String>? headers,
  String? body,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    HttpClientRequest req;
    if (method == 'POST') {
      req = await client.postUrl(Uri.parse(url));
      if (body != null) req.write(body);
    } else {
      req = await client.getUrl(Uri.parse(url));
    }
    headers?.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(const Duration(seconds: 18));
    if (resp.statusCode < 200 || resp.statusCode >= 400) return null;
    final text = await resp.transform(utf8.decoder).join();
    return jsonDecode(text);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

const _uaChrome =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

// ==================== 网易云 ====================

CommentItem _mapWy(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  String? id;
  final cid = m['commentId'];
  if (cid != null) id = cid.toString();
  String? avatar;
  final au = m['user'];
  if (au is Map) {
    avatar = (au['avatarUrl'] as String?) ?? (au['avatarImgUrlStr'] as String?);
  }
  final user = au is Map
      ? (au.cast<String, dynamic>()['nickname'] as String?) ?? ''
      : '';
  final ip = m['ipLocation'];
  String? location;
  if (ip is Map) location = ip['location'] as String?;
  return CommentItem(
    id: id ?? '',
    nickName: user,
    avatar: avatar,
    comment: (m['content'] as String?) ?? '',
    like: (m['likedCount'] as num?)?.toInt() ?? 0,
    createAt: (m['time'] as num?)?.toInt(),
    location: location,
    replies: [
      for (final r in (m['beReplied'] as List?) ?? const [])
        _mapWyReply(r),
    ],
  );
}

CommentItem _mapWyReply(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  final u = m['user'];
  final user = u is Map
      ? (u.cast<String, dynamic>()['nickname'] as String?) ?? ''
      : '';
  final ip = m['ipLocation'];
  String? location;
  if (ip is Map) location = ip['location'] as String?;
  return CommentItem(
    id: (m['beRepliedCommentId'] as num?)?.toString() ?? '',
    nickName: user,
    comment: (m['content'] as String?) ?? '',
    createAt: (m['time'] as num?)?.toInt(),
    location: location,
  );
}

Future<CommentPage?> _fetchWy(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id']);
  if (id == null) return null;
  final offset = (page - 1) * _pageSize;
  final data = await _httpJson(
    'GET',
    'https://music.163.com/api/v1/resource/comments/R_SO_4_$id'
        '?rid=R_SO_4_$id&limit=$_pageSize&offset=$offset',
    headers: {'Referer': 'https://music.163.com/', 'User-Agent': _uaChrome},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['code'] != 200) return empty;

  final list = <CommentItem>[];
  final hot = m['hotComments'];
  if (page == 1 && hot is List) {
    for (final c in hot) {
      list.add(_mapWy(c));
    }
  }
  if (m['comments'] is List) {
    final seen = <String>{};
    for (final c in (m['comments'] as List)) {
      final item = _mapWy(c);
      if (item.id.isNotEmpty && seen.contains(item.id)) continue;
      if (item.id.isNotEmpty) seen.add(item.id);
      list.add(item);
    }
  }
  return CommentPage(items: list, isEnd: m['more'] != true);
}

// ==================== QQ 音乐 ====================

CommentItem _mapTx(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  String? id;
  final cid = m['CmId'];
  if (cid != null) id = cid.toString();
  int? createAt;
  final pt = m['PubTime'];
  if (pt is int) createAt = int.parse('${pt}000');
  return CommentItem(
    id: id ?? '',
    nickName: (m['Nick'] as String?) ?? '',
    avatar: m['Avatar'] as String?,
    comment: (m['Content'] as String?) ?? '',
    like: (m['PraiseNum'] as num?)?.toInt() ?? 0,
    createAt: createAt,
    replies: [
      for (final r in (m['SubComments'] as List?) ?? const [])
        _mapTxReply(r),
    ],
  );
}

CommentItem _mapTxReply(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  int? createAt;
  final pt = m['PubTime'];
  if (pt is int) createAt = int.parse('${pt}000');
  return CommentItem(
    id: (m['CmId'])?.toString() ?? '',
    nickName: (m['Nick'] as String?) ?? '',
    avatar: m['Avatar'] as String?,
    comment: (m['Content'] as String?) ?? '',
    like: (m['PraiseNum'] as num?)?.toInt() ?? 0,
    createAt: createAt,
  );
}

Future<String?> _resolveTxSongId(Map<String, dynamic> musicInfo) async {
  final rid = _id(musicInfo, ['songId', 'id']);
  if (rid != null && RegExp(r'^\d+$').hasMatch(rid) && int.tryParse(rid) != 0) {
    return rid;
  }
  final songmid = musicInfo['songmid'] ?? musicInfo['mid'];
  if (songmid == null || songmid.toString().isEmpty) return null;
  final body = jsonEncode({
    'comm': {'ct': '19', 'cv': '1859', 'uin': '0'},
    'req': {
      'module': 'music.trackInfo.UniformRuleCtrl',
      'method': 'CgiGetTrackInfo',
      'param': {'types': [1], 'ids': [0], 'mids': [songmid], 'ctx': 0},
    },
  });
  final data = await _httpJson('POST', 'https://u.y.qq.com/cgi-bin/musicu.fcg',
      headers: {
        'Referer': 'https://y.qq.com',
        'User-Agent': _uaChrome,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: body);
  final req = data is Map ? data['req'] : null;
  final reqMap = req is Map ? req.cast<String, dynamic>() : null;
  final dd = reqMap?['data'];
  final tracks = dd is Map ? dd['tracks'] : null;
  final first = tracks is List && tracks.isNotEmpty ? tracks.first : null;
  final trackId = first is Map ? first['id'] : null;
  return trackId?.toString();
}

Future<CommentPage?> _fetchTx(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final songId = await _resolveTxSongId(musicInfo);
  if (songId == null) return empty;
  final body = jsonEncode({
    'comm': {
      'cv': 4747474,
      'ct': 24,
      'format': 'json',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': 0,
      'platform': 'yqq.json',
      'needNewCode': 1,
      'uin': 0,
    },
    'req': {
      'module': 'music.globalComment.CommentRead',
      'method': 'GetHotCommentList',
      'param': {
        'BizType': 1,
        'BizId': songId,
        'LastCommentSeqNo': '',
        'PageSize': _pageSize,
        'PageNum': page - 1,
        'HotType': 1,
        'WithAirborne': 0,
        'PicEnable': 1,
      },
    },
  });
  final data = await _httpJson('POST', 'https://u.y.qq.com/cgi-bin/musicu.fcg',
      headers: {
        'accept': 'application/json',
        'user-agent': _uaChrome,
        'referer': 'https://y.qq.com/',
        'origin': 'https://y.qq.com',
        'content-type': 'application/json; charset=utf-8',
      },
      body: body);
  final req0 = data is Map ? data['req'] : null;
  final req = req0 is Map ? req0.cast<String, dynamic>() : null;
  if (req == null || req['code'] != 0) return empty;
  final commentsList = req['data'];
  final comments = commentsList is Map ? commentsList['Comments'] : null;
  if (comments is! List) return empty;
  final items = comments.map(_mapTx).toList();
  return CommentPage(items: items, isEnd: comments.length < _pageSize);
}

// ==================== 酷狗 ====================

const _kgSaltAndroid = 'OIlwieks28dk2k092lksi2UIkp';

String _md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

/// md5(salt + sort(params).join('') + body + salt)
String _kugouSign(String params, {String body = ''}) {
  final list = params.split('&')..sort();
  final input = '$_kgSaltAndroid${list.join()}$body$_kgSaltAndroid';
  return _md5Hex(input);
}

/// 酷狗 hash → mixsongid（res_id），评论接口的必选参数。
Future<String?> _resolveKgMixsongId(String hash) async {
  final body = jsonEncode({
    'area_code': '1',
    'show_privilege': 1,
    'show_album_info': '1',
    'is_publish': '',
    'appid': 1005,
    'clientver': 11451,
    'mid': '1',
    'dfid': '-',
    'clienttime': DateTime.now().millisecondsSinceEpoch,
    'key': _kgSaltAndroid,
    'fields': 'album_info,author_name,audio_info,ori_audio_name,base,'
        'songname,classification',
    'data': [
      {'hash': hash}
    ],
  });
  final data = await _httpJson(
    'POST',
    'http://gateway.kugou.com/v3/album_audio/audio',
    headers: {
      'KG-THash': '13a3164',
      'KG-RC': '1',
      'KG-Fake': '0',
      'KG-RF': '00869891',
      'User-Agent': 'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi',
      'x-router': 'kmr.service.kugou.com',
      'Content-Type': 'application/json',
    },
    body: body,
  );
  final list = (data is Map ? data['data'] : null) as List?;
  final audio = list == null || list.isEmpty ? null : list.first;
  final cls = audio is Map ? (audio['classification'] as List?) : null;
  final resId = cls == null || cls.isEmpty ? null : cls.first;
  if (resId == null) return null;
  return resId is Map ? resId['res_id']?.toString() : resId.toString();
}

Future<CommentPage?> _fetchKg(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final hash = musicInfo['hash'] ?? musicInfo['id'];
  if (hash == null || hash.toString().isEmpty) return empty;
  final mixsongId = await _resolveKgMixsongId(hash.toString());
  if (mixsongId == null) return empty;

  final params = [
    'appid=1005',
    'clienttime=${DateTime.now().millisecondsSinceEpoch}',
    'clienttoken=0',
    'clientver=11409',
    'code=fc4be23b4e972707f36b8a828a93ba8a',
    'dfid=0',
    'extdata=$hash',
    'kugouid=0',
    'mid=16249512204336365674023395779019',
    'mixsongid=$mixsongId',
    'p=$page',
    'pagesize=$_pageSize',
    'uuid=0',
    'ver=10',
  ].join('&');
  final signature = _kugouSign(params);

  final data = await _httpJson(
    'GET',
    'http://m.comment.service.kugou.com/r/v1/rank/newest'
        '?$params&signature=$signature',
    headers: {
      'accept': 'application/json',
      'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 '
          'Edg/107.0.1418.24',
    },
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || (m['list'] is! List)) return empty;
  final items = <CommentItem>[];
  for (final item in (m['list'] as List)) {
    final raw = item is Map ? item.cast<String, dynamic>() : const {};
    final like = raw['like'] is Map
        ? ((raw['like'] as Map)['likenum'] as num?)?.toInt()
        : null;
    int? createAt;
    final addtime = raw['addtime'];
    if (addtime is num) createAt = addtime.toInt() * 1000;
    items.add(CommentItem(
      id: raw['id']?.toString() ?? '',
      nickName: (raw['user_name'] as String?) ?? '',
      avatar: raw['user_pic'] as String?,
      comment: (raw['content'] as String?) ?? '',
      like: like ?? 0,
      createAt: createAt,
      location: raw['location'] as String?,
    ));
  }
  return CommentPage(items: items, isEnd: items.length < _pageSize);
}

// ==================== 酷我 ====================

CommentItem _mapKw(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  int? createAt;
  final t = m['time'];
  if (t is num) createAt = t.toInt() * 1000;
  return CommentItem(
    id: m['id']?.toString() ?? '',
    nickName: (m['u_name'] as String?) ?? '',
    avatar: m['u_pic'] as String?,
    comment: (m['msg'] as String?) ?? '',
    like: (m['like_num'] as num?)?.toInt(),
    createAt: createAt,
    replies: [
      for (final c in (m['child_comments'] as List?) ?? const [])
        _mapKw(c),
    ],
  );
}

Future<CommentPage?> _fetchKw(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id', 'rid']);
  if (id == null) return null;
  final start = (page - 1) * _pageSize;
  final data = await _httpJson(
    'GET',
    'http://ncomment.kuwo.cn/com.s?f=web&type=get_comment&aapiver=1'
        '&prod=kwplayer_ar_10.5.2.0&digest=15&sid=${Uri.encodeComponent(id)}'
        '&start=$start&msgflag=1&count=$_pageSize&newver=3&uid=0',
    headers: {'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)'},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['code'] != '200') return empty;
  final total = num.tryParse((m['comments_counts'] ?? '').toString())?.toInt() ?? 0;
  final comments = (m['comments'] as List?) ?? const [];
  return CommentPage(
    items: comments.map(_mapKw).toList(),
    isEnd: page * _pageSize >= total || comments.isEmpty,
  );
}

// ==================== 咪咕 ====================

CommentItem _mapMg(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  String? avatar;
  final au = m['author'];
  if (au is Map) {
    final av = au.cast<String, dynamic>()['avatar'];
    if (av is String && av.startsWith('//')) avatar = 'http:$av';
  }
  int? createAt;
  final ct = m['createTime'];
  if (ct is String) {
    createAt = DateTime.tryParse(ct)?.millisecondsSinceEpoch;
  }
  return CommentItem(
    id: m['commentId']?.toString() ?? '',
    nickName: au is Map
        ? (au.cast<String, dynamic>()['name'] as String?) ?? ''
        : '',
    avatar: avatar,
    comment: (m['body'] as String?) ?? '',
    like: (m['praiseCount'] as num?)?.toInt(),
    createAt: createAt,
    replies: [
      for (final r in (m['replyCommentList'] as List?) ?? const [])
        _mapMg(r),
    ],
  );
}

Future<CommentPage?> _fetchMg(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id', 'copyrightId', 'copyright_id']);
  if (id == null) return null;
  final data = await _httpJson(
    'GET',
    'https://music.migu.cn/v3/api/comment/listComments'
        '?targetId=${Uri.encodeComponent(id)}&pageSize=$_pageSize&pageNo=$page',
    headers: {'User-Agent': _uaChrome, 'Referer': 'https://music.migu.cn'},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['returnCode'] != '000000') return empty;
  final inner = m['data'] is Map
      ? (m['data'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final items = (inner['items'] as List?) ?? const [];
  final total = (inner['itemTotal'] as num?)?.toInt() ?? 0;
  return CommentPage(
    items: items.map(_mapMg).toList(),
    isEnd: page * _pageSize >= total || items.isEmpty,
  );
}

// ==================== 汽水 ====================

Future<CommentPage?> _fetchQishui(
  Map<String, dynamic> musicInfo,
  int page,
) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id', 'item_id', 'track_id']);
  if (id == null) return null;
  final params = {
    'aid': '386088',
    'app_name': 'luna_pc',
    'region': 'cn',
    'geo_region': 'cn',
    'os_region': 'cn',
    'sim_region': '',
    'device_id': '100000305367703244',
    'cdid': '',
    'iid': '',
    'version_name': '3.2.1',
    'version_code': '30020100',
    'channel': 'official',
    'build_mode': 'master',
    'network_carrier': '',
    'ac': 'wifi',
    'tz_name': 'Asia/Shanghai',
    'resolution': '',
    'device_platform': 'windows',
    'device_type': 'Windows',
    'os_version': 'Windows 11 Home China',
    'fp': '100000305367703244',
    'group_id': id,
    'cursor': '${(page - 1) * _pageSize}',
    'count': '$_pageSize',
    'group_type': '1',
    'image_strategy': '2',
  };
  final query = Uri(queryParameters: params).query;
  final data = await _httpJson(
    'GET',
    'https://api.qishui.com/luna/pc/comments?$query',
    headers: {
      'Accept': '*/*',
      'Content-Type': 'application/json; charset=utf-8',
      'User-Agent': 'LunaPC/3.2.1(343009595)',
      'x-luna-background-type': 'foreground',
      'x-luna-is-background-req': '0',
      'x-luna-is-local-user': '0',
    },
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || (m['status_code'] as num?)?.toInt() != 0) return empty;
  final comments = (m['comments'] as List?) ?? const [];
  final items = <CommentItem>[];
  for (final raw in comments) {
    final c = raw is Map ? raw.cast<String, dynamic>() : const {};
    final user = c['user'] is Map
        ? (c['user'] as Map).cast<String, dynamic>()
        : null;
    final av = user?['medium_avatar_url'];
    num? rawTime = c['time_created'];
    if (rawTime is! num) rawTime = 0;
    final t = rawTime.toInt();
    final createAt = t > 0 && t < 1000000000000 ? t * 1000 : t;
    items.add(CommentItem(
      id: c['id']?.toString() ?? '',
      nickName: (user?['nickname'] as String?) ?? '',
      avatar: av is String ? av : null,
      comment: (c['content'] as String?) ?? '',
      like: (c['count_digged'] as num?)?.toInt(),
      createAt: createAt > 0 ? createAt : null,
    ));
  }
  return CommentPage(
    items: items,
    isEnd: m['has_more'] == false || items.length < _pageSize,
  );
}

// ==================== 工具 ====================

/// 从 musicInfo 依次取首个非空 id 字段（支持嵌套 rawData 兜底）。
String? _id(Map<String, dynamic> musicInfo, List<String> keys) {
  String? pick(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  for (final k in keys) {
    final v = pick(musicInfo, k);
    if (v != null) return v;
  }
  final raw = musicInfo['rawData'];
  if (raw is Map) {
    final rm = raw.cast<String, dynamic>();
    for (final k in keys) {
      final v = pick(rm, k);
      if (v != null) return v;
    }
  }
  return null;
}