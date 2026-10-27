import 'package:flutter/material.dart';

/// 弹窗外壳：实底卡片（不应用玻璃材质）。
/// 「上半内容、下半按钮区」结构保留：按钮区用 dialogTheme 原色底。
class GlassDialogShell extends StatelessWidget {
  const GlassDialogShell({
    super.key,
    required this.content,
    this.actions,
    this.actionsPadding,
  });

  /// 上半内容区（图标/标题/正文/页签等）
  final Widget content;

  /// 下半按钮区（原色实底；null 则整窗同底色）
  final List<Widget>? actions;

  final EdgeInsetsGeometry? actionsPadding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = Theme.of(context).dialogTheme.backgroundColor ??
        scheme.surfaceContainerHigh;
    final fill = isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF);
    final actionsRow = actions;
    // 无按钮区时直接返回 content：外层 Column(min) 会把 content 当
    // 非 flex 子项松掉高度约束，导致 content 里的 Flexible/TabBarView
    // 拿到无界高度直接崩溃（Horizontal viewport unbounded height）
    final Widget body;
    if (actionsRow == null || actionsRow.isEmpty) {
      body = content;
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          content,
          Container(
            color: dialogBg,
            padding:
                actionsPadding ?? const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: actionsRow,
            ),
          ),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(24),
      ),
      child: body,
    );
  }
}
