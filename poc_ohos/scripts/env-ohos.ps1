# env-ohos.ps1 - switch current session to Flutter-OH toolchain
# (does not touch global PATH, official Flutter unaffected)
# Usage: . ./scripts/env-ohos.ps1   (note the leading dot: dot-source)
#
# Optional env overrides:
#   FLUTTER_OHOS_HOME   Flutter-OH install dir  (default D:\flutter-ohos)
#   DEVECO_SDK_HOME     DevEco SDK root        (default C:\Program Files\Huawei\DevEco Studio\sdk)
#   PUB_CACHE_OVERRIDE  Pub cache dir          (default D:\pub-cache)

$FlutterOhos = if ($env:FLUTTER_OHOS_HOME) { $env:FLUTTER_OHOS_HOME } else { 'D:\flutter-ohos' }
if (-not (Test-Path (Join-Path $FlutterOhos 'bin\flutter.bat'))) {
    throw "Flutter-OH not found: $FlutterOhos (set FLUTTER_OHOS_HOME after install)"
}
$env:PATH = "$(Join-Path $FlutterOhos 'bin');$env:PATH"

# CN mirrors (pub + engine artifacts)
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

# Pub cache MUST be on the same drive as the project:
# flutter-hvigor-plugin computes plugin srcPath via path.relative;
# across drives (D: project -> C: cache) it yields an absolute path
# and hvigor fails with "The srcPath is not a relative path".
$env:PUB_CACHE = if ($env:PUB_CACHE_OVERRIDE) { $env:PUB_CACHE_OVERRIDE } else { 'D:\pub-cache' }

# Silence flutter doctor upstream warning (session-only)
$env:FLUTTER_GIT_URL = 'https://atomgit.com/CPF-Flutter/flutter_flutter.git'

# DevEco SDK (build-rust-ohos.ps1 needs its native/llvm + sysroot)
$Sdk = if ($env:DEVECO_SDK_HOME) { $env:DEVECO_SDK_HOME } else { 'C:\Program Files\Huawei\DevEco Studio\sdk' }
if (Test-Path $Sdk) { $env:DEVECO_SDK_HOME = $Sdk }

# DevEco tools (ohpm/hvigorw/node, session-only)
$DevecoTools = Split-Path -Parent $Sdk  # ...\DevEco Studio\sdk -> ...\DevEco Studio
$DevecoTools = Join-Path $DevecoTools 'tools'
foreach ($t2 in @('ohpm\bin', 'hvigor\bin', 'node')) {
    $p = Join-Path $DevecoTools $t2
    if (Test-Path $p) { $env:PATH = "$p;" + $env:PATH }
}

flutter --version
Write-Host ''
Write-Host 'Session switched to Flutter-OH. Dot-source this script before flutter run / build scripts.'
