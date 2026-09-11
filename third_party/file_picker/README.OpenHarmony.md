> Template version: v0.4.1

<p align="center">
  <h1 align="center"> <code>file_picker</code> </h1>
</p>

This project is based on [file_picker](https://pub.dev/packages/file_picker).

## Introduction

A package that allows you to use the native file explorer to pick single or multiple files, with extensions filtering support.

## Installation

Add the dependency in `pubspec.yaml`:

```yaml
dependencies:
  file_picker_ohos:
    git:
      url: https://gitcode.com/CPF-Flutter/fluttertpc_file_picker.git
      # ref: 10.3.8-ohos-1.0.0
      ref: x.x.x-ohos-x.x.x # Please select the TAG to the TAG Version Mapping
```

Execute Command:

```bash
flutter pub get
```

#### TAG Version Mapping

| Flutter Framework Version | TAG                      | Branch |
|---------------------------|--------------------------|--------|
| 3.7                       | 10.2.0-ohos-1.0.0-beta.1 | [br_v10.2.0_ohos](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/tree/br_v10.2.0_ohos) |
| 3.22                      | 10.2.0-ohos-1.0.0-beta.1 | [br_v10.2.0_ohos](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/tree/br_v10.2.0_ohos) |
| 3.27                      | 10.2.0-ohos-1.0.0-beta.1 | [br_v10.2.0_ohos](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/tree/br_v10.2.0_ohos) |
| 3.35                      | 10.3.8-ohos-1.0.0        | [br_v10.3.8_ohos](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/tree/br_v10.3.8_ohos) |

> Note: If your project targets Android, iOS, and OpenHarmony at the same time, make sure dependency sources are aligned across platforms. Do not mix in package versions that do not include OpenHarmony adaptation.

## Constraints and Limits

### Compatibility

Validated with the following environments:

1. Flutter: 3.7.12-ohos-1.0.6; SDK: 5.0.0(12); IDE: DevEco Studio: 5.0.13.200; ROM: 5.1.0.120 SP3;
2. Flutter: 3.22.1-ohos-1.0.1; SDK: 5.0.0(12); IDE: DevEco Studio: 5.0.13.200; ROM: 5.1.0.120 SP3;
3. Flutter: 3.27.5-ohos-0.0.1; SDK: 5.0.0(12); IDE: DevEco Studio: 5.1.0.828; ROM: 5.1.0.130 SP8;
4. Flutter: 3.35.7-ohos-0.0.1; SDK: 6.0.1(21); IDE: DevEco Studio: 6.0.1.260; ROM: 6.0.0.120 SP6;

### Permission Requirements

None.

## Usage Example

```dart
import 'package:file_picker_ohos/file_picker_ohos.dart';
import 'package:flutter/foundation.dart';

Future<void> pickSingleImage() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    allowMultiple: false,
    type: FileType.custom,
    allowedExtensions: ['jpg', 'png'],
  );

  if (result == null) {
    return; // User canceled the dialog
  }

  final PlatformFile pickedFile = result.files.single;
}
```

Refer to [ohos/example](/example/lib/main.dart) for a runnable sample.

## Usage Guide

**Single file**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles();

if (result != null) {
  File file = File(result.files.single.path!);
} else {
  // User canceled the picker
}
```

**Multiple files**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);

if (result != null) {
  List<File> files = result.paths.map((path) => File(path!)).toList();
} else {
  // User canceled the picker
}
```

**Multiple files with extension filter**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles(
  allowMultiple: true,
  type: FileType.custom,
  allowedExtensions: ['jpg', 'pdf', 'doc'],
);
```

**Pick a directory**
```dart
String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

if (selectedDirectory == null) {
  // User canceled the picker
}
```

**Save-file / save-as dialog**

```dart
String? outputFile = await FilePicker.platform.saveFile(
  dialogTitle: 'Please select an output file:',
  fileName: 'output-file.pdf',
);

if (outputFile == null) {
  // User canceled the picker
}
```

**Load result and file details**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles();

if (result != null) {
  PlatformFile file = result.files.first;

  print(file.name);
  print(file.bytes);
  print(file.size);
  print(file.extension);
  print(file.path);
} else {
  // User canceled the picker
}
```

**Retrieve all files as XFiles or individually**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles();

if (result != null) {
  // All files
  List<XFile> xFiles = result.xFiles;

  // Individually
  XFile xFile = result.files.first.xFile;
} else {
  // User canceled the picker
}
```

**Clear temporary files**

```dart
final bool? cleaned = await FilePicker.platform.clearTemporaryFiles();
```


## Available APIs

> [!TIP] If the value of **OpenHarmony Support** is **yes**, it means that the ohos platform supports this property; **no** means the opposite; **partially** means some capabilities of this property are supported. The usage method is the same on different platforms and the effect is the same as that of iOS or Android.


### API

| Name                | Description                                                                                                                                                                                                                           | Type     | Input                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Output                    | OpenHarmony Support |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------|--------------|
| pickFiles           | This is the main method to pick files and provides all the properties mentioned before                                                                                                                                                | function | String ?   dialogTitle , String ?   initialDirectory ,      FileType   type   =   FileType . any ,      List < String > ?   allowedExtensions ,      Function ( FilePickerStatus ) ?   onFileLoading ,      bool   allowCompression   =   true ,      int   compressionQuality   =   30 ,      bool   allowMultiple   =   false ,      bool   withData   =   false ,      bool   withReadStream   =   false ,      bool   lockParentWindow   =   false ,      bool   readSequential   =   false | Future<FilePickerResult?> | yes          |
| getDirectoryPath    | Opens a folder picker dialog which lets the user select a directory path. Returns the absolute path to the selected directory. Returns null, if the user canceled the dialog or if the folder path couldn't be resolved               | function | String ?   dialogTitle ,      bool   lockParentWindow   =   false ,      String ?   initialDirectory                                                                                                                                                                                                                                                                                                                                                                                            | Future<String?>           | yes          |
| pickFileAndDirectoryPaths  | Picking both files and directories simultaneously|function |FileType type = FileType.any, List<String>? allowedExtensions, String? initialDirectory | Future<List<String?>      | no| 
| clearTemporaryFiles | An utility method that will explicitly prune cached files from the picker. This is not required as the system will take care on its own, however, sometimes you may want to remove them, specially if your app handles a lot of files | function | /                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Future<bool?>             | yes          |
| saveFile            | Opens a save-file / save-as dialog which lets the user select a file path and a file name to save a file                                                                                                                              | function | String ?   dialogTitle ,      String ?   fileName ,      String ?   initialDirectory ,      FileType   type   =   FileType . any ,      List < String > ?   allowedExtensions ,      Uint8List ?   bytes ,      bool   lockParentWindow   =   false                                                                                                                                                                                                                                             | Future<String?>           | yes          |


### Properties

#### FileType

| Name            | Description                                                                        | Type | Input | Output | OpenHarmony Support |
|-----------------|------------------------------------------------------------------------------------|------|-------|--------|--------------|
| FileType.any    | Will let you pick all available files                                              | enum | /     | /      | yes          |
| FileType.custom | Will let you pick a path for the extension matching the allowedExtensions provided | enum | /     | /      | yes          |
| FileType.image  | Will let you pick an image file                                                    | enum | /     | /      | yes          |
| FileType.video  | Will let you pick a video file                                                     | enum | /     | /      | yes          |
| FileType.media  | Will let you pick either video or images                                           | enum | /     | /      | yes          |
| FileType.audio  | Will let you pick an audio file                                                    | enum | /     | /      | yes          |

#### PickFilesOptions

| Name               | Description                                                                                                                                                                         | Type                        | Input            | Output | OpenHarmony Support |
|--------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------|------------------|--------|--------------|
| allowedExtensions  | Accepts a list of allowed extensions to be filtered                                                                                                                                 | List?                       | /                | /      | yes          |
| dialogTitle        | The title to be set on desktop platforms modal dialog. Hasn't any effect on Web or Mobile                                                                                           | String?                     | /                | /      | no           |
| initialDirectory   | Can be optionally set to an absolute path to specify where the dialog should open                                                                                                   | String?                     | /                | /      | no           |
| withData           | Sets if the file should be immediately loaded into memory and available as Uint8List on its PlatformFile instance                                                                   | bool?                       | /                | /      | yes          |
| compressionQuality | Defines the compression quality percentage to use when compressing images. This value ranges from 0 (no compression) to 100                                                         | int?                        | /                | /      | no           |
| withReadStream     | Allows the file to be read into a Stream> instead of immediately loading it into memory, to prevent high usage, specially with bigger files                                         | bool?                       | /                | /      | no           |
| lockParentWindow   | If true, then the child window (file picker window) will stay in front of the Flutter window until it is closed (like a modal window)                                               | bool?                       | /                | /      | no           |
| type               | Defines the type of the filtered files                                                                                                                                              | FileType                    | /                | /      | yes          |
| onFileLoading      | When provided, will receive the processing status of picked files. This is particularly useful if you want to display a loading dialog or so when files are being downloaded/cached | Function(FilePickerStatus)? | FilePickerStatus | void   | no           |

## Known Issues

- [ ] ohos file picker selectMode setting does not work for folder
  selection: [issue#14](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/14).
- [ ] When using flutter version 3.27 to reference this third-party library, you need to set a mandatory dependency on win32: ^5.0.0 in the project 'pubspec.yaml' file.

## FAQ

1. `The current platform "ohos" is not supported by this plugin` is thrown.
   - Make sure you are using `file_picker_ohos` and importing `import 'package:file_picker_ohos/file_picker_ohos.dart';`.
   - Related issue: [#23](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/23).
2. Unclear how to integrate this plugin in a multi-platform project.
   - First verify OpenHarmony dependency points to the `ohos` subdirectory in this repository, then align dependency versions for other platforms.
   - Related issues: [#16](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/16), [#26](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/26).
3. Directory selection behavior is different from expectation.
   - Some directory-mode capabilities are limited by device form factors. Validate on target hardware first.
   - Related issue: [#14](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/14).
4. `saveFile` throws `PlatformException(13900019, Is a directory, null, null)`.
   - Ensure a valid file name is provided and avoid passing a directory as a file path. If needed, retry without `initialDirectory`.
   - Related issue: [#33](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/33).

## Directory Structure

```text
fluttertpc_file_picker/
|- lib/                       # Shared plugin implementation and platform-agnostic interfaces
|- ohos/
|  |- lib/                    # OpenHarmony adaptation Dart layer
|  |- ohos/                   # OpenHarmony project and native-side implementation
|  |- example/                # OpenHarmony sample application
|- example/                   # Multi-platform sample application
|- android/                   # Android native implementation
|- ios/                       # iOS native implementation
|- test/                      # Dart unit tests
|- README.OpenHarmony_CN.md   # Chinese documentation
|- README.OpenHarmony.md      # English documentation
```

## How to Contribute

If you find any problem when using file_picker, submit an [issue](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues) or a [PR](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/pulls).

## License

This project is licensed under the [MIT License](/LICENSE).
