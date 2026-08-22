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
./scripts/build-release.ps1
# 产物：releases/弦予音乐_<version>_arm64.apk（约 14MB，按 ABI 拆包）
```

脚本逻辑：

1. robocopy 源码到 `D:\build\XianYuMusicSrc`（ASCII 路径，规避 `gen_snapshot` 对非 ASCII 路径的兼容问题）
2. 在该目录执行 `flutter build apk --release --split-per-abi`（Rust 部分同样由 rustHook 自动处理）
3. 将 arm64 单架构 APK 复制到 `releases/`

## 一句话总结

IDEA 里 **直接 Run 就行，Rust 全自动**；Release 走 `./scripts/build-release.ps1`。
