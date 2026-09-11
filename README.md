
<div align="center">
  <img src="logo.png" width="120" height="120" alt="XianYu Logo" style="border-radius: 24px; box-shadow: 0 8px 24px rgba(0,0,0,0.15);" />

# 弦予音乐 · 移动端
## (XianYu-Music-Mobile)

弦予音乐的移动端。基于 **Flutter + Rust** 跨平台架构，Rust 核心（`xianyu_core`）与桌面端同源复用，通过 [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 桥接，提供专业级音频播放与音效体验。

 [](https://flutter.dev/)
 [](https://www.rust-lang.org/)
 [](https://dart.dev/)

[](./LICENSE)

</div>

## ✨ 功能亮点

- 🎨 **高颜值液态玻璃 UI**

  - **液态玻璃质感**：自研液态玻璃着色器，半透明磨砂设计与系统环境自然融合（鸿蒙端受引擎限制降级为毛玻璃，见「鸿蒙平台差异说明」）。
  - **Material 3 动态取色**：支持浅色 / 暗色 / 跟随系统，主题强调色可自定义（默认网易云红 `#EC4141`）。
  - **沉浸式播放页**：封面液态网格渐变背景随曲目色彩动态演变，实时频谱可视化。

- 🎧 **专业音频引擎**

  - **全格式解码**：基于 `symphonia`，支持 MP3 / FLAC / AAC / ALAC / OGG / Vorbis / WAV / AIFF。
  - **QMC2 解密**：内置加密格式解密，在线加密资源直接播放。
  - **USB 独占输出**：Android 端 AAudio `EXCLUSIVE` 模式直连 USB DAC，绕过系统混音器，bit-perfect 输出。

- 🎚️ **全 Rust 音效 DSP**

  - **完整音效链**：响度归一化 → 10 段 EQ → 音效 → 音量 → 限幅，独占 / 共享模式管线一致。
  - **30+ 音效**：FFT 卷积混响、常数功率交叉淡入、变速不变调（OLA 相位声码器）、3D / 8D / 36D 环绕等。
  - **实时频谱**：环形缓冲 + 4096 点 FFT + 时间平滑，低开销高帧率。

- 📱 **平台原生体验**

  - **原生手势**：Android Predictive Back 预测性返回、下拉返回等系统级手势与转场，不做自绘转场，省电且跟手。
  - **后台播放**：系统媒体通知 + 锁屏控制，后台稳定续航。
  - **本地音乐库**：`rayon` 并行扫描、标签解析、封面提取与调色板、增量差异更新。

- 🌐 **在线与云端**

  - **双格式插件**：兼容 MusicFree / LX 落雪插件，QuickJS 沙箱执行，HTTP 请求经 Rust 代理无 CORS 限制。
  - **云端同步**：歌单 / 收藏 / 插件 / 设置多端同步，自动同步调度。
  - **WebDAV 远程音源**：远程曲库扫描、LRU 缓存、流式播放。
  - **歌词**：QRC / LYS / YRC 逐字歌词，AMLL 风格渲染，本地缓存 + 远程获取。

- 📦 **极致体积**

  - 安装包仅 **~17MB**：`.so` 包内压缩 + Dart AOT 混淆 + R8 收缩 + thin LTO，安装时自动解压。

---

## 🛠️ 使用源码构建运行

### 环境要求

| 依赖项 | 推荐版本 / 要求 |
| --- | --- |
| **Flutter** | `3.47.0+`（Dart `3.13.0`，三平台通用） |
| **Rust** | Stable 稳定版 + `cargo ndk`（构建钩子自动调用） |

各平台额外要求：

| 平台 | 操作系统 | 平台依赖 |
| --- | --- | --- |
| **Android** | Windows 10 / 11（构建钩子为 PowerShell 脚本） | Android SDK + NDK（API 36 编译，NDK r27+）；真机开启 USB 调试，`flutter devices` 确认识别 |
| **iOS** | macOS（需 Xcode） | Rust `aarch64-apple-ios` / `aarch64-apple-ios-sim` 工具链、CocoaPods；真机调试需在 Xcode 选择开发团队 |
| **鸿蒙** | Windows 10 / 11 | DevEco Studio 6+（含 HarmonyOS SDK + hdc）、Flutter-OH 分支（OpenHarmony SIG 维护的 Flutter fork，`scripts/ohos/env-ohos.ps1` 绑定工具链）、Rust `aarch64-unknown-linux-ohos` / `x86_64-unknown-linux-ohos`（musl std，`rustup target add`）；签名材料由 DevEco「自动生成签名」落盘 |

### 运行与调试

1. 克隆本仓库并安装依赖：

  ```bash
  git clone https://github.com/TaXiaoQi/XianYu-Music-Mobile.git
  cd XianYu-Music-Mobile
  flutter pub get
  ```

2. Android 开发调试（热重载 `r` / 热重启 `R`）：

  ```powershell
  .\scripts\dev.ps1   # 包装脚本：先同步版本号并编译 Rust，再 flutter run
  # 或直接：
  flutter run
  ```

  > **改完代码怎么传递一句话记住**：`run` 进程还在就只在 run 终端按 `r`（热重载）或 `R`（热重启）直接传新构建，**不用每次全量 `flutter build`**；只有当 `run` 终端被关 / 进程退了才需要重新 `flutter run`。改的都是 Dart 业务代码（含新增 import、State、Ticker 等）时 `r`/`R` 都能覆盖，无需整包重装。改了 Rust 代码则不走热重载，重编后需 `R` 热重启或重新 Run。

3. 鸿蒙构建 / 调试（统一走 `scripts/ohos/build-ohos.ps1`，**代码始终在主工程改**）：

  ```powershell
  .\scripts\ohos\build-ohos.ps1 -Run -d 127.0.0.1:5555    # run 调试（热重载 r / 热重启 R）
  .\scripts\ohos\build-ohos.ps1 -SkipRust                 # 只改 Dart/ets 时快速出 HAP
  .\scripts\ohos\build-ohos.ps1                           # 完整构建（自动编 Rust）
  .\scripts\ohos\build-ohos.ps1 -Codegen                  # 改了 Rust API 签名时，强制 FRB 再生成
  ```

  > **镜像机制（为什么不能直接在主工程构建）**：主工程路径含空格（`Program Files`），ohpm/hvigor 会崩溃。脚本自动把源码同步到同盘无空格镜像目录（默认 `D:\xianyu-mobile-ohos`，`XIANYU_OHOS_MIRROR` 可覆盖）并在镜像内完成依赖解析与打包；Rust/FRB 仍在主工程执行，产物回填镜像。**主工程 `ohos/` 是唯一事实源**（含签名材料），镜像内 `ohos/` 仅承接构建。
  >
  > 参数：`-Abi x64|arm64` 显式指定 CPU 架构（不传自动探测在线设备；模拟器是 x86_64，真机是 arm64）；`-Device` 等其余参数透传给 flutter。产物在镜像目录 `build\ohos\hap\entry-default-signed.hap`，装机：`hdc install -r <HAP>`。
  >
  > **注意：构建期间必须完全关闭 DevEco Studio**——它会对镜像工程做 ohpm 重装（用未打补丁的 embedding 实例导致编译失败）并回写 `build-profile.json5`（清掉签名材料），与构建脚本互相破坏。

> **Rust 自动编译**：以上任意 `flutter run` / `flutter build` 命令均会自动检测并编译 Rust（绑定 + `.so` / `.framework`）——改内部逻辑直接生效；改 API 时首次构建会中止，重跑一次命令即可。`XIANMU_SKIP_RUST=1` 可跳过。
>
> 版本号同步（`version.ts` → `pubspec.yaml` / `account_api.dart`）仅在 release 模式触发（debug 不受影响），`XIANMU_SKIP_VERSION_SYNC=1` 可跳过。

### 构建各平台安装包

> Flutter 无法跨平台出包：Android 包建议在 Windows 上构建（Rust 构建钩子为 PowerShell 脚本），iOS 包需在 macOS 上构建（Rust 构建钩子为 bash 脚本 `scripts/ios-rust-hook.sh`，Windows/Linux 上自动放行，不影响 Android 构建）。

#### Android（.apk）

```bash
flutter build apk --release
```

一条命令完成全部发版动作（等价旧 build-release.ps1，脚本已移除）：

- **版本号自动同步**：`version.ts` → `pubspec.yaml` / `account_api.dart`（改版本只需改 `version.ts`）
- 产物自动归档到 `releases/弦予音乐_<版本>_arm64.apk`（约 17MB，arm64 单架构 + Dart 混淆 + R8 收缩 + .so 压缩，Rust 亦自动编译）
- 混淆符号自动归档到 `releases/symbols/<版本>/app.symbols`（`flutter symbolize -d` 还原线上崩溃堆栈用）

#### iOS（Xcode 归档 / .ipa）

前置：`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`，然后 `cd ios && pod install && cd ..`（pod 注册 `xianyu_core` 本地 pod，编译前自动重编 Rust 动态框架，与 Android 的 gradle rustHook 机制对齐）。

```bash
flutter build ios --release --no-codesign
```

未签名校验构建，归档 / 签名走 Xcode；Rust 产物 `ios/Frameworks/xianyu_core.framework`（动态框架）会按当前 SDK（真机/模拟器）自动编译并更新，`XIANMU_SKIP_RUST=1` 同样可跳过。真机构建需在 Xcode 中为 **Runner** 与 **XianYuWidget** 两个 target 选择开发团队（Bundle ID 分别为 `cc.xymusic.mobile` / `cc.xymusic.mobile.XianYuWidget`）。

**iOS 平台差异说明**（Android 专属功能在 iOS 上隐藏入口）：
   - 下载固定保存到应用 Documents/Downloads（「文件」App → 弦予音乐 可访问），无自定义下载目录
   - 悬浮歌词窗、状态栏歌词（车机歌词）、本地文件夹扫描、应用内更新为 Android 专属
   - 分享走系统分享面板；`xianyu://` 分享深链已支持（Safari/扫码等场景拉起 App）
   - QQ 直分享（QQ 好友音乐卡片 + QQ 空间网页卡片）已支持，与 Android 同一入口：
     Universal Link 关联域 `api.xianyumusic.cn/qq_conn/{app_id}/`，三处必须一致
     （`qq_share_service.universalLink`、`pubspec.yaml tencent_kit.universal_link`、
     QQ 互联后台登记值）；AASA 文件由服务端 `/.well-known/apple-app-site-association`
     路由托管；关联域签名需付费开发者账号，pod install 时 tencent_setup.rb 自动
     注入 URL Scheme/查询白名单/ATS/entitlements
   - 桌面小组件（WidgetKit）+ 锁屏/灵动岛歌词（Live Activity）已支持：需 iOS 16.1+，
     小组件/锁屏交互按钮需 iOS 17+（低版本自动回落 `xianyu://play/*` 深链）；
     数据经 App Group（`group.cc.xymusic.mobile`）共享，真机签名时 Xcode 自动管理即可

#### 鸿蒙（.hap）

前置：安装 DevEco Studio 6+ 并完成一次「自动生成签名」（签名四件套落盘 `~/.ohos/config`，Bundle name 为正式包名 `com.xianyumusic.app`）；Rust 工具链 `rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos`。构建命令见上文「运行与调试」第 3 步（同一条 `build-ohos.ps1`，run 与出包共用）。

```powershell
.\scripts\ohos\build-ohos.ps1 --release    # release HAP（--release 透传给 flutter build hap）
```

- 构建全流程自动化：版本同步 → FRB codegen（按需）→ 镜像同步 → 依赖覆盖（`scripts/ohos/pubspec-ohos-overrides.yaml`）→ Rust 双架构 `.so` → hvigor 打包签名
- 第三方插件鸿蒙适配：`shared_preferences` / `file_picker` 等走 openharmony-tpc 社区版本或 vendor 改造（`third_party/file_picker`），由 overrides 模板统一注入
- 签名/证书变更一律回主工程 `ohos/` 修改（或 DevEco 里直接对主工程签名，注意别开着构建）

**鸿蒙平台差异说明**（受 HarmonyOS NEXT 沙盒与 Flutter-OH 引擎能力限制）：
   - 下载固定保存到应用沙盒 Documents/Downloads，无自定义下载目录（与 iOS 同策略），下载完成自动扫描入库
   - 本地库为沙盒库模式：首访预置沙盒 Downloads/Music 目录，支持系统文件选择器导入音频（「+」入口）；无任意目录扫描（同 iOS）

**⚠️ 鸿蒙引擎 Impeller 缺失说明**：

Flutter 官方引擎在 Android/iOS 上默认启用新一代渲染引擎 **Impeller**，而 OpenHarmony SIG 维护的 Flutter-OH fork 目前**只编译了 Skia 后端，Impeller 后端完全缺失**（对引擎产物做符号核验：x86_64 debug 与 arm64-v8a release 的 `libflutter.so` 中 `impeller::` / `ImpellerOpenGLES` / `ImpellerVulkan` 符号均不存在；`buildinfo.json5` 的 `enable_impeller` 开关通道已预留，但底层无实现可启用）。

受影响的功能：

   - **液态玻璃**：核心折射效果依赖 `ui.ImageFilter.shader`（把自定义 fragment shader 挂进 BackdropFilter，Impeller 专属 API，非 Impeller 后端调用会抛 `UnsupportedError`）。`liquid_glass_widgets` 启动时通过 `ui.ImageFilter.isShaderFilterSupported`（实现即 `_impellerEnabled`）静态探测，鸿蒙上探测结果为 false，自动强制降级到 `GlassQuality.minimal`（纯 BackdropFilter，零 shader 成本）。因此鸿蒙上液态玻璃**开关可开、悬浮底栏联动正常，但无液态折射效果，呈现为普通毛玻璃**——这是自动降级在工作，非功能故障。
   - 毛玻璃（BackdropFilter / `ImageFilter.blur`）走 Skia，不受影响，全量可用。

恢复条件：待 Flutter-OH SIG 编出 OHOS Impeller 后端后，同一份代码**无需任何改动**即自动恢复液态效果（组件探测通过即走完整 shader 路径）。可用 `hdc shell hilog | grep -i impeller` 或引擎二进制符号核验跟踪引擎支持进展。

---

*更新日期：2026-09-11*
