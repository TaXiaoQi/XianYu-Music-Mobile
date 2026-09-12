# 弦予音乐移动端 · IDEA 构建指南

在 IntelliJ IDEA / Android Studio 中构建与运行本项目的完整流程。

> 前提环境均已就绪，见下表。

| 项 | 路径 / 版本 |
|----|------------|
| Flutter SDK | `C:\flutter\sdk_tmp\flutter` |
| JDK | `D:\Program Files\Java\jdk-25.0.2`（JDK 25，兼容要求的 Java 17） |
| Android SDK | `C:\Users\小奇\AppData\Local\Android\Sdk` |
| Rust 工具链 | 仅改 Rust 代码时需要（rustHook 自动调用，见下） |

## Rust 自动编译（rustHook）

**无需任何手动步骤**：`flutter run` / `flutter build apk` 会自动带上 Rust（绑定 + `.so`）。
Gradle 的 `preBuild` 前会执行 `scripts/gradle-rust-hook.ps1`，按 Rust 源码状态自动处理：

| 场景 | 行为 |
|------|------|
| 只改 Dart（日常） | 钩子约 1 秒静默通过，不拖慢构建 |
| 改 Rust 内部逻辑 | 自动 `cargo ndk` 重编 `.so`，一次构建直接生效 |
| 改 Rust API（`rust/src/api/`） | 自动 `flutter_rust_bridge_codegen generate` 后**中止本次构建**，重跑一次 Run 即可 |

- 编译输出记录于 `build/rust-hook.log`，失败时自动打印尾部
- 环境变量 `XIANMU_SKIP_RUST=1` 可临时跳过钩子
- Rust 改动不会热重载，重编后需 `R` 热重启或重新 Run
- Windows 中文用户名路径会导致 NDK 链接失败；钩子已自动使用 ASCII 工具链拷贝（`D:\ascii-env\`）

## 步骤 1：打开项目并装插件

- IDEA（或 Android Studio）→ `Open` → 选根目录 `XianYu-Music-Mobile`（识别为 Flutter 项目）
- `Settings → Plugins`：安装 **Flutter** 和 **Dart** 插件，重启

## 步骤 2：配置 SDK

- `Settings → Languages & Frameworks → Flutter` → SDK path 填 Flutter SDK 路径
- `Settings → Languages & Frameworks → Dart` → 指向同一个 SDK
- `File → Project Structure → Project SDK` → 添加 JDK `D:\Program Files\Java\jdk-25.0.2`

## 步骤 3：拉依赖

终端里跑：

```bash
flutter pub get
```

## 步骤 4：Debug 运行

- 右上设备下拉选模拟器 / 真机 → 点绿色三角 `Run`（或 `main.dart` 右键 Run）
- 改了 Rust 代码也直接 Run，rustHook 自动重编（见上表）

## 步骤 5：Release 构建

```powershell
flutter build apk --release
```

一条命令完成全部发版动作（等价旧 build-release.ps1，脚本已移除）：

1. 版本号自动同步：`version.ts` → `pubspec.yaml` / `account_api.dart`（改版本只需改 `version.ts`）
2. Rust 由 rustHook 自动编译（见上表）
3. APK 自动归档到 `releases/弦予音乐_<版本>_arm64.apk`（约 16MB，arm64 + 混淆 + R8）
4. 混淆符号自动归档到 `releases/symbols/<版本>/app.symbols`（还原线上崩溃堆栈用）

> 版本同步仅 release 模式触发（debug 不受影响），`XIANMU_SKIP_VERSION_SYNC=1` 可跳过。

## 一句话总结

IDEA 里 **直接 Run 就行，Rust 全自动**；Release 直接 `flutter build apk --release`，发版动作全自动。

## FFmpeg 裁剪库（体积优化）

AAR 自带的完整 FFmpeg 7 个库约 18MB（未压缩），本工程改用**裁剪版**（`scripts/ffmpeg-trim/dist/arm64-v8a/`，约 4MB），已拷入
`android/app/src/main/jniLibs/arm64-v8a/`（jniLibs 优先级高于 AAR，同名即覆盖），**正常构建即可生效**，无需额外步骤。

裁剪保留能力（与两个工具页对齐）：

- 输入：mp3 / aac / m4a / flac / ogg / opus / wav / ape / wv / wma / aiff / mka
- 输出：mp3（lame）/ aac / m4a / flac / ogg（vorbis）/ opus / wma / wav
- 滤镜：`atrim/trim/asetpts/aresample/volume/atempo` 等（裁剪/变速/音量）
- 网络协议、音轨复制（`-c copy`）、封面/元数据保留

### 重建裁剪库（需 WSL）

仅当需要调整裁剪清单（增删编解码器/滤镜）时：

```powershell
# 前置（一次性）：
#  1. junction：NDK 与构建树路径必须全 ASCII（中文路径在 pkg-config→clang 链路会编码损坏）
#     New-Item -ItemType Junction -Path C:\ndk27 -Target <NDK 27.1.12297006 路径>
#     New-Item -ItemType Junction -Path C:\ffbuild -Target <构建树目标>
#  2. 源码包放 C:\ffbuild\src-dl\（ffmpeg-8.0.3 / lame-3.100 / opus-1.5.2 / libogg-1.3.5 / libvorbis-1.3.7）
wsl -e bash "/mnt/d/Program Files/XianYu-Music/XianYu-Music-Mobile/scripts/ffmpeg-trim/build-android.sh"
# 产物 → scripts/ffmpeg-trim/dist/arm64-v8a/*.so，拷入 jniLibs 覆盖
```

符号覆盖校验（新库须满足 libffmpegkit.so 的全部 FFmpeg 引用，否则运行时 dlopen 失败）：

```bash
bash scripts/ffmpeg-trim/check-symbols.sh <libffmpegkit.so路径> scripts/ffmpeg-trim/dist/arm64-v8a
```

> 已知坑：WSL 无外网时先在 Windows 下载源码包；FFmpeg configure 的 `TMPDIR` 必须指到 `/mnt/c`（默认 `/tmp` Windows clang 读不了）；依赖库链接需 `--extra-libs="-lm -logg -lvorbis"`；shim 的路径转换必须匹配带 `-I/-L` 前缀的参数。
