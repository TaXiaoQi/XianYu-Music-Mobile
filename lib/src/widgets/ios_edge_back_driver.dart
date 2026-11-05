import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';

import '../core/application_logger.dart';
import 'predictive_back_transitions.dart';

/// iOS 左边缘滑动返回作用域：包在每条路由的转场层外侧（Cupertino
/// 同款布局——左缘窄带覆盖条位于页面内容之上，成为 hit-test 链中
/// 最内层，事件派发与竞技场 sweep 都先于页面内的滚动/横滑识别器）。
///
/// iOS 没有系统预测返回事件源（Android 由原生逐帧回传），把左边缘
/// 横向拖拽合成为 [PredictiveBackEvent] 喂给现有预测返回链路
/// （[PredictiveBackSyntheticDispatch]）：认领、转场、commit/cancel
/// 与 Android 系统预测返回及左上角返回按钮完全同一套。
///
/// 设计要点：
///  · 仅 iOS 竖屏启用（Android 由系统事件驱动，重复驱动会双份分派）；
///  · 覆盖条内竞技场必先报名（hit-test 最内层），横向意图确立时
///    accept 获胜，页面里正在竞争同一指针的滚动/横滑识别器被当场
///    reject——拖拽返回期间列表滚动等其它手势被冻结，与 iOS 原生
///    边缘返回一致；纵向滚动起步时识别器主动弃权（reject），页面
///    照常滚动（tap 同理：up 时未达横滑阈值即 reject 让贤）；
///  · 认领失败（根部页/弹窗覆盖/播放页覆盖互斥等 detector 全 decline）
///    时整段手势静默放弃。
class EdgeBackGestureScope extends StatefulWidget {
  const EdgeBackGestureScope({super.key, required this.child});

  final Widget child;

  @override
  State<EdgeBackGestureScope> createState() => _EdgeBackGestureScopeState();
}

class _EdgeBackGestureScopeState extends State<EdgeBackGestureScope> {
  bool get _platformEnabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool _active = false;

  void _handleStart(Offset position) {
    final width = MediaQuery.of(context).size.width;
    final claimed = PredictiveBackSyntheticDispatch.start(
      _synthEvent(position, clampDouble(position.dx / width, 0.0, 1.0)),
    );
    if (!claimed) return;
    _active = true;
  }

  void _handleUpdate(Offset position) {
    if (!_active) return;
    final width = MediaQuery.of(context).size.width;
    final progress = clampDouble(position.dx / width, 0.0, 1.0);
    PredictiveBackSyntheticDispatch.update(_synthEvent(position, progress));
  }

  void _handleEnd(Offset position, double velocityDx) {
    if (!_active) return;
    _active = false;
    final width = MediaQuery.of(context).size.width;
    final progress = clampDouble(position.dx / width, 0.0, 1.0);
    if (progress > _EdgeBackRecognizer.commitProgress ||
        velocityDx > _EdgeBackRecognizer.commitVelocity) {
      PredictiveBackSyntheticDispatch.commit();
    } else {
      PredictiveBackSyntheticDispatch.cancel();
    }
  }

  void _handleCancel() {
    if (!_active) return;
    _active = false;
    PredictiveBackSyntheticDispatch.cancel();
  }

  PredictiveBackEvent _synthEvent(Offset position, double progress) {
    // swipeEdge 0 = left： PredictiveBackEvent.fromMap 是 SDK 公开工厂，
    // 私有构造无法直达
    return PredictiveBackEvent.fromMap(<String, Object?>{
      'touchOffset': <Object?>[position.dx, position.dy],
      'progress': progress,
      'swipeEdge': 0,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_platformEnabled) return widget.child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        // 左缘窄带覆盖条：位于内容之上 → hit-test 最内层，事件与
        // sweep 均先于页面内识别器（Cupertino 同款布局）
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _EdgeBackRecognizer.edgeWidth,
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: <Type, GestureRecognizerFactory>{
              _EdgeBackRecognizer:
                  GestureRecognizerFactoryWithHandlers<_EdgeBackRecognizer>(
                () => _EdgeBackRecognizer(),
                (_EdgeBackRecognizer instance) {
                  instance
                    ..shouldAcceptPointer = (PointerDownEvent event) {
                      final mq = MediaQuery.of(context);
                      return mq.orientation == Orientation.portrait;
                    }
                    ..onStart = (Offset position) {
                      _handleStart(position);
                    }
                    ..onUpdate = (Offset position, double velocityDx) {
                      _handleUpdate(position);
                    }
                    ..onEnd = _handleEnd
                    ..onCancel = _handleCancel;
                },
              ),
            },
          ),
        ),
      ],
    );
  }
}

/// 左边缘返回手势识别器：横向意图确立时在竞技场中获胜，同指针上的
/// 滚动/横滑识别器被 reject 冻结；纵向滚动/tap 主动弃权让贤。
class _EdgeBackRecognizer extends OneSequenceGestureRecognizer {
  _EdgeBackRecognizer();

  /// 边缘触发区宽度（逻辑像素），对齐系统 ~20pt 略放宽
  static const double edgeWidth = 24;

  /// 懒认领所需的横向位移下限
  static const double _claimDx = 12;

  /// 认领放弃：纵向位移明显超过横向（页面纵向滚动起步）
  static const double _verticalGiveUpDy = 24;

  /// 提交返回的最小进度（页面 1:1 跟手时的位移占比，约半屏）
  static const double commitProgress = 0.4;

  /// 提交返回的最小甩动速度（逻辑像素/秒）
  static const double commitVelocity = 800;

  /// 由宿主 State 注入：平台/竖屏判定
  bool Function(PointerDownEvent event) shouldAcceptPointer = (_) => false;

  /// arena 获胜（其它识别器已被冻结）后回调
  void Function(Offset position)? onStart;

  /// 认领期间逐帧回调（绝对位置 + 横向速度 px/s）
  void Function(Offset position, double velocityDx)? onUpdate;

  /// 松手回调
  void Function(Offset position, double velocityDx)? onEnd;

  /// 系统取消/弃权回调（来电打断等）
  VoidCallback? onCancel;

  _EdgePhase _phase = _EdgePhase.idle;
  int? _pointer;
  Offset _startPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  Duration _lastTime = Duration.zero;
  double _velocityDx = 0;

  @override
  void addPointer(PointerDownEvent event) {
    if (_phase != _EdgePhase.idle) return;
    if (!shouldAcceptPointer(event)) return;
    AppLog.info('backgesture',
        'recognizer down x=${event.position.dx.toStringAsFixed(1)} y=${event.position.dy.toStringAsFixed(1)}');
    _phase = _EdgePhase.possible;
    _pointer = event.pointer;
    _startPos = _lastPos = event.position;
    _lastTime = event.timeStamp;
    _velocityDx = 0;
    startTrackingPointer(event.pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    switch (_phase) {
      case _EdgePhase.possible:
        if (event is PointerMoveEvent) {
          _trackVelocity(event);
          final dx = event.position.dx - _startPos.dx;
          final dy = event.position.dy - _startPos.dy;
          if (dx <= 4 && dy <= 4) break;
          AppLog.info('backgesture',
              'possible dx=${dx.toStringAsFixed(1)} dy=${dy.toStringAsFixed(1)}');
          if (dy > dx * 2 + 12 && dy > _verticalGiveUpDy) {
            // 纵向滚动起步：弃权，页面照常滚动
            AppLog.info('backgesture', 'give up (vertical)');
            resolve(GestureDisposition.rejected);
            _phase = _EdgePhase.idle;
            _pointer = null;
            stopTrackingPointer(event.pointer);
          } else if (dx > _claimDx && dy < dx * 2) {
            // 横向意图确立（允许约 63° 内的斜滑——拇指为轴心画弧，
            // 越偏离拇指高度手势越斜）：竞技场获胜，其它识别器被冻结
            AppLog.info('backgesture', 'resolving accept');
            resolve(GestureDisposition.accepted);
          }
        } else if (event is PointerUpEvent ||
            event is PointerCancelEvent) {
          // tap/无位移松手：弃权让贤（tap recognizer 在 sweep 前接管）
          resolve(GestureDisposition.rejected);
          _phase = _EdgePhase.idle;
          _pointer = null;
          stopTrackingPointer(event.pointer);
        }
      case _EdgePhase.claimed:
        if (event is PointerMoveEvent) {
          _trackVelocity(event);
          onUpdate?.call(event.position, _velocityDx);
        } else if (event is PointerUpEvent) {
          onUpdate?.call(event.position, _velocityDx);
          onEnd?.call(event.position, _velocityDx);
          _phase = _EdgePhase.idle;
          _pointer = null;
          stopTrackingPointer(event.pointer);
        } else if (event is PointerCancelEvent) {
          onCancel?.call();
          _phase = _EdgePhase.idle;
          _pointer = null;
          stopTrackingPointer(event.pointer);
        }
      case _EdgePhase.idle:
        break;
    }
  }

  void _trackVelocity(PointerMoveEvent event) {
    final dtUs = (event.timeStamp - _lastTime).inMicroseconds;
    if (dtUs > 0) {
      final instant = (event.position.dx - _lastPos.dx) /
          (dtUs / Duration.microsecondsPerSecond);
      _velocityDx = _velocityDx * 0.6 + instant * 0.4;
    }
    _lastPos = event.position;
    _lastTime = event.timeStamp;
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer != _pointer || _phase != _EdgePhase.possible) return;
    _phase = _EdgePhase.claimed;
    AppLog.info('backgesture', 'recognizer claimed');
    onStart?.call(_lastPos);
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer != _pointer) return;
    if (_phase == _EdgePhase.claimed) {
      // 竞技场意外改判（理论上不会发生）：按取消收尾
      onCancel?.call();
    }
    _phase = _EdgePhase.idle;
    _pointer = null;
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'edge back';
}

/// 手势阶段
enum _EdgePhase { idle, possible, claimed }
