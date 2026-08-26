// 生成 Android 启动图 splash_logo.png：品牌 logo（透明）+ 下方中文标语「将音乐给予你」。
// 复用品牌原生 logo 像素做 logo，用中文字体（tool/fonts/simhei.ttf）渲染文字，逐层合成；
// 输出亮（day，logo 原色+深灰字）/暗（night，logo 反色+浅灰字）两版，覆盖各 density。
//
// 运行：flutter test tool/gen_splash.dart  （需 flutter 引擎，勿用 dart run）
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

/// 中文字体在当前工程中的相对路径（仅生成期用，不随包打包）。
const fontRelPath = 'tool/fonts/simhei.ttf';
/// 品牌 logo 源（透明底）。
const logoRelPath = 'android/app/src/main/res/drawable-xxxhdpi/splash_logo.png';
/// 标语。
const slogan = '将音乐给予你';

/// 亮 / 暗两版配色（透明底，背景色由 launch_background 的 splash_background 提供）。
const dayText = 0xFF3A4148; // 深灰
const nightText = 0xFFDDE1E6; // 浅灰（比反色 logo 略亮，保证夜间标语可读）

// 布局（dp，再乘 density）。
const canvasWdp = 360.0;
const logoWdp = 148.0;
const logoTextGapDp = 26.0;
const sloganFontDp = 17.0;
const sloganLetterSpacingDp = 2.0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('生成启动图', () async {
    final ok = await run();
    expect(ok, true);
  });
}

Future<bool> run() async {
  final fontBytes = File(fontRelPath).readAsBytesSync();
  final loader = FontLoader('Xianyusplash');
  loader.addFont(Future.value(ByteData.view(fontBytes.buffer)));
  await loader.load();

  final logoBytes = File(logoRelPath).readAsBytesSync();
  final codec = await ui.instantiateImageCodec(logoBytes);
  final frame = await codec.getNextFrame();
  final logo = frame.image;

  const densityMap = {
    'mdpi': 1.0,
    'hdpi': 1.5,
    'xhdpi': 2.0,
    'xxhdpi': 3.0,
    'xxxhdpi': 4.0,
  };

  var count = 0;
  for (final e in densityMap.entries) {
    // 亮版：logo 原色 + 深灰字。
    await _write(
      'android/app/src/main/res/drawable-${e.key}/splash_logo.png',
      await _compose(logo, density: e.value, invertLogo: false, textColor: dayText),
    );
    count++;
    // 暗版：logo 反色（变浅）+ 浅灰字。
    await _write(
      'android/app/src/main/res/drawable-night-${e.key}/splash_logo.png',
      await _compose(logo, density: e.value, invertLogo: true, textColor: nightText),
    );
    count++;
  }
  stdout.writeln('完成，共生成 $count 张启动图');
  return true;
}

Future<Uint8List> _compose(
  ui.Image logo, {
  required double density,
  required bool invertLogo,
  required int textColor,
}) async {
  final sc = density;
  final logoW = logoWdp * sc;
  final logoH = logoW * logo.height / logo.width;
  final canvasW = canvasWdp * sc;
  final gap = logoTextGapDp * sc;

  final tb = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: ui.TextAlign.center))
    ..pushStyle(ui.TextStyle(
      color: ui.Color(textColor),
      fontSize: sloganFontDp * sc,
      letterSpacing: sloganLetterSpacingDp * sc,
      fontFamily: 'Xianyusplash',
    ))
    ..addText(slogan)
    ..pop();
  final para = tb.build();
  para.layout(ui.ParagraphConstraints(width: canvasW));
  final canvasH = logoH + gap + para.height;

  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final paint = ui.Paint();
  if (invertLogo) {
    paint.colorFilter = const ui.ColorFilter.matrix([
      -1, 0, 0, 0, 255, //
      0, -1, 0, 0, 255, //
      0, 0, -1, 0, 255, //
      0, 0, 0, 1, 0,
    ]);
  }
  final dstX = (canvasW - logoW) / 2;
  c.drawImageRect(
    logo,
    ui.Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
    ui.Rect.fromLTWH(dstX, 0, logoW, logoH),
    paint,
  );
  c.drawParagraph(para, ui.Offset(0, logoH + gap));

  final img = await rec.endRecording().toImage(canvasW.round(), canvasH.ceil());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _write(String path, Uint8List bytes) async {
  File(path).parent.createSync(recursive: true);
  await File(path).writeAsBytes(bytes);
  stdout.writeln('写入 $path');
}