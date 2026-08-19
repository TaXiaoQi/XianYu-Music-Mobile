import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/frb_generated.dart' as frb;

/// 初始化 RustLib 桥接（只初始化一次）。
///
/// 不手动指定 externalLibrary，交由生成的 [defaultExternalLibraryLoaderConfig]
/// 按平台加载正确的库名：Android `libxianyu_core.so`、Windows `xianyu_core.dll`
/// 等。手动传裸名 `xianyu_core` 会导致 Android 下 dlopen 失败。
final rustInitProvider = FutureProvider<void>((ref) async {
  await frb.RustLib.init();
});