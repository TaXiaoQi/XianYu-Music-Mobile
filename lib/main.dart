import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'src/auth/account_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  _installErrorReporting(container);
  runApp(UncontrolledProviderScope(container: container, child: const XianYuApp()));
}

/// 全局错误上报（fire-and-forget，失败静默），与桌面端 main.ts 对齐。
void _installErrorReporting(ProviderContainer container) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    container.read(accountApiProvider).reportError(
          errorType: 'flutter',
          errorMessage: details.exceptionAsString(),
          errorStack: details.stack?.toString() ?? '',
          page: 'global',
        );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    container.read(accountApiProvider).reportError(
          errorType: 'platform',
          errorMessage: error.toString(),
          errorStack: stack.toString(),
          page: 'global',
        );
    return true;
  };
}
