import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/frb_generated.dart' as frb;

/// 初始化 RustLib 桥接（只初始化一次）。
final rustInitProvider = FutureProvider<void>((ref) async {
  await frb.RustLib.init(externalLibrary: ExternalLibrary.open('xianyu_core'));
});