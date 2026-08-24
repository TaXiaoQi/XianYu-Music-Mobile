import 'dart:io';

import 'package:image/image.dart' as img;

/// 用 assets/icon/source.jpg（白底、logo 居中）覆盖生成 Android 启动图标。
///
/// 与 adjust_launcher_icon.dart 不同：本脚本【不】对源图做"缩小+右下平移"，
/// 而是直接立方缩放、logo 保持居中，避免源图被反复污染出偏移/杂质。
/// 生成目标：legacy mipmap/ic_launcher.png + adaptive drawable/ic_launcher_foreground.png。
void main() {
  final srcBytes = File('assets/icon/source.jpg').readAsBytesSync();
  final src = img.decodeJpg(srcBytes);
  if (src == null) {
    stderr.writeln('读取 assets/icon/source.jpg 失败');
    exit(1);
  }
  stdout.writeln('源图: ${src.width}x${src.height}');

  // 密度 -> 传统图标尺寸（Android 节点 48dp）。
  const legacy = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  // 密度 -> 自适应前景画布尺寸（108dp）。
  const fore = {
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };

  var count = 0;
  for (final e in legacy.entries) {
    final out = img.resize(src,
        width: e.value, height: e.value, interpolation: img.Interpolation.average);
    final path = 'android/app/src/main/res/mipmap-${e.key}/ic_launcher.png';
    File(path).writeAsBytesSync(img.encodePng(out));
    stdout.writeln('写入 $path (${out.width}x${out.height})');
    count++;
  }
  for (final e in fore.entries) {
    final out = img.resize(src,
        width: e.value, height: e.value, interpolation: img.Interpolation.average);
    final path = 'android/app/src/main/res/drawable-${e.key}/ic_launcher_foreground.png';
    File(path).writeAsBytesSync(img.encodePng(out));
    stdout.writeln('写入 $path (${out.width}x${out.height})');
    count++;
  }
  stdout.writeln('完成，共生成 $count 个图标');
}