import 'package:pinyin/pinyin.dart';

/// 拼音排序键：中文按全拼转为字母序（A-Z），英文/数字原样小写，
/// 其他符号原样保留。用于列表「按标题/歌手/专辑」排序，使中文条目
/// 严格按拼音 A-Z 排列（Dart 默认 compareTo 是码点序，中文会乱序）。
String pinyinSortKey(String text) {
  final s = text.trim().toLowerCase();
  if (s.isEmpty) return '';
  final buf = StringBuffer();
  var hasHan = false;
  for (final ch in s.runes) {
    // ASCII 可见字符直接原样，避免无谓的拼音表查询
    if (ch < 0x80) {
      buf.writeCharCode(ch);
      continue;
    }
    final c = String.fromCharCode(ch);
    final py = PinyinHelper.getFirstWordPinyin(c).toLowerCase();
    if (py.isEmpty) {
      buf.write(c);
    } else {
      buf.write(py);
      hasHan = true;
    }
  }
  return hasHan ? buf.toString() : s;
}

/// 拼音排序键的首字母（大写 A-Z；非字母开头归入 '#'）
String letterOfPinyinKey(String text) {
  final key = pinyinSortKey(text);
  if (key.isEmpty) return '#';
  final c = key[0].toUpperCase();
  final code = c.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) ? c : '#';
}
