import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/effects/sound_effect_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/i18n/i18n.dart';

part 'effects_page.eq.dart';
part 'effects_page.sections.dart';
part 'effects_page.advanced.dart';
part 'effects_page.sliders.dart';

class EffectsPage extends ConsumerWidget {
  const EffectsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(soundEffectProvider).settings;
    final notifier = ref.read(soundEffectProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final locked = ref.watch(playerProvider.select((s) => s.usbExclusive));
    final dspActive =
        ref.watch(playerProvider.select((s) => s.dspActive));
    final hasCurrent =
        ref.watch(playerProvider.select((s) => s.current != null));

    final mq = MediaQuery.of(context);
    final isLandscape = mq.size.width >= mq.size.height * 1.05;
    final cutLeft = isLandscape ? mq.padding.left : 0.0;
    final cutRight = isLandscape ? mq.padding.right : 0.0;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: RepaintBoundary(child: Stack(
        children: [
          IgnorePointer(
            ignoring: locked,
            child: Opacity(
              opacity: locked ? 0.5 : 1.0,
              child: ListView(
                padding: EdgeInsets.only(
                    top: GlassTopBar.height(context),
                    left: 16 + cutLeft,
                    right: 16 + cutRight,
                    bottom: 150),
                children: [
                  if (locked)
                    Container(
                      width: double.infinity,
                      margin:
                          const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_outline,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr('Bit-perfect / DSD 直出中，音效已锁定'),
                              style: TextStyle(
                                  fontSize: 13, color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!locked && dspActive)
                    Container(
                      width: double.infinity,
                      margin:
                          const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.graphic_eq,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr('音效引擎处理中（Rust DSP 管线）'),
                              style: TextStyle(
                                  fontSize: 13, color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!locked && !dspActive && hasCurrent)
                    Container(
                      width: double.infinity,
                      margin:
                          const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: scheme.outline.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: scheme.outline.withValues(alpha: 0.30)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: scheme.outline),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr('当前播放未经过音效引擎，音效不生效'),
                              style: TextStyle(
                                  fontSize: 13, color: scheme.outline),
                            ),
                          ),
                        ],
                      ),
                    ),
                  _sectionHeader(context, tr('均衡器')),
                  _EqSection(settings: settings, notifier: notifier),
                  _sectionHeader(context, tr('变速变调')),
                  _PitchRateSection(settings: settings, notifier: notifier),
                  _sectionHeader(context, tr('混响')),
                  _ReverbSection(settings: settings, notifier: notifier),
                  _sectionHeader(context, tr('空间音效')),
                  _SpatialSection(settings: settings, notifier: notifier),
                  _sectionHeader(context, tr('高级音效')),
                  _AdvancedSection(settings: settings, notifier: notifier),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      tr('音效由 Rust DSP 引擎实时处理；变速变调即时生效，其余效果在播放时同步到引擎。'),
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title:   Text(tr('音效')),
              leading: cutLeft > 0 ? SizedBox(width: cutLeft) : null,
              titleSpacing: 16,
              actions: [
                TextButton.icon(
                  onPressed: locked ? null : () => notifier.resetAll(),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label:   Text(tr('重置')),
                ),
                if (cutRight > 0) SizedBox(width: cutRight),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
