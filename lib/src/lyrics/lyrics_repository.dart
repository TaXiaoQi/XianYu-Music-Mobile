import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../i18n/i18n.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_provider.dart';
import '../rust/api.dart';
import 'lyric_model.dart';

final Map<String, (I18nMode, List<LyricLine>)> _lyricsCache = {};
const int _lyricsCacheMax = 24;

final Map<String, String> _payloadCache = {};

void _cacheLyrics(String path, List<LyricLine> lines) {
  if (path.isEmpty || lines.isEmpty) return;
  _lyricsCache[path] = (I18n.mode, lines);
  if (_lyricsCache.length > _lyricsCacheMax) {
    _lyricsCache.remove(_lyricsCache.keys.first);
  }
}

class LyricsRepository {
  LyricsRepository(this._ref);

  final Ref _ref;

  Future<List<LyricLine>> fetchLyrics(QueueItem item) async {
    final cached = _lyricsCache[item.path];
    if (cached != null && cached.$2.isNotEmpty) {
      if (cached.$1 == I18n.mode) return cached.$2;
      _lyricsCache.remove(item.path);
    }
    try {
      final jsonStr = await fetchPayloadJson(item);
      if (jsonStr.isEmpty || jsonStr == 'null') return const [];
      final parsed = await compute(_parseLyricsJson, jsonStr);
      final lines = await compute(_normalizeBoundaries, parsed);
      final localized = localizeLyricLines(lines);
      if (localized.isNotEmpty) _cacheLyrics(item.path, localized);
      return localized;
    } catch (_) {
      return const [];
    }
  }

  Future<String> fetchPayloadJson(QueueItem item) async {
    final cached = _payloadCache[item.path];
    if (cached != null) return cached;
    final payload = await _fetchLyricsJson(item);
    if (payload.isNotEmpty && payload != 'null') {
      _payloadCache[item.path] = payload;
      if (_payloadCache.length > _lyricsCacheMax) {
        _payloadCache.remove(_payloadCache.keys.first);
      }
    }
    return payload;
  }

  Future<String> _fetchLyricsJson(QueueItem item) async {
    if (item.isOnline) {
      final pluginText = await _fetchPluginLyric(item);
      if (pluginText.trim().isNotEmpty) {
        return parseLyrics(rawLyrics: pluginText);
      }
      if (item.source != null && item.onlineInfoJson != null) {
        final rawResultStr = await fetchLyricFromSource(
          source: item.source!,
          songInfoJson: item.onlineInfoJson!,
        );
        if (rawResultStr != 'null' && rawResultStr.isNotEmpty) {
          String lyricsToParse = '';
          try {
            final lyricObj = jsonDecode(rawResultStr) as Map<String, dynamic>;
            final lxlyric = lyricObj['lxlyric'] as String? ?? '';
            final lyric = lyricObj['lyric'] as String? ?? '';
            final tlyric = lyricObj['tlyric'] as String? ?? '';
            if (lxlyric.trim().isNotEmpty) {
              lyricsToParse = lxlyric;
            } else if (lyric.trim().isNotEmpty) {
              if (tlyric.trim().isNotEmpty && !lyric.contains('tlyric')) {
                lyricsToParse = '$lyric\n$tlyric';
              } else {
                lyricsToParse = lyric;
              }
            }
          } catch (_) {
            lyricsToParse = rawResultStr;
          }
          if (lyricsToParse.trim().isNotEmpty) {
            return parseLyrics(rawLyrics: lyricsToParse);
          }
        }
      }
      return '';
    }
    final dbPath = await _ref.read(dbPathProvider.future);
    return getSongLyricsPayload(dbPath: dbPath, path: item.path);
  }

  Future<String> _fetchPluginLyric(QueueItem item) async {
    final online = item.onlineSongJson;
    if (online == null || online.isEmpty) return '';
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(online) as Map<String, dynamic>;
    } catch (_) {
      return '';
    }
    final pluginId = parsed['pluginId'] as String?;
    if (pluginId == null || pluginId.isEmpty) return '';
    final sourceKey = parsed['source'] as String? ?? '';
    final musicInfo = parsed['musicInfo'] as Map<String, dynamic>? ?? {};
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final matches = sources.where((s) => s.id == pluginId).toList();
      if (matches.isEmpty) return '';
      final res = await engine.getLyric(matches.first, sourceKey, musicInfo);
      if (res == null) return '';
      final mainText = (res['lxlyric'] ??
              res['yrc'] ??
              res['qrc'] ??
              res['eslrc'] ??
              res['lyric']) as String? ??
          '';
      if (mainText.trim().isEmpty) return '';
      final tlyric = (res['tlyric'] as String?)?.trim() ?? '';
      if (tlyric.isNotEmpty && !mainText.contains('tlyric')) {
        return '$mainText\n$tlyric';
      }
      return mainText;
    } catch (_) {
      return '';
    }
  }
}

String _cleanLyricText(String raw) {
  if (raw.isEmpty) return '';
  String text = raw;
  text = text.replaceAll(
    RegExp(
      r'\[(ar|ti|al|by|offset|kuwo|kugou|hash|sign|qq|total|language|types):[^\]]*\]',
      caseSensitive: false,
    ),
    '',
  );
  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');
  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return text.trim();
}

List<LyricLine> _parseLyricsJson(String jsonStr) {
  final map = jsonDecode(jsonStr) as Map<String, dynamic>;
  final rawLines =
      (map['displayLines'] as List?) ??
      (map['display_lines'] as List?) ??
      (map['lines'] as List?) ??
      [];
  final lines = <LyricLine>[];
  for (final item in rawLines) {
    if (item is! Map<String, dynamic>) continue;
    double timeSec = 0.0;
    if (item['time'] is num) {
      timeSec = (item['time'] as num).toDouble();
    } else if (item['timeMs'] is num) {
      timeSec = (item['timeMs'] as num).toDouble() / 1000.0;
    } else if (item['startTime'] is num) {
      timeSec = (item['startTime'] as num).toDouble();
    } else if (item['startTimeMs'] is num) {
      timeSec = (item['startTimeMs'] as num).toDouble() / 1000.0;
    }

    double endTimeSec = 0.0;
    final rawEndTime = item['endTime'] ?? item['end_time'];
    if (rawEndTime is num) {
      endTimeSec = rawEndTime.toDouble();
    } else if (item['endTimeMs'] is num) {
      endTimeSec = (item['endTimeMs'] as num).toDouble() / 1000.0;
    }

    final text = _cleanLyricText((item['text'] as String?) ?? '');
    final rawTrans = item['translation'] as String?;
    final translation = rawTrans != null && rawTrans.trim().isNotEmpty
        ? _cleanLyricText(rawTrans)
        : null;
    final rawRomaji = (item['romaji'] as String?)?.trim();
    final romaji = (rawRomaji != null && rawRomaji.isNotEmpty)
        ? rawRomaji
        : null;

    final secondary = <String>[];
    final rawSecondary = item['secondary'] as List?;
    if (rawSecondary != null) {
      for (final s in rawSecondary) {
        if (s is String && s.trim().isNotEmpty) {
          secondary.add(_cleanLyricText(s));
        }
      }
    }

    final words = <LyricWord>[];
    final rawWords = item['words'] as List?;
    if (rawWords != null && rawWords.isNotEmpty) {
      for (final w in rawWords) {
        if (w is Map<String, dynamic>) {
          final wText = _cleanLyricText((w['text'] as String?) ?? '');
          final wStart = (w['start'] as num?)?.toDouble() ?? 0.0;
          final wEnd = (w['end'] as num?)?.toDouble() ?? 0.0;
          final wRomaji = (w['romaji'] as String?)?.trim();
          if (wText.isNotEmpty) {
            words.add(LyricWord(
              text: wText,
              start: wStart,
              end: wEnd,
              romaji: (wRomaji != null && wRomaji.isNotEmpty)
                  ? wRomaji
                  : null,
            ));
          }
        }
      }
    }

    if (text.isNotEmpty) {
      lines.add(LyricLine(
        timeMs: (timeSec * 1000).toInt(),
        endTimeMs: (endTimeSec * 1000).round(),
        text: text,
        translation: translation,
        romaji: romaji,
        words: words,
        secondary: secondary,
        speaker: (item['speaker'] as String?)?.trim().isNotEmpty == true
            ? (item['speaker'] as String).trim()
            : null,
        isBg: item['isBg'] == true,
        isDuet: item['isDuet'] == true,
        isDuetPartner: item['isDuetPartner'] == true,
      ));
    }
  }
  return lines;
}

List<LyricLine> _normalizeBoundaries(List<LyricLine> lines) {
    final result = <LyricLine>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final startMs = line.timeMs.toDouble();
      final nextStartMs = i + 1 < lines.length
          ? lines[i + 1].timeMs.toDouble()
          : double.infinity;

      var endMs = line.endTimeMs.toDouble();
      if (endMs <= startMs) {
        if (nextStartMs.isFinite) {
          final gap = nextStartMs - startMs;
          final leadIn = math.min(300.0, gap * 0.25);
          endMs = nextStartMs - leadIn;
        } else {
          endMs = startMs + 5000;
        }
      }
      endMs = math.max(endMs, startMs + 40);

      final words = <LyricWord>[];
      for (var j = 0; j < line.words.length; j++) {
        final w = line.words[j];
        final wStartMs = w.start * 1000.0;
        var wEndMs = w.end * 1000.0;
        if (j + 1 < line.words.length) {
          wEndMs = math.min(wEndMs, line.words[j + 1].start * 1000.0);
        }
        wEndMs = math.min(wEndMs, endMs);
        wEndMs = math.max(wEndMs, wStartMs + 20);

        final chars = w.text.runes.toList();
        if (chars.length > 1) {
          final durMs = (wEndMs - wStartMs) / chars.length;
          for (var c = 0; c < chars.length; c++) {
            words.add(LyricWord(
              text: String.fromCharCode(chars[c]),
              start: (wStartMs + durMs * c) / 1000.0,
              end: (wStartMs + durMs * (c + 1)) / 1000.0,
              romaji: c == 0 ? w.romaji : null,
            ));
          }
        } else {
          words.add(LyricWord(
            text: w.text,
            start: wStartMs / 1000.0,
            end: wEndMs / 1000.0,
            romaji: w.romaji,
          ));
        }
      }

      result.add(LyricLine(
        timeMs: line.timeMs,
        endTimeMs: endMs.round(),
        text: line.text,
        translation: line.translation,
        romaji: line.romaji,
        words: words,
        secondary: line.secondary,
      ));
    }
    return result;
  }

final lyricsRepositoryProvider = Provider<LyricsRepository>(
  (ref) => LyricsRepository(ref),
);

List<LyricLine> localizeLyricLines(List<LyricLine> lines) {
  if (I18n.mode != I18nMode.zhTw) return lines;
  return [
    for (final l in lines)
      l.copyWith(
        text: localizeLyricText(l.text),
        translation:
            l.translation == null ? null : localizeLyricText(l.translation!),
        secondary: [for (final s in l.secondary) localizeLyricText(s)],
        words: [
          for (final w in l.words)
            LyricWord(
              text: localizeLyricText(w.text),
              start: w.start,
              end: w.end,
              romaji: w.romaji,
            ),
        ],
      ),
  ];
}
