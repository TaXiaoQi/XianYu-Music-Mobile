import 'dart:convert';

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

class LyricLine {
  final int timeMs;
  final int endTimeMs;
  final String text;
  final String? translation;
  final String? romaji;
  final List<LyricWord> words;

  final List<String> secondary;

  final String? speaker;

  final bool isBg;

  final bool isDuet;

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

class TimingNavigator {
  final List<LyricLine> _lines;

  TimingNavigator(List<LyricLine> lines)
      : _lines = List.unmodifiable(lines);

  int findIndex(int positionMs) {
    if (_lines.isEmpty) return -1;
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

  LyricLine? find(int positionMs) {
    final idx = findIndex(positionMs);
    return idx < 0 ? null : _lines[idx];
  }
}

String serializeLyricsForOverlay(List<LyricLine> lines) {
  return jsonEncode({
    'lines': lines.map((l) => l.toJson()).toList(),
  });
}
