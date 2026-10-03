part of 'settings_category_page.dart';

class _AccentColorSheet extends StatefulWidget {
  const _AccentColorSheet({
    required this.current,
    this.title = '主题色',
    this.presets,
    this.autoLabel,
    this.autoColor,
  });
  final int current;
  final String title;
  final Map<int, String>? presets;

  /// 非空时在预设首位插入「自动」档（取值 0，如未播放色跟随主色）
  final String? autoLabel;

  /// 自动档色块的预览色
  final Color? autoColor;

  static Map<int, String> get _defaultPresets => <int, String>{
    0xFFEC4141: tr('经典红'),
    0xFFF9735B: tr('珊瑚'),
    0xFFF59E0B: tr('琥珀'),
    0xFF22C55E: tr('翡翠'),
    0xFF06B6D4: tr('青绿'),
    0xFF3B82F6: tr('湖蓝'),
    0xFF8B5CF6: tr('鸢尾紫'),
    0xFFEC4899: tr('蔷薇'),
  };

  static Map<int, String> get lyricPresets => <int, String>{
    0xFFFFFFFF: tr('纯白'),
    0xFFBFBFBF: tr('银灰'),
    0xFF91CDFF: tr('天蓝'),
    0xFFA6EBCB: tr('薄荷'),
    0xFFB388FF: tr('淡紫'),
    0xFFFFBCD6: tr('粉红'),
    0xFFFFE096: tr('暖黄'),
  };

  @override
  State<_AccentColorSheet> createState() => _AccentColorSheetState();
}

class _AccentColorSheetState extends State<_AccentColorSheet> {
  late HSVColor _hsv;
  final _hexCtrl = TextEditingController();
  bool _hexError = false;

  /// 自动档无真实色值，取色器以预览色作为初始 HSV
  Color get _initialColor => widget.current == 0 && widget.autoColor != null
      ? widget.autoColor!
      : Color(widget.current);

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(_initialColor);
    _syncHex();
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  void _syncHex() {
    _hexCtrl.text = _colorToHex(_color);
  }

  static String _colorToHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _update(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hexError = false;
      _syncHex();
    });
  }

  void _commitHex() {
    final text = _hexCtrl.text.trim().replaceFirst('#', '');
    if (text.length != 6 || int.tryParse(text, radix: 16) == null) {
      setState(() => _hexError = true);
      return;
    }
    final value = int.parse('FF$text', radix: 16);
    setState(() {
      _hsv = HSVColor.fromColor(Color(value));
      _hexError = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(widget.title), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.5,
              children: [
                for (final entry in [
                  if (widget.autoLabel != null) MapEntry(0, widget.autoLabel!),
                  ...(widget.presets ?? _AccentColorSheet._defaultPresets).entries,
                ])
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context, entry.key),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: widget.current == entry.key
                              ? scheme.primary
                              : scheme.outlineVariant.withValues(alpha: 0.6),
                          width: widget.current == entry.key ? 2 : 1,
                        ),
                        color: widget.current == entry.key
                            ? scheme.primary.withValues(alpha: 0.08)
                            : null,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: entry.key == 0
                                    ? (widget.autoColor ?? Colors.transparent)
                                    : Color(entry.key),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: widget.current == entry.key
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 16,
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              entry.value,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Divider(color: scheme.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    tr('自定义颜色'),
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
                Expanded(child: Divider(color: scheme.outlineVariant)),
              ],
            ),
            const SizedBox(height: 14),
            _HsvPicker(hsv: _hsv, onChanged: _update),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _hexCtrl,
                    enabled: true,
                    maxLength: 7,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      letterSpacing: 1,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      labelText: 'Hex',
                      hintText: '#EC4141',
                      errorText: _hexError ? tr('格式应为 #RRGGBB') : null,
                      border: const OutlineInputBorder(),
                    ),
                    onEditingComplete: _commitHex,
                    onSubmitted: (_) => _commitHex(),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _color.toARGB32()),
                  child:   Text(tr('应用')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HsvPicker extends StatelessWidget {
  const _HsvPicker({required this.hsv, required this.onChanged});
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  HSVColor _fromSvBox(Offset local, Size size) {
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    return HSVColor.fromAHSV(1, hsv.hue, s, v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumbColor = Colors.white;
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, 150);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => onChanged(_fromSvBox(d.localPosition, size)),
              onPanUpdate: (d) => onChanged(_fromSvBox(d.localPosition, size)),
              child: Container(
                width: size.width,
                height: size.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: CustomPaint(
                  painter: _SvBoxPainter(
                    baseColor: hsv.withSaturation(1).withValue(1).toColor(),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: (hsv.saturation * size.width).clamp(
                          0.0,
                          size.width - 22,
                        ),
                        top: ((1 - hsv.value) * size.height).clamp(
                          0.0,
                          size.height - 22,
                        ),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hsv.toColor(),
                            border: Border.all(color: thumbColor, width: 2.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => _setHue(d.localPosition.dx / width),
              onPanUpdate: (d) => _setHue(d.localPosition.dx / width),
              child: Container(
                height: 26,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    const _HueRainbow(),
                    Positioned(
                      left: (hsv.hue / 360 * width).clamp(0.0, width - 18),
                      top: -3,
                      child: Container(
                        width: 18,
                        height: 18,
                        margin: const EdgeInsets.all(4.5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hsv.withSaturation(1).withValue(1).toColor(),
                          border: Border.all(color: thumbColor, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _setHue(double ratio) {
    final h = (ratio.clamp(0.0, 1.0)) * 360;
    onChanged(HSVColor.fromAHSV(1, h, hsv.saturation, hsv.value));
  }
}

class _SvBoxPainter extends CustomPainter {
  _SvBoxPainter({required this.baseColor});
  final Color baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final horizontal = LinearGradient(
      colors: [Colors.white, baseColor],
    ).createShader(rect);
    final vertical = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.transparent, Colors.black],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = horizontal);
    canvas.drawRect(rect, Paint()..shader = vertical);
  }

  @override
  bool shouldRepaint(_SvBoxPainter old) => old.baseColor != baseColor;
}

class _HueRainbow extends StatelessWidget {
  const _HueRainbow();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

class _Choice {
  final String label;
  final String? subtitle;
  final dynamic value;
  const _Choice(this.label, this.value, {this.subtitle});
}
