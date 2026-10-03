# flutter_secure_storage_ohos (vendored)

OpenHarmony 原生实现，vendor 自 SIG 适配仓库：
`gitcode.com/CPF-Flutter/fluttertpc_flutter_secure_storage`（gitee
`openharmony-sig/fluttertpc_flutter_secure_storage` 的 gitcode 镜像，2024-10，
插件版本 1.0.0，Apache-2.0，见 `ohos/src/main/ets/` 各文件头部声明）。

## 与上游 fork 的差异

1. **剥离 Dart 层**（上游 fork 的 `lib/` 整体移除）：上游 Dart 依赖
   `flutter_secure_storage_platform_interface ^1.0.1`，与主工程官方
   `flutter_secure_storage 11.2.0` 要求的 `^2.1.1` 版本冲突；且其 Dart 层
   （v8 时代的独立 `FlutterSecureStorage` 入口类）本工程完全不使用。
2. **放开 Dart SDK 约束**：上游 `sdk: ">=2.19.6 <3.0.0"` → `>=3.11.0 <4.0.0`。

## 为什么不需要 Dart 层

官方主包 `flutter_secure_storage` 11.2.0 的默认平台实现
（platform_interface 2.1.1 `MethodChannelFlutterSecureStorage`）固定使用
channel `plugins.it_nomads.com/flutter_secure_storage`，方法集
`write/read/readAll/containsKey/delete/deleteAll`，参数形状
`{key, value, options}`——与本插件 ArkTS 侧
（`FlutterSecureStorageOhosPlugin.ets`）完全一致。v11 新增的
`checkUpgradeStatus` 在本插件返回 notImplemented，Dart 侧捕获
MissingPluginException 后按 unsupported 兜底，行为无损。

即：主包 Dart → 同名 channel → 本插件原生 HUKS/RSA 加密存储，
无任何 Dart 侧胶水代码。

## 平台注册

仅声明 `flutter.plugin.platforms.ohos`：Android/iOS 构建不参与插件注册
（主工程把它作为 path 依赖引入只为让鸿蒙构建拿到原生实现，其他平台
零影响）。`ohos/har/flutter.har` 不入库，由 Flutter-OH 构建工具生成
（与 third_party/file_picker 同模式）。

## 升级注意

更新此 vendor 时保持 pubspec 三要素：无 Dart 依赖、sdk >=3.11、
仅 ohos 平台声明；并重新核对上游插件的方法集/channel 名是否仍与
官方主包对齐。
