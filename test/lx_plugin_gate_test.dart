import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/plugin/lx_plugin_gate.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_models.dart';

// 内置 lx 兜底的平台开关：与桌面端 lxPluginGate.ts 同规则——
// 对应平台需有启用插件才可用，汽水特例接受任意格式汽水插件
PluginSource _p({
  String name = '测试插件',
  PluginFormat format = PluginFormat.lx,
  bool enabled = true,
  List<String> sources = const [],
}) => PluginSource(
      id: 'pid',
      name: name,
      format: format,
      importedAt: 1,
      enabled: enabled,
      sources: sources,
    );

void main() {
  test('无任何插件 → 全平台不可用', () {
    for (final p in ['kg', 'qishui', 'wy', 'tx', 'kw', 'mg']) {
      expect(hasEnabledLxPluginFor(const [], p), isFalse);
    }
  });

  test('启用的 lx 插件声明对应音源 → 命中；未声明平台不命中', () {
    final plugins = [_p(sources: ['tx'])];
    expect(hasEnabledLxPluginFor(plugins, 'tx'), isTrue);
    expect(hasEnabledLxPluginFor(plugins, 'wy'), isFalse);
  });

  test('插件已停用 → 不可用', () {
    final plugins = [_p(sources: ['kg'], enabled: false)];
    expect(hasEnabledLxPluginFor(plugins, 'kg'), isFalse);
  });

  test('musicfree 插件不算 lx 音源声明（汽水除外）', () {
    final plugins = [
      _p(
        name: '网易云插件',
        format: PluginFormat.musicfree,
        sources: ['wy'],
      ),
    ];
    expect(hasEnabledLxPluginFor(plugins, 'wy'), isFalse);
    // 名字含「汽水」的 anime 插件命中汽水兜底开关
    final qishuiPlugins = [
      _p(
        name: '汽水音乐-xm',
        format: PluginFormat.anime,
        sources: [],
      ),
    ];
    expect(hasEnabledLxPluginFor(qishuiPlugins, 'qishui'), isTrue);
    expect(hasEnabledLxPluginFor(qishuiPlugins, 'wy'), isFalse);
  });

  test('qishui：lx 插件声明 qs 音源 → 命中', () {
    final plugins = [_p(name: '某汽水源', sources: ['qs'])];
    expect(hasEnabledLxPluginFor(plugins, 'qishui'), isTrue);
  });

  test('qishui：仅普通 lx 插件（无 qs/汽水特征）→ 不命中', () {
    final plugins = [_p(name: 'QQ音乐', sources: ['tx'])];
    expect(hasEnabledLxPluginFor(plugins, 'qishui'), isFalse);
  });

  test('多平台声明逐个判定', () {
    final plugins = [
      _p(sources: ['kg', 'kw']),
      _p(sources: ['mg']),
    ];
    expect(hasEnabledLxPluginFor(plugins, 'kg'), isTrue);
    expect(hasEnabledLxPluginFor(plugins, 'kw'), isTrue);
    expect(hasEnabledLxPluginFor(plugins, 'mg'), isTrue);
    expect(hasEnabledLxPluginFor(plugins, 'tx'), isFalse);
  });
}
