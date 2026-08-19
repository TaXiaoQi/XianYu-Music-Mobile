// 裁切 logo 源图：自动去除白边，居中放到方形画布并留边距。
//
// 用法：dart run tool/crop_icon.dart
// 输入：assets/icon/source.jpg
// 输出：
//   assets/icon/app_icon.png            透明背景方形图（前景色 logo）
//   assets/icon/app_icon_bg.png         白色背景方形图（用于旧版不支持透明的图标）
//   assets/icon/app_icon_foreground.png 自适应图标前景层（更大留白）

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const int whiteThreshold = 244; // 高于该亮度视为白底

bool _isWhitish(img.Pixel p) {
  return p.r >= whiteThreshold &&
      p.g >= whiteThreshold &&
      p.b >= whiteThreshold;
}

void main() {
  final srcFile = File('assets/icon/source.jpg');
  if (!srcFile.existsSync()) {
    stderr.writeln('找不到源图 assets/icon/source.jpg');
    exit(1);
  }

  final decoded = img.decodeImage(srcFile.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('源图解码失败');
    exit(1);
  }
  final src = decoded.convert(numChannels: 4); // 确保有 alpha 通道

  // 1) 检测内容边界框（非白色像素）
  int minX = src.width, minY = src.height, maxX = -1, maxY = -1;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      if (!_isWhitish(src.getPixel(x, y))) {
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
  final contentW = maxX - minX + 1;
  final contentH = maxY - minY + 1;
  stdout.writeln('内容边界: ($minX,$minY) - ($maxX,$maxY), 尺寸 ${contentW}x$contentH');

  // 2) 裁出内容区，并把白底像素转为透明
  final content = img.copyCrop(src, x: minX, y: minY, width: contentW, height: contentH);
  for (var y = 0; y < content.height; y++) {
    for (var x = 0; x < content.width; x++) {
      final p = content.getPixel(x, y);
      if (_isWhitish(p)) {
        content.setPixelRgba(x, y, p.r, p.g, p.b, 0);
      }
    }
  }

  // 3) 生成透明方形图（内容占比约 78%，四周留边距）
  _composeSquare(content, marginRatio: 0.11, output: 'assets/icon/app_icon.png', background: null);

  // 4) 白底方形图（同布局，填白背景）
  _composeSquare(content, marginRatio: 0.11, output: 'assets/icon/app_icon_bg.png',
      background: img.ColorRgba8(255, 255, 255, 255));

  // 5) 自适应图标前景层：留更大边距（约 32%），避免被系统圆形/圆角遮罩裁掉
  _composeSquare(content, marginRatio: 0.30, output: 'assets/icon/app_icon_foreground.png', background: null);

  stdout.writeln('完成：已生成 app_icon.png / app_icon_bg.png / app_icon_foreground.png');
}

void _composeSquare(img.Image content,
    {required double marginRatio, required String output, img.Color? background}) {
  final longSide = math.max(content.width, content.height);
  // 画布边长 = 内容长边 / (1 - 2*margin)
  final canvasSize = (longSide / (1 - 2 * marginRatio)).round();

  final canvas = img.Image(width: canvasSize, height: canvasSize, numChannels: 4);
  if (background != null) {
    img.fill(canvas, color: background);
  } else {
    img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 0));
  }

  final dx = ((canvasSize - content.width) / 2).round();
  final dy = ((canvasSize - content.height) / 2).round();
  img.compositeImage(canvas, content, dstX: dx, dstY: dy);

  File(output).writeAsBytesSync(img.encodePng(canvas));
  stdout.writeln('  → $output  ${canvasSize}x$canvasSize');
}
