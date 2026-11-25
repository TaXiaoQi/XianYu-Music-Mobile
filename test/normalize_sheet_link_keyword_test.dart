import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_catalog.dart';

// 背景：BakaMusic QQ[T] 插件 URL 正则有缺陷（playlist.html?id=... 解析不出
// 歌单 ID，只有 &id= 才命中），应用侧须先把链接规范化成纯 ID 再传插件。
void main() {
  test('QQ n3 页面链接（?id= 开头）规范化为纯 ID', () {
    expect(
      PluginCatalogService.normalizeSheetLinkKeyword(
          'https://i2.y.qq.com/n3/other/pages/details/playlist.html?id=2301168231&hosteuin='),
      '2301168231',
    );
  });

  test('QQ taoge 分享链接', () {
    expect(
      PluginCatalogService.normalizeSheetLinkKeyword(
          'https://i.y.qq.com/n2/m/share/details/taoge.html?hosteuin=xxx&id=8722212590'),
      '8722212590',
    );
  });

  test('网易/酷我/酷狗链接', () {
    expect(
      PluginCatalogService.normalizeSheetLinkKeyword(
          'https://music.163.com/playlist?id=7268074324&userid=1'),
      '7268074324',
    );
    expect(
      PluginCatalogService.normalizeSheetLinkKeyword(
          'https://www.kuwo.cn/playlist_detail/123456'),
      '123456',
    );
    expect(
      PluginCatalogService.normalizeSheetLinkKeyword(
          'https://www.kugou.com/playlist/99.html'),
      '99',
    );
  });

  test('纯数字 ID 与非链接输入原样返回', () {
    expect(PluginCatalogService.normalizeSheetLinkKeyword('2301168231'),
        '2301168231');
    expect(
        PluginCatalogService.normalizeSheetLinkKeyword('周杰伦精选'), '周杰伦精选');
  });

  test('无法识别的链接原样返回（交由插件自行处理）', () {
    expect(
      PluginCatalogService.normalizeSheetLinkKeyword('https://example.com/x'),
      'https://example.com/x',
    );
  });
}
