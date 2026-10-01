import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import 'sleep_timer.dart';

/// 常用时长的快捷档（分钟）。用户也可在下方自定义任意时长。
const kSleepTimerMinutes = <int>[15, 30, 60, 90];

/// 自定义时长的取值范围（分钟）：至少 1 分钟，最多 24 小时，避免误输入天文数字。
const kSleepTimerMinMinutes = 1;
const kSleepTimerMaxMinutes = 1440;

/// 弹出睡眠定时面板：选快捷档或自定义时长即启动；已启动时显示剩余时间与取消。
Future<void> showSleepTimerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _SleepTimerSheet(),
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

    return SafeArea(
      // 键盘弹出时把面板顶上去，否则输入框会被遮住。
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 8 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('睡眠定时'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              state.active
                  ? tr('将在 {n} 分钟后暂停播放',
                      {'n': (state.remainingSeconds / 60).ceil()})
                  : tr('到点后淡出并暂停播放'),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final m in kSleepTimerMinutes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('{n} 分钟', {'n': m})),
                onTap: () => _start(m),
              ),
            const Divider(height: 20),
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
                      labelText: tr('自定义时长（分钟）'),
                      hintText: '$kSleepTimerMinMinutes - $kSleepTimerMaxMinutes',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  // 输入非法时禁用，避免提交出 0 分钟或负数这类无效定时。
                  onPressed: custom == null ? null : () => _start(custom),
                  child: Text(tr('确定')),
                ),
              ],
            ),
            if (state.active) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  ref.read(sleepTimerProvider.notifier).cancel();
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.timer_off_outlined, size: 18),
                label: Text(tr('取消睡眠定时')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
