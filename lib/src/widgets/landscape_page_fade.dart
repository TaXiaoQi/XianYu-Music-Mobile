import 'package:flutter/material.dart';

/// 横屏内容容器共用的桌面版 page-fade out-in 切换器。
///
/// 横屏壳层右侧面板（音乐库/下载/歌单详情/搜索/账号）与设置页横屏
/// master-detail 右侧分类详情共用：切换/关闭时旧内容「淡出 + 微上移 + 微
/// 缩小」，完成后换新内容「自下方微上移淡入」（0.22s，
/// cubic-bezier(0.16, 1, 0.3, 1)，桌面端同款）。
///
/// [child] 允许为 null（视为关闭）；[open] 为 false 时先淡出旧内容再清空，
/// 因此本组件可常驻挂载（关闭不再是硬切）。[trigger] 变化触发换内容 out-in，
/// 同 trigger 的常规内容更新直接跟随、不触发动画。
class LandscapePageFade extends StatefulWidget {
  const LandscapePageFade({
    super.key,
    required this.open,
    required this.trigger,
    required this.child,
  });

  /// 当前是否应显示内容；false 时先播淡出再清空。
  final bool open;

  /// 内容标识（面板 key/分类 path…）：变化触发换内容 out-in。
  final Object? trigger;

  /// open 时的内容；null 视为关闭。
  final Widget? child;

  static const _duration = Duration(milliseconds: 220);
  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);

  @override
  State<LandscapePageFade> createState() => _LandscapePageFadeState();
}

class _LandscapePageFadeState extends State<LandscapePageFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;

  /// 当前渲染的内容（关闭淡出期间保留旧内容，避免瞬间消失）。
  Widget? _shown;

  /// out 阶段：true=正在淡出（换内容或关闭）。
  bool _out = false;

  /// out 完成后要显示的内容（null=关闭卸载）。
  Widget? _pending;

  /// 代数守卫：reverse 被打断时作废旧回调。
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: LandscapePageFade._duration);
    final curve = CurvedAnimation(
      parent: _c,
      curve: LandscapePageFade._ease,
    );
    _fade = curve;
    // 与桌面版 enter-from 一致：translateY(8px) + scale(0.996) → 原位。
    _slide = Tween<Offset>(
      begin: const Offset(0, 8),
      end: Offset.zero,
    ).animate(curve);
    _scale = Tween<double>(begin: 0.996, end: 1).animate(curve);
    if (widget.open && widget.child != null) {
      _shown = widget.child;
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(LandscapePageFade old) {
    super.didUpdateWidget(old);
    if (!widget.open || widget.child == null) {
      // 关闭：淡出旧内容后再卸载；out 进行中则让 pending 归 null（完成后关）。
      if (_shown != null && !_out) _beginOut(null);
      return;
    }
    if (_shown == null) {
      // 从关闭直接打开：淡入新内容。
      setState(() => _shown = widget.child);
      _c.forward(from: 0);
    } else if (widget.trigger != old.trigger) {
      // 内容切换：旧内容淡出后换新内容淡入。
      if (_out) {
        _pending = widget.child; // 始终采纳最新目标
      } else {
        _beginOut(widget.child);
      }
    } else {
      // 同内容的常规更新：直接跟随，不触发动画。
      _shown = widget.child;
    }
  }

  /// out 阶段：当前内容淡出（上移 6px、缩至 0.996），完成后换 [target]
  /// 进入 in 阶段；target 为 null 表示关闭卸载。
  void _beginOut(Widget? target) {
    _out = true;
    _pending = target;
    final gen = ++_gen;
    _c.reverse().whenComplete(() {
      if (!mounted || gen != _gen) return;
      setState(() {
        _shown = _pending;
        _pending = null;
        _out = false;
      });
      if (_shown != null) _c.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _c,
      child: shown,
      builder: (context, child) {
        final t = _c.value;
        if (_out) {
          // out：淡出 + 微上移 + 微缩小（桌面版 page-fade 出场方向）。
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, -6 * (1 - t)),
              child: Transform.scale(
                scale: 0.996 + 0.004 * t,
                child: child,
              ),
            ),
          );
        }
        // in：自下方微上移淡入。
        return Transform.translate(
          offset: _slide.value,
          child: Transform.scale(
            scale: _scale.value,
            child: Opacity(opacity: _fade.value, child: child),
          ),
        );
      },
    );
  }
}
