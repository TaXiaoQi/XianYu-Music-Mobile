import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/shell.dart';

final orientationContentFade = ValueNotifier<double>(1.0);

class OrientationTransitionOverlay extends ConsumerStatefulWidget {
  const OrientationTransitionOverlay({super.key});

  @override
  ConsumerState<OrientationTransitionOverlay> createState() =>
      _OrientationTransitionOverlayState();
}

class _OrientationTransitionOverlayState
    extends ConsumerState<OrientationTransitionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _opacity;

  int _gen = 0;

  bool _listening = false;

  ProviderSubscription<bool>? _sub;

  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);
  static const _outDuration = Duration(milliseconds: 110);
  static const _inDuration = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: _outDuration);
    _opacity = CurvedAnimation(parent: _c, curve: _ease);
    _opacity.addListener(_syncFade);
  }

  void _syncFade() {
    orientationContentFade.value = 1.0 - _opacity.value;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listening) return;
    _listening = true;
    _sub = ref.listenManual(isLandscapeProvider, (prev, next) {
      if (prev == null || prev == next) return;
      _run();
    });
  }

  Future<void> _run() async {
    final gen = ++_gen;
    try {
      await _c.forward().orCancel;
    } catch (_) {
      return;
    }
    if (!mounted || gen != _gen) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || gen != _gen) return;
    _c.duration = _inDuration;
    final inGen = gen;
    try {
      await _c.reverse().orCancel;
    } catch (_) {
      return;
    }
    if (!mounted || inGen != _gen) return;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  void dispose() {
    _opacity.removeListener(_syncFade);
    orientationContentFade.value = 1.0;
    _sub?.close();
    _c.dispose();
    super.dispose();
  }
}
