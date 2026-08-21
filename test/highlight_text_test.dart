import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/widgets/song_list_view.dart';

/// 从 highlightedText 返回的 widget 中提取 (文本, 是否高亮) 序列。
List<(String, bool)> _segments(Widget w) {
  if (w is Text) {
    if (w.textSpan case final InlineSpan span?) {
      final out = <(String, bool)>[];
      span.visitChildren((s) {
        if (s is TextSpan && s.text != null) {
          out.add((s.text!, s.style?.color != null));
        }
        return true;
      });
      return out;
    }
    return [(w.data ?? '', false)];
  }
  return const [];
}

void main() {
  const hl = Color(0xFFEC4141);

  test('关键词为空时返回原文且无高亮', () {
    final segs = _segments(highlightedText('今天你要嫁给我', '', hl));
    expect(segs, [('今天你要嫁给我', false)]);
  });

  test('无命中时返回原文且无高亮', () {
    final segs = _segments(highlightedText('今天你要嫁给我', '昨日', hl));
    expect(segs, [('今天你要嫁给我', false)]);
  });

  test('单次命中：仅命中片段着色', () {
    final segs = _segments(highlightedText('今天你要嫁给我', '天', hl));
    expect(segs, [('今', false), ('天', true), ('你要嫁给我', false)]);
  });

  test('命中位于开头', () {
    final segs = _segments(highlightedText('天空之城', '天', hl));
    expect(segs, [('天', true), ('空之城', false)]);
  });

  test('多次命中全部着色', () {
    final segs = _segments(highlightedText('一天到晚游泳的天', '天', hl));
    expect(segs, [
      ('一', false),
      ('天', true),
      ('到晚游泳的', false),
      ('天', true),
    ]);
  });

  test('大小写不敏感匹配，但保留原文大小写', () {
    final segs = _segments(highlightedText('Hello World', 'WOR', hl));
    expect(segs, [('Hello ', false), ('Wor', true), ('ld', false)]);
  });

  test('高亮片段只改颜色，不设置背景色', () {
    final w = highlightedText('今天', '天', hl) as Text;
    final spans = <TextSpan>[];
    w.textSpan!.visitChildren((s) {
      if (s is TextSpan && s.text != null) spans.add(s);
      return true;
    });
    final hit = spans.firstWhere((s) => s.text == '天');
    expect(hit.style?.color, hl);
    expect(hit.style?.backgroundColor, isNull);
    expect(hit.style?.background, isNull);
  });
}
