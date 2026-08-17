#requires -version 5.1
param(
    [switch]$SkipBuild,
    [string]$SourceRoot = ""
)
<#
.SYNOPSIS
  构建移动端 release APK 并将产物移动到项目根目录 releases/ 下（参考桌面版 move-bundles.js）。

.DESCRIPTION
  移动端 release 构建必须在纯 ASCII 路径下进行（Flutter 的 Dart AOT 快照生成器
  gen_snapshot 无法读取含中文/非 ASCII 字符的路径，见 flutter/flutter#149194）。
  因此本脚本：
    1. 用 robocopy 将源码增量同步到 ASCII 构建目录（D:\build\XianYuMusicSrc）
    2. 在该目录执行 `flutter build apk --release --split-per-abi`
       （按 ABI 拆包，交付 arm64 单架构包，避免通用包把所有 ABI 引擎都打进 42MB）
    3. 将 arm64 分架构的 APK 复制到项目根目录 releases/，命名格式：弦予音乐_<version>_arm64.apk
       （arm64 单包约 14MB）

.PARAMETER SkipBuild
  仅移动已存在的 APK 产物到 releases/，不重新构建。
.PARAMETER SourceRoot
  项目源码根目录（默认取脚本所在目录的父目录）。
#>

$ErrorActionPreference = "Stop"

# ---------- 路径与常量 ----------
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot   # XianYu-Music-Mobile
}
# 项目源码根目录（可能含中文）实际路径
$realSource = (Resolve-Path $SourceRoot).Path
# ASCII 构建目录（junction 会被 Flutter 解析回真实路径，故用真实复制目录）
$buildRoot   = "D:\build\XianYuMusicSrc"
$releasesDir = Join-Path $realSource "releases"
# 排除的缓存/平台目录（不必同步到 ASCII 构建目录）
$excludeDirs = @(
    "build", ".dart_tool", "rust\target", ".git", ".idea", "logs",
    "windows", "macos", "linux", "ios"
)

# APK 源产物目录（ASCII 构建目录下）
# --split-per-abi 会生成 per-ABI 的 APK，交付 arm64 单架构产物
$apkDir  = Join-Path $buildRoot "build\app\outputs\flutter-apk"
$apkFile = Join-Path $apkDir "app-arm64-v8a-release.apk"

# ---------- 环境变量（构建所需） ----------
$env:ANDROID_HOME     = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = "$env:LOCALAPPDATA\Android\Sdk"
$env:JAVA_HOME        = "D:\Program Files\Java\jdk-25.0.2"
$env:Path = "C:\Windows\System32;C:\Windows;C:\flutter\sdk_tmp\flutter\bin\cache\dart-sdk\bin;C:\flutter\sdk_tmp\flutter\bin;" + `
            "$env:LOCALAPPDATA\Android\Sdk\platform-tools;" + `
            [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
            [Environment]::GetEnvironmentVariable("Path","User")

# ---------- 1. 同步源码到 ASCII 构建目录 ----------
if (-not $SkipBuild) {
    Write-Host "[build-release] 同步源码到 ASCII 构建目录: $buildRoot" -ForegroundColor Cyan
    if (-not (Test-Path $buildRoot)) { New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null }
    $excludeArgs = @()
    foreach ($d in $excludeDirs) { $excludeArgs += "/XD"; $excludeArgs += (Join-Path $realSource $d) }
    robocopy $realSource $buildRoot /E @excludeArgs /NFL /NDL /NJH /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "[build-release] robocopy 同步失败 (exit=$LASTEXITCODE)" }

    # ---------- 2. 构建 release ----------
    Write-Host "[build-release] 执行 flutter build apk --release --split-per-abi ..." -ForegroundColor Cyan
    Push-Location $buildRoot
    try {
        & "C:\flutter\sdk_tmp\flutter\bin\flutter.bat" build apk --release --split-per-abi
        if ($LASTEXITCODE -ne 0) { throw "[build-release] flutter build 失败 (exit=$LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

# ---------- 3. 校验产物 ----------
if (-not (Test-Path $apkFile)) {
    Write-Host "[build-release] 未找到 APK 产物: $apkFile" -ForegroundColor Yellow
    exit 0
}

# ---------- 4. 移动到 releases/ ----------
if (-not (Test-Path $releasesDir)) { New-Item -ItemType Directory -Force -Path $releasesDir | Out-Null }

# 从 pubspec.yaml 读取版本号
$pubspec = Join-Path $buildRoot "pubspec.yaml"
$version = "0.0.0"
if (Test-Path $pubspec) {
    $line = Select-String -Path $pubspec -Pattern "^version:" | Select-Object -First 1
    if ($line) { $version = ($line.Line -replace "^version:\s*", "" -split "\+")[0] }
}

# 目标文件名：弦予音乐_<version>_arm64.apk（releases 下用中文原名，与桌面版一致）
$destName = "弦予音乐_${version}_arm64.apk"
$destPath = Join-Path $releasesDir $destName

# 优先 rename（同盘原子），失败回退复制。源文件删除为尽力而为：
# 保留 ASCII 构建目录下的源 APK 无害，还能供下次增量构建复用。
try {
    Move-Item -Path $apkFile -Destination $destPath -Force -ErrorAction Stop
    Write-Host "[build-release] 已移动: $destName" -ForegroundColor Green
} catch {
    Copy-Item -Path $apkFile -Destination $destPath -Force
    Write-Host "[build-release] 已复制: $destName" -ForegroundColor Green
}

$apkSize = [math]::Round((Get-Item $destPath).Length/1MB, 1)
Write-Host "[build-release] 完成: $destPath ($apkSize MB)" -ForegroundColor Green