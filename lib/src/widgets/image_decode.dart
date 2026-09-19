import 'package:flutter/widgets.dart';

extension ImageDecodeSize on num {
  int? cacheSize(BuildContext context) {
    if (this == 0) return null;
    return (this * MediaQuery.devicePixelRatioOf(context)).round();
  }
}
