# 鸿蒙原生 PoC 壳工程

验证「弦予音乐」移动端迁移 HarmonyOS NEXT 的两个最大不确定点：
Rust 交叉编译管线 与 播放插件链路。不动主工程任何代码。

## 前置条件

| 依赖 | 说明 |
|---|---|
| DevEco Studio 6+ | 含 HarmonyOS SDK（native/llvm + sysroot），登录华为开发者账号下载 |
| Flutter-OH | openharmony-sig/flutter_flutter 分支，`flutter --version` 需含 `ohos` 字样 |
| Rust + rustup | 本机已有；ohos target 由脚本自动 `rustup target add` |
| 鸿蒙真机 | NEXT 5.0+ 一台（模拟器亦可，音频链路建议真机） |

## 步骤

```powershell
# 1. 装配壳工程（生成 ohos/、拷贝 FRB 生成代码、打 module.json5 权限补丁、pub get）
./poc_ohos/scripts/setup.ps1

# 2. 交叉编译 Rust（SDK 自动探测；失败时 -SdkRoot 指定 SDK 根目录）
./poc_ohos/scripts/build-rust-ohos.ps1

# 3. 重跑 setup 完成 .so 拷贝（或手动拷到 poc_ohos/ohos/entry/libs/arm64-v8a/）
./poc_ohos/scripts/setup.ps1

# 4. DevEco Studio 打开 poc_ohos/ohos，File > Project Structure > Signing Configs
#    勾选 Automatically generate signature 完成调试签名

# 5. 运行
flutter devices
flutter run
```

## 验证项与判定

| # | 测试项 | 覆盖风险 | 通过标准 |
|---|---|---|---|
| 1 | FRB 加载与调用（hostSha256Hex） | .so 加载 + FRB 2.12 运行时 | 返回 64 位 hex |
| 2 | AMLL 歌词解析（parseLyrics） | 纯 Rust 计算栈 | 返回 JSON 含 displayLines |
| 3 | 网络栈（fetchAnnouncement） | reqwest+rustls+tokio+DNS on musl | 请求成功返回字节数 |
| 4 | QuickJS 插件引擎 | rquickjs 运行时 | 返回引擎 JSON（ok/error 均可，崩溃才算失败） |
| 5 | SQLite（rusqlite bundled） | C 交叉编译产物 + 读写 | 写入后读取往返一致 |
| 6 | just_audio（AVPlayer） | 播放内核适配 | 输入直链后能出声 |
| 7 | audio_service（AVSession） | 锁屏/播控中心/通知 | 通知栏出现播控卡片 |

## 已知说明

- FRB 2.12 loader 不识别 ohos 平台（抛 Unknown platform），`main.dart` 的
  `initRust()` 已做手动 `DynamicLibrary.open('libxianyu_core.so')` 兜底；
  升级 flutter_rust_bridge 2.13+ 后可移除。
- pubspec Dart 下限放宽到 3.9：Flutter-OH 3.41 稳定版 = Dart 3.11；
  主工程 ^3.12.2 需等 Flutter-OH 3.44 Release（路线图 2026-09）。
- FRB 生成代码在 setup 时从主工程 `lib/src/rust` 拷贝，勿在 PoC 内手工修改。

## 故障排查

- **pub get 解析失败（git 依赖）**：2026-06 起三方库陆续迁移至 AtomGit
  CPF-Flutter 组织，可将 pubspec 中的 `gitcode.com/openharmony-sig/...`
  换成 `atomgit.com/CPF-Flutter/...` 对应仓库；
  `just_audio_ohos` 若路径不存在（主包已内置 ohos 声明），直接删除该条目重试。
- **rquickjs/bindgen 编译失败**：缺 libclang。Windows：`winget install LLVM.LLVM`；
  脚本会自动探测 `C:\Program Files\LLVM\bin`。
- **找不到头文件**：确认 SDK `native/sysroot` 存在，必要时用 `-SdkRoot` 显式指定。
- **flutter create 不含 ohos 平台**：说明当前 flutter 不是鸿蒙分支。
- **pub get 时 git-lfs smudge 失败**：TPC 仓库 LFS 资源（仅 example 目录测试数据）下载易失败，
  设 `GIT_LFS_SKIP_SMUDGE=1` 后重跑（setup.ps1 已内置该环境变量）。
- **audio_session 双 ref 冲突 / path_provider 双源冲突**：pubspec 的 `dependency_overrides`
  已内置解决方案（audio_session 钉 br_v0.2.2_ohos；path_provider 走 openharmony-tpc git 源）。
- **ohos 实现位置**：just_audio 的 ohos 实现内嵌于主包（`ohos/` 子目录），
  audio_service 走 federated 子包 `audio_service_ohos`（主包已 endorsed），均无需单独引依赖。