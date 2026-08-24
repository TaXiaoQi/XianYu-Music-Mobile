import 'dart:io';

import 'package:image/image.dart' as img;

const int whiteThreshold = 244;

bool _isWhitish(img.Pixel p) =>
    p.r >= whiteThreshold && p.g >= whiteThreshold && p.b >= whiteThreshold;

/// 以 assets/icon/source.jpg 为底图，裁掉四周白边、居中放大后覆盖生成
/// Android 启动图标（直接用 source 放大 logo）。
///
/// legacy 图标全方形展示，logo 放大到约占画布 92%（缩小边距，格子更大）；
/// adaptive 前景存在 inset 16% + 圆形遮罩，logo 约占画布 60%，
/// 保证正好落在圆形安全区内、不裁边（再大四角会被圆遮罩切掉）。
void main() {
  final srcBytes = File('assets/icon/source.jpg').readAsBytesSync();
  final src = img.decodeJpg(srcBytes);
  if (src == null) {
    stderr.writeln('读取 assets/icon/source.jpg 失败');
    exit(1);
  }
  stdout.writeln('源图: ${src.width}x${src.height}');

  final rgba = src.convert(numChannels: 4);

  // 检测非白色内容边界框
  int minX = rgba.width, minY = rgba.height, maxX = -1, maxY = -1;
  for (var y = 0; y < rgba.height; y++) {
    for (var x = 0; x < rgba.width; x++) {
      final p = rgba.getPixel(x, y);
      if (p.a > 0 && !_isWhitish(p)) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) {
    stderr.writeln('未检测到非白色内容，无法裁切');
    exit(1);
  }
  final content = img.copyCrop(rgba,
      x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);
  stdout.writeln('裁切内容边界: ($minX,$minY) 尺寸 ${content.width}x${content.height}');

  // 密度 -> 目标尺寸（legacy 48dp / adaptive 108dp）
  const legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
  const fore = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432};

  var count = 0;
  for (final e in legacy.entries) {
    final canvas = _compose(content, e.value, margin: 0.04);
    final path = 'android/app/src/main/res/mipmap-${e.key}/ic_launcher.png';
    File(path).writeAsBytesSync(img.encodePng(canvas));
    stdout.writeln('写入 $path (${canvas.width}x${canvas.height})');
    count++;
  }
  for (final e in fore.entries) {
    final canvas = _compose(content, e.value, margin: 0.20);
    final path = 'android/app/src/main/res/drawable-${e.key}/ic_launcher_foreground.png';
    File(path).writeAsBytesSync(img.encodePng(canvas));
    stdout.writeln('写入 $path (${canvas.width}x${canvas.height})');
    count++;
  }
  stdout.writeln('完成，共生成 $count 个图标');
}

/// 把内容按给定 margin 占画布正比例放到目标尺寸的方形画布中央。
img.Image _compose(img.Image content, int canvasPx, {required double margin}) {
  final inner = (canvasPx * (1 - 2 * margin)).round();
  final scaled = img.resize(content,
      width: inner, height: inner, interpolation: img.Interpolation.average);
  final canvas = img.Image(width: canvasPx, height: canvasPx, numChannels: 4);
  img.compositeImage(canvas, scaled,
      dstX: ((canvasPx - scaled.width) / 2).round(),
      dstY: ((canvasPx - scaled.height) / 2).round());
  return canvas;
}