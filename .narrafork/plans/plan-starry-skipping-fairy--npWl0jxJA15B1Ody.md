# 本地音乐扫描功能实现方案（定稿）

## 目标
1. 设置页新增「扫描文件夹」：自定义扫描目录（可多个，系统文件夹选择器）
2. 设置页新增「扫描格式」：主流音频格式多选，未选格式**不入库**
3. 音乐库 → 文件夹 Tab 下拉刷新触发扫描

## 用户已确认的决策
- 文件夹选择：系统文件夹选择器（file_picker）+ MANAGE_EXTERNAL_STORAGE 权限
- 目录存储：复用 SQLite `library_folders`；格式选择存 SharedPreferences
- 格式过滤：**改 Rust**，未选格式根本不写库（走到底，装工具链）

## 环境现状
- Rust: cargo 1.97 ✓；NDK 已装（27.1 / 28.2）✓
- 缺：`flutter_rust_bridge_codegen`、`cargo-ndk`、android rust targets
- 现有 .so：arm64-v8a, armeabi-v7a

---

## 阶段 A：工具链搭建
1. `dart pub global activate flutter_rust_bridge_codegen 2.12.0`（与 pubspec 版本一致）
2. `cargo install cargo-ndk`
3. `rustup target add aarch64-linux-android armv7-linux-androideabi`
4. 设 `ANDROID_NDK_HOME` 指向已装 NDK（如 .../ndk/27.1.12297006）

## 阶段 B：改 Rust（格式白名单，未选不入库）
文件：`rust/src/api/mod.rs`、`rust/src/music/scanner/*`、`rust/src/music/utils.rs`

设计：给扫描链路加**可选格式白名单**参数，为空/None 时保持原行为（全部支持格式）。
- `scan_music_folder(db_path, folder_path, minimum_duration_seconds, allowed_formats: Option<Vec<String>>)`
- `ScanOptions` 增加 `allowed_extensions: Option<HashSet<String>>` 字段
- 扫描时的扩展名判断：`is_supported_library_extension(ext) && (allowed.is_none() || allowed.contains(ext))`
  - 需要把 allowed 传进 `parser.rs` 的过滤点（第 248 行 `is_supported_library_extension` 附近）
- 同步给 `refresh_folder_songs` 也加该参数（下拉刷新走这条或 scan_music_folder，二选一，实现时统一）
- 格式名归一化：用户选 "m4a" 应同时覆盖 m4a/m4b；"ogg" 覆盖 ogg/oga；"aiff" 覆盖 aif/aiff；
  "mp4" 归 m4a 家族。UI 暴露主流大类，内部展开为扩展名集合。

主流格式 → 扩展名映射（UI 选项 → 实际扩展名）：
```
FLAC  → flac
MP3   → mp3
WAV   → wav
AAC   → aac
M4A   → m4a, m4b, mp4
OGG   → ogg, oga
AIFF  → aif, aiff
```

## 阶段 C：重新生成绑定 + 交叉编译
1. `flutter_rust_bridge_codegen generate`（注意 flutter_rust_bridge.yaml 里 rust_root 是绝对路径，
   指向旧机器 `D:\...`，**需临时改成当前项目 rust 目录**或用命令行参数覆盖）
2. `cargo ndk -t arm64-v8a -t armeabi-v7a -o android/app/src/main/jniLibs build --release`
   生成新的 libxianyu_core.so 覆盖 jniLibs
3. `cargo check` 先验证 Rust 编译通过

> 风险：codegen 的 yaml 绝对路径、交叉编译 linker 首次配置。若交叉编译受阻，
> 阶段 B 的 Rust 改动仍有效，可先 `cargo check` 确认逻辑，再逐步解决 NDK 编译。

## 阶段 D：Flutter 依赖 + 权限
- `pubspec.yaml`：`file_picker: ^8.1.0`、`permission_handler: ^11.3.0`
- `AndroidManifest.xml`（`<application>` 前）：
```xml
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
```

## 阶段 E：Flutter 状态与设置
- `settings.dart`：`AppSettings` 加 `scanFormats: List<String>`（默认全选 7 个大类），
  SharedPreferences `setStringList`
- 新增 `lib/src/library/scan_settings_provider.dart`：封装 SQLite 扫描目录
  - `scanFoldersProvider`（读 getLibraryFolders → path 列表）
  - `addFolder / removeFolder / refresh`

## 阶段 F：设置页 UI（settings_page.dart，"音乐库" section）
- 「扫描文件夹」`_tile` → 新页 `lib/pages/settings/scan_folders_page.dart`
  - 列表展示已加目录 + 删除
  - 「添加目录」：申请 MANAGE_EXTERNAL_STORAGE → `FilePicker.platform.getDirectoryPath()`
    → 校验真实路径（非 content://）→ `addLibraryFolder`
  - 权限被拒 / 返回 content URI 时给出提示（兜底：说明需授予所有文件访问权限）
- 「扫描格式」`_tile` → `showModalBottomSheet` 多选（7 个大类，勾选），存 scanFormats，
  trailing 显示已选数量

## 阶段 G：文件夹 Tab 下拉刷新扫描
- `library_page.dart` `_FoldersTab` 外包 `RefreshIndicator`
- `onRefresh` → `libraryProvider.notifier.scanAllFolders(formats, minDuration)`：
  1. 读 SQLite 所有扫描目录
  2. 把 scanFormats 大类展开为扩展名集合，作为白名单传给 `scanMusicFolder`
  3. 逐目录扫描（Rust 侧按白名单过滤，未选格式不入库）
  4. `load()` 刷新音乐库全量数据
  5. 完成 toast：扫描到 N 首
- 空目录时下拉提示「请先在设置中添加扫描目录」

## 验证
- `cargo check`（Rust 编译）
- `flutter analyze`（零问题）
- 逻辑走查：加目录 → 选格式 → 文件夹 Tab 下拉 → 扫描入库 → 列表刷新

## 涉及文件
- 工具链（全局安装，无仓库改动）
- `rust/src/api/mod.rs`、`rust/src/music/scanner/{orchestrator,parser}.rs`、`rust/src/music/utils.rs`
- `rust/src/frb_generated.*`、`lib/src/rust/*`（codegen 重新生成）
- `android/app/src/main/jniLibs/*/libxianyu_core.so`（重编译）
- `pubspec.yaml`、`android/app/src/main/AndroidManifest.xml`
- `lib/src/core/settings.dart`
- `lib/src/library/scan_settings_provider.dart`（新增）
- `lib/pages/settings/settings_page.dart`
- `lib/pages/settings/scan_folders_page.dart`（新增）
- `lib/src/library/library_provider.dart`
- `lib/pages/library/library_page.dart`

## 已知风险
1. codegen 的 `flutter_rust_bridge.yaml` 含旧机器绝对路径，需先修正
2. Android 交叉编译首次配置（NDK 环境变量、linker）
3. file_picker 在部分设备返回 content URI 而非真实路径 → 提供权限说明兜底
4. 重编译 .so 后需完整重装 App 才生效（非热重载）
