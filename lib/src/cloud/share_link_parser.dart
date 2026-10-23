// 分享链接归属识别：输入任意分享 URL，识别属于哪张盘并提取分享码/提取码。
// 具体解析（列文件/转存/直链）由各 provider.parseShareLink 完成。

class ShareLinkInfo {
  const ShareLinkInfo({
    required this.providerId,
    required this.shareId,
    this.passcode,
    required this.url,
  });

  final String providerId;

  /// 各盘分享标识（surl / pwd_id / shareCode…）。
  final String shareId;
  final String? passcode;
  final String url;
}

/// 按域名/路径正则逐盘匹配；未识别返回 null。
ShareLinkInfo? parseUrlToProvider(String raw) {
  final url = raw.trim();
  if (url.isEmpty) return null;

  // 百度：pan.baidu.com/s/1xxxx（surl= 与短链 #/s/1xxx）
  var m = RegExp(
    r'pan\.baidu\.com/(?:s/1|#/s/1|\?surl=|share/init\?surl=)([A-Za-z0-9_-]+)',
  ).firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'baidu',
      shareId: m.group(1)!,
      passcode: _queryParam(url, 'pwd'),
      url: url,
    );
  }

  // 阿里：www.alipan.com/s/xxx / www.aliyundrive.com/s/xxx
  m = RegExp(
    r'(?:alipan|aliyundrive)\.com/(?:s|#/s)/([A-Za-z0-9]+)',
  ).firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'aliyun',
      shareId: m.group(1)!,
      passcode: _queryParam(url, 'pwd'),
      url: url,
    );
  }

  // 夸克：pan.quark.cn/s/xxx（#提取码）
  m = RegExp(r'pan\.quark\.cn/s/([A-Za-z0-9]+)').firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'quark',
      shareId: m.group(1)!,
      passcode: _trailingPwd(url) ?? _queryParam(url, 'pwd'),
      url: url,
    );
  }

  // UC：drive.uc.cn/s/xxx
  m = RegExp(r'drive\.uc\.cn/s/([A-Za-z0-9]+)').firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'uc',
      shareId: m.group(1)!,
      passcode: _trailingPwd(url) ?? _queryParam(url, 'pwd'),
      url: url,
    );
  }

  // 天翼：cloud.189.cn/t/xxx（web 分享）；web/share?code=xxx（web 分享页变体）
  m = RegExp(r'cloud\.189\.cn/(?:t|web/share)/([A-Za-z0-9]+)|cloud\.189\.cn/web/share\?code=([A-Za-z0-9]+)').firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'ecloud189',
      shareId: (m.group(1) ?? m.group(2))!,
      passcode: _queryParam(url, 'accessCode'),
      url: url,
    );
  }

  // 139：yun.139.com/shareweb/#/w/i/xxx
  m = RegExp(r'yun\.139\.com/shareweb/#/w/i/([A-Za-z0-9]+)').firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'mobile139',
      shareId: m.group(1)!,
      passcode: _queryParam(url, 'pwd'),
      url: url,
    );
  }

  // 迅雷：pan.xunlei.com/s/xxx#提取码
  m = RegExp(r'pan\.xunlei\.com/s/([A-Za-z0-9]+)').firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'thunder',
      shareId: m.group(1)!,
      passcode: _trailingPwd(url),
      url: url,
    );
  }

  // 123 盘：新域名 {uid}.share.123pan.cn/123pan/{key}，经典域名
  // 123pan.com / 123684 / 123865 / 123912 等 /s/{key}；key 现为 a-b
  // 连字符形态，整段即 ShareKey（实测拆开报 ShareKey格式异常）；提取码取 ?pwd=
  m = RegExp(
    r'[A-Za-z0-9]+\.share\.123pan\.cn/123pan/([A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)|'
    r'(?:123pan|123684|123865|123912|123685)\.(?:com|cn)/s/([A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)',
  ).firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'pan123',
      shareId: m.group(1) ?? m.group(2)!,
      passcode: _queryParam(url, 'pwd'),
      url: url,
    );
  }

  // PikPak：mypikpak.com/s/xxx
  m = RegExp(r'mypikpak\.com/s/([A-Za-z0-9]+)').firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'pikpak',
      shareId: m.group(1)!,
      passcode: _trailingPwd(url),
      url: url,
    );
  }

  // 蓝奏：lanzou[xiouu]/lanzn/lanvf/lanpv 等域名 /s/ 或 /#/s/
  m = RegExp(
    r'lanzou[a-z]?\.com/(?:s/|#(?:/s/))([A-Za-z0-9]+)|'
    r'lanz(?:n|vf|pv|ou?i|ou?u|ou?x|ou?e)\.(?:com|net|org)/(?:s/|#(?:/s/))([A-Za-z0-9]+)',
  ).firstMatch(url);
  if (m != null) {
    final id = m.group(1) ?? m.group(2)!;
    return ShareLinkInfo(
      providerId: 'lanzou',
      shareId: id,
      passcode: _queryParam(url, 'pwd'),
      url: url,
    );
  }

  // 微云：share.weiyun.com/xxx
  m = RegExp(r'share\.weiyun\.com/([A-Za-z0-9]+)').firstMatch(url);
  if (m != null) {
    return ShareLinkInfo(
      providerId: 'weiyun',
      shareId: m.group(1)!,
      passcode: _queryParam(url, 'pwd'),
      url: url,
    );
  }

  return null;
}

String? _queryParam(String url, String key) {
  final idx = url.indexOf('?');
  if (idx < 0) return null;
  final q = url.substring(idx + 1);
  for (final seg in q.split(RegExp(r'[#&]'))) {
    final kv = seg.split('=');
    if (kv.length == 2 && kv[0] == key && kv[1].isNotEmpty) {
      return Uri.decodeComponent(kv[1]);
    }
  }
  return null;
}

/// `.../s/xxx#提取码` 形式的尾缀提取码。
String? _trailingPwd(String url) {
  final hashIdx = url.indexOf('#');
  if (hashIdx < 0) return null;
  final tail = url.substring(hashIdx + 1).trim();
  if (tail.isEmpty || tail.contains('/')) return null;
  if (tail.startsWith('访问码:') || tail.startsWith('pwd=')) {
    return tail.split(':').last.split('=').last;
  }
  return tail;
}
