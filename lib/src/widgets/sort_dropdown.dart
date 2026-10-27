import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

/// 排序下拉选项：类型值 + 显示文案
class SortOption<T> {
  const SortOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// 锚定玻璃下拉菜单项
class AnchoredMenuEntry {
  const AnchoredMenuEntry({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.showDirectionUp,
    this.showCheck = true,
    this.dividerBefore = false,
    this.subtle = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;

  /// 选中项：主色 + 勾
  final bool selected;

  /// 选中项方向箭头（null=不显示）
  final bool? showDirectionUp;

  final bool showCheck;

  /// 项前分隔线（菜单顶部的方向切换行与选项组之间）
  final bool dividerBefore;

  /// 弱化样式（方向切换行）
  final bool subtle;

  /// 当前类型无方向语义时方向行置灰不可点（对齐桌面端始终可见）
  final bool enabled;
}

/// 桌面端同款锚定排序下拉：点入口在按钮下方弹出实底卡片菜单。
/// 选中项右侧方向箭头 + 勾；点已选项翻转升降序，点新项落默认方向。
class SortMenuButton<T> extends StatefulWidget {
  const SortMenuButton({
    super.key,
    required this.options,
    required this.current,
    required this.ascending,
    required this.isDirectional,
    required this.defaultAscending,
    required this.onChanged,
    required this.child,
  });

  final List<SortOption<T>> options;
  final T current;
  final bool ascending;
  final bool Function(T value) isDirectional;
  final bool Function(T value) defaultAscending;
  final void Function(T value, bool ascending) onChanged;
  final Widget child;

  @override
  State<SortMenuButton<T>> createState() => _SortMenuButtonState<T>();
}

class _SortMenuButtonState<T> extends State<SortMenuButton<T>> {
  OverlayEntry? _entry;

  bool get _open => _entry != null;

  void _toggle() {
    if (_open) {
      _close();
      return;
    }
    final box = context.findRenderObject();
    final overlayState = Overlay.of(context);
    final overlayBox =
        overlayState.context.findRenderObject() as RenderBox?;
    if (box is! RenderBox || !box.hasSize) return;
    if (overlayBox == null || !overlayBox.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final overlaySize = overlayBox.size;

    const w = 220.0;
    var dx = topLeft.dx;
    if (dx + w > overlaySize.width - 8) dx = overlaySize.width - 8 - w;
    if (dx < 8) dx = 8;

    final directional = widget.isDirectional(widget.current);
    final estH = (directional ? 52 : 0) + widget.options.length * 46 + 10;
    final below = topLeft.dy + box.size.height;
    double dy = below + 6;
    if (dy + estH > overlaySize.height - 8) {
      dy = (topLeft.dy - estH - 6).clamp(8.0, overlaySize.height - 8);
    }

    final entries = <AnchoredMenuEntry>[
      // 方向切换行（资源管理器同款）：点它直接翻转当前类型升降序；
      // 始终显示，当前类型无方向语义时置灰（对齐桌面端按钮置灰可见）
      AnchoredMenuEntry(
        label: widget.ascending ? tr('升序排列') : tr('降序排列'),
        selected: false,
        showCheck: false,
        showDirectionUp: widget.ascending,
        subtle: true,
        enabled: directional,
        onTap: () => _select(widget.current, !widget.ascending),
      ),
      for (final opt in widget.options)
        AnchoredMenuEntry(
          label: opt.label,
          selected: opt.value == widget.current,
          showDirectionUp: opt.value == widget.current &&
                  widget.isDirectional(widget.current)
              ? widget.ascending
              : null,
          onTap: () => _select(
            opt.value,
            opt.value == widget.current
                ? (widget.isDirectional(opt.value)
                    ? !widget.ascending
                    : widget.ascending)
                : widget.defaultAscending(opt.value),
          ),
        ),
    ];
    // 方向切换行与选项组之间加分隔
    if (entries.length > 1) {
      entries[1] = _withDivider(entries[1]);
    }

    _entry = OverlayEntry(
      builder: (octx) => AnchoredGlassMenu(
        left: dx,
        top: dy,
        width: w,
        entries: entries,
        onDismiss: _close,
      ),
    );
    overlayState.insert(_entry!);
    setState(() {});
  }

  AnchoredMenuEntry _withDivider(AnchoredMenuEntry e) => AnchoredMenuEntry(
        label: e.label,
        onTap: e.onTap,
        selected: e.selected,
        showDirectionUp: e.showDirectionUp,
        showCheck: e.showCheck,
        dividerBefore: true,
        subtle: e.subtle,
      );

  void _select(T value, bool asc) {
    final cb = widget.onChanged;
    _close();
    cb(value, asc);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _toggle,
      borderRadius: BorderRadius.circular(8),
      child: widget.child,
    );
  }
}

/// 锚定菜单浮层：全屏手势层（点外部关闭）+ 实底卡片菜单。
/// 实底卡片菜单（不应用玻璃材质）。
class AnchoredGlassMenu extends StatefulWidget {
  const AnchoredGlassMenu({
    super.key,
    required this.left,
    required this.top,
    required this.width,
    required this.entries,
    required this.onDismiss,
  });

  final double left;
  final double top;
  final double width;
  final List<AnchoredMenuEntry> entries;
  final VoidCallback onDismiss;

  @override
  State<AnchoredGlassMenu> createState() => _AnchoredGlassMenuState();
}

class _AnchoredGlassMenuState extends State<AnchoredGlassMenu> {
  @override
  void dispose() {
    _closingTimer?.cancel();
    super.dispose();
  }

  Timer? _closingTimer;

  void _select(VoidCallback onTap) {
    widget.onDismiss();
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 实底卡片（不应用玻璃材质）
    final fill = isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF);
    final menu = Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.40),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          for (final e in widget.entries) ...[
            if (e.dividerBefore)
              Divider(
                height: 9,
                thickness: 0.6,
                indent: 14,
                endIndent: 14,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            InkWell(
              onTap: e.enabled ? () => _select(e.onTap) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    if (e.showDirectionUp != null) ...[
                      Icon(
                        e.showDirectionUp!
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 14,
                        color: e.enabled
                            ? scheme.primary
                            : scheme.outline,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        e.label,
                        style: TextStyle(
                          fontSize: e.subtle ? 13.5 : 14,
                          color: !e.enabled
                              ? scheme.outline
                              : e.selected
                                  ? scheme.primary
                                  : (e.subtle
                                      ? scheme.onSurfaceVariant
                                      : scheme.onSurface),
                        ),
                      ),
                    ),
                    if (e.selected && e.showCheck)
                      Icon(
                        Icons.check,
                        size: 18,
                        color: scheme.primary,
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
        ],
        ),
      ),
    );
    return Stack(
      children: [
        // 全屏手势层：点击菜单外关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
          ),
        ),
        Positioned(
          left: widget.left,
          top: widget.top,
          width: widget.width,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * -6),
                child: child,
              ),
            ),
            child: RepaintBoundary(child: menu),
          ),
        ),
      ],
    );
  }
}
