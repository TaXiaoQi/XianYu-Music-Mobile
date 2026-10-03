part of 'effects_page.dart';

class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.display,
    this.displayBuilder,
  });

  final String label;
  final double value;
  final double min;
  final double max;

  final String? display;

  final String Function(double)? displayBuilder;
  final ValueChanged<double> onChanged;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final v = (_draft ?? widget.value).clamp(widget.min, widget.max);
    final text = widget.displayBuilder?.call(v) ??
        widget.display ??
        v.round().toString();
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(widget.label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: widget.min,
            max: widget.max,
            onChanged: (x) => setState(() => _draft = x),
            onChangeEnd: (x) {
              widget.onChanged(x);
              setState(() => _draft = null);
            },
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _EqBand extends StatefulWidget {
  const _EqBand({
    required this.value,
    required this.freqLabel,
    required this.onCommit,
  });

  final double value;
  final String freqLabel;
  final ValueChanged<double> onCommit;

  @override
  State<_EqBand> createState() => _EqBandState();
}

class _EqBandState extends State<_EqBand> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = (_draft ?? widget.value).clamp(-12.0, 12.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        children: [
          Text(
            '${v >= 0 ? '+' : ''}${v.round()}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: v,
                min: -12,
                max: 12,
                onChanged: (x) => setState(() => _draft = x),
                onChangeEnd: (x) {
                  widget.onCommit(x);
                  setState(() => _draft = null);
                },
              ),
            ),
          ),
          Text(widget.freqLabel,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
