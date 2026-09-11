import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/shell.dart' show isLandscapeProvider;

/// 统一竖屏 / 横屏两套独立布局的排布组件（横屏适配总收纳第一层）。
///
/// 页面顶层统一这么接：
/// ```dart
/// return LandscapeGate(
///   portrait: _buildPortrait(context),   // 竖屏（默认）布局子树
///   landscape: _buildLandscape(context), // 横屏（独立一套 UI）布局子树
/// );
/// ```
/// - 竖屏树与横屏树在结构上【完全分开】；新增 / 修改横屏只动 [landscape]，
///   竖屏逻辑不受影响，横屏是一套独立 UI。
/// - 是否横屏由统一的 [isLandscapeProvider] 判定（宽 ≥ 1.05 × 高），切换时
///   用轻量交叉淡入淡出平滑过渡，避免竖/横屏硬切造成的页面跳变（移动端
///   仅淡入淡出，不做重特效，避免额外帧率/耗电开销）。
///
/// 横屏适配的“总入口”就是这个：任何页面要接横屏，就在顶层套一层
/// `LandscapeGate`。全部横屏适配点见 `lib/src/responsive/README.md` 索引。
class LandscapeGate extends ConsumerWidget {
  const LandscapeGate({
    super.key,
    required this.portrait,
    required this.landscape,
  }) : sequential = false;

  /// 顺序转场变体：先淡出旧形态、再淡入新形态，两套子树【不共存】。
  ///
  /// 交叉淡入淡出要求新旧子树短暂共存；若两套子树里存在同名 GlobalKey /
  /// Hero（如播放页封面的 `player-cover` Hero 与歌词视图 key），共存会触发
  /// key 冲突或元素盗用，反而把过渡打断成硬切。这类页面改用本构造器。
  const LandscapeGate.sequential({
    super.key,
    required this.portrait,
    required this.landscape,
  }) : sequential = true;

  /// 竖屏（默认）布局子树。
  final Widget portrait;

  /// 横屏（独立一套 UI）布局子树。
  final Widget landscape;

  /// 是否用「淡出→换挂载→淡入」的顺序转场（默认 false = 交叉淡入淡出）。
  final bool sequential;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLandscape = ref.watch(isLandscapeProvider);
    if (sequential) {
      return _SequentialFadeGate(
        isLandscape: isLandscape,
        portrait: portrait,
        landscape: landscape,
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [...previousChildren, ?currentChild],
      ),
      child: KeyedSubtree(
        key: ValueKey(isLandscape),
        child: isLandscape ? landscape : portrait,
      ),
    );
  }
}

/// 顺序淡出→淡入转场（新旧子树不共存，规避 GlobalKey / Hero 冲突）。
class _SequentialFadeGate extends StatefulWidget {
  const _SequentialFadeGate({
    required this.isLandscape,
    required this.portrait,
    required this.landscape,
  });

  final bool isLandscape;
  final Widget portrait;
  final Widget landscape;

  @override
  State<_SequentialFadeGate> createState() => _SequentialFadeGateState();
}

class _SequentialFadeGateState extends State<_SequentialFadeGate>
    with SingleTickerProviderStateMixin {
  // 惰性创建但不在 dispose 里创建（late final 在 dispose 首次访问会执行
  // 初始化器，createTicker 于失活元素上抛异常中断 finalizeTree）。
  AnimationController? _cC;
  AnimationController get _c => _cC ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 130),
  );

  /// 当前挂载的形态：旧形态完全淡出后才切换挂载，两套子树不共存。
  late bool _showLandscape = widget.isLandscape;

  /// 代数守卫：快速连续翻转丢弃过期回调。
  int _gen = 0;

  @override
  void didUpdateWidget(_SequentialFadeGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLandscape != widget.isLandscape) {
      _swapTo(widget.isLandscape);
    }
  }

  Future<void> _swapTo(bool target) async {
    final gen = ++_gen;
    // 旧形态淡出（1 → 0），快速压暗并掩盖旋转过渡期的拉伸帧。
    await _c.forward().orCancel;
    if (!mounted || gen != _gen) return;
    // 换挂载新形态，等它完成一帧 build/布局再淡入。
    setState(() => _showLandscape = target);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || gen != _gen) return;
    // 新形态淡入（0 → 1）。
    _c.duration = const Duration(milliseconds: 200);
    await _c.reverse().orCancel;
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: _showLandscape ? widget.landscape : widget.portrait,
    );
  }

  @override
  void dispose() {
    _cC?.dispose();
    super.dispose();
  }
}

/// 便捷读横屏态：`final ls = useLandscape(ref);` 等效 `ref.watch(isLandscapeProvider)`。
///
/// 用于侧栏、`if (ls)` 等不套 `LandscapeGate` 的局部判断，保证断点判断单一来源。
bool useLandscape(WidgetRef ref) => ref.watch(isLandscapeProvider);