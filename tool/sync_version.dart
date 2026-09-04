// ignore_for_file: avoid_print  // CLI 工具，print 为预期输出
//
// 版本号同步脚本（参考桌面端 scripts/sync-version.js）
//
// 从项目根 version.ts 读取 APP_VERSION 作为唯一版本号源头，同步到：
//   - pubspec.yaml（version 字段，+build 段按版本自动推导，见下方公式）
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

  // 3) 同步 pubspec.yaml 的 version（+build 段 = deriveVersionCode 推导结果）
  //
  // versionCode 推导公式（应用商店/F-Droid 均要求 versionCode 随版本单调递增；
  // 旧逻辑恒为 +1 会导致所有版本 versionCode 相同、商店无法识别升级）：
  //   versionCode = major×1,000,000 + minor×10,000 + patch×100
  //                 + (预发布 betaN，N∈1..98 → N；正式版 → 99)
  //   例：1.0.1-beta7 → 1000107；1.0.1 正式 → 1000199；1.0.2-beta1 → 1000201
  // 同一 major.minor.patch 内 betaN 递增；正式版大于其全部 beta；更高 patch 的
  // beta 大于低 patch 正式版；minor/major 进位天然更大——整体单调。
  // 显式带 +build 的版本号视为手动指定，原样使用（可覆盖推导结果应急）。
  final pubContent = pubspec.readAsStringSync();
  var pubUpdated = false;
  final pubMatch = RegExp(r'^version\s*:[^\n]*', multiLine: true).firstMatch(pubContent);
  if (pubMatch != null) {
    final oldLine = pubMatch.group(0)!;
    final hasCr = oldLine.endsWith('\r');
    final bareOld = hasCr ? oldLine.substring(0, oldLine.length - 1) : oldLine;
    final newBare = version.contains('+')
        ? 'version: $version'
        : 'version: $version+${deriveVersionCode(version)}';
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

/// 从版本号推导单调递增的 versionCode（pubspec 的 +build 段）。
///
/// 公式与单调性论证见 main 内步骤 3 注释。beta 序号超出 1..98、或预发布段
/// 不是 beta/bateN 形式时报错退出，避免生成破坏单调性的 versionCode。
/// 历史版本号曾有 bate 拼写（如 1.0.0-bate2），推导时一并兼容。
String deriveVersionCode(String version) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$').firstMatch(version);
  if (m == null) {
    stderr.writeln('ERROR: 无法解析版本号: $version');
    exit(1);
  }
  final major = int.parse(m.group(1)!);
  final minor = int.parse(m.group(2)!);
  final patch = int.parse(m.group(3)!);
  final pre = m.group(4);
  int suffix;
  if (pre == null) {
    suffix = 99;
  } else {
    final n = int.tryParse(
          RegExp(r'^(?:beta|bate)(\d+)$').firstMatch(pre)?.group(1) ?? '',
        ) ??
        -1;
    if (n < 1 || n > 98) {
      stderr.writeln(
        'ERROR: 预发布段「-$pre」无法推导 versionCode（仅支持 beta/bate 1..98）。'
        '请改用如 1.0.1-beta3 的形式，或显式写 +build 手动指定',
      );
      exit(1);
    }
    suffix = n;
  }
  return '${major * 1000000 + minor * 10000 + patch * 100 + suffix}';
}