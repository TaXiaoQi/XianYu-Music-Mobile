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
  const PressableScale({
    super.key,
    this.pressScale = 0.97,
    this.swing = false,
    required super.child,
  });

  /// 按下时的目标缩放。大件（卡片/行/播放条）用默认 0.97：浅按压、含蓄；
  /// 小 ui（播放页控制键、顶栏按钮等）显式传 0.88~0.92 声明深按压，
  /// 走小件档（沉得深、回弹 Q 弹）
  final double pressScale;

  /// 松手回弹时左右轻摆：全局默认关闭，仅播放队列等明确需要晃感的
  /// 小件开启
  final bool swing;

  @override
  RenderPressableScale createRenderObject(BuildContext context) =>
      RenderPressableScale(pressScale: pressScale, swing: swing);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderPressableScale renderObject) {
    renderObject
      ..pressScale = pressScale
      ..swing = swing;
  }
}

class RenderPressableScale extends RenderProxyBox {
  RenderPressableScale({required double pressScale, bool swing = false}) {
    this.pressScale = pressScale;
    this.swing = swing;
  }

  // 欠阻尼物理弹簧（Telegram/iOS 手感），大小控件分档：
  // 小 ui（显式传 0.88~0.92 深按压的：播放页控制键、顶栏按钮等）沉得
  // 深、回弹 Q 弹；大件（卡片/行/播放条，默认 0.97）浅按压、回弹利落
  // 几乎不过冲。左右轻摆默认关闭，swing=true（播放队列等）的小件松手
  // 摇摆一次补足表现力
  static const double _stiffnessDown = 520; // 下压刚度：几十毫秒内沉到位
  static const double _dampingDown = 0.55; // 下压阻尼比：底部轻微顿挫
  static const double _stiffnessUpSmall = 240; // 小件回弹：稍缓释放
  static const double _dampingUpSmall = 0.32; // 小件回弹：明显过冲 Q 弹
  static const double _stiffnessUpLarge = 300; // 大件回弹：更快收敛
  static const double _dampingUpLarge = 0.62; // 大件回弹：几乎无过冲
  static const double _boostSmall = 1.35; // 小件按压深度增益
  static const double _boostLarge = 1.0; // 大件保持原始深度，不再加深
  // 小件判定：显式深按压（≤0.92）才算小 ui；默认按压（0.97）的行内
  // 按钮/列表元素一律按大件处理
  static const double _smallPressScaleMax = 0.92;
  // 小件松手摇摆：旋转弹簧参数与交替方向的激励初速
  static const double _stiffnessSwing = 220;
  static const double _dampingSwing = 0.35;
  static const double _swingKick = 1.25;

  double _rawPressScale = 0.97;
  set pressScale(double value) {
    if (value == _rawPressScale) return;
    _rawPressScale = value;
    _applyPressScale();
  }

  set swing(bool value) {
    if (value == _swingEnabled) return;
    _swingEnabled = value;
    if (!value && attached) {
      // 关闭摇摆时立即回正，残留角不再参与绘制
      _angle = 0.0;
      _angleVel = 0.0;
      markNeedsPaint();
    }
  }

  bool _small = false;
  bool _isPressed = false;
  bool _pulseReturn = false; // 快速点按：先把下沉脉冲走完再回弹
  bool _swingEnabled = false; // 松手摇摆开关：仅显式传入 swing 的控件启用
  bool _swingFlip = false; // 摇摆方向交替，避免每次同向
  double _scale = 1.0;
  double _velocity = 0.0;
  double _target = 1.0;
  double _angle = 0.0; // 摇摆角（弧度）
  double _angleVel = 0.0;
  double _pressScale = 1.0;
  Ticker? _ticker;
  Duration? _lastElapsed;

  double get _boost => _small ? _boostSmall : _boostLarge;

  void _applyPressScale() {
    final effective = 1.0 - (1.0 - _rawPressScale) * _boost;
    if (effective == _pressScale) return;
    _pressScale = effective;
    if (_isPressed) _springTo(_pressScale);
  }

  void pressDown() {
    if (!attached) return;
    _isPressed = true;
    _pulseReturn = false;
    // 档位按显式按压深度划分：深按压（≤0.92）= 小 ui，默认按压 = 大件
    _small = _rawPressScale <= _smallPressScaleMax;
    _applyPressScale();
    _angle = 0.0;
    _angleVel = 0.0;
    _springTo(_pressScale);
  }

  void pressUp() {
    if (!attached) return;
    _isPressed = false;
    // 快速点按时下沉常未过半，直接回弹会"没感觉"——
    // 先把下沉脉冲走完再交给回弹弹簧，保证每次点击都有完整起伏
    final gap = 1.0 - _pressScale;
    final progress = gap > 0 ? (1.0 - _scale) / gap : 1.0;
    if (progress < 0.6) {
      _pulseReturn = true;
      _springTo(_pressScale);
    } else {
      _startReturn();
    }
  }

  void _startReturn() {
    _springTo(1.0);
    // 小件松手左右轻摆（播放队列切换那种晃感）；仅 swing 显式开启处
    // 生效，全局默认不摇
    if (_swingEnabled && _small) {
      _swingFlip = !_swingFlip;
      _angleVel += _swingFlip ? _swingKick : -_swingKick;
    }
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
    // 下压与回弹用不同手感参数：快沉、弹回
    final pressing = _target < 1.0;
    final stiffness = pressing
        ? _stiffnessDown
        : (_small ? _stiffnessUpSmall : _stiffnessUpLarge);
    final dampingRatio = pressing
        ? _dampingDown
        : (_small ? _dampingUpSmall : _dampingUpLarge);
    final damping = 2 * dampingRatio * math.sqrt(stiffness);
    _velocity += (stiffness * (_target - _scale) - damping * _velocity) * dt;
    _scale += _velocity * dt;
    if (_pulseReturn && _scale <= _pressScale + 0.015) {
      // 下沉脉冲到位，转入回弹
      _pulseReturn = false;
      _startReturn();
    }
    // 旋转弹簧（小件摇摆）：目标 0，衰减振荡
    if (_angle != 0.0 || _angleVel != 0.0) {
      final dSwing = 2 * _dampingSwing * math.sqrt(_stiffnessSwing);
      _angleVel += (-_stiffnessSwing * _angle - dSwing * _angleVel) * dt;
      _angle += _angleVel * dt;
      if (_angle.abs() < 0.0008 && _angleVel.abs() < 0.008) {
        _angle = 0.0;
        _angleVel = 0.0;
      }
    }
    final scaleSettled =
        (_target - _scale).abs() < 0.0005 && _velocity.abs() < 0.005;
    final swingSettled = _angle == 0.0 && _angleVel == 0.0;
    if (scaleSettled && swingSettled) {
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

  // 绕中心缩放 + 旋转（摇摆）
  Matrix4 _transform() {
    final c = size.center(Offset.zero);
    return Matrix4.translationValues(c.dx, c.dy, 0)
        .multiplied(Matrix4.diagonal3Values(_scale, _scale, 1))
        .multiplied(Matrix4.rotationZ(_angle))
        .multiplied(Matrix4.translationValues(-c.dx, -c.dy, 0));
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // 按压缩放期间命中位置按逆变换映射回子坐标系（摇摆角极小，忽略不计）
    if (_scale == 1.0 && _angle == 0.0) {
      return super.hitTest(result, position: position);
    }
    final c = size.center(Offset.zero);
    final mapped = Offset(
      c.dx + (position.dx - c.dx) / _scale,
      c.dy + (position.dy - c.dy) / _scale,
    );
    return super.hitTest(result, position: mapped);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_scale == 1.0 && _angle == 0.0) {
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
    _pulseReturn = false;
    _scale = 1.0;
    _velocity = 0.0;
    _angle = 0.0;
    _angleVel = 0.0;
    super.detach();
  }
}
