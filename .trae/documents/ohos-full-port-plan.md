# 弦予移动端鸿蒙（HarmonyOS NEXT）全量移植计划

## Context

PoC（poc_ohos + D:\xianyu-poc）已验证全部核心链路：Rust 交叉编译（aarch64/x86_64 ohos）、FRB 2.12、AMLL、reqwest+rustls、QuickJS 插件引擎、rusqlite bundled、just_audio→AVPlayer、audio_service→AVSession（含 metadata 401 修复与 KEEP_BACKGROUND_RUNNING 长时任务）。用户拍板开始全量移植：让主工程 XianYu-Music-Mobile 在鸿蒙上全功能运行（模拟器先行），产出真机验证清单。

## 硬约束与核心决策

1. **主工程路径带空格**（`d:\Program Files\...`）且 ohpm/hvigor 对空格敏感（PoC 实证，subst 无效）→ **镜像构建**：`robocopy /MIR` 同步到 `D:\xianyu-mobile-ohos` 后在镜像内执行 Dart/hvigor 构建；cargo 与 FRB codegen 留在主工程执行（对空格不敏感，dev.ps1 既有流程）。
2. **Android/iOS 构建零影响**：ohos 依赖 override 通过官方 `pubspec_overrides.yaml` 机制**只在镜像内注入**（注意：该文件存在时整体替换 pubspec 的 dependency_overrides，故必须一并写入现有 tencent_kit 的 path override）。主工程 pubspec 唯一改动：`sdk: ^3.12.2` → `>=3.11.0`（Flutter-OH 的 Dart 是 3.11.5）。
3. **能力门控复用现有单点**：[platform_caps.dart](file:///d:/Program%20Files/XianYu-Music/XianYu-Music-Mobile/lib/src/core/platform_caps.dart) 已按"能力判定→UI 隐藏入口"模式建好，新增 `isOhos` 判定并给每个能力归类 ohos 去向。
4. PoC 脚本升级后迁入主工程 `scripts/ohos/`，poc_ohos 保留作参考（后续可删）。

## 依赖接入清单（镜像内 pubspec_overrides.yaml，模板存 scripts/ohos/）

| 依赖 | 方案 |
|---|---|
| just_audio / audio_service / audio_session / path_provider | PoC 已验证的 gitcode fork，直接沿用 |
| sqflite（cached_network_image 传递依赖，**必踩坑**） | gitcode.com/openharmony-sig/flutter_sqflite |
| shared_preferences / image_picker / url_launcher / share_plus / webview_flutter | gitcode.com/openharmony-tpc/flutter_packages 对应 path |
| permission_handler | openharmony-sig/flutter_permission_handler |
| file_picker | fluttertpc_file_picker br_v8.0.7_ohos（主工程 12.x → 8.0.7 降版，API 兼容） |
| record | fluttertpc_record（核对 ^7.1.1 API 差距） |
| mobile_scanner | fluttertpc_mobile_scanner |
| tencent_kit | 首版降级：QQ 直分享走系统分享面板（share_plus），原生 QQ SDK 二期 |
| liquid_glass_widgets / cached_network_image / riverpod / go_router / crypto / encrypt / image / pinyin | 纯 Dart，不动 |

## 实施阶段

### P0 构建基础设施
- 新增 `scripts/ohos/env-ohos.ps1`（自 PoC：Flutter-OH PATH、ohpm/hvigor/node、PUB_CACHE=D:\pub-cache 同盘、GIT_LFS_SKIP_SMUDGE）
- 新增 `scripts/ohos/build-ohos.ps1` 总入口：版本同步（tool/sync_version.dart）→ FRB codegen（复用 gradle-rust-hook 的 codegen 段）→ `build-rust-ohos.ps1`（自 PoC，编译主工程 rust/）→ robocopy /MIR（排除 .git、build、.dart_tool、releases、poc_ohos、ohos/build、rust/target、android、ios、third_party）→ 镜像内 `flutter create --platforms ohos`（仅首次）+ 写 pubspec_overrides.yaml + pub get → patch-embedding.ps1（API 22 ArkTS 补丁，自 PoC）→ `flutter build hap` / `flutter run`
- pubspec.yaml 放宽 sdk；ohos/ 平台目录（镜像首次生成后）回拷主工程入库
- **验收**：镜像内空壳 HAP 构建成功、模拟器安装启动

### P1 Rust 全量接入
- 主 crate 全量 API 经 FRB 生成（lib/src/rust 已是全量绑定，无需重写）；.so 部署 ohos/entry/libs
- rust_init.dart 加载路径确认（ExternalLibrary.open('libxianyu_core.so') 模式沿用 PoC 修复）
- **验收**：模拟器启动首页，Rust 初始化 + 任一核心 API（公告/插件引擎初始化）真实调用成功

### P2 依赖 ohos 化
- overrides 清单逐项接入 + 逐个冒烟：sqflite（封面缓存）、shared_preferences（设置）、webview（人机验证）、permission_handler+file_picker（本地扫描）、image_picker（头像）、record（识曲录音）、url_launcher、share_plus、mobile_scanner
- **验收**：HAP 构建零插件缺失警告；上述功能模拟器各跑一次

### P3 平台分支适配
- platform_caps.dart 增 `isOhos`（`Platform.operatingSystem == 'ohos'`，以实测为准）；20 文件 40 处 Platform 分支归拢
- ohos 首版归类：supportsFloatingLyrics/StatusBarLyrics/HomeWidgets/InAppUpdate/DownloadNotification/FolderScan/CustomDownloadDir = false（Android 原生能力，二期原生补）；supportsQQShare 首版 false（系统分享兜底）
- **验收**：flutter analyze 零新增告警；全页面 walkthrough 无 unknown platform 崩溃

### P4 回归与真机清单
- 模拟器全功能 walkthrough（播放/歌词/插件/本地库/下载/登录）
- 产出真机验证清单（音频焦点、后台保活、AVSession 通知卡片、Impeller 对 assets/shaders/*.frag 与 liquid_glass 渲染、ArkWeb 人机验证风控、扫码）

## 关键文件

- [pubspec.yaml](file:///d:/Program%20Files/XianYu-Music/XianYu-Music-Mobile/pubspec.yaml)（sdk 放宽）
- 新增 `scripts/ohos/`（env-ohos / build-ohos / build-rust-ohos / patch-embedding / pubspec-ohos-overrides.yaml 模板）
- [platform_caps.dart](file:///d:/Program%20Files/XianYu-Music/XianYu-Music-Mobile/lib/src/core/platform_caps.dart)（isOhos + 能力归类）
- [rust_init.dart](file:///d:/Program%20Files/XianYu-Music/XianYu-Music-Mobile/lib/src/core/rust_init.dart)（.so 加载确认）
- `ohos/`（平台目录，入库）

## 风险

1. sqflite ohos fork 与 flutter_cache_manager 的版本约束解析（P2 首验，有 fallback：封面缓存换 hive/纯文件缓存）
2. Flutter-OH Impeller 对自定义 frag shader 的支持未经真机验证（预案：回退磨砂）
3. file_picker 8.0.7 / record / share_plus 基线低于主工程版本，API 冒烟逐个过
4. 直接在 master 实施（改动为新增文件 + sdk 一行放宽，不影响 Android/iOS 日常构建）

## 验证方式

- 每阶段按验收标准执行；P0-P2 每步产出可安装 HAP
- 最终：`flutter analyze` + 模拟器 walkthrough + 真机清单交付
