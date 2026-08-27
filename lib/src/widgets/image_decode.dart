import 'package:flutter/widgets.dart';

/// 按“显示尺寸 × 屏幕密度”计算图片解码宽度（对齐 PiliNara 的 cacheSize 扩展）。
///
/// 列表小图按此解码可避免整张高清图解码后再缩放到小格子，降低内存与
/// GPU 上采样开销。尺寸为 0 时返回 null（交给引擎按原图解码）。
extension ImageDecodeSize on num {
  int? cacheSize(BuildContext context) {
    if (this == 0) return null;
    return (this * MediaQuery.devicePixelRatioOf(context)).round();
  }
}
