import 'dart:convert';

/// 外部歌词体系数据模型（移植自 RawS-Music lyric/model 模块）。
///
/// 统一承载逐行/逐字时间轴、翻译、罗马音与背景歌词（富歌词），
/// 供播放页歌词视图与桌面歌词悬浮窗共用。

/// 单个字/词的时间数据（单位：秒）。
class LyricWord {
  final String text;
  final double start;
  final double end;
  final String? romaji;

  const LyricWord({
    required this.text,
    required this.start,
    required this.end,
    this.romaji,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'start': start,
        'end': end,
        if (romaji != null) 'romaji': romaji,
      };
}

/// 单行歌词数据（单位：毫秒）。
class LyricLine {
  final int timeMs;
  final int endTimeMs;
  final String text;
  final String? translation;
  final String? romaji;
  final List<LyricWord> words;

  /// 背景/副歌等次要歌词行（富歌词 secondary）。
  final List<String> secondary;

  /// 演唱者标识（对唱行的角色前缀）。
  final String? speaker;

  /// 是否为背景/和声行（整行被括号包裹等）。
  final bool isBg;

  /// 是否为对唱行（带演唱者前缀）。
  final bool isDuet;

  /// 是否为由括号拆分出的对唱和声伙伴行。
  final bool isDuetPartner;

  const LyricLine({
    required this.timeMs,
    this.endTimeMs = 0,
    required this.text,
    this.translation,
    this.romaji,
    this.words = const [],
    this.secondary = const [],
    this.speaker,
    this.isBg = false,
    this.isDuet = false,
    this.isDuetPartner = false,
  });

  LyricLine copyWith({
    int? timeMs,
    int? endTimeMs,
    String? text,
    String? translation,
    String? romaji,
    List<LyricWord>? words,
    List<String>? secondary,
    String? speaker,
    bool? isBg,
    bool? isDuet,
    bool? isDuetPartner,
  }) {
    return LyricLine(
      timeMs: timeMs ?? this.timeMs,
      endTimeMs: endTimeMs ?? this.endTimeMs,
      text: text ?? this.text,
      translation: translation ?? this.translation,
      romaji: romaji ?? this.romaji,
      words: words ?? this.words,
      secondary: secondary ?? this.secondary,
      speaker: speaker ?? this.speaker,
      isBg: isBg ?? this.isBg,
      isDuet: isDuet ?? this.isDuet,
      isDuetPartner: isDuetPartner ?? this.isDuetPartner,
    );
  }

  Map<String, dynamic> toJson() => {
        'startMs': timeMs,
        'endMs': endTimeMs,
        'text': text,
        if (translation != null) 'translation': translation,
        if (romaji != null) 'romaji': romaji,
        if (words.isNotEmpty) 'words': words.map((w) => w.toJson()).toList(),
        if (secondary.isNotEmpty) 'secondary': secondary,
        if (speaker != null) 'speaker': speaker,
        'isBg': isBg,
        'isDuet': isDuet,
        'isDuetPartner': isDuetPartner,
      };
}

/// 毫秒级时间轴导航器（移植自 RawS-Music TimingNavigator）。
///
/// 歌词行按 begin 升序排列，支持 O(log N) 定位当前行；
/// 顺序播放时利用上次命中索引步进，避免重复二分查找。
class TimingNavigator {
  final List<LyricLine> _lines;

  TimingNavigator(List<LyricLine> lines)
      : _lines = List.unmodifiable(lines);

  /// 返回 positionMs 时刻正在播放的行索引；无匹配返回 -1。
  int findIndex(int positionMs) {
    if (_lines.isEmpty) return -1;
    // 顺序播放优化：从上次命中位置向后步进。
    var lo = 0;
    var hi = _lines.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lines[mid].timeMs <= positionMs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final idx = lo;
    final line = _lines[idx];
    if (line.endTimeMs > 0 && positionMs >= line.endTimeMs) {
      // 该行已结束：向后找仍在播放的行（重叠场景）。
      for (var i = idx + 1; i < _lines.length; i++) {
        final l = _lines[i];
        if (l.timeMs <= positionMs && (l.endTimeMs <= 0 || positionMs < l.endTimeMs)) {
          return i;
        }
        if (l.timeMs > positionMs) break;
      }
      return -1;
    }
    return idx;
  }

  /// 返回 positionMs 时刻正在播放的行；无匹配返回 null。
  LyricLine? find(int positionMs) {
    final idx = findIndex(positionMs);
    return idx < 0 ? null : _lines[idx];
  }
}

/// 将歌词行列表序列化为悬浮窗可消费的 JSON 字符串。
String serializeLyricsForOverlay(List<LyricLine> lines) {
  return jsonEncode({
    'lines': lines.map((l) => l.toJson()).toList(),
  });
}
