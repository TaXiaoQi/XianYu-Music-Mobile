import 'dart:io';

import 'package:image/image.dart' as img;

const int whiteThreshold = 244;

bool _isWhitish(img.Pixel p) =>
    p.r >= whiteThreshold && p.g >= whiteThreshold && p.b >= whiteThreshold;

/// logo 包围盒宽度占画布比例（调小 → logo 更小）。源图内 logo 约 55% 宽，
/// 这里定为 0.50。
const double logoFraction = 0.50;

/// 相对中心向右偏移的画布比例（正值为右；0 = 严格居中）。
const double shiftRightFraction = 0.0;

/// 从 source.jpg 裁出 logo，按 [logoFraction]（更小）比例、纵向居中、横向
/// 略偏右组合到白色画布，生成 Android 启动图标，保持"白底方图标"外观。
void main() {
  final src = img.decodeJpg(File('assets/icon/source.jpg').readAsBytesSync());
  if (src == null) {
    stderr.writeln('读取 assets/icon/source.jpg 失败');
    exit(1);
  }
  stdout.writeln('源图: ${src.width}x${src.height}');
  final rgba = src.convert(numChannels: 4);

  // 检测 logo（非白色）内容边界框
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
    stderr.writeln('未检测到 logo 内容');
    exit(1);
  }
  final content = img.copyCrop(rgba,
      x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);
  stdout.writeln('logo 包围盒: ${content.width}x${content.height}（原占画布 '
      '${(content.width / rgba.width * 100).toStringAsFixed(0)}%）');

  const legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
  const fore = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432};

  var count = 0;
  for (final e in legacy.entries) {
    final c = _composeWhite(content, e.value);
    File('android/app/src/main/res/mipmap-${e.key}/ic_launcher.png')
        .writeAsBytesSync(img.encodePng(c));
    stdout.writeln('写入 mipmap-${e.key}/ic_launcher.png (${c.width}x${c.height})');
    count++;
  }
  for (final e in fore.entries) {
    final c = _composeWhite(content, e.value);
    File('android/app/src/main/res/drawable-${e.key}/ic_launcher_foreground.png')
        .writeAsBytesSync(img.encodePng(c));
    stdout.writeln('写入 drawable-${e.key}/ic_launcher_foreground.png (${c.width}x${c.height})');
    count++;
  }
  stdout.writeln('完成，共生成 $count 个图标');
}

/// 白色画布：logo 按 [logoFraction] 宽度等比缩放，纵向居中，横向略偏右。
img.Image _composeWhite(img.Image content, int canvasPx) {
  final targetW = (canvasPx * logoFraction).round();
  final targetH = (content.height * (targetW / content.width)).round();
  final scaled = img.copyResize(content,
      width: targetW, height: targetH, interpolation: img.Interpolation.average);

  final canvas = img.Image(width: canvasPx, height: canvasPx, numChannels: 4);
  img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));

  final dx = ((canvasPx - scaled.width) / 2).round() +
      (canvasPx * shiftRightFraction).round();
  final dy = ((canvasPx - scaled.height) / 2).round();
  img.compositeImage(canvas, scaled, dstX: dx, dstY: dy);
  return canvas;
}