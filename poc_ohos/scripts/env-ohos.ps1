# env-ohos.ps1 - 当前会话切换到 Flutter-OH 工具链（不改全局 PATH，不影响官方 Flutter）
# 用法: . ./scripts/env-ohos.ps1   （注意前面的点：dot-source 注入当前会话）
#
# 可用环境变量覆盖默认值:
#   FLUTTER_OHOS_HOME   Flutter-OH 安装目录（默认 D:\flutter-ohos）
#   DEVECO_SDK_HOME     DevEco SDK 根目录（默认 "C:\Program Files\Huawei\DevEco Studio\sdk"）

$FlutterOhos = if ($env:FLUTTER_OHOS_HOME) { $env:FLUTTER_OHOS_HOME } else { 'D:\flutter-ohos' }
if (-not (Test-Path (Join-Path $FlutterOhos 'bin\flutter.bat'))) {
    throw "Flutter-OH 不存在: $FlutterOhos（装好后可设 FLUTTER_OHOS_HOME 指向安装目录）"
}
$env:PATH = "$(Join-Path $FlutterOhos 'bin');$env:PATH"

# 国内镜像（Pub 与 Flutter 引擎产物）
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

# 消除 flutter doctor 的 upstream 警告（仅本会话，不影响官方 Flutter）
$env:FLUTTER_GIT_URL = 'https://atomgit.com/CPF-Flutter/flutter_flutter.git'

# DevEco SDK（build-rust-ohos.ps1 依赖其 native/llvm 与 sysroot）
$Sdk = if ($env:DEVECO_SDK_HOME) { $env:DEVECO_SDK_HOME } else { 'C:\Program Files\Huawei\DevEco Studio\sdk' }
if (Test-Path $Sdk) { $env:DEVECO_SDK_HOME = $Sdk }

flutter --version
Write-Host ''
Write-Host '当前会话已切换到 Flutter-OH。运行 flutter run / build-rust-ohos.ps1 前先 dot-source 本脚本。'