import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 睡眠定时到点后要执行的动作。
///
/// 首版只做 [pause]（方案里已确认先做一种）；桌面端是 `SleepAction` 枚举多值，
/// 移动端按需再加，避免现在就引入用不到的分支。
enum SleepAction { pause }

/// 睡眠定时状态（供界面显示，以及界面重建后恢复）。
class SleepTimerState {
  const SleepTimerState({this.deadline, this.action = SleepAction.pause});

  /// 到点时刻。为 null 表示未设置定时。
  final DateTime? deadline;

  final SleepAction action;

  bool get active => deadline != null;

  /// 剩余秒数，**向上取整**。
  ///
  /// 沿用桌面端处理：不显示「0 秒」却还没到点。
  int get remainingSeconds {
    final d = deadline;
    if (d == null) return 0;
    final ms = d.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  SleepTimerState copyWith({DateTime? deadline, SleepAction? action}) =>
      SleepTimerState(deadline: deadline, action: action ?? this.action);
}

/// 睡眠定时器：只负责「什么时候到点」，不负责「到点做什么」。
///
/// 到点动作由播放侧通过 [onFire] 注入 —— 播放控制在 Dart 侧（just_audio），
/// 且淡出必须走 `_effectiveVolume()` 的因子而不能写裸音量，这些都不属于本类。
///
/// 设计要点（与桌面端对齐）：
/// - 存**绝对 deadline**，不做逐秒递减，避免累积漂移
/// - **generation 代次保护**：每次重设/取消都自增；到点先核对代次，不一致即放弃，
///   防止被重设或取消过的旧任务误触发
class SleepTimerNotifier extends Notifier<SleepTimerState> {
  Timer? _ticker;
  int _generation = 0;

  /// 到点时要执行的动作，由播放侧注入。
  Future<void> Function(SleepAction action)? onFire;

  @override
  SleepTimerState build() {
    ref.onDispose(_cancelTicker);
    return const SleepTimerState();
  }

  /// 设置（或替换）定时器；重复调用会重置倒计时并使旧任务失效。
  void start(Duration duration, {SleepAction action = SleepAction.pause}) {
    _generation++;
    _cancelTicker();
    state = SleepTimerState(
      deadline: DateTime.now().add(duration),
      action: action,
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// 取消定时器。
  void cancel() {
    _generation++;
    _cancelTicker();
    state = const SleepTimerState();
  }

  void _tick() {
    final deadline = state.deadline;
    if (deadline == null) {
      _cancelTicker();
      return;
    }
    if (!DateTime.now().isBefore(deadline)) {
      _fire();
      return;
    }
    // 只是让界面重算剩余秒数；状态里存的仍是绝对 deadline。
    state = state.copyWith(deadline: deadline);
  }

  Future<void> _fire() async {
    final expected = _generation;
    final action = state.action;
    _cancelTicker();
    // 先核对代次：期间被重设或取消过就放弃本次触发。
    if (expected != _generation) return;
    state = const SleepTimerState();
    await onFire?.call(action);
  }

  void _cancelTicker() {
    _ticker?.cancel();
    _ticker = null;
  }
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerNotifier, SleepTimerState>(
  SleepTimerNotifier.new,
);
