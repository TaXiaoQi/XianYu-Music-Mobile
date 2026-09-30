import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/lyrics/lyrics_repository.dart';

/// 插件译文的两件事：时间戳对齐 + raw 组装（QRC 外壳哨兵）。
///
/// 线上实测（同一首英文歌，连续五次）：插件返回 `keys=[lyric, tlyric, …]`、
/// `tLen=821`、译文时间戳与主行逐个一致，界面却一个中文都没有。原因是 Rust 侧
/// 挂载插件译文的唯一入口要求文本里存在 `</QrcInfos>`：
///
///     if !qrc_candidate.is_empty() {
///         if let Some(end) = normalized.find("</QrcInfos>") {
///             attach_lrc_translation_lines(&mut qrc_candidate, tail);   // ±2s 就近挂载
///
/// 插件主文是 QRC 内层行（`[540,4170]You (540,480)make`）但没有 XML 外壳，
/// 于是整段挂载逻辑从未执行。
void main() {
  const main = '[00:10.000]Hello world\n'
      '[00:14.000]Second line\n'
      '[00:18.000]Third line';

  group('时间戳对齐', () {
    test('译文与主歌词同刻时保留，并补上角色前缀', () {
      final aligned = alignTranslationToMainLyric(
          main, '[00:10.000]你好世界\n[00:14.000]第二行\n[00:18.000]第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
    });

    test('译文时间戳错位时吸附回对应主行', () {
      final aligned = alignTranslationToMainLyric(
          main, '[00:10.200]你好世界\n[00:14.200]第二行\n[00:18.200]第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
    });

    test('译文完全没有时间戳时按行序补齐', () {
      final aligned = alignTranslationToMainLyric(main, '你好世界\n第二行\n第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
    });

    test('译文缺行时剩下的不会被整体错位', () {
      final aligned = alignTranslationToMainLyric(
          main, '[00:10.000]你好世界\n[00:18.000]第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
      expect(aligned, isNot(contains('[00:14.000]【翻译】第三行')));
    });

    test('译文自带 QRC 行首时剥掉再对齐（译文必须保持 LRC 形状）', () {
      // 译文写成 [起,时长] 会被 parse_qrc 当成主文行重复收录，必须还原成 LRC。
      const krcMain = '[10000,1200]Hello world\n[14000,1200]Second line';
      final aligned = alignTranslationToMainLyric(
          krcMain, '[10000,1200]你好世界\n[14000,1200]第二行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
    });
  });

  group('raw 组装（QRC 外壳哨兵）', () {
    test('主文是 QRC 内层行时补出外壳，译文留在 Infos 之后', () {
      const qrcBody = '[540,4170]You (540,480)make (1020,540)me\n'
          '[5760,4170]Every (5760,480)time';
      const tlyric = '[00:00.540]是你让我想为爱高歌\n[00:05.760]每当我一抬头';

      final raw = composePluginLyricsRaw(qrcBody, tlyric);

      expect(raw, contains('</QrcInfos>'), reason: '缺这个哨兵标记 Rust 不会挂载译文');
      expect(raw.indexOf(qrcBody), lessThan(raw.indexOf('</QrcInfos>')),
          reason: '主文应在 QRC 文档内');
      expect(raw.indexOf(tlyric), greaterThan(raw.indexOf('</QrcInfos>')),
          reason: '译文应在 Infos 之后，作为尾部 LRC 被挂载');
    });

    test('主文是普通 LRC 时不加外壳，按原样拼接', () {
      final raw = composePluginLyricsRaw(main, '[00:10.000]【翻译】你好世界');

      expect(raw, isNot(contains('QrcInfos')));
      expect(raw, startsWith(main));
    });

    test('没有译文时原样返回主文', () {
      const qrcBody = '[540,4170]You (540,480)make';
      expect(composePluginLyricsRaw(qrcBody, ''), contains(qrcBody));
      expect(composePluginLyricsRaw(qrcBody, ''), isNot(contains('QrcInfos')));
    });
  });
}
