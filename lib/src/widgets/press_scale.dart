import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 全局 iOS 风格按压缩放：宿主统一监听指针，命中 [PressableScale] 后由
/// RenderObject 直接动画 paint 变换——不重建子树、不改布局、不参与手势竞技，
/// 任意子组件的手势逻辑零侵入。
class PressScaleHost extends StatefulWidget {
  const PressScaleHost({super.key, required this.child});

  final Widget child;

  @override
  State<PressScaleHost> createState() => _PressScaleHostState();
}

class _PressScaleHostState extends State<PressScaleHost> {
  // pointer → 按住的缩放节点；down 位置用于滑动越界时释放
  final Map<int, RenderPressableScale> _pressed = {};
  final Map<int, Offset> _downPos = {};

  void _onDown(PointerDownEvent event) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final result = BoxHitTestResult();
    if (!box.hitTest(result, position: box.globalToLocal(event.position))) {
      return;
    }
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderPressableScale) {
        target.pressDown();
        _pressed[event.pointer] = target;
        _downPos[event.pointer] = event.position;
        return;
      }
    }
  }

  void _onMove(PointerMoveEvent event) {
    final node = _pressed[event.pointer];
    if (node == null) return;
    // 手指滑动超过判定距离（滚动列表起始拖拽）视为取消按压
    final down = _downPos[event.pointer];
    if (down != null && (event.position - down).distance > 18) {
      node.pressUp();
      _pressed.remove(event.pointer);
      _downPos.remove(event.pointer);
    }
  }

  void _release(int pointer) {
    _pressed.remove(pointer)?.pressUp();
    _downPos.remove(pointer);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (e) => _release(e.pointer),
      onPointerCancel: (e) => _release(e.pointer),
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _pressed.clear();
    _downPos.clear();
    super.dispose();
  }
}

/// 按压缩放单元：包住任意可点内容，按下时整体缩至 [pressScale]，
/// 松手以回弹曲线恢复。包装不改变布局与手势行为。
///
/// ```dart
/// PressableScale(child: ListTile(...))
/// PressableScale(pressScale: 0.88, child: IconButton(...))
/// ```
class PressableScale extends SingleChildRenderObjectWidget {
  const PressableScale({super.key, this.pressScale = 0.94, required super.child});

  /// 按下时的目标缩放；大卡片/行/瓦片用默认，小图标按钮建议 0.88~0.92
  final double pressScale;

  @override
  RenderPressableScale createRenderObject(BuildContext context) =>
      RenderPressableScale(pressScale: pressScale);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderPressableScale renderObject) {
    renderObject.pressScale = pressScale;
  }
}

class RenderPressableScale extends RenderProxyBox {
  RenderPressableScale({required double pressScale}) : _pressScale = pressScale;

  // 欠阻尼物理弹簧（Telegram/iOS 手感）：过冲后振荡衰减，
  // 中途打断（连按/快速抬起）带着速度续算，天然连续
  static const double _stiffness = 220; // 刚度 k：决定响应快慢
  static const double _dampingRatio = 0.42; // 阻尼比 ζ：越小越 Q 弹

  double _pressScale;
  set pressScale(double value) {
    if (value == _pressScale) return;
    _pressScale = value;
    if (_isPressed) _springTo(_pressScale);
  }

  bool _isPressed = false;
  double _scale = 1.0;
  double _velocity = 0.0;
  double _target = 1.0;
  Ticker? _ticker;
  Duration? _lastElapsed;

  void pressDown() {
    if (!attached) return;
    _isPressed = true;
    _springTo(_pressScale);
  }

  void pressUp() {
    if (!attached) return;
    _isPressed = false;
    _springTo(1.0);
  }

  void _springTo(double target) {
    if (_scale == target && _velocity == 0.0) {
      _stopTicker();
      return;
    }
    _target = target;
    _lastElapsed = null;
    final ticker = _ticker ??= Ticker(_onTick, debugLabel: 'pressScale');
    if (!ticker.isActive) ticker.start();
  }

  void _onTick(Duration elapsed) {
    // 半隐式欧拉积分；dt 夹到单帧上限防卡帧后爆炸
    final dt = _lastElapsed == null
        ? 0.0
        : ((elapsed - _lastElapsed!).inMicroseconds / 1e6)
            .clamp(0.0, 0.032);
    _lastElapsed = elapsed;
    final damping = 2 * _dampingRatio * math.sqrt(_stiffness); // c = 2ζ√k
    _velocity += (_stiffness * (_target - _scale) - damping * _velocity) * dt;
    _scale += _velocity * dt;
    if ((_target - _scale).abs() < 0.0005 && _velocity.abs() < 0.005) {
      _scale = _target;
      _velocity = 0.0;
      _stopTicker();
    }
    markNeedsPaint();
  }

  void _stopTicker() {
    _lastElapsed = null;
    _ticker?.stop();
  }

  // 以缩放中心（1 - s）· c 补偿平移，等效于绕中心缩放
  Matrix4 _transform() {
    final c = size.center(Offset.zero);
    return Matrix4.translationValues(c.dx * (1 - _scale), c.dy * (1 - _scale), 0)
        .multiplied(Matrix4.diagonal3Values(_scale, _scale, 1));
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // 按压缩放期间命中位置按逆变换映射回子坐标系
    if (_scale == 1.0) return super.hitTest(result, position: position);
    final c = size.center(Offset.zero);
    final mapped = Offset(
      c.dx + (position.dx - c.dx) / _scale,
      c.dy + (position.dy - c.dy) / _scale,
    );
    return super.hitTest(result, position: mapped);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_scale == 1.0) {
      super.paint(context, offset);
      return;
    }
    // pushTransform 自动处理子树含合成层（毛玻璃）的场景
    context.pushTransform(needsCompositing, offset, _transform(), super.paint);
  }

  @override
  void detach() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _isPressed = false;
    _scale = 1.0;
    super.detach();
  }
}
