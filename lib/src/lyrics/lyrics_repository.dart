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
      final pluginRes = await _fetchPluginLyric(item);
      if (pluginRes != null) {
        final mainText = pickPluginMainText(pluginRes);
        final tlyric = (pluginRes['tlyric'] as String?)?.trim() ?? '';
        if (mainText.trim().isNotEmpty &&
            !pluginLyricLooksEncrypted(mainText)) {
          if (tlyric.isNotEmpty && !mainText.contains('tlyric')) {
            return parseLyrics(rawLyrics: '$mainText\n$tlyric');
          }
          if (tlyric.isEmpty) {
            // 插件没带翻译（如 QQ 音源）→ 原生歌词源补齐翻译
            final native = await _fetchNativeLyricResult(item);
            final nTrans = native?['tlyric']?.trim() ?? '';
            if (nTrans.isNotEmpty && !mainText.contains('tlyric')) {
              return parseLyrics(rawLyrics: '$mainText\n$nTrans');
            }
          }
          return parseLyrics(rawLyrics: mainText);
        }
      }
      // 插件无歌词，或返回的是未解密的加密密文 → 原生歌词源整包兜底
      final native = await _fetchNativeLyricResult(item);
      if (native != null) {
        final lx = (native['lxlyric'] ?? '').trim();
        if (lx.isNotEmpty) return parseLyrics(rawLyrics: lx);
        final main = (native['lyric'] ?? '').trim();
        final t = (native['tlyric'] ?? '').trim();
        if (main.isNotEmpty) {
          return parseLyrics(
              rawLyrics: t.isNotEmpty && !main.contains('tlyric')
                  ? '$main\n$t'
                  : main);
        }
      }
      return '';
    }
    final dbPath = await _ref.read(dbPathProvider.future);
    return getSongLyricsPayload(dbPath: dbPath, path: item.path);
  }

  /// 原生歌词源兜底：插件歌曲没有 source/onlineInfoJson，
  /// 从 onlineSongJson.musicInfo 推导平台（仅支持原生实现了歌词抓取的四家）。
  static const _nativeLyricSources = {'tx', 'wy', 'kw', 'kg'};

  Future<Map<String, String>?> _fetchNativeLyricResult(QueueItem item) async {
    Map<String, dynamic>? songInfo;
    final online = item.onlineSongJson;
    if (online != null && online.isNotEmpty) {
      try {
        final parsed = jsonDecode(online) as Map<String, dynamic>;
        final musicInfo = parsed['musicInfo'];
        if (musicInfo is Map<String, dynamic>) songInfo = musicInfo;
      } catch (_) {}
    }
    if (songInfo == null && item.onlineInfoJson != null) {
      try {
        songInfo = jsonDecode(item.onlineInfoJson!) as Map<String, dynamic>;
      } catch (_) {}
    }
    if (songInfo == null || songInfo.isEmpty) return null;
    final sourceKey = (songInfo['source'] ?? songInfo['platform']) as String? ??
        item.source ??
        '';
    if (!_nativeLyricSources.contains(sourceKey)) return null;
    try {
      final raw = await fetchLyricFromSource(
        source: sourceKey,
        songInfoJson: jsonEncode(songInfo),
      );
      if (raw.isEmpty || raw == 'null') return null;
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in obj.entries)
          e.key: e.value is String ? e.value as String : '',
      };
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchPluginLyric(QueueItem item) async {
    final online = item.onlineSongJson;
    if (online == null || online.isEmpty) return null;
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(online) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final pluginId = parsed['pluginId'] as String?;
    if (pluginId == null || pluginId.isEmpty) return null;
    final sourceKey = parsed['source'] as String? ?? '';
    final musicInfo = parsed['musicInfo'] as Map<String, dynamic>? ?? {};
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final matches = sources.where((s) => s.id == pluginId).toList();
      if (matches.isEmpty) return null;
      return await engine.getLyric(matches.first, sourceKey, musicInfo);
    } catch (_) {
      return null;
    }
  }
}

/// 插件歌词结果的主文本挑选：lxlyric（逐字）→ yrc → qrc → eslrc → lyric。
String pickPluginMainText(Map<String, dynamic> res) {
  return (res['lxlyric'] ??
          res['yrc'] ??
          res['qrc'] ??
          res['eslrc'] ??
          res['lyric']) as String? ??
      '';
}

/// 是否为未解密的加密歌词密文：部分音源（QQ 的 QRC / 酷我的 e-lrc）对特定
/// 歌曲会返回十六进制密文（3DES+zlib 压缩包的 hex），不能当歌词展示或落盘。
/// 判据：剥掉空白后几乎全是十六进制字符，且不含任何 `[mm:ss` 时间戳——
/// 真实歌词（LRC/QRC/YRC/lys）必然带时间戳。
bool pluginLyricLooksEncrypted(String text) {
  final t = text.replaceAll(RegExp(r'\s'), '');
  if (t.length < 48) return false;
  final nonHex = t.replaceAll(RegExp(r'[0-9A-Fa-f]'), '').length;
  return nonHex <= t.length * 0.05 &&
      !RegExp(r'\[\d{1,3}:\d{2}').hasMatch(text);
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

/// 逐字文本清理：与 [_cleanLyricText] 类似但不 trim，
/// 单词首尾的空格是英语逐字歌词的单词间隔，trim 掉会导致单词连在一起。
String _cleanLyricWordText(String raw) {
  if (raw.isEmpty) return '';
  String text = raw.replaceAll('\u200b', '').replaceAll('\u2063', '');
  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');
  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return text;
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
          final wText = _cleanLyricWordText((w['text'] as String?) ?? '');
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
