import 'dart:async';

import 'package:flutter/material.dart';

/// 悬浮字母索引条：叠在平铺列表右侧边缘（Stack 覆盖，不占布局宽度）。
/// 平时藏于屏幕外；用户滑动列表或拖拽字母条时滑入显示，
/// 停止滑动 2 秒后滑出隐藏。点击/拖拽字母跳到该首字母第一项。
class FloatingLetterIndex extends StatefulWidget {
  const FloatingLetterIndex({
    super.key,
    required this.child,
    required this.letters,
    required this.itemExtent,
    required this.topInset,
    required this.controller,
  });

  final Widget child;

  /// 每项对应的首字母（大写 A-Z 或 '#'），顺序与列表一致（按当前排序键取）
  final List<String> letters;

  /// 列表行高（itemExtent），用于偏移与项序号换算
  final double itemExtent;

  /// 列表第一项距 scroll offset 0 的距离（padding + 顶部操作行高度）
  final double topInset;

  final ScrollController controller;

  @override
  State<FloatingLetterIndex> createState() => _FloatingLetterIndexState();
}

class _FloatingLetterIndexState extends State<FloatingLetterIndex> {
  static const _hideAfter = Duration(seconds: 2);

  bool _visible = false;
  Timer? _timer;
  String _current = '';

  /// 字母表（去重，'#' 排末尾）
  List<String> get _alphabet {
    final seen = <String>{};
    final out = <String>[];
    for (final l in widget.letters) {
      if (seen.add(l)) out.add(l);
    }
    out.sort((a, b) {
      if (a == '#') return 1;
      if (b == '#') return -1;
      return a.compareTo(b);
    });
    return out;
  }

  void _poke() {
    if (!_visible) setState(() => _visible = true);
    _updateCurrent();
    _timer?.cancel();
    _timer = Timer(_hideAfter, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _updateCurrent() {
    final c = widget.controller;
    if (!c.hasClients || widget.letters.isEmpty) return;
    final idx =
        (((c.offset - widget.topInset) / widget.itemExtent).floor())
            .clamp(0, widget.letters.length - 1);
    final l = widget.letters[idx];
    if (l != _current) setState(() => _current = l);
  }

  void _jumpToLetter(String letter) {
    final i = widget.letters.indexOf(letter);
    if (i < 0 || !widget.controller.hasClients) return;
    final target = widget.topInset + i * widget.itemExtent;
    widget.controller.jumpTo(
      target.clamp(0.0, widget.controller.position.maxScrollExtent),
    );
    _poke();
  }

  /// 拖拽/点按字母条：按纵向位置定位字母
  void _letterAt(Offset localPos, double height, int count) {
    if (count == 0) return;
    final i =
        (localPos.dy / height * count).floor().clamp(0, count - 1);
    _jumpToLetter(_alphabet[i]);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.depth == 0 &&
            (n is ScrollUpdateNotification ||
                n is UserScrollNotification)) {
          _poke();
        }
        return false;
      },
      child: Stack(
        children: [
          widget.child,
          Positioned(
            right: 2,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_visible,
              child: AnimatedSlide(
                offset: Offset(_visible ? 0 : 1.4, 0),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: Center(
                  child: _LetterStrip(
                    alphabet: _alphabet,
                    current: _current,
                    scheme: scheme,
                    onLetter: _letterAt,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LetterStrip extends StatelessWidget {
  const _LetterStrip({
    required this.alphabet,
    required this.current,
    required this.scheme,
    required this.onLetter,
  });

  final List<String> alphabet;
  final String current;
  final ColorScheme scheme;
  final void Function(Offset localPos, double height, int count) onLetter;

  @override
  Widget build(BuildContext context) {
    if (alphabet.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        // 字母间距自适应：屏高富余时 14，紧张时最小 11
        final itemH =
            (((box.maxHeight - 24) / alphabet.length).clamp(11.0, 14.0));
        final stripH = itemH * alphabet.length + 12;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) =>
              onLetter(d.localPosition, stripH, alphabet.length),
          onVerticalDragUpdate: (d) =>
              onLetter(d.localPosition, stripH, alphabet.length),
          onVerticalDragStart: (d) =>
              onLetter(d.localPosition, stripH, alphabet.length),
          child: Container(
            width: 20,
            margin: const EdgeInsets.only(right: 2),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 10,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final l in alphabet)
                  SizedBox(
                    height: itemH,
                    child: Center(
                      child: Text(
                        l,
                        style: TextStyle(
                          fontSize: 9.5,
                          height: 1,
                          fontWeight: l == current
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: l == current
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
