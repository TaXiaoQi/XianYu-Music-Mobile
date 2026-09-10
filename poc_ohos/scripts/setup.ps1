# setup.ps1 - 装配鸿蒙 PoC 壳工程
#
# 前置：已安装 Flutter-OH（flutter --version 含 ohos 字样）
# 步骤：
#   1. 检查 Flutter-OH
#   2. flutter create --platforms ohos 生成壳工程（已存在则跳过）
#   3. 拷贝主工程 FRB 生成代码 lib/src/rust -> poc_ohos/lib/src/rust
#   4. 给 ohos/entry/src/main/module.json5 打权限/后台播放补丁
#   5. 拷贝已编译的 libxianyu_core.so（若有）
#   6. flutter pub get
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PocDir    = Split-Path -Parent $ScriptDir
$MobileDir = Split-Path -Parent $PocDir

Write-Host "== 鸿蒙 PoC 装配 =="

# ---- 1. Flutter-OH 检查 ----
# FLUTTER_OHOS_AUTO
# 当前 PATH 里的 flutter 不是鸿蒙分支时，自动优先使用本地 Flutter-OH
$ohosFlutter = 'D:\flutter-ohos\bin'
if (Test-Path (Join-Path $ohosFlutter 'flutter.bat')) {
    $env:PATH = '$ohosFlutter;' + $env:PATH
    $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
}
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) { throw '未找到 flutter，请先安装并接入 PATH（需 Flutter-OH 分支）' }
$verOutput = (& flutter --version) -join ' '
Write-Host $verOutput
if ($verOutput -notmatch 'ohos') {
    Write-Warning '当前 flutter 不是鸿蒙分支。请安装 Flutter-OH（openharmony-sig/flutter_flutter），'
    Write-Warning '或临时用环境变量切换：PATH 指向 ohos 版 flutter 后重跑本脚本。'
    throw '需要 Flutter-OH'
}

# ---- 2. 生成 ohos 壳工程 ----
if (-not (Test-Path (Join-Path $PocDir 'ohos'))) {
    Write-Host 'flutter create --platforms ohos ...'
    & flutter create --platforms ohos --project-name xianyu_ohos_poc --org cn.xianyumusic $PocDir
    if ($LASTEXITCODE -ne 0) { throw 'flutter create 失败，请检查 Flutter-OH 安装' }
} else {
    Write-Host 'ohos/ 已存在，跳过 create'
}

# ---- 3. 拷贝主工程 FRB 生成代码（与 flutter_rust_bridge 2.12.0 严格配套）----
$srcRust = Join-Path $MobileDir 'lib\src\rust'
$dstRust = Join-Path $PocDir 'lib\src\rust'
if (-not (Test-Path $srcRust)) { throw "主工程生成代码缺失：$srcRust" }
New-Item -ItemType Directory -Force -Path $dstRust | Out-Null
Copy-Item (Join-Path $srcRust '*.dart') $dstRust -Force
Write-Host "FRB 生成代码已拷贝: $dstRust"

# ---- 4. module.json5 补丁（INTERNET 权限 + 后台音频）----
$modFile = Join-Path $PocDir 'ohos\entry\src\main\module.json5'
if (-not (Test-Path $modFile)) { throw "module.json5 缺失：$modFile（请检查 ohos 工程模板版本）" }
$utf8 = [System.Text.UTF8Encoding]::new($false)
$mod  = [System.IO.File]::ReadAllText($modFile, $utf8)

if ($mod -notmatch 'ohos\.permission\.INTERNET') {
    if ($mod -match '"requestPermissions"') {
        Write-Warning 'module.json5 已有 requestPermissions 但缺 INTERNET，请手工补充：{ "name": "ohos.permission.INTERNET" }'
    } elseif ($mod -match '"module"\s*:\s*\{') {
        $mod = [regex]::Replace($mod, '"module"\s*:\s*\{', "`$0`n    `"requestPermissions`": [`n      { `"name`": `"ohos.permission.INTERNET`" }`n    ],", 1)
        Write-Host '已添加 ohos.permission.INTERNET'
    }
}
if ($mod -notmatch 'backgroundModes') {
    $mod2 = [regex]::Replace($mod, '("abilities"\s*:\s*\[\s*\{)', "`$1`n      `"backgroundModes`": [`"audioPlayback`"],", 1)
    if ($mod2 -ne $mod) {
        $mod = $mod2
        Write-Host '已添加 backgroundModes: [audioPlayback]'
    } else {
        Write-Warning '未能定位 abilities 节点，请手工在 entry ability 中添加 "backgroundModes": ["audioPlayback"]'
    }
}
[System.IO.File]::WriteAllText($modFile, $mod, $utf8)

# ---- 5. 拷贝 .so（若已编译）----
$So = Join-Path $MobileDir "rust\target\aarch64-unknown-linux-ohos\release\libxianyu_core.so"
if (Test-Path $So) {
    $dest = Join-Path $PocDir 'ohos\entry\libs\arm64-v8a'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item $So (Join-Path $dest 'libxianyu_core.so') -Force
    Write-Host "libxianyu_core.so 已拷贝（可先跑 scripts/build-rust-ohos.ps1 编译）"
} else {
    Write-Warning '尚未编译 libxianyu_core.so（OHOS 版），跑完 build-rust-ohos.ps1 后重新执行本脚本或手动拷贝'
}

# ---- 6. pub get ----
Push-Location $PocDir
try {
    $env:GIT_LFS_SKIP_SMUDGE = '1' # TPC 仓库 LFS 资源（example 目录）下载易失败，跳过不影响包源码
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败：检查 pubspec.yaml 中 git 依赖地址（见 README 故障排查）' }
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '== 装配完成，后续步骤 =='
Write-Host ' 1. cargo .so 编译： ./scripts/build-rust-ohos.ps1（然后重跑本脚本完成拷贝）'
Write-Host ' 2. DevEco Studio 打开 poc_ohos/ohos 完成签名（File > Project Structure > Signing Configs 勾选 Automatically generate）'
Write-Host ' 3. 连接鸿蒙真机后运行： flutter devices && flutter run'