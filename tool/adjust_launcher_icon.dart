// 启动图标微调工具：对图标源图做"缩小 + 向右下平移"，并重新生成各密度资源。
// 用法：dart run tool/adjust_launcher_icon.dart
// 调整幅度改下面两个常量后重跑即可；源图和 res 资源均被 git 跟踪，可随时回退。
import 'dart:io';

import 'package:image/image.dart' as img;

/// 字形缩放系数（1.0 = 不缩放，0.95 = 缩小 5%）。
const double kScale = 0.95;

/// 向右下平移量（占画布边长的比例，0.025 = 2.5%）。
const double kShiftFrac = 0.025;

const Map<String, int> kDrawableSizes = {
  'mdpi': 108,
  'hdpi': 162,
  'xhdpi': 216,
  'xxhdpi': 324,
  'xxxhdpi': 432,
};

const Map<String, int> kMipmapSizes = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

void main() {
  final fg = _adjust('assets/icon/app_icon_foreground.png', transparent: true);
  final bg = _adjust('assets/icon/app_icon_bg.png', transparent: false);

  kDrawableSizes.forEach((density, size) {
    final out = img.copyResize(fg,
        width: size, height: size, interpolation: img.Interpolation.average);
    File('android/app/src/main/res/drawable-$density/ic_launcher_foreground.png')
        .writeAsBytesSync(img.encodePng(out));
    print('drawable-$density/ic_launcher_foreground.png -> ${size}px');
  });

  kMipmapSizes.forEach((density, size) {
    final out = img.copyResize(bg,
        width: size, height: size, interpolation: img.Interpolation.average);
    File('android/app/src/main/res/mipmap-$density/ic_launcher.png')
        .writeAsBytesSync(img.encodePng(out));
    print('mipmap-$density/ic_launcher.png -> ${size}px');
  });
}

/// 缩放源图内容并平移到原尺寸画布上（右下方向），返回处理后图像。
img.Image _adjust(String path, {required bool transparent}) {
  final file = File(path);
  final src = img.decodePng(file.readAsBytesSync())!;
  final w = src.width, h = src.height;

  final sw = (w * kScale).round();
  final sh = (h * kScale).round();
  final scaled = img.copyResize(src,
      width: sw, height: sh, interpolation: img.Interpolation.average);

  // 注意：image 包默认 numChannels=3（无 alpha），透明画布必须显式指定 4 通道
  final out = img.Image(width: w, height: h, numChannels: 4);
  if (!transparent) {
    // 白底图：用源图边缘色填充画布，避免接缝
    final corner = src.getPixel(2, 2);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out.setPixelRgba(
            x, y, corner.r.toInt(), corner.g.toInt(), corner.b.toInt(), 255);
      }
    }
  }

  final dx = ((w - sw) / 2 + w * kShiftFrac).round();
  final dy = ((h - sh) / 2 + h * kShiftFrac).round();
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final p = scaled.getPixel(x, y);
      final a = p.a.toInt();
      if (transparent) {
        if (a == 0) continue;
        out.setPixelRgba(
            dx + x, dy + y, p.r.toInt(), p.g.toInt(), p.b.toInt(), a);
      } else if (a == 255) {
        out.setPixelRgba(
            dx + x, dy + y, p.r.toInt(), p.g.toInt(), p.b.toInt(), 255);
      } else if (a > 0) {
        final t = a / 255.0;
        out.setPixelRgba(
          dx + x,
          dy + y,
          (p.r * t + 255 * (1 - t)).round(),
          (p.g * t + 255 * (1 - t)).round(),
          (p.b * t + 255 * (1 - t)).round(),
          255,
        );
      }
    }
  }

  file.writeAsBytesSync(img.encodePng(out));
  print('$path: ${w}x$h -> ${sw}x$sh @ ($dx,$dy)'
      ' [缩放 ${(kScale * 100).toStringAsFixed(0)}%，右下移 ${(kShiftFrac * 100).toStringAsFixed(1)}%]');
  return out;
}
