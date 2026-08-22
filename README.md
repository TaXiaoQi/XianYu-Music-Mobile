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

  - **液态玻璃质感**：自研液态玻璃着色器，半透明磨砂设计与系统环境自然融合。
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
| **Flutter** | `3.47.0+`（Dart `3.13.0`） |
| **Android SDK + NDK** | API 36 编译，NDK r27+ |
| **Rust** | Stable 稳定版 + `cargo ndk`（构建钩子自动调用） |
| **操作系统** | Windows 10 / 11（构建钩子为 PowerShell 脚本） |

### 运行与构建步骤

1. 克隆本仓库：

  ```bash
  git clone https://github.com/TaXiaoQi/XianYu-Music-Mobile.git
  cd XianYu-Music-Mobile
  ```

2. 安装依赖并连接设备（真机开启 USB 调试，`flutter devices` 确认识别）：

  ```bash
  flutter pub get
  ```

3. 开发调试运行（热重载 `r` / 热重启 `R`）：

  ```bash
  flutter run
  ```

4. 构建 Release 正式安装包：

   ```bash
   flutter build apk --release
   ```

   一条命令完成全部发版动作（等价旧 build-release.ps1，脚本已移除）：
   - **版本号自动同步**：`version.ts` → `pubspec.yaml` / `account_api.dart`（改版本只需改 `version.ts`）
   - 产物自动归档到 `releases/弦予音乐_<版本>_arm64.apk`（约 17MB，arm64 单架构 + Dart 混淆 + R8 收缩 + .so 压缩，Rust 亦自动编译）
   - 混淆符号自动归档到 `releases/symbols/<版本>/app.symbols`（`flutter symbolize -d` 还原线上崩溃堆栈用）

> **Rust 自动编译**：以上任意 `flutter run` / `flutter build` 命令均会自动检测并编译 Rust（绑定 + `.so`）——改内部逻辑直接生效；改 API 时首次构建会中止，重跑一次命令即可。`XIANMU_SKIP_RUST=1` 可跳过。
>
> 版本号同步仅在 release 模式触发（debug 不受影响），`XIANMU_SKIP_VERSION_SYNC=1` 可跳过。

---

*更新日期：2026-08-22*
