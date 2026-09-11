// 星海 LX 插件 + 真实 lx_backup.lxmc 在移动端 Rust 引擎上的端到端回归。
//
// 运行：flutter test test/lx_x_backup_import_test.dart
// 依赖：rust/target/debug/xianyu_core.dll（XIANYU_DLL 可覆盖）与本机样例文件，
// 缺失时自动跳过，不影响 CI。
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xianyu_music_mobile/src/plugin/plugin_backup_file.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_backup_import.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_engine.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_models.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_store.dart';
import 'package:xianyu_music_mobile/src/rust/frb_generated.dart' show RustLib;

const _samplesDir = r'C:\Users\小奇\Downloads';
const _xinghaiFile = '$_samplesDir\\1.xinghai-music-sourcev2.3.13.js';
const _lxmcFile = '$_samplesDir\\lx_backup.lxmc';

PluginSource _xinghaiStub(String id, List<String> sources) => PluginSource(
      id: id,
      name: '星海音乐源',
      format: PluginFormat.lx,
      version: '2.3.13',
      filePath: _xinghaiFile,
      importedAt: 1,
      sources: sources,
    );

void main() {
  final dllPath = Platform.environment['XIANYU_DLL'] ??
      p.join('rust', 'target', 'debug', 'xianyu_core.dll');
  final hasDll = File(dllPath).existsSync();
  final hasXinghai = File(_xinghaiFile).existsSync();

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!hasDll) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(dllPath));
  });

  test('星海插件在移动端 Rust 引擎初始化并报告音源', () async {
    if (!hasDll || !hasXinghai) return;
    final script = File(_xinghaiFile).readAsStringSync();
    final engine = PluginEngine(
      Directory.systemTemp.createTempSync('xy_plugin_test').path,
      PluginStore(Directory.systemTemp.createTempSync('xy_store_test').path),
    );

    expect(engine.isLxPluginScript(script), isTrue,
        reason: '星海脚本应被识别为 LX 格式');
    final info = engine.parseLxScriptInfo(script);
    // ignore: avoid_print
    print('LX 头信息: $info');

    final metadata = await engine.loadLx('test-xinghai', script, scriptInfo: info);
    expect(metadata, isNotNull, reason: 'LX 插件初始化失败：$metadata');
    final sources = metadata!['sources'];
    // ignore: avoid_print
    print('报告音源: $sources');
    expect(sources, isNotEmpty, reason: '插件应报告可用音源（wy/tx/kw/kg/mg）');
  });

  test('真实 lxmc 备份 + 星海插件 stub 走通导入管线', () async {
    if (!hasDll || !hasXinghai || !File(_lxmcFile).existsSync()) return;
    final script = File(_xinghaiFile).readAsStringSync();
    final engine = PluginEngine(
      Directory.systemTemp.createTempSync('xy_plugin_test').path,
      PluginStore(Directory.systemTemp.createTempSync('xy_store_test').path),
    );
    final info = engine.parseLxScriptInfo(script);
    final metadata = await engine.loadLx('test-xinghai', script, scriptInfo: info);
    final declared = (metadata?['sources'] as List?)?.cast<String>() ??
        const ['wy', 'tx', 'kw', 'kg', 'mg'];

    final json = extractBackupJsonBytes(File(_lxmcFile).readAsBytesSync(), _lxmcFile);
    final prepared = preparePluginBackupImport(json, [_xinghaiStub('test-xinghai', declared)]);
    // ignore: avoid_print
    print('format=${prepared.format} sheets=${prepared.sourcePlaylistCount} '
        'imported=${prepared.importedSongCount} failed=${prepared.failures.length}');
    expect(prepared.format, 'lxmusic');
    expect(prepared.importedSongCount, 456);
    expect(prepared.missingPlugins, isEmpty);
  });

  test('gzip(lxmc) 解码与 JSON 提取（无引擎依赖）', () {
    if (!File(_lxmcFile).existsSync()) return;
    final json = extractBackupJsonBytes(File(_lxmcFile).readAsBytesSync(), _lxmcFile);
    expect(json.trimLeft().startsWith('{'), isTrue);
    expect(json, contains('allData_v3'));
  });
}
