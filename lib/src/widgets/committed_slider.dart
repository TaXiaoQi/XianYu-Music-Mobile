import 'package:flutter/material.dart';

/// 提交式滑杆：拖动期间只本地跟手（[State] 内 `setState`），松手才通过
/// [onCommit] 提交一次。
///
/// 用途：滑块一旦直连 Provider / DSP / 数据层，若每 tick 都写回状态，会
/// 触发整页 rebuild，造成「纯滑动页面都卡」的问题。本组件把「跟手」与
/// 「提交」解耦——拖动过程零外部写入，仅重建自身；滚动（不交互）时页面
/// 完全不会被无关滑块拖动波及。需要实时预览时可给 [onChangeLive]。
class CommittedSlider extends StatefulWidget {
  const CommittedSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onCommit,
    this.onChangeLive,
    this.divisions,
    this.enabled = true,
    this.semanticFormatterCallback,
  });

  final double value;
  final double min;
  final double max;

  /// 松手时提交最终值；为 null 或 [enabled] 为 false 时滑杆禁用。
  final ValueChanged<double>? onCommit;

  /// 可选：拖动中每 tick 的实时回调（仅作辅助预览）；不传则拖动全程零
  /// 外部状态写入。
  final ValueChanged<double>? onChangeLive;

  final int? divisions;
  final bool enabled;
  final SemanticFormatterCallback? semanticFormatterCallback;

  @override
  State<CommittedSlider> createState() => _CommittedSliderState();
}

class _CommittedSliderState extends State<CommittedSlider> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onCommit != null;
    if (!active) {
      return Slider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        onChanged: null,
        semanticFormatterCallback: widget.semanticFormatterCallback,
      );
    }
    final v = (_draft ?? widget.value).clamp(widget.min, widget.max);
    return Slider(
      value: v,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      semanticFormatterCallback: widget.semanticFormatterCallback,
      onChanged: (x) {
        widget.onChangeLive?.call(x);
        setState(() => _draft = x);
      },
      onChangeEnd: (x) {
        widget.onCommit!(x);
        setState(() => _draft = null);
      },
    );
  }
}