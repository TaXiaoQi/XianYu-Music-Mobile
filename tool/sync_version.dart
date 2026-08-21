// 版本号同步脚本（参考桌面端 scripts/sync-version.js）
//
// 从项目根 version.ts 读取 APP_VERSION 作为唯一版本号源头，同步到：
//   - pubspec.yaml（version 字段，保留 +build）
//   - lib/src/auth/account_api.dart（appVersion 常量）
//
// 用法：dart run tool/sync_version.dart [可选版本号]
//   不带参数：读取 version.ts 中的 APP_VERSION
//   带参数：临时使用指定版本号（用于验证脚本，不修改 version.ts）

import 'dart:io';

void main(List<String> args) {
  final override = args.isNotEmpty ? args.first : null;

  final versionTs = File('version.ts');
  final pubspec = File('pubspec.yaml');
  final accountApi = File('lib/src/auth/account_api.dart');

  if (!versionTs.existsSync()) {
    stderr.writeln('ERROR: 未找到 version.ts（请在项目根目录运行本脚本）');
    exit(1);
  }

  // 1) 从 version.ts 读取 APP_VERSION
  final tsContent = versionTs.readAsStringSync();
  final match = RegExp(r'''APP_VERSION\s*=\s*['"]([^'"]+)['"]''').firstMatch(tsContent);
  if (match == null) {
    stderr.writeln('ERROR: 未在 version.ts 中找到 APP_VERSION');
    exit(1);
  }
  final version = override ?? match.group(1)!;

  if (!RegExp(r'^\d+\.\d+\.\d+([-+][0-9A-Za-z.\-]+)?$').hasMatch(version)) {
    stderr.writeln('ERROR: 非法的版本号: $version');
    exit(1);
  }

  // 2) 同步 account_api.dart 的 appVersion
  final accContent = accountApi.readAsStringSync();
  final accNew = accContent.replaceFirst(
    RegExp(r"const appVersion = '[^']*'", multiLine: true),
    "const appVersion = '$version'",
  );
  final accUpdated = accNew != accContent;
  if (accUpdated) accountApi.writeAsStringSync(accNew);

  // 3) 同步 pubspec.yaml 的 version（保留 +build，无 build 时补 +1）
  final pubContent = pubspec.readAsStringSync();
  var pubUpdated = false;
  final pubMatch = RegExp(r'^version\s*:[^\n]*', multiLine: true).firstMatch(pubContent);
  if (pubMatch != null) {
    final oldLine = pubMatch.group(0)!;
    final hasCr = oldLine.endsWith('\r');
    final bareOld = hasCr ? oldLine.substring(0, oldLine.length - 1) : oldLine;
    String newBare;
    if (version.contains('+')) {
      newBare = 'version: $version';
    } else {
      final oldBuild = RegExp(r'\+\s*\d+\s*$').firstMatch(bareOld)?.group(0)?.trim();
      newBare = 'version: $version${oldBuild ?? '+1'}';
    }
    final newLine = newBare + (hasCr ? '\r' : '');
    pubUpdated = bareOld != newBare;
    if (pubUpdated) pubspec.writeAsStringSync(pubContent.replaceFirst(oldLine, newLine));
  } else {
    stderr.writeln('WARNING: pubspec.yaml 中未找到 version 行');
  }

  // 4) 输出结果
  print('Synchronized version $version (source: version.ts)');
  print('- lib/src/auth/account_api.dart${accUpdated ? '' : ' (already up to date)'}');
  print('- pubspec.yaml${pubUpdated ? '' : ' (already up to date)'}');
}