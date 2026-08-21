import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 设置页「问题诊断」开关的状态（驱动 UI 刷新，与 [AppLogger] 同步）。
final diagRecordingProvider = StateProvider<bool>((ref) => false);

/// 轻量诊断日志。
///
/// 专为排查「按返回直接回桌面」这类难复现的问题设计：
/// - 内存环形缓冲（上限 [maxEntries] 条），不落盘、零开销（未记录时 log 直接返回）
/// - [start] 开始记录，[stopAndSave] 停止并落盘为 txt
/// - 记录期间监听应用生命周期（回桌面瞬间的事件序列是关键证据）
///
/// 打点位置：路由 push/pop（root 与 branch 各挂 observer）、
/// shell 的 PopScope 回调、二级页面进出（HidesShellChrome）。
class AppLogger with WidgetsBindingObserver {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  /// 缓冲上限，超出丢弃最旧条目。
  static const int maxEntries = 2000;

  final List<String> _entries = [];
  bool _recording = false;
  int _seq = 0;

  bool get isRecording => _recording;

  /// 开始记录。
  void start() {
    _recording = true;
    _seq = 0;
    _entries
      ..clear()
      ..add('==== 弦予音乐诊断日志 开始于 ${_fullStamp(DateTime.now())} ====');
    WidgetsBinding.instance.addObserver(this);
  }

  /// 记录一条日志；未开启记录时为空操作。
  void log(String tag, String message) {
    if (!_recording) return;
    _entries.add('${_stamp(DateTime.now())} [#$_seq] [$tag] $message');
    _seq++;
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  /// 停止记录并写入文件，返回文件路径；失败/未记录返回 null。
  Future<String?> stopAndSave() async {
    if (!_recording) return null;
    _recording = false;
    WidgetsBinding.instance.removeObserver(this);
    _entries.add('==== 记录结束于 ${_fullStamp(DateTime.now())} ====');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(
        dir.path,
        'xianyu_log_${_fileNameStamp(DateTime.now())}.txt',
      ));
      await file.writeAsString(_entries.join('\n'), flush: true);
      return file.path;
    } catch (e) {
      debugPrint('AppLogger 落盘失败: $e');
      return null;
    }
  }

  /// 生命周期事件：inactive→paused 即用户离开应用（回桌面）的关键信号。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    log('lifecycle', '应用状态 -> ${state.name}');
  }

  String _stamp(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

  String _fullStamp(DateTime t) => '${t.year}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${_stamp(t)}';

  String _fileNameStamp(DateTime t) => '${t.year}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}'
      '_${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}';
}

/// 诊断用路由观察者：记录目标 navigator 上的路由进出。
///
/// 同一份类挂 root 与各 branch navigator，用 [tag] 区分来源——
/// 「返回回桌面」问题的核心就是搞清楚 pop 打在了哪个 navigator 上。
class DiagRouteObserver extends NavigatorObserver {
  DiagRouteObserver(this.tag);

  /// navigator 标识（root / home / library / effects / settings）。
  final String tag;

  String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route.runtimeType.toString();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.instance.log('route', '[$tag] push ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.instance.log('route', '[$tag] pop ${_name(route)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.instance.log('route', '[$tag] remove ${_name(route)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLogger.instance
        .log('route', '[$tag] replace ${_name(oldRoute)} -> ${_name(newRoute)}');
  }
}
