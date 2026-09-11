export './src/file_picker.dart';
export './src/platform_file.dart';
export './src/file_picker_result.dart';
export './src/file_picker_macos.dart';
export './src/linux/file_picker_linux.dart';
export './src/file_picker_io.dart';
// XY shim: 移动端（Android/iOS/ohos）永不运行 Windows，无条件导出 stub。
// 原条件 `if (dart.library.ffi)` 在 ohos 上为真（FRB 依赖 dart:ffi），
// 会把 win32 5.x 风格的 FFI 实现拉进 kernel 编译，与 win32 6.x 不兼容。
export './src/windows/file_picker_windows_stub.dart';
