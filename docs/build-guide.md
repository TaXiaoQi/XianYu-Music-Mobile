# 弦予音乐移动端 · IDEA 构建指南

在 IntelliJ IDEA / Android Studio 中构建与运行本项目的完整流程。

> 前提环境均已就绪，见下表。

| 项 | 路径 / 版本 |
|----|------------|
| Flutter SDK | `C:\flutter\flutter`（`android/local.properties` 已配 `flutter.sdk`） |
| JDK | `D:\Program Files\Java\jdk-25.0.2`（JDK 25，兼容要求的 Java 17） |
| Android SDK | `C:\Users\小奇\AppData\Local\Android\sdk` |
| Rust 核心 `.so` | 已预编译在 `android/app/src/main/jniLibs/`（arm64-v8a / armeabi-v7a） |

> ⚠️ Debug 运行无需 Rust 工具链（用的是预编译 `.so`）。只有改 Rust 代码时才需要。

## 关键坑：中文路径

项目路径 `d:\Program Files\MC\开发端\开发组\弦予音乐\XianYu-Music-Mobile` 含中文：

- **Debug 构建（JIT）** → 中文路径可用 ✓
- **Release 构建（AOT）** → 会失败 ✗（`gen_snapshot` 无法读取含中文路径，见 flutter/flutter#149194），必须用 `scripts/build-release.ps1`

## 步骤 1：打开项目并装插件

- IDEA（或 Android Studio）→ `Open` → 选根目录 `XianYu-Music-Mobile`（识别为 Flutter 项目）
- `Settings → Plugins`：安装 **Flutter** 和 **Dart** 插件，重启

## 步骤 2：配置 SDK

- `Settings → Languages & Frameworks → Flutter` → SDK path 填 `C:\flutter\flutter`
- `Settings → Languages & Frameworks → Dart` → 指向同一个 SDK
- `File → Project Structure → Project SDK` → 添加 JDK `D:\Program Files\Java\jdk-25.0.2`

## 步骤 3：拉依赖

终端里跑：

```bash
flutter pub get
```

> 改过 Rust 侧 `api/` 公开签名才需要再跑 `flutter_rust_bridge_codegen generate`（需 Rust toolchain + git 在 PATH）。

## 步骤 4：Debug 运行（JIT，中文路径可用 ✓）

- 右上设备下拉选模拟器 / 真机 → 点绿色三角 `Run`（或 `main.dart` 右键 Run）
- Debug 是 JIT 模式，不受中文路径影响，直接跑

## 步骤 5：Release 构建（⚠️ 不能直接在中文路径下 build）

**不要在 IDEA 里直接 `flutter build apk --release`** —— `gen_snapshot` 的 AOT 快照生成器无法读取含中文的路径，会编译失败。

用项目自带脚本，它会先 robocopy 到 ASCII 路径再构建：

```powershell
./scripts/build-release.ps1
# 产物：releases/弦予音乐_1.0.0_arm64.apk（约 14MB，按 ABI 拆包）
```

IDEA 终端里也能直接调这个脚本。脚本逻辑：

1. robocopy 源码到 `D:\build\XianYuMusicSrc`（ASCII 路径）
2. 在该目录执行 `flutter build apk --release --split-per-abi`
3. 将 arm64 单架构 APK 复制到 `releases/`

## 改了 Rust 代码怎么办

Debug 用的是预编译的 `.so`，改 Rust 后要让 Debug 也生效：

1. 需要 Rust toolchain（stable）+ `cargo` 在 PATH
2. `cd rust && cargo build --target aarch64-linux-android`（或对应 ABI），把产物 `.so` 复制到 `android/app/src/main/jniLibs/<abi>/` 替换
3. 改了 `rust/src/api/` 的公开签名 → 跑 `flutter_rust_bridge_codegen generate` 更新 `lib/src/rust/` 下的 Dart 绑定
4. 重新 `Run`

## 一句话总结

IDEA 里 **Debug 直接 Run 就行；Release 走 `scripts/build-release.ps1`，别在中文路径下硬 build。**
