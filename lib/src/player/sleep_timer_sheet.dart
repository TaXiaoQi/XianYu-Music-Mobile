import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import '../widgets/press_scale.dart';
import '../widgets/sheet_dialog.dart';
import 'sleep_timer.dart';

/// 常用时长的快捷档（分钟）。用户也可在下方自定义任意时长。
const kSleepTimerMinutes = <int>[15, 30, 60, 90];

/// 自定义时长的取值范围（分钟）：至少 1 分钟，最多 24 小时，避免误输入天文数字。
const kSleepTimerMinMinutes = 1;
const kSleepTimerMaxMinutes = 1440;

/// 睡眠定时弹窗（showSheetDialog 统一样式，与音质选择等一致）：选快捷档
/// 或自定义时长即启动；已启动时显示剩余时间与取消。
Future<void> showSleepTimerSheet(BuildContext context) {
  return showSheetDialog<void>(
    context,
    (dialogContext) => const _SleepTimerSheet(),
  );
}

class _SleepTimerSheet extends ConsumerStatefulWidget {
  const _SleepTimerSheet();

  @override
  ConsumerState<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends ConsumerState<_SleepTimerSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 输入是否可提交：非空、能解析为整数、且在允许范围内。
  int? get _customMinutes {
    final v = int.tryParse(_controller.text.trim());
    if (v == null) return null;
    if (v < kSleepTimerMinMinutes || v > kSleepTimerMaxMinutes) return null;
    return v;
  }

  void _start(int minutes) {
    ref.read(sleepTimerProvider.notifier).start(Duration(minutes: minutes));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sleepTimerProvider);
    final scheme = Theme.of(context).colorScheme;
    final custom = _customMinutes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('睡眠定时'),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                state.active
                    ? tr('将在 {n} 分钟后暂停播放',
                        {'n': (state.remainingSeconds / 60).ceil()})
                    : tr('到点后淡出并暂停播放'),
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        // 快捷时长芯片行：样式对齐播放页弹层的 segment 行（图二参考）
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('快捷时长'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < kSleepTimerMinutes.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _SleepDurationChip(
                        label: tr('{n} 分钟', {'n': kSleepTimerMinutes[i]}),
                        onTap: () => _start(kSleepTimerMinutes[i]),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('自定义时长（分钟）'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) {
                        final m = _customMinutes;
                        if (m != null) _start(m);
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        hintText:
                            '$kSleepTimerMinMinutes - $kSleepTimerMaxMinutes',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: scheme.onSurface.withValues(alpha: 0.12),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              BorderSide(color: scheme.primary, width: 1.2),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    // 输入非法时禁用，避免提交出 0 分钟或负数这类无效定时。
                    onPressed: custom == null ? null : () => _start(custom),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    child: Text(tr('确定')),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (state.active)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  ref.read(sleepTimerProvider.notifier).cancel();
                  Navigator.pop(context);
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.error,
                ),
                icon: const Icon(Icons.timer_off_outlined, size: 16),
                label: Text(tr('取消睡眠定时')),
              ),
            ),
          ),
      ],
    );
  }
}

/// 快捷时长芯片：34 高、圆角 10，与播放页弹层的 _SheetSegmentButton 同款。
class _SleepDurationChip extends StatelessWidget {
  const _SleepDurationChip({required this.label, required this.onTap});

  final String label;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(10),
      child: PressableScale(child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: 34,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      )),
    );
  }
}
