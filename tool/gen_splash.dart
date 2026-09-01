// 生成 Android 启动图 splash_logo.png：桌面端透明 logo（无文字）深浅两版。
//
// 自安卓 12（API 31）起系统闪屏只允许「纯色背景 + 图标」，无法显示文字；
// 启动页背景随系统昼夜（@color/splash_background：白天白 / 夜间 #121212），
// 深色 logo 配浅底、反白 logo（srcIn 保 alpha 染白）配深底，昼夜皆清晰。
//
// 运行：flutter test tool/gen_splash.dart  （需 flutter 引擎，勿用 dart run）
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 桌面端透明 logo 源（构建产物 dist 下的 logo.png）。
const logoRelPath = '../XianYu-Music-Desktop/dist/logo.png';

/// 输出的 density → 目标宽度（px）。基准 148dp。
const densityMap = {
  'mdpi': 148,
  'hdpi': 222,
  'xhdpi': 296,
  'xxhdpi': 444,
  'xxxhdpi': 592,
};

/// 输出变体：drawable 密度目录前缀 → 绘制用画笔。
/// 日间用原 logo，夜间用反白（保留 alpha、颜色统一染白）。
final variants = <String, ui.Paint>{
  '': ui.Paint(),
  '-night': ui.Paint()
    ..colorFilter = const ui.ColorFilter.mode(
      ui.Color(0xFFFFFFFF),
      ui.BlendMode.srcIn,
    ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('生成启动图', () async {
    final ok = await run();
    expect(ok, true);
  });
}

Future<bool> run() async {
  final logoBytes = File(logoRelPath).readAsBytesSync();
  final codec = await ui.instantiateImageCodec(logoBytes);
  final frame = await codec.getNextFrame();
  final logo = frame.image;

  var count = 0;
  for (final entry in variants.entries) {
    for (final e in densityMap.entries) {
      final w = e.value;
      final h = (w * logo.height / logo.width).round();
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      c.drawImageRect(
        logo,
        ui.Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        entry.value,
      );
      final img = await rec.endRecording().toImage(w, h);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      final bytes = data!.buffer.asUint8List();
      // ignore: unused_local_variable
      final Uint8List out = bytes;
      final dir = entry.key.isEmpty
          ? 'drawable-${e.key}'
          : 'drawable${entry.key}-${e.key}';
      final path = 'android/app/src/main/res/$dir/splash_logo.png';
      File(path).parent.createSync(recursive: true);
      await File(path).writeAsBytes(bytes);
      // ignore: avoid_print
      print('写入 $path ($w x $h)');
      count++;
    }
  }
  // ignore: avoid_print
  print('完成，共生成 $count 张启动图');
  return true;
}
