# share_plus_ohos (vendored)

OpenHarmony 原生实现，vendor 自 SIG 适配仓库：
`gitcode.com/openharmony-sig/flutter_plus_plugins`，分支
`br_share_plus-v10.1.1_ohos`，取 `packages/share_plus/share_plus/ohos`
（原生实现版权 Hunan OpenValley，Apache-2.0，见各 .ets 文件头部声明）。

## 与上游 fork 的差异

1. **剥离 Dart 层**（上游 fork 的 `lib/` 整体移除）：上游是全平台整包
   fork（Dart 与官方 share_plus 同名冲突）。官方主包
   `share_plus 13.3.0` 经 platform_interface 6.1.0 以同名 MethodChannel
   `dev.fluttercommunity.plus/share` 调用，本插件 ArkTS 侧 channel 一致，
   无任何 Dart 侧胶水代码。
2. **改名 `share_plus_ohos`**：pubspec 包名、oh-package 模块名同步改名，
   避免与官方主包同名；pubspec 仅声明 ohos 平台（Android/iOS 构建
   零参与），pluginClass 保持 `SharePlusOhosPlugin`。
3. **协议适配（关键）**：上游原生实现是老协议——`share` 只处理纯文本、
   文件走独立 `shareFiles` 方法；官方 share_plus 10+ 的 Dart 统一走
   `share` 方法、文件以 `paths`/`mimeTypes` 随参数携带。不补丁的话
   鸿蒙上分享文件会被静默丢弃（只出文本）。已在
   `MethodChannelHandlerImpl.ets` 的 `share` 分支按 `paths` 参数有无
   路由到 `shareFiles`/`share`，同时兼容两代协议。

## 行为说明

- 走鸿蒙系统分享面板（`@hms.collaboration.systemShare` ShareController），
  文件先复制到应用 cache 的 `share_plus/` 目录再以 fileUri 分享。
- `share`/`shareFiles`（非 WithResult）在拉起面板后立即回执
  `share/unavailable`，Dart 侧按 unavailable 结果处理——只影响
  `ShareResult.status`，本工程导出流程不读该状态，无影响。

## 平台注册

pubspec `flutter.plugin.platforms` 仅声明 ohos，由 Flutter-OH 工具链
生成注册表自动挂载（同 flutter_secure_storage_ohos 模式）；
`ohos/oh-package.json5` 的 `@ohos/flutter_ohos: file:./har/flutter.har`
由鸿蒙构建过程注入。
