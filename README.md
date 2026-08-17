# 弦予音乐 · 移动端（XianYu-Music-Mobile）

弦予音乐的移动端，基于 **Flutter + Rust** 跨平台架构。Rust 核心（`xianyu_core`）从桌面端抽取为纯逻辑库（不依赖 Tauri），通过 [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 暴露给 Flutter 调用，实现音频解码、DSP 处理、音乐库管理、USB 独占播放等能力跨平台复用。

> 仓库：`github.com/TaXiaoQi/XianYu-Music-Mobile`  
> 版本：`1.0.0+1` · Rust 核心 `0.1.0` · 许可证 `AGPL-3.0-only`

## 技术栈

| 层 | 技术 |
|----|------|
| UI | Flutter 3.47.0 + Dart 3.13.0、`go_router`、`flutter_riverpod`、`just_audio` |
| 跨语言桥接 | flutter_rust_bridge 2.12.0（生成 Dart 绑定） |
| Rust 核心 | `serde`、`symphonia`（解码）、`rustfft`（FFT）、`rusqlite`（bundled）、`reqwest`（rustls-tls，无 OpenSSL 依赖）、`rayon`（并行）、`tokio` |
| 音频 I/O | 共享模式 `just_audio`；Android 独占模式 AAudio（FFI 动态加载 `libaaudio.so`） |
| 平台 | Android（主）/ iOS / 桌面（Windows/macOS/Linux 兜底） |

## 功能特性

### Rust 核心（`rust/`）
- **音频解码**：基于 `symphonia`，支持 MP3/FLAC/AAC/ALAC/OGG/Vorbis/WAV/AIFF 等格式
- **QMC2 解密**：内置 QMC2 加密格式解密，支持在线加密资源播放
- **DSP 音效链**：解码 → 响度归一化 → 均衡器(EQ) → 音效 → 音量 → 限幅，独占/共享模式管线一致
  - **FFT 卷积混响**（`sound_effect/convolver.rs`）：均匀分块重叠相加（uniform partitioned overlap-add）算法
  - **交叉淡入 / Gapless**（`crossfade.rs`）：常数功率交叉淡入（cos/sin 归一化增益）
  - **实时频谱**（`spectrum.rs`）：环形缓冲 + 4096 点 FFT + 时间平滑（30ms 上升 / 180ms 释放）
  - **变速保持音调**（`pitch.rs`）：OLA 相位声码器时间拉伸
  - 动态、调制、塑形、空间等效果模块
- **USB 独占播放**（`player/output/`）：Android 端 AAudio `AAUDIO_SHARING_MODE_EXCLUSIVE`，绕过混音器直连 USB DAC，bit-perfect 输出；非 Android 返回不支持错误
- **音乐库**：`rayon` 并行扫描、`id3`/`lofty` 标签解析、封面提取与调色板、增量差异更新
- **歌词**：支持 QRC/LYS/YRC 多种格式，经 `amll-lyric` 渲染；本地缓存 + 远程获取
- **WebDAV 远程**：远程音乐库扫描、缓存、流式播放
- **数据库**：`rusqlite`（bundled），含迁移、schema 自检、自动补列、本地缓存降级
- **统计 / 插件 / 识别**等工具模块
- **安全**：路径校验器，防止越权访问

### Flutter UI（`lib/`）
- 底部导航 5 入口（规划）：主界面 / 音乐库 / 音效 / 搜索 / 设置
- 页面：音乐库（全部/歌手/专辑/文件夹 4 Tab）、播放器、收藏、最近、设置、账号
- 迷你播放条、歌曲列表、通用组件
- Material 3 动态取色，支持浅色/暗色/跟随系统，主题强调色可自定义
- 移动端主页重构方向：融合桌面版风格（网易云红 `#EC4141` + 毛玻璃）与 RawS 布局，详见 [`docs/mobile-home-design.md`](docs/mobile-home-design.md)

## 项目结构

```
XianYu-Music-Mobile/
├── lib/                          # Flutter 侧
│   ├── app.dart / main.dart      # 应用入口、主题与路由装配
│   ├── pages/                    # 页面：library / player / favorites / recent / settings / account
│   └── src/
│       ├── auth/                 # 账号认证状态
│       ├── core/                 # db 路径、Rust 初始化、设置持久化
│       ├── library/              # 音乐库状态
│       ├── navigation/           # 路由定义、AppShell 底栏
│       ├── player/               # 播放状态
│       ├── rust/                 # flutter_rust_bridge 生成的 Dart 绑定（frb_generated.*）
│       └── widgets/              # 迷你播放条、歌曲列表等通用组件
├── rust/                         # Rust 核心（crate: xianyu_core）
│   └── src/
│       ├── api/                  # 暴露给 Flutter 的 API（FRB 入口）
│       ├── database/             # SQLite：迁移 / schema / 状态 / 重置
│       ├── music/                # 扫描 / 标签 / 封面 / 调色板 / 歌词 / WebDAV / URL 解析
│       │   └── scanner/          # 并行扫描：编排 / 解析 / 差异 / 进度 / 仓储
│       ├── player/               # 音频播放核心
│       │   ├── output/           # 跨平台输出 + Android AAudio 独占
│       │   └── sound_effect/     # EQ / 卷积混响 / 动态 / 调制 / 塑形 / 空间 / 变速
│       ├── remote/               # WebDAV 远程库：缓存 / 仓储 / 扫描
│       ├── security/             # 路径校验
│       └── statistics/ plugins/ recognize/ toolbox/ ...
├── android/ ios/ linux/ macos/ windows/   # 各平台壳工程
├── scripts/build-release.ps1     # 按 ABI 拆包构建（arm64 ≈14MB）
└── docs/                         # 设计稿与说明
```

## 架构设计

```
┌──────────────────────────────────────┐
│  Flutter UI（Dart）                  │  状态：Riverpod · 路由：go_router
├──────────────────────────────────────┤
│  flutter_rust_bridge（自动生成绑定） │
├──────────────────────────────────────┤
│  Rust 核心 xianyu_core               │  纯逻辑，无 Tauri 依赖
│  ┌────────┬──────────┬─────────────┐ │
│  │ 解码   │ DSP 音效 │ USB 独占播放│ │
│  │ 扫描   │ 歌词/QMC │ WebDAV/DB   │ │
│  └────────┴──────────┴─────────────┘ │
├──────────────────────────────────────┤
│  平台音频后端                         │  Android: AAudio · 其他: rodio/just_audio
└──────────────────────────────────────┘
```

Rust 核心从桌面端抽取为纯逻辑库，同一套算法在桌面端（Tauri + Vue）、移动端（Flutter）、服务端复用，仅音频 I/O 与窗口材质按平台 `#[cfg]` 分流。

## 构建与运行

### 环境要求
- Flutter 3.47.0 + Dart 3.13.0，`git` 与 `System32` 在 PATH 中
- Rust toolchain（stable）
- Android SDK + NDK（Android 构建）
- 系统依赖：Linux 需 `libwebkit2gtk-4.1-dev`

### 生成 Dart 绑定
修改 Rust 侧 API 后需重新生成绑定：
```bash
flutter_rust_bridge_codegen generate
```

### 本地运行
```bash
flutter pub get
flutter run
```

### Release 构建（按 ABI 拆包）
使用 `scripts/build-release.ps1`，自动同步源码到 ASCII 构建目录（规避 Dart AOT 对非 ASCII 路径的 bug），按 ABI 拆包并交付 arm64 单架构产物（约 14MB）：
```powershell
./scripts/build-release.ps1
# 产物：releases/弦予音乐_<version>_arm64.apk
```
> 中文路径会导致 `gen_snapshot` AOT 编译失败，故脚本先 robocopy 到 `D:\build\XianYuMusicSrc` 再构建。

## 开发约定

- Rust 核心使用 `rustls-tls`（非 `native-tls`），保证移动端无系统 OpenSSL 依赖
- 平台相关模块用 `#[cfg(target_os)]` 分流：`output/`、窗口材质、字体、音频环回、凭据存储等
- Linux/macOS 音频回退 `rodio`（ALSA/PulseAudio/CoreAudio），独占模式不可用时降级共享模式
- 验证码、账号、反馈、审核等业务规则与桌面端/服务端保持一致（见 `project_memory` 约束）
- 移动端 UI 采用平台原生手势（Android Predictive Back），避免自定义转场耗电

## 相关项目

| 仓库 | 说明 |
|------|------|
| `XianYu-Music-Desktop` | 桌面端，Vue 3 + Tauri 2 + Rust，本端 Rust 核心的上游 |
| `XianYu-Music-Server` | 服务端，Rust 纯 API 服务（`/api` `/admin/api` `/uploads`） |
| `XianYu-Music-Website` | 官网，含隐藏后台入口 |
| `XY-Music-Mobile` | RawS 原生安卓端（Kotlin + C++），算法参考来源 |

## 设计稿

- 移动主页高保真稿：[`docs/mobile-home-mockup.html`](docs/mobile-home-mockup.html)
- 移动主页设计说明：[`docs/mobile-home-design.md`](docs/mobile-home-design.md)
