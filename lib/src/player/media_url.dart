// media_url.dart - 播放直链清洗与请求头补齐
//
// 对齐桌面端 utils/mediaUrl.ts：插件直链常带反引号/引号/逗号等脏字符，
// 且酷狗/网易云等 CDN 防盗链要求 Referer/Origin，缺失时返回错误页或空响应，
// 最终表现为 ExoPlayer「加载但不播放」（UnrecognizedInputFormatException）。

/// 从尾部逐字符剥离非 URL 字符（引号/逗号/分号/空白等）。
bool _isTrailingDirtyChar(int code) {
  return code == 0x2c || // ,
      code == 0x3b || // ;
      code == 0x60 || // `
      code == 0x27 || // '
      code == 0x22 || // "
      code == 0x3e || // >
      code == 0x3c || // <
      code == 0x2018 || // ‘
      code == 0x2019 || // ’
      code == 0x201c || // “
      code == 0x201d || // ”
      code == 0x201b || // ‛
      code == 0x201f || // ‟
      code == 0x2033 || // ″
      code == 0x02b9 || // ʹ
      code == 0x02ca || // ʊ
      code == 0xff0c || // ，
      code == 0xff1b || // ；
      code == 0xff02 || // ＂
      code == 0xff07 || // ＇
      code == 0xff1e || // ＞
      code == 0xff1c || // ＜
      code <= 0x20; // 空白控制字符
}

String _stripTrailingDirty(String s) {
  var end = s.length;
  while (end > 0 && _isTrailingDirtyChar(s.codeUnitAt(end - 1))) {
    end--;
  }
  return end > 0 ? s.substring(0, end) : '';
}

/// 清洗插件返回的媒体 URL：定位 http(s):// 起点，剥离尾部脏字符。
String sanitizeMediaUrl(String raw) {
  if (raw.isEmpty) return '';
  final httpsIdx = raw.indexOf('https://');
  final httpIdx = raw.indexOf('http://');
  int start;
  if (httpsIdx >= 0 && (httpIdx < 0 || httpsIdx <= httpIdx)) {
    start = httpsIdx;
  } else if (httpIdx >= 0) {
    start = httpIdx;
  } else {
    return '';
  }
  return _stripTrailingDirty(raw.substring(start));
}

bool _hasHeader(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  return headers.keys.any((k) => k.toLowerCase() == lower);
}

void _setHeaderIfMissing(
    Map<String, String> headers, String name, String value) {
  if (!_hasHeader(headers, name)) headers[name] = value;
}

/// 为播放直链补齐通用请求头。
///
/// 插件有时只返回 URL，不返回防盗链 headers。酷狗等第三方代理接口在 UA 与
/// Referer 缺失时可能返回错误页或空响应，最终表现为「加载但不播放」。
Map<String, String>? normalizeMediaRequestHeaders(
  String url,
  Map<String, String>? rawHeaders,
) {
  final cleaned = sanitizeMediaUrl(url);
  if (cleaned.isEmpty ||
      !RegExp(r'^https?://', caseSensitive: false).hasMatch(cleaned)) {
    return rawHeaders;
  }
  final headers = <String, String>{};
  rawHeaders?.forEach((k, v) {
    if (k.trim().isNotEmpty && v.trim().isNotEmpty) headers[k] = v;
  });
  _setHeaderIfMissing(headers, 'Accept', 'audio/*,*/*;q=0.8');

  final uri = Uri.tryParse(cleaned);
  if (uri != null) {
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isKugouLike = host.contains('kugou') ||
        host.contains('kg.') ||
        host.contains('haitangw.cc') ||
        path.contains('/kgqq/') ||
        path.contains('/kugou/');
    final isNeteaseLike = host.contains('music.126.net') ||
        host.contains('music.163.com') ||
        host.contains('netease') ||
        path.contains('/netease/') ||
        path.contains('/wy/');
    final isKuwoLike = host.contains('kuwo.cn') ||
        host.contains('kuwo.com') ||
        host.contains('kuwo') ||
        path.contains('/kuwo/') ||
        path.contains('/kw/');
    final isJooxLike = host.contains('joox.com') ||
        host.contains('music.joox.com') ||
        path.contains('/joox/');
    final isQishuiLike = host.contains('douyin.com') ||
        host.contains('pglstatp-toutiao.com') ||
        host.contains('pangolin-sdk-toutiao.com') ||
        host.contains('bytescm.com') ||
        host.contains('pstatp.com') ||
        host.contains('bytecdn.cn') ||
        host.contains('toutiao.com') ||
        path.contains('/qishui/');
    final isBilibiliLike = host.contains('bilivideo.com') ||
        host.contains('bilivideo.cn') ||
        host.contains('hdslb.com') ||
        host.contains('bilibili.com');

    if (isKugouLike) {
      final referer = host.contains('haitangw.cc')
          ? '${uri.scheme}://${uri.host}/'
          : 'https://www.kugou.com/';
      _setHeaderIfMissing(headers, 'Referer', referer);
      _setHeaderIfMissing(headers, 'Origin', referer.replaceAll(RegExp(r'/$'), ''));
    } else if (isNeteaseLike) {
      _setHeaderIfMissing(headers, 'Referer', 'https://music.163.com/');
      _setHeaderIfMissing(headers, 'Origin', 'https://music.163.com');
    } else if (isKuwoLike) {
      _setHeaderIfMissing(headers, 'Referer', 'http://www.kuwo.cn/');
      _setHeaderIfMissing(headers, 'Origin', 'http://www.kuwo.cn');
    } else if (isJooxLike) {
      _setHeaderIfMissing(headers, 'Referer', 'https://www.joox.com/');
      _setHeaderIfMissing(headers, 'Origin', 'https://www.joox.com');
    } else if (isBilibiliLike) {
      _setHeaderIfMissing(headers, 'Referer', 'https://www.bilibili.com');
      _setHeaderIfMissing(headers, 'Origin', 'https://www.bilibili.com');
    } else if (isQishuiLike) {
      _setHeaderIfMissing(headers, 'Referer', 'https://www.douyin.com/');
      _setHeaderIfMissing(headers, 'Origin', 'https://www.douyin.com');
    }
  }
  return headers.isNotEmpty ? headers : null;
}

/// 解析得到的播放源：直链 + 可选请求头。
class ResolvedMediaUrl {
  const ResolvedMediaUrl({required this.url, this.headers});
  final String url;
  final Map<String, String>? headers;
}
