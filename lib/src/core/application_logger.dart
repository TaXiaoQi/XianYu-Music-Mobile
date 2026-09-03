import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../i18n/i18n.dart';

/// 日志级别（与桌面端 applicationLogger 对齐）。
enum LogLevel {
  debug('debug'),
  info('info'),
  warn('warn'),
  error('error');

  const LogLevel(this.value);
  final String value;
}

/// 一条应用日志（与桌面端 ApplicationLogEntry 对齐）。
class AppLogEntry {
  final String id;
  final int timestamp;
  final LogLevel level;
  final String category;
  final String message;

  const AppLogEntry({
    required this.id,
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp,
        'level': level.value,
        'category': category,
        'message': message,
      };

  static AppLogEntry? fromJson(Map<String, dynamic> json) {
    final level = LogLevel.values
        .where((l) => l.value == json['level'])
        .cast<LogLevel?>()
        .firstWhere((l) => l != null, orElse: () => null);
    if (json['id'] is! String ||
        json['timestamp'] is! num ||
        level == null ||
        json['category'] is! String ||
        json['message'] is! String) {
      return null;
    }
    return AppLogEntry(
      id: json['id'] as String,
      timestamp: (json['timestamp'] as num).toInt(),
      level: level,
      category: json['category'] as String,
      message: json['message'] as String,
    );
  }
}

/// 通用应用日志最大保留量：全部日志最近 200 条，错误日志最近 10 条。
const int kMaxAppLogEntries = 200;
const int kMaxAppErrorEntries = 10;

/// 通用应用日志管理（对齐桌面端 applicationLogger.ts）。
///
/// 与专用于「问题诊断」的 [AppLogger] 不同，本日志系统：
/// - 分级别（debug/info/warn/error）与分类（category）记录；
/// - 常驻内存 + 持久化到本地文件，重启仍可追溯；
/// - 按量保留（200 全部 / 10 错误），可导出「全部日志」或「错误日志」，
///   供意见反馈页勾选随反馈一并上传。
class ApplicationLogManager extends StateNotifier<List<AppLogEntry>> {
  ApplicationLogManager._() : super(const []);

  static final ApplicationLogManager instance = ApplicationLogManager._();

  Timer? _persistDebounce;
  int _seq = 0;

  /// 待批量 flush 的新日志条目。
  final List<AppLogEntry> _pending = [];
  bool _flushScheduled = false;

  /// 记录前加载历史（异步），避免阻塞首帧。
  void bootstrap() {
    unawaited(_restore());
  }

  bool get hasErrorLogs => state.any((e) => e.level == LogLevel.error);

  void log(LogLevel level, String category, String message) {
    _seq++;
    _pending.add(AppLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_$_seq',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      level: level,
      category: category,
      message: message,
    ));
    // 双写控制台：调试时 logcat/IDE 控制台同样可见（release 下 debugPrint
    // 为空操作，日志系统照常工作）。引擎侧 JS 日志也经此统一出口。
    debugPrint('[AppLog:${level.value}] [$category] $message');
    _flushLater();
  }

  /// 把待写日志合并成一次 state 更新。
  ///
  /// 注意：绝不能同步发生在 build/draw 阶段。异常上报链路（FlutterError.onError
  /// → AppLog.error → log → 换 state）正是由 build 期抛错触发；若在此同步通知
  /// StateNotifier 的监听者，监听者 widget 会在 buildScope 期间重建并再次抛
  /// "setState() called during build"，经 onError 再一次 log，形成无限递归，
  /// 每帧都无法结束 → 程序在跑（解码线程正常）但触控/画面被冻死。
  /// 这里把换 state 延后到当前事件栈跑完（microtask）再统一 flush，中断该循环。
  void _flushLater() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_flush);
  }

  void _flush() {
    _flushScheduled = false;
    // 注意：不能因 `!mounted` 就丢弃本次 flush——本单例在启动期（尚无任何
    // UI 订阅 applicationLogsProvider 时）就记日志，此时 mounted=false，
    // 若在此 return，启动/运行期日志会一直卡在 [_pending]，既不上屏也不落盘，
    // 用户打开日志页看到的就是「没有日志」。真正的防递归靠 microtask 延后
    // 换 state + onError 的 reportingError 抑制，与是否有监听者无关。
    if (_pending.isEmpty) return;
    final entries = _pending;
    _pending.clear();
    state = _retain([...state, ...entries]);
    _schedulePersist();
  }

  void debug(String category, String m) => log(LogLevel.debug, category, m);
  void info(String category, String m) => log(LogLevel.info, category, m);
  void warn(String category, String m) => log(LogLevel.warn, category, m);
  void error(String category, String m) => log(LogLevel.error, category, m);

  /// 按量保留：全部最近 200 条；错误日志额外只留最近 10 条。
  static List<AppLogEntry> _retain(List<AppLogEntry> source) {
    var result = source.length > kMaxAppLogEntries
        ? source.sublist(source.length - kMaxAppLogEntries)
        : List.of(source);
    final errorEntries = result.where((e) => e.level == LogLevel.error).toList();
    if (errorEntries.length > kMaxAppErrorEntries) {
      final dropIds = errorEntries
          .sublist(0, errorEntries.length - kMaxAppErrorEntries)
          .map((e) => e.id)
          .toSet();
      result = result.where((e) => !dropIds.contains(e.id)).toList();
    }
    return result;
  }

  void clear() {
    _pending.clear();
    _flushScheduled = false;
    state = const [];
    _schedulePersist();
  }

  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 800), _persist);
  }

  Future<File> get _storageFile async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File(p.join(dir.path, 'xianyu_application_logs.json'));
    } catch (_) {
      final dir = await getApplicationDocumentsDirectory();
      return File(p.join(dir.path, 'xianyu_application_logs.json'));
    }
  }

  Future<void> _restore() async {
    try {
      final file = await _storageFile;
      if (!await file.exists()) return;
      final text = await file.readAsString();
      final parsed = jsonDecode(text) as List? ?? const [];
      final entries = parsed
          .whereType<Map<String, dynamic>>()
          .map(AppLogEntry.fromJson)
          .whereType<AppLogEntry>()
          .toList();
      if (entries.isEmpty) return;
      // 同样不因 `!mounted` 跳过恢复：启动期 bootstrap 时通常尚无 UI 订阅，
      // 否则上次会话的日志永远加载不回来（恢复只填充 state，无副作用）。
      state = _retain(entries);
    } catch (_) {
      // 恢复失败静默：日志只是辅助信息，不影响应用运行。
    }
  }

  Future<void> _persist() async {
    try {
      final file = await _storageFile;
      await file.writeAsString(
        jsonEncode(state.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (_) {
      // 写盘失败静默，日志不应影响主流程。
    }
  }

  /// 导出日志文本（对齐桌面端 formatApplicationLogExport）。
  String formatExport({required bool onlyErrors}) {
    final selected = onlyErrors
        ? state.where((e) => e.level == LogLevel.error).toList()
        : state;
    final counts = <LogLevel, int>{for (final l in LogLevel.values) l: 0};
    for (final e in state) {
      counts[e.level] = (counts[e.level] ?? 0) + 1;
    }
    final headline = counts[LogLevel.error]! > 0
        ? '检测到 ${counts[LogLevel.error]} 条错误日志'
        : counts[LogLevel.warn]! > 0
            ? '检测到 ${counts[LogLevel.warn]} 条警告日志'
            : tr('未发现明显异常');
    final buffer = StringBuffer()
      ..writeln(tr('弦予音乐调试日志'))
      ..writeln('导出范围：${onlyErrors ? '错误日志' : '全部日志'}')
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('日志数量：${selected.length}')
      ..writeln('自动分析：$headline')
      ..writeln('日志级别：debug=${counts[LogLevel.debug]} info=${counts[LogLevel.info]} '
          'warn=${counts[LogLevel.warn]} error=${counts[LogLevel.error]}')
      ..writeln('');
    for (final e in selected) {
      buffer.writeln(
          '[${DateTime.fromMillisecondsSinceEpoch(e.timestamp, isUtc: true).toIso8601String()}] '
          '[${e.level.value.toUpperCase()}] [${e.category}] ${e.message}');
    }
    return buffer.toString().trimRight();
  }
}

/// 便捷门面：无需 Riverpod 即可在任何地方记录日志。
class AppLog {
  static ApplicationLogManager get manager => ApplicationLogManager.instance;

  static void debug(String category, String m) =>
      ApplicationLogManager.instance.debug(category, m);
  static void info(String category, String m) =>
      ApplicationLogManager.instance.info(category, m);
  static void warn(String category, String m) =>
      ApplicationLogManager.instance.warn(category, m);
  static void error(String category, String m) =>
      ApplicationLogManager.instance.error(category, m);
}

/// 全局应用日志入口（UI 依赖注入用，驱动反馈页可用日志数量刷新）。
final applicationLogsProvider =
    StateNotifierProvider<ApplicationLogManager, List<AppLogEntry>>(
        (ref) => ApplicationLogManager.instance);

/// 路由观察者：把 push/pop 等导航事件记入通用应用日志。
/// 与 AppLogger 的诊断观察者并存，本观察者专供日志系统（不受「问题诊断」开关影响）。
class AppLogRouteObserver extends NavigatorObserver {
  String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route.runtimeType.toString();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.info('route', 'push ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.info('route', 'pop ${_name(route)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.info('route', 'remove ${_name(route)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLog.info(
        'route', 'replace ${_name(oldRoute)} -> ${_name(newRoute)}');
  }
}

/// 生命周期观察者：应用前后台切换记入通用应用日志。
class AppLogLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.info('lifecycle', '应用状态 -> ${state.name}');
  }
}