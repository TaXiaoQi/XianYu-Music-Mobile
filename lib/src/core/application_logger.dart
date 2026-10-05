import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../i18n/i18n.dart';

enum LogLevel {
  debug('debug'),
  info('info'),
  warn('warn'),
  error('error'),
  // 未捕获异常/平台异常专用：与普通错误分流，导出头单独统计
  fatal('fatal');

  const LogLevel(this.value);
  final String value;
}

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

const int kMaxAppLogEntries = 3000;

class ApplicationLogManager extends StateNotifier<List<AppLogEntry>> {
  ApplicationLogManager._() : super(const []);

  static final ApplicationLogManager instance = ApplicationLogManager._();

  Timer? _persistDebounce;
  int _seq = 0;

  void bootstrap() {
    unawaited(_restore());
  }

  bool get hasErrorLogs =>
      state.any((e) => e.level.index >= LogLevel.error.index);

  void log(LogLevel level, String category, String message) {
    _seq++;
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = AppLogEntry(
      id: '${now}_$_seq',
      timestamp: now,
      level: level,
      category: category,
      message: message,
    );
    // 构建期（persistentCallbacks 含 build/layout/paint）同步写 state 会
    // 触发 Riverpod「widget tree 构建中修改 provider」断言红屏——三键导航
    // 的预测返回链路在构建/导航同步段经 didPush/didPop 等打点即命中。
    // 推迟到帧末补记：条目时序不变，仅落盘与通知延后半帧。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      debugPrint('[AppLog:${level.value}] [$category] $message (deferred)');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        state = _appendAndTrim(state, entry);
        _schedulePersist();
      });
      return;
    }
    state = _appendAndTrim(state, entry);
    debugPrint('[AppLog:${level.value}] [$category] $message');
    _schedulePersist();
  }

  void debug(String category, String m) => log(LogLevel.debug, category, m);
  void info(String category, String m) => log(LogLevel.info, category, m);
  void warn(String category, String m) => log(LogLevel.warn, category, m);
  void error(String category, String m) => log(LogLevel.error, category, m);
  void fatal(String category, String m) => log(LogLevel.fatal, category, m);

  static List<AppLogEntry> _appendAndTrim(
    List<AppLogEntry> current,
    AppLogEntry entry,
  ) {
    final result = <AppLogEntry>[...current, entry];
    if (result.length <= kMaxAppLogEntries) return result;
    return result.sublist(result.length - kMaxAppLogEntries);
  }

  static List<AppLogEntry> _retain(List<AppLogEntry> source) {
    if (source.length <= kMaxAppLogEntries) return List.of(source);
    return source.sublist(source.length - kMaxAppLogEntries);
  }

  void clear() {
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
      state = _retain([...entries, ...state]);
      _schedulePersist();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final file = await _storageFile;
      await file.writeAsString(
        jsonEncode(state.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (_) {}
  }

  String formatExport({required bool onlyErrors}) {
    final selected = onlyErrors
        ? state
            .where((e) => e.level.index >= LogLevel.error.index)
            .toList()
        : state;
    final counts = <LogLevel, int>{for (final l in LogLevel.values) l: 0};
    for (final e in state) {
      counts[e.level] = (counts[e.level] ?? 0) + 1;
    }
    final fatalCount = counts[LogLevel.fatal]!;
    final errorCount = counts[LogLevel.error]!;
    final headline = fatalCount > 0
        ? '检测到 $fatalCount 条致命崩溃'
            '${errorCount > 0 ? '、$errorCount 条错误日志' : ''}'
        : errorCount > 0
        ? '检测到 $errorCount 条错误日志'
        : counts[LogLevel.warn]! > 0
        ? '检测到 ${counts[LogLevel.warn]} 条警告日志'
        : tr('未发现明显异常');
    final buffer = StringBuffer()
      ..writeln(tr('弦予音乐调试日志'))
      ..writeln('导出范围：${onlyErrors ? '错误日志' : '全部日志'}')
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('日志数量：${selected.length}')
      ..writeln('自动分析：$headline')
      ..writeln(
        '日志级别：debug=${counts[LogLevel.debug]} info=${counts[LogLevel.info]} '
        'warn=${counts[LogLevel.warn]} error=$errorCount fatal=$fatalCount',
      )
      ..writeln('');
    for (final e in selected) {
      buffer.writeln(
        // 本地时间（与导出时间一致）；带 isUtc 会输出 UTC 并带 Z 后缀，
        // 看起来像晚 8 小时，排查问题时易误判时段
        '[${DateTime.fromMillisecondsSinceEpoch(e.timestamp).toIso8601String()}] '
        '[${e.level.value.toUpperCase()}] [${e.category}] ${e.message}',
      );
    }
    return buffer.toString().trimRight();
  }
}

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
  static void fatal(String category, String m) =>
      ApplicationLogManager.instance.fatal(category, m);
}

final applicationLogsProvider =
    StateNotifierProvider<ApplicationLogManager, List<AppLogEntry>>(
      (ref) => ApplicationLogManager.instance,
    );

class AppLogRouteObserver extends NavigatorObserver {
  String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route.runtimeType.toString();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.debug('route', 'push ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.debug('route', 'pop ${_name(route)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.debug('route', 'remove ${_name(route)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLog.debug('route', 'replace ${_name(oldRoute)} -> ${_name(newRoute)}');
  }
}

class AppLogLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.debug('lifecycle', '应用状态 -> ${state.name}');
  }
}

class AppLogBackGestureObserver with WidgetsBindingObserver {
  static bool _pulledNativeStatus = false;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 手势开始的详情由 detector 的 claim 日志覆盖（非认领路径 decline 也有
    // 记录），这里不再重复打点；保留首次拉取原生状态的诊断动作
    if (!_pulledNativeStatus) {
      _pulledNativeStatus = true;
      BackGestureNativeBridge.pull();
    }
    return false;
  }
}

class BackGestureNativeBridge {
  BackGestureNativeBridge._();

  static const MethodChannel _channel = MethodChannel('xianyu/backgesture');

  static void init() {
    // 原生逐帧 event 不再逐条入日志（健康 ROM 上每手势会刷几十条，纯垃圾）；
    // 合成进度的关键节点由 detector 的 claim/synth engage/commit 日志覆盖。
    // pull 保留：一次性确认原生观察者注册状态
    pull();
  }

  static void pull() {
    _channel
        .invokeMethod<String>('pull')
        .then((status) {
          if (status != null) AppLog.debug('backgesture', status);
        })
        .catchError((Object e) {
          AppLog.debug('backgesture', 'pull failed: $e');
        });
  }
}
