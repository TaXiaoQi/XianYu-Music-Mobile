// 网盘音频文件名解析（与桌面端 src/services/cloud/cloudFilename.ts 同构）：
// 「歌手 - 歌名.flac」「歌名 (FLAC).mp3」等常见命名 → {artist, title}。
// 解析仅供展示与日推候选匹配，不参与播放（播放用 CloudFile 原始数据）。

const _kAudioExts = <String>[
  'mp3',
  'flac',
  'm4a',
  'aac',
  'wav',
  'ogg',
  'opus',
  'ape',
  'wma',
  'aiff',
];

const _kTagKeywords = <String>[
  'flac',
  '无损',
  'hi-res',
  'sq',
  'hq',
  'dsd',
  '320k',
  '128k',
  'ape',
  'wav',
  '全辑',
  '伴奏',
  'dj版',
  'live',
];

/// 中英文括号包裹的分组：【…】[…]（…）（…）
final RegExp _kBracketGroup = RegExp(r'[【\[\(（][^\】\]\)）]*[】\]\)）]');

/// 去扩展名与音质/来源标签（括号包裹形式整体剔除）。
String cleanCloudFileName(String raw) {
  var name = raw.trim();
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    final ext = name.substring(dot + 1).toLowerCase();
    if (_kAudioExts.contains(ext)) name = name.substring(0, dot);
  }
  name = name.replaceAllMapped(_kBracketGroup, (m) {
    final low = m.group(0)!.toLowerCase();
    return _kTagKeywords.any(low.contains) ? '' : m.group(0)!;
  });
  return name.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class CloudNameParts {
  final String title;

  /// 单段命名（无分隔符）时为 null。
  final String? artist;

  const CloudNameParts({required this.title, this.artist});
}

/// 文件名 → {artist, title}。分隔符优先级：' - ' > '–' > '-' > '_'。
/// 网盘音频文件名拆歌名/歌手：主流命名是「歌名 - 歌手」（天天-陶喆、
/// 7 Years-Lukas Graham），两段默认段1=歌名、段2=歌手；三段以上余段
/// 并回歌手。单段整体作歌名。
CloudNameParts parseCloudFileName(String raw) {
  final name = cleanCloudFileName(raw);
  if (name.isEmpty) return CloudNameParts(title: raw);
  List<String> segments;
  if (name.contains(' - ')) {
    segments = name.split(' - ');
  } else if (name.contains('–')) {
    segments = name.split('–');
  } else if (name.contains('-')) {
    segments = name.split('-');
  } else if (name.contains('_')) {
    segments = name.split('_');
  } else {
    return CloudNameParts(title: name);
  }
  if (segments.length < 2) return CloudNameParts(title: name);
  final s1 = segments.first.trim();
  final s2 = segments.sublist(1).join(' - ').trim();
  if (s1.isEmpty) return CloudNameParts(title: s2);
  if (s2.isEmpty) return CloudNameParts(title: s1);
  return CloudNameParts(title: s1, artist: s2);
}
