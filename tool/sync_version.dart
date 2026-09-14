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
  // versionCode 推导公式（应用商店/F-Droid 要求 versionCode 随版本单调递增；
  // 旧逻辑恒为 +1 会导致所有版本 versionCode 相同、商店无法识别升级）：
  //   versionCode = major×1,000,000 + minor×10,000 + patch×100
  //   例：1.0.1 → 1000100；1.0.2 → 1000200；1.0.3-beta1 → 1000300
  // 数字系列只和数字系列比：同一 major.minor.patch 的正式版与任意预发布版
  // （betaN/alpha/rc…）取同一 versionCode —— Android 安装器只认一维整数、
  // 无法表达「beta 与正式版互为独立分支」，若给预发布段编入序号（旧公式
  // betaN→N、正式版→99），同数字系列先装的会拦截后装的（降级误判）。
  // 同码后系统层面互相覆盖安装均放行；beta 先后关系由应用内 versionName
  // 比较器承担（plugin_updates.dart / app_update.dart，预发布独立语义）。
  // 跨数字版本天然单调递增，满足商店要求（同数字的 beta/正式版不重复上架
  // 即无同码冲突）。
  // 显式带 +build 的版本号视为手动指定，原样使用（可覆盖推导结果应急）。
  // versionCode 单调保护：同一版本号重新同步时，推导值若低于 pubspec 现值
  // （历史上手动抬过码过渡，如 1.0.2 → 1000299），保留现值不回退——回退会让
  // 已安装用户被系统判降级拦截；跨数字版本推导值天然更高，不受影响。
  final pubContent = pubspec.readAsStringSync();
  var pubUpdated = false;
  final pubMatch = RegExp(r'^version\s*:[^\n]*', multiLine: true).firstMatch(pubContent);
  if (pubMatch != null) {
    final oldLine = pubMatch.group(0)!;
    final hasCr = oldLine.endsWith('\r');
    final bareOld = hasCr ? oldLine.substring(0, oldLine.length - 1) : oldLine;
    final oldCode =
        int.tryParse(RegExp(r'\+(\d+)\s*$').firstMatch(bareOld)?.group(1) ?? '');
    final derived =
        version.contains('+') ? null : int.tryParse(deriveVersionCode(version));
    var targetCode = derived;
    if (derived != null && oldCode != null && derived < oldCode) {
      targetCode = oldCode;
      stderr.writeln(
        'NOTE: 推导 versionCode $derived 低于 pubspec 现值 $oldCode，'
        '保留现值（单调保护）。如确需回退请显式写 +build。',
      );
    }
    final newBare = version.contains('+')
        ? 'version: $version'
        : 'version: $version+$targetCode';
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
/// 公式与「数字系列只和数字系列比」的语义论证见 main 内步骤 3 注释：
/// 预发布段（betaN/alpha/rc…）不参与推导，与同数字正式版共用 versionCode。
/// 任意合法版本号均可推导；历史版本号曾有 bate 拼写（如 1.0.0-bate2），无需
/// 特判——预发布段一律忽略。需要精细控制时显式写 +build 手动指定。
String deriveVersionCode(String version) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$').firstMatch(version);
  if (m == null) {
    stderr.writeln('ERROR: 无法解析版本号: $version');
    exit(1);
  }
  final major = int.parse(m.group(1)!);
  final minor = int.parse(m.group(2)!);
  final patch = int.parse(m.group(3)!);
  return '${major * 1000000 + minor * 10000 + patch * 100}';
}