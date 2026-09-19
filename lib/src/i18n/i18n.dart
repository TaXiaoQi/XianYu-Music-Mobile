import 'package:flutter/foundation.dart' show ValueNotifier;

import 's2t_table.dart';
import 'en_dict_gen.dart';
import 'en_dict_manual.dart';
import 'tw_dict.dart';

enum I18nMode { zhCn, zhTw, en }

class I18n {
  I18n._();

  static I18nMode mode = I18nMode.zhCn;

  static final ValueNotifier<int> modeVersion = ValueNotifier(0);

  static final Map<String, String> _convCache = {};
  static const _maxCacheEntries = 4096;

  static void setMode(I18nMode m) {
    if (m == mode) return;
    mode = m;
    _convCache.clear();
    modeVersion.value++;
  }
}

final Map<String, String> enDict = {...enDictGen, ...enDictManual};

final RegExp _placeholderRe = RegExp(r'\{([a-zA-Z][a-zA-Z0-9]*)\}');
final RegExp _hanRe = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]');

String tr(String source, [Map<String, Object>? args]) {
  if (source.isEmpty) return source;
  String out;
  switch (I18n.mode) {
    case I18nMode.zhCn:
      out = source;
    case I18nMode.zhTw:
      out = twDict[source] ?? _toTraditional(source);
    case I18nMode.en:
      out = enDict[source] ?? source;
  }
  if (args != null && args.isNotEmpty) {
    out = out.replaceAllMapped(_placeholderRe, (m) => '${args[m.group(1)] ?? m.group(0)}');
  }
  return out;
}

String fmtCompact(num n) {
  if (n >= 100000000) {
    final v = (n / 100000000).toStringAsFixed(1);
    return I18n.mode == I18nMode.en ? '${_trimZero(v)}B' : '${_trimZero(v)}亿';
  }
  if (n >= 10000) {
    if (I18n.mode == I18nMode.en) {
      final k = n / 1000;
      return k >= 100 ? '${k.round()}K' : '${_trimZero(k.toStringAsFixed(1))}K';
    }
    return '${_trimZero((n / 10000).toStringAsFixed(1))}万';
  }
  return '$n';
}

String _trimZero(String s) => s.endsWith('.0') ? s.substring(0, s.length - 2) : s;

String localizeLyricText(String text) =>
    I18n.mode == I18nMode.zhTw ? _convertS2t(text) : text;

bool _containsHan(String s) => _hanRe.hasMatch(s);

int? _maxS2tPhraseLen;
int? _maxTwPhraseLen;

String _toTraditional(String text) {
  if (text.length > 64) return _convertS2t(text);
  final cached = I18n._convCache[text];
  if (cached != null) return cached;
  final converted = _convertS2t(text);
  if (I18n._convCache.length >= I18n._maxCacheEntries) {
    I18n._convCache.clear();
  }
  I18n._convCache[text] = converted;
  return converted;
}

String _convertS2t(String text) {
  if (!_containsHan(text)) return text;
  _maxS2tPhraseLen ??= _maxKeyLen(s2tPhrases);
  final stage1 = _mapSegments(text, s2tPhrases, _maxS2tPhraseLen!, s2tChars);
  _maxTwPhraseLen ??= _maxKeyLen(twPhrases);
  return _mapSegments(stage1, twPhrases, _maxTwPhraseLen!, twVariantChars);
}

int _maxKeyLen(Map<String, String> m) {
  var len = 0;
  for (final k in m.keys) {
    if (k.length > len) len = k.length;
  }
  return len;
}

String _mapSegments(String text, Map<String, String> phrases, int maxPhraseLen, Map<String, String> chars) {
  if (phrases.isEmpty && chars.isEmpty) return text;
  final buf = StringBuffer();
  final runes = text.runes.toList();
  var i = 0;
  while (i < runes.length) {
    final ch = String.fromCharCode(runes[i]);
    if (!_hanRe.hasMatch(ch)) {
      buf.write(ch);
      i++;
      continue;
    }
    var matched = false;
    final remain = runes.length - i;
    final tryLen = remain < maxPhraseLen ? remain : maxPhraseLen;
    for (var l = tryLen; l >= 2; l--) {
      final seg = String.fromCharCodes(runes, i, i + l);
      final hit = phrases[seg];
      if (hit != null) {
        buf.write(hit);
        i += l;
        matched = true;
        break;
      }
    }
    if (!matched) {
      final one = String.fromCharCode(runes[i]);
      buf.write(chars[one] ?? one);
      i++;
    }
  }
  return buf.toString();
}
