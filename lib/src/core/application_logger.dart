import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  error('error');

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

const int kMaxAppLogEntries = 200;
const int kMaxAppErrorEntries = 10;

class ApplicationLogManager extends StateNotifier<List<AppLogEntry>> {
  ApplicationLogManager._() : super(const []);

  static final ApplicationLogManager instance = ApplicationLogManager._();

  Timer? _persistDebounce;
  int _seq = 0;

  final List<AppLogEntry> _pending = [];
  bool _flushScheduled = false;

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
    debugPrint('[AppLog:${level.value}] [$category] $message');
    _flushLater();
  }

  void _flushLater() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_flush);
  }

  void _flush() {
    _flushScheduled = false;
    if (_pending.isEmpty) return;
    final entries = List<AppLogEntry>.of(_pending);
    _pending.clear();
    state = _retain([...state, ...entries]);
    _schedulePersist();
  }

  void debug(String category, String m) => log(LogLevel.debug, category, m);
  void info(String category, String m) => log(LogLevel.info, category, m);
  void warn(String category, String m) => log(LogLevel.warn, category, m);
  void error(String category, String m) => log(LogLevel.error, category, m);

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
      state = _retain(entries);
    } catch (_) {
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
    }
  }

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

final applicationLogsProvider =
    StateNotifierProvider<ApplicationLogManager, List<AppLogEntry>>(
        (ref) => ApplicationLogManager.instance);

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

class AppLogLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.info('lifecycle', '应用状态 -> ${state.name}');
  }
}

class AppLogBackGestureObserver with WidgetsBindingObserver {
  static bool _pulledNativeStatus = false;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    AppLog.debug('backgesture',
        'start ${backEvent.isButtonEvent ? 'button' : 'gesture'} '
        'progress=${backEvent.progress.toStringAsFixed(3)}');
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
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        AppLog.debug('backgesture', 'native ${call.arguments}');
      }
    });
    pull();
  }

  static void pull() {
    _channel.invokeMethod<String>('pull').then((status) {
      if (status != null) AppLog.debug('backgesture', status);
    }).catchError((Object e) {
      AppLog.debug('backgesture', 'pull failed: $e');
    });
  }
}