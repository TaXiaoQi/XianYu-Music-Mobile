import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final diagRecordingProvider = StateProvider<bool>((ref) => false);

class AppLogger with WidgetsBindingObserver {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  static const int maxEntries = 2000;

  final List<String> _entries = [];
  bool _recording = false;
  int _seq = 0;

  bool get isRecording => _recording;

  void start() {
    _recording = true;
    _entries.add('==== 诊断开启于 ${_fullStamp(DateTime.now())}'
        '（以下含启动至今的历史记录）====');
    WidgetsBinding.instance.addObserver(this);
  }

  void log(String tag, String message) {
    _entries.add('${_stamp(DateTime.now())} [#$_seq] [$tag] $message');
    _seq++;
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

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

class DiagRouteObserver extends NavigatorObserver {
  DiagRouteObserver(this.tag);

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
