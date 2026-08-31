# 调试会话：wallpaper-cover-vanish

## 症状
- 竖屏 + 壁纸模式 + 覆盖动画：push 二级页（如 我的页→本地、设置导航页→分类页）时，
  **旧页内容在新页滑入瞬间直接消失**，露出纯壁纸；部分目标页（本地库）内容不加载。
- 常规模式（非壁纸）完全正常。
- 已确认：用户重新打包安装（非热重载）；`_CoverBackdrop` 已放滑动层内部仍复现。

## 关键观察
- 露出的是「纯壁纸」= 根层 `CustomBackgroundLayer`（在 Overlay/Navigator 之外）仍渲染，
  说明不是整个 app 白屏，而是 **Overlay 内的路由子树渲染失败或未绘制**。
- 「本地不加载」暗示目标页初始化（权限申请 `androidSdkInt`/扫描）可能抛异常。

## 假设（可证伪）
- **H1（主）**：转场期间某构建异常（`_CoverBackdrop`/`CustomBackgroundLayer`/目标页 init，
  如 `androidSdkInt` MethodChannel、settingsProvider emit 链路）导致 Overlay 构建中断，
  release 下 ErrorWidget 为空白 → 旧页+新页内容全没，只剩根层壁纸。
  - 验证点：flutter run 控制台出现异常堆栈（指向具体文件）。
- **H2**：框架对 opaque 路由的跳过绘制在转场期间生效（与预期相反），旧页未绘制；
  新页面板透明（壁纸垫底未生效）→ 壁纸透出。
  - 验证点：无异常日志但旧页不绘制；需插桩 _CoverBackdrop/old route build。
- **H3**：`Image.file` 异步解码/`ImageFiltered` 在滑动面板内首帧失败，面板透明，
  同时旧页被 opaque 机制跳过 → 纯壁纸。
  - 验证点：插桩 `_CoverBackdrop` build 与 Image 帧回调。
- **H4**：push 时 `settingsProvider` emit（本地页 init 写设置），触发 `_CoverBackdrop`
  所在路由重建链路异常。
  - 验证点：日志显示异常紧跟 push 与 settings 变更。

## 运行记录
- [2026-08-30] 会话建立；设备 NOH AN00 (Android 10, 192.168.3.2:5555)；
  证据收集方式：flutter run（debug）控制台日志。
- [2026-08-30 复发] microtask 修复后用户最新测试仍复现「新页划入中、旧页直接消失」。
  已确认框架机制（SDK routes.dart `_handleStatusChanged`）：转场 forward/reverse 期间
  路由 overlayEntry.opaque 被框架置 false（下层照常绘制），completed 后才置 true
  （下层停绘）——框架层行为符合预期。壁纸模式下旧页背景透明，故「露出纯壁纸」
  等价于「旧页内容子树渲染失败（release ErrorWidget 为空白）」。
- [2026-08-30 二轮取证] 复用会话插桩：TransitionTracker didPush/didPop 日志、
  notifier 变更/微任务应用日志、_CoverRoute/_CoverBackRoute 动画 status 日志
  （全部 `[dbg-t]` 前缀）。logcat 无用户 release 测试痕迹（缓冲已滚动）。

## 复发后的假设（可证伪）
- **H5（主）**：转场窗口内旧页子树 rebuild 抛异常（触发源：isTransitioningProvider
  微任务引发的玻璃表面重建 / 目标页 init 同步写 provider 的 Riverpod 守卫异常），
  release 下旧页内容变空白、透出壁纸；新页 SlideTransition 逐帧动画不重建子树故仍在滑入。
  验证点：debug 控制台异常堆栈紧跟 `[dbg-t]` 时序。
- **H6**：Overlay opaque 置位提前——新路由 status=completed 早于视觉滑入结束，
  下层停绘。验证点：`[dbg-t] _CoverRoute status=completed` 出现时 controller.value 是否 <1。
- **H7**：GlobalKey 撞 key（musicLibraryPageKeys/分支容器），转场期间 shell 重建
  使壳层子树构建异常 → 旧页（壳层分支）消失，新路由页独立仍在滑入。
  验证点：控制台 "Duplicate keys / Multiple widgets used the same key"。
- **H8**：用户测试包未包含 microtask 修复（时间线错位）。验证点：debug 复现时若无异常
  且现象不同，需核对包版本。

## 状态
[CLOSED 2026-08-30] 根因定案：「页面透明 + 透出根层壁纸」模型下，壁纸垫底补偿
（_CoverBackdrop 反向平移对齐）方案过于复杂且是症状来源。已按用户定案改为
「页面烘焙壁纸」模型：AppPageBackground 壁纸启用时直接铺 CustomBackgroundLayer
为页面底色（不透明卡片），转场与普通模式完全同构；_CoverBackdrop 整体删除
（routes.dart 三处用法一并移除），根层壁纸层保留作兜底。另修复 app.dart 中
残留的 wallpaperTextMode 死赋值（全局变量已不存在，编译错误）。用户实测转场正常。
