import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/src/file_picker_io.dart';
import 'package:file_picker/src/file_picker_macos.dart';
import 'package:file_picker/src/file_picker_result.dart';
import 'package:file_picker/src/platform_file.dart';
import 'package:file_picker/src/linux/file_picker_linux.dart';
// XY shim: 无条件 stub（同 lib/file_picker.dart 顶部说明）——原
// `if (dart.library.io)` 条件在 ohos 为真，会把 win32 FFI 实现拉进编译。
import 'package:file_picker/src/windows/stub.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const String defaultDialogTitle = '';

enum FileType {
  any,
  media,
  image,
  video,
  audio,
  custom,
}

enum FilePickerStatus {
  picking,
  done,
}

/// The interface that implementations of file_picker must implement.
///
/// Platform implementations should extend this class rather than implement it as `file_picker`
/// does not consider newly added methods to be breaking changes. Extending this class
/// (using `extends`) ensures that the subclass will get the default implementation, while
/// platform implementations that `implements` this interface will be broken by newly added
/// [FilePicker] methods.
abstract class FilePicker extends PlatformInterface {
  FilePicker() : super(token: _token);

  static final Object _token = Object();

  static FilePicker _instance = FilePicker._setPlatform();

  static FilePicker get platform => _instance;

  static set platform(FilePicker instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  factory FilePicker._setPlatform() {
    if (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.operatingSystem == "ohos") {
      return FilePickerIO();
    } else if (Platform.isLinux) {
      return FilePickerLinux();
    } else if (Platform.isWindows) {
      return filePickerWithFFI();
    } else if (Platform.isMacOS) {
      return FilePickerMacOS();
    } else {
      throw UnimplementedError(
        'The current platform "${Platform.operatingSystem}" is not supported by this plugin.',
      );
    }
  }

  // ── XY shim: file_picker 12.x 静态门面（本 vendored fork 基于 10.3.8）──────
  // 主工程调用点按 file_picker 12.x 的静态 API 编写（pickFiles 直接返回
  // List<PlatformFile>），而本 fork 保留 10.x 实例 API（返回 FilePickerResult?）。
  // 为让主工程同一份 lib/ 代码在两端（Android 用 pub 12.x / 鸿蒙镜像用本 fork）
  // 编译，实例方法已改名 *Impl，这里补充 12.x 形态的静态入口。
  /// Picks files per 12.x semantics: cancel/abort resolves to an empty list.
  static Future<List<PlatformFile>> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
  }) async {
    final result = await _instance.pickFilesImpl(
      type: type,
      allowedExtensions: allowedExtensions,
      allowMultiple: allowMultiple,
      withData: withData,
    );
    return result?.files ?? const <PlatformFile>[];
  }

  /// Directory picker per 12.x semantics (same shape as 10.x instance API).
  static Future<String?> getDirectoryPath() =>
      _instance.getDirectoryPathImpl();

  /// Retrieves the file(s) from the underlying platform
  ///
  /// Default [type] set to [FileType.any] with [allowMultiple] set to `false`.
  /// Optionally, [allowedExtensions] might be provided (e.g. `[pdf, svg, jpg]`.).
  ///
  /// If [withData] is set, picked files will have its byte data immediately available on memory as `Uint8List`
  /// which can be useful if you are picking it for server upload or similar. However, have in mind that
  /// enabling this on IO (iOS & Android) may result in out of memory issues if you allow multiple picks or
  /// pick huge files. Use [withReadStream] instead. Defaults to `true` on web, `false` otherwise.
  ///
  /// If [withReadStream] is set, picked files will have its byte data available as a [Stream<List<int>>]
  /// which can be useful for uploading and processing large files. Defaults to `false`.
  ///
  /// If you want to track picking status, for example, because some files may take some time to be
  /// cached (particularly those picked from cloud providers), you may want to set [onFileLoading] handler
  /// that will give you the current status of picking.
  ///
  /// If [allowCompression] is set, it will allow media to apply the default OS compression.
  /// Defaults to `true`.
  ///
  /// If [lockParentWindow] is set, the child window (file picker window) will
  /// stay in front of the Flutter window until it is closed (like a modal
  /// window). This parameter works only on Windows desktop.
  ///
  /// [dialogTitle] can be optionally set on desktop platforms to set the modal window title. It will be ignored on
  /// other platforms.
  ///
  /// [initialDirectory] can be optionally set to an absolute path to specify
  /// where the dialog should open. Only supported on Linux, macOS, and Windows.
  ///
  /// [readSequential] can be optionally set on web to keep the import file order during import.
  ///
  /// The result is wrapped in a [FilePickerResult] which contains helper getters
  /// with useful information regarding the picked [List<PlatformFile>].
  ///
  /// For more information, check the [API documentation](https://github.com/miguelpruivo/flutter_file_picker/wiki/api).
  ///
  /// Returns `null` if aborted.
  Future<FilePickerResult?> pickFilesImpl({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      throw UnimplementedError('pickFilesImpl() has not been implemented.');

  /// Asks the underlying platform to remove any temporary files created by this plugin.
  ///
  /// This typically relates to cached files that are stored in the cache directory of
  /// each platform and it isn't required to invoke this as the system should take care
  /// of it whenever needed. However, this will force the cleanup if you want to manage those on your own.
  ///
  /// This method is only available on mobile platforms (Android & iOS).
  ///
  /// Returns `true` if the files were removed with success, `false` otherwise.
  Future<bool?> clearTemporaryFiles() async => throw UnimplementedError(
      'clearTemporaryFiles() has not been implemented.');

  /// Selects a directory and returns its absolute path.
  ///
  /// On Android, this requires to be running on SDK 21 or above, else won't work.
  /// Note: Some Android paths are protected, hence can't be accessed and will return `/` instead.
  ///
  /// [dialogTitle] can be set to display a custom title on desktop platforms. It will be ignored on Web & IO.
  ///
  /// If [lockParentWindow] is set, the child window (file picker window) will
  /// stay in front of the Flutter window until it is closed (like a modal
  /// window). This parameter works only on Windows desktop.
  ///
  /// [initialDirectory] can be optionally set to an absolute path to specify
  /// where the dialog should open. Only supported on Linux, macOS, and Windows.
  ///
  /// Returns a [Future<String?>] which resolves to  the absolute path of the selected directory,
  /// if the user selected a directory. Returns `null` if the user aborted the dialog or if the
  /// folder path couldn't be resolved.
  ///
  /// Note: on Windows, throws a `WindowsException` with a detailed error message, if the dialog
  /// could not be instantiated or the dialog result could not be interpreted.
  /// Note: Some Android paths are protected, hence can't be accessed and will return `/` instead.
  Future<String?> getDirectoryPathImpl({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async =>
      throw UnimplementedError('getDirectoryPathImpl() has not been implemented.');

  /// Displays a dialog that allows the user to select both files and
  /// directories simultaneously, returning their absolute paths.
  ///
  /// **Platform Support:** As of right now, this functionality is only
  /// supported on macOS.
  ///
  /// [initialDirectory] can be optionally set to an absolute path to specify
  /// where the dialog should open. On macOS the home directory shortcut (~/) is
  /// not necessary and passing it will be ignored. On macOS if the
  /// [initialDirectory] is invalid the user directory or previously valid
  /// directory will be used.
  ///
  /// The file type filter [type] defaults to [FileType.any]. Optionally,
  /// [allowedExtensions] might be provided (e.g. `["pdf", "svg", "jpg"]`).
  ///
  /// Returns a [Future<List<String>?>] that resolves to a list of absolute
  /// paths for the selected files and directories. If the user cancels the
  /// dialog or if the paths cannot be resolved, the method returns `null`.
  Future<List<String>?> pickFileAndDirectoryPaths({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    String? initialDirectory,
  }) async =>
      throw UnimplementedError(
          'pickFileAndDirectoryPaths() has not been implemented.');

  /// Opens a save file dialog which lets the user select a file path and a file
  /// name to save a file.
  ///
  /// For mobile platforms, this function will save file with [bytes] to return a path.
  ///
  /// For desktop platforms (Linux, macOS & Windows),This function does not actually
  /// save a file. It only opens the dialog to let the user choose a location and
  /// file name. This function only returns the **path** to this (non-existing) file.
  ///
  /// [dialogTitle] can be set to display a custom title on desktop platforms.
  ///
  /// [fileName] can be set to a non-empty string to provide a default file
  /// name. Throws an `IllegalCharacterInFileNameException` under Windows if the
  /// given [fileName] contains forbidden characters.
  ///
  /// [initialDirectory] can be optionally set to an absolute path to specify
  /// where the dialog should open. Only supported on Linux, macOS, and Windows.
  ///
  /// The file type filter [type] defaults to [FileType.any]. Optionally,
  /// [allowedExtensions] might be provided (e.g. `[pdf, svg, jpg]`.). Both
  /// parameters are just a proposal to the user as the save file dialog does
  /// not enforce these restrictions.
  ///
  /// If [lockParentWindow] is set, the child window (file picker window) will
  /// stay in front of the Flutter window until it is closed (like a modal
  /// window). This parameter works only on Windows desktop.
  ///
  /// Returns `null` if aborted. Returns a [Future<String?>] which resolves to
  /// the absolute path of the selected file, if the user selected a file.
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      throw UnimplementedError('saveFile() has not been implemented.');
}
