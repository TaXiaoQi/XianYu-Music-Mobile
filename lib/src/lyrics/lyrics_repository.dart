import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_provider.dart';
import '../rust/api.dart';
import 'lyric_model.dart';

/// 歌词仓库：统一从插件 / 内置音源 / 本地数据库获取歌词并解析为
/// [LyricLine] 列表。播放页歌词视图与桌面歌词悬浮窗共用。
class LyricsRepository {
  LyricsRepository(this._ref);

  final Ref _ref;

  /// 获取并解析指定曲目的歌词；无歌词返回空列表。
  Future<List<LyricLine>> fetchLyrics(QueueItem item) async {
    try {
      final jsonStr = await _fetchLyricsJson(item);
      if (jsonStr.isEmpty || jsonStr == 'null') return const [];
      final lines = _parseLyricsJson(jsonStr);
      return _normalizeBoundaries(lines);
    } catch (_) {
      return const [];
    }
  }

  /// 按优先级获取歌词原始 JSON（插件 → 内置 LX 音源 → 本地数据库）。
  Future<String> _fetchLyricsJson(QueueItem item) async {
    if (item.isOnline) {
      // (A) 插件来源：通过插件 getLyric 拉歌词（lxlyric/lyric/翻译/罗马音）。
      final pluginText = await _fetchPluginLyric(item);
      if (pluginText.trim().isNotEmpty) {
        return parseLyrics(rawLyrics: pluginText);
      }
      // (B) 内置 lx 音源：通过 Rust 接口在线抓取指定音源的歌词。
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
    // 本地曲目：通过数据库及本地资源提取。
    final dbPath = await _ref.read(dbPathProvider.future);
    return getSongLyricsPayload(dbPath: dbPath, path: item.path);
  }

  /// 从在线插件拉取当前播放曲目的歌词正文。
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
      final lyric = await engine.getLyric(matches.first, sourceKey, musicInfo);
      if (lyric == null) return '';
      return (lyric['lxlyric'] ??
              lyric['yrc'] ??
              lyric['qrc'] ??
              lyric['eslrc'] ??
              lyric['lyric']) as String? ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// 剥离所有音源内嵌的逐字时间戳与元数据标签。
  String cleanLyricText(String raw) {
    if (raw.isEmpty) return '';
    String text = raw;
    // 1. 过滤元数据控制头 [ar:xx], [ti:xx] 等。
    text = text.replaceAll(
      RegExp(
        r'\[(ar|ti|al|by|offset|kuwo|kugou|hash|sign|qq|total|language|types):[^\]]*\]',
        caseSensitive: false,
      ),
      '',
    );
    // 2. 过滤酷狗 KRC / YRC 圆括号逐字时间戳。
    text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');
    // 3. 过滤方括号内嵌逐字时间戳。
    text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');
    // 4. 过滤尖括号时间戳。
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');
    return text.trim();
  }

  /// 将歌词 JSON（displayLines/lines）解析为歌词行列表。
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

      final text = cleanLyricText((item['text'] as String?) ?? '');
      final rawTrans = item['translation'] as String?;
      final translation = rawTrans != null && rawTrans.trim().isNotEmpty
          ? cleanLyricText(rawTrans)
          : null;
      final rawRomaji = (item['romaji'] as String?)?.trim();
      final romaji = (rawRomaji != null && rawRomaji.isNotEmpty)
          ? rawRomaji
          : null;

      // 富歌词：背景/副歌等次要歌词行。
      final secondary = <String>[];
      final rawSecondary = item['secondary'] as List?;
      if (rawSecondary != null) {
        for (final s in rawSecondary) {
          if (s is String && s.trim().isNotEmpty) {
            secondary.add(cleanLyricText(s));
          }
        }
      }

      final words = <LyricWord>[];
      final rawWords = item['words'] as List?;
      if (rawWords != null && rawWords.isNotEmpty) {
        for (final w in rawWords) {
          if (w is Map<String, dynamic>) {
            final wText = cleanLyricText((w['text'] as String?) ?? '');
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

  /// 时间边界修正：行结束时间缺失时用下一行起点回推，逐字裁剪重叠，
  /// 多字符词拆成逐字符子词（英文单词也能逐字母卡拉OK）。
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
}

final lyricsRepositoryProvider = Provider<LyricsRepository>(
  (ref) => LyricsRepository(ref),
);
