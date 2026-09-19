import 'package:flutter/material.dart';

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

  final ValueChanged<double>? onCommit;

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