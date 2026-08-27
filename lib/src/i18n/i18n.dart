import 's2t_table.dart';
import 'en_dict_gen.dart';
import 'en_dict_manual.dart';
import 'tw_dict.dart';

/// 界面语言渲染模式。zhCN 为源语言（字面中文直出），en 走精确词典，
/// zhTW 走繁体精确词典 + 运行期简繁转换兜底（对齐桌面端 i18n 架构）。
enum I18nMode { zhCn, zhTw, en }

/// 全局界面语言状态。
///
/// 由 app.dart 在 build 时根据设置语言（或系统语言解析结果）同步；
/// tr() 是无 context 的纯函数查表，provider/服务层的用户可见文案
/// （toast、通知、状态文本）无需 BuildContext 也能拿到当前语言。
class I18n {
  I18n._();

  static I18nMode mode = I18nMode.zhCn;

  /// 运行期简繁转换缓存（短 UI 文案重复出现，命中率高）。
  static final Map<String, String> _convCache = {};
  static const _maxCacheEntries = 4096;

  static void setMode(I18nMode m) {
    if (m == mode) return;
    mode = m;
    _convCache.clear();
  }
}

final Map<String, String> enDict = {...enDictGen, ...enDictManual};

final RegExp _placeholderRe = RegExp(r'\{([a-zA-Z][a-zA-Z0-9]*)\}');
final RegExp _hanRe = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]');

/// 翻译一条界面文案。
///
/// - [source]：简体中文源文案；动态值用 `{name}` 占位符表达。
/// - [args]：占位符实际值，插入 zh 与翻译结果。
/// - 未收录词条回退源文案（zhCN 恒等，en 兜底中文，zhTW 走转换）。
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

/// 万/亿数量缩写：中文 3.2万 / 1.2亿，英文 32K / 120M。
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

bool _containsHan(String s) => _hanRe.hasMatch(s);

int? _maxS2tPhraseLen;
int? _maxTwPhraseLen;

/// 简体 → 台湾正体：短语最长优先，剩余按字符转换，再做台湾变体替换。
String _toTraditional(String text) {
  if (text.length > 64) return _convertS2t(text); // 长文本不进缓存
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

/// 逐段转换：每个位置先尝试最长短语命中，否则单字转换；非中文段原样保留。
String _mapSegments(String text, Map<String, String> phrases, int maxPhraseLen, Map<String, String> chars) {
  if (phrases.isEmpty && chars.isEmpty) return text;
  final buf = StringBuffer();
  final runes = text.runes.toList();
  var i = 0;
  while (i < runes.length) {
    // ASCII / 非中文字符直接透传（占位符、数字、英文标签）。
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
      // end 为绝对索引 = i + l，不能用相对长度 l（位置靠后时 end<start 会越界）
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
