import 'package:flutter/material.dart';

import 'page_switch_tab_view.dart';

/// 横屏主 tab 切换器（独立模式，与竖屏 PageView 容器完全分开）。
///
/// - 动画：桌面版 page-fade 同款 out-in（旧页淡出微上移缩小 → 换页 → 新页
///   自下方微上移淡入，0.22s，expo-out，±6/8px + 0.996），受「横屏切换动画」
///   开关控制，关闭即硬切。
/// - 右侧面板（音乐库/下载/歌单详情/搜索/账号）打开时切 tab：suppress
///   （取 old 值）→ 硬切，切换动画由面板关闭淡出承担，避免两层动画叠加。
/// - 分支状态：所有分支 Offstage + keepAlive 常驻树中，离屏分支保留滚动/
///   播放状态；横竖屏互换容器时由 routes.dart 的分支 GlobalKey 跨容器保留。
class LandscapeTabSwitcher extends StatefulWidget {
  const LandscapeTabSwitcher({
    super.key,
    required this.currentIndex,
    required this.children,
    this.enabled = true,
    this.suppress = false,
  });

  final int currentIndex;
  final List<Widget> children;

  /// 「横屏切换动画」开关；false 时硬切。
  final bool enabled;

  /// 右侧面板打开中：切 tab 硬切。注意取 didUpdateWidget 的 old 值判断——
  /// 面板关闭与 currentIndex 变化发生在同一帧。
  final bool suppress;

  @override
  State<LandscapeTabSwitcher> createState() => _LandscapeTabSwitcherState();
}

class _LandscapeTabSwitcherState extends State<LandscapeTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final CurvedAnimation _curved;

  /// [_shownIndex] 实际显示的分支：静止时 = currentIndex，out 阶段 = 旧页。
  int _shownIndex = 0;
  int _pendingIndex = -1;
  bool _animating = false;
  bool _outPhase = false;

  /// 代数守卫：_anim.value 赋值会强停运行中的 ticker，被打断的旧 forward 的
  /// whenComplete 会以 TickerCanceled 触发，必须忽略（同 PageSwitchTabView）。
  int _gen = 0;

  static const _fadeDuration = Duration(milliseconds: 220);
  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);

  @override
  void initState() {
    super.initState();
    _shownIndex = widget.currentIndex;
    // 静止态 = in 阶段 t=1（恒等映射），包装层无视觉影响。
    _anim = AnimationController(vsync: this, duration: _fadeDuration)
      ..value = 1.0;
    _curved = CurvedAnimation(parent: _anim, curve: _ease);
  }

  @override
  void didUpdateWidget(covariant LandscapeTabSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex == old.currentIndex) return;
    _pendingIndex = widget.currentIndex;
    // 硬切判定取 old 值：切换前面板还开着 → 面板关闭淡出即本次切换的动画。
    if (!widget.enabled || old.suppress) {
      _gen++;
      _animating = false;
      _outPhase = false;
      _anim.stop();
      _anim.value = 1.0;
      setState(() => _shownIndex = _pendingIndex);
      return;
    }
    // pending 始终同步为最新目标（不设守卫，避免 A→B→A 快速切换时 pending
    // 滞后导致循环跳页）。
    if (_animating) {
      // out 阶段并入当前周期；in 阶段被打断则重启一轮 out。
      if (!_outPhase) _beginOut();
    } else {
      _beginOut();
    }
  }

  /// out 阶段：旧页淡出（上移 6px、缩至 0.996），完成后换到目标页进入 in 阶段。
  void _beginOut() {
    _animating = true;
    _outPhase = true;
    final gen = ++_gen;
    // 同步把动画值归零再 forward：若 value 停留在上一轮 in 结束的 1.0，本帧
    // paint 时 out 映射 opacity = 1 - 1 = 0，旧页会先满帧消失一拍（硬闪）。
    _anim.value = 0;
    _anim.forward().whenComplete(() {
      if (!mounted || gen != _gen) return;
      _onOutComplete();
    });
  }

  void _onOutComplete() {
    if (!mounted) return;
    final target = _pendingIndex;
    // 先同步切到 in 映射并把 value 归零、再换页：换页后的首帧新页以 opacity 0
    // 出现，否则新页会满帧闪现一拍。
    _outPhase = false;
    _anim.value = 0;
    setState(() => _shownIndex = target);
    if (target != widget.currentIndex) {
      // out 期间目标又变了：再来一轮 out。
      _beginOut();
      return;
    }
    // in 阶段：新页自下方 8px、scale 0.996 淡入归位。
    final gen = _gen;
    _anim.forward().whenComplete(() {
      if (!mounted || gen != _gen) return;
      if (mounted) setState(() => _animating = false);
    });
  }

  @override
  void dispose() {
    _curved.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 每个分支的包装链必须【类型恒定 + 稳定 key】：Stack children 按「位置+
    // 类型」diff，若像旧结构那样「离屏 Offstage(TK)、显示 TK」两种包装类型
    // 随 _shownIndex 互换，切换时显示分支（首页/我的导航子树，最重）会被整树
    // 卸载重建，淡入首帧掉帧白闪，看起来像硬切。这里恒定 KeyedSubtree(key) →
    // Offstage → TK 链，切页只翻转 offstage 布尔，分支 element 永远复用，
    // 滚动/播放状态跨切换保留。
    final stack = Stack(
      children: [
        for (var i = 0; i < widget.children.length; i++)
          KeyedSubtree(
            key: ValueKey('landscape-branch-$i'),
            child: Offstage(
              offstage: i != _shownIndex,
              child: TabKeepAlivePage(child: widget.children[i]),
            ),
          ),
      ],
    );

    // 恒定经由同一个 AnimatedBuilder 包装，静止态恒等变换（不切换根 widget
    // 类型，避免子树重挂载）。
    return AnimatedBuilder(
      animation: _anim,
      child: stack,
      builder: (context, child) {
        final t = _curved.value;
        final double opacity;
        final double dy;
        final double scale;
        if (_outPhase) {
          opacity = 1 - t;
          dy = -6 * t;
          scale = 1 - 0.004 * t;
        } else {
          opacity = t;
          dy = 8 * (1 - t);
          scale = 0.996 + 0.004 * t;
        }
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              child: IgnorePointer(ignoring: _outPhase, child: child),
            ),
          ),
        );
      },
    );
  }
}
