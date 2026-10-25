#requires -version 5.1
<#
.SYNOPSIS
  开发运行：键入本脚本时先自动同步版本号（version.ts），再直接 `flutter run`。

.DESCRIPTION
  参考桌面端 pretaura 钩子：`npm run tauri dev` 会自动把 version.ts 的版本号写入
  各处构建配置。移动端对应地，用本脚本包装 flutter run，在启动前先把 version.ts
  的版本号同步到 pubspec.yaml 与 account_api.dart，然后再正常运行到真机/模拟器。

  额外参数会原样转发给 flutter run，例如：
    .\scripts\dev.ps1
    .\scripts\dev.ps1 -d deviceId          # 指定设备/模拟器运行

  工具链定位与机器无关：flutter 从 PATH 解析（flutter-ohos fork 或官方均可），
  dart 从 flutter 根目录推导；ANDROID_HOME/JAVA_HOME 仅在未设置时按系统默认补，
  不覆盖开发者已有环境。
#>
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FlutterArgs)

$ErrorActionPreference = "Stop"
$realSource = Split-Path -Parent $PSScriptRoot   # XianYu-Music-Mobile

# ---- 工具链定位（机器无关）----
# flutter：从 PATH 取应用型命令（-CommandType Application 只匹配 exe/bat，
# 不会被 shell 函数/别名遮蔽）。找不到时回落项目旁惯例路径。
$flutterCmd = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq 'flutter.bat' } | Select-Object -First 1
if ($flutterCmd) {
    $flutterBin = $flutterCmd.Source
} else {
    $flutterBin = Join-Path $realSource '..\flutter\bin\flutter.bat'
    if (-not (Test-Path $flutterBin)) {
        throw "[dev] PATH 与项目旁均未找到 flutter.bat；请先安装 Flutter（或 flutter-ohos fork）并加入 PATH"
    }
}
$flutterRoot = Split-Path -Parent (Split-Path -Parent $flutterBin)   # ...\flutter

# dart：新版 SDK 的 bin\cache\dart-sdk\bin 只有 dart.exe（不再带 dart.bat）；
# cache 未解压时回退顶层 bin\dart.bat（flutter wrapper 会自举下载 dart-sdk）。
$dartBin = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path $dartBin)) { $dartBin = Join-Path $flutterRoot 'bin\dart.bat' }
if (-not (Test-Path $dartBin)) {
    throw "[dev] 未找到 dart 可执行（$flutterRoot\bin\cache\dart-sdk\bin\dart.exe 与 $flutterRoot\bin\dart.bat 均不存在）；先跑一次 flutter --version 让 SDK 自举"
}

# ---- 构建环境（仅缺失时补默认值，不覆盖已有配置）----
if (-not $env:ANDROID_HOME) {
    $defaultAndroid = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $defaultAndroid) { $env:ANDROID_HOME = $defaultAndroid }
}
if (-not $env:ANDROID_SDK_ROOT -and $env:ANDROID_HOME) { $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME }
if (-not $env:JAVA_HOME) {
    # gradle 需要 JAVA_HOME：从 PATH 上的 java.exe 推导安装根（...\bin\java.exe → 上级）
    $javaCmd = Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javaCmd -and $javaCmd.Source -match '^(.+)\\bin\\java\.exe$') {
        $env:JAVA_HOME = $Matches[1]
        Write-Host "[dev] JAVA_HOME 未设置，按 PATH java 推断: $env:JAVA_HOME" -ForegroundColor DarkGray
    }
}
# PATH 前置 flutter bin 与 platform-tools（存在才加，不整体重建 Path）
$flutterBinDir = Split-Path -Parent $flutterBin
foreach ($dir in @($flutterBinDir, ($(if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME 'platform-tools' })))) {
    if ($dir -and (Test-Path $dir) -and (($env:Path -split ';') -notcontains $dir)) {
        $env:Path = "$dir;$env:Path"
    }
}

# 一次性启动：先把 Rust 绑定生成 + 编译 .so 做完（等价桌面端 tauri dev 先编 Rust），
# 再 flutter run。这样 flutter 编译 Dart 时桥接已是最新，gradle 的 rustHook 只会
# 1 秒静默放行，单条命令即可完成，不需要像以前那样在绑定更新后再跑一次。
# 如需完全跳过 Rust 编译（直接复用已有 .so），设置 XIANMU_SKIP_RUST=1。

Push-Location $realSource
try {
    # 1) 同步版本号（version.ts -> pubspec.yaml / account_api.dart）
    #    脚本纯 dart:io 无依赖：直接跑文件，不走 dart run——dart run 会触发
    #    flutter_rust_bridge 的 native-assets 构建钩子，无谓拖慢且要编译 hook.dill
    Write-Host "[dev] 同步版本号 (version.ts -> pubspec/account_api) ..." -ForegroundColor Cyan
    & $dartBin tool/sync_version.dart
    if ($LASTEXITCODE -ne 0) { throw "[dev] 版本号同步失败 (exit=$LASTEXITCODE)" }

    # 2) 预生成 Rust 绑定并编译 .so（gradle-rust-hook.ps1）：
    #    在 flutter 编译 Dart 之前让桥接保持最新，从而单条命令一次性完成。
    #    绑定有更新时钩子返回 3，但在这里发生在 flutter run 之前，本轮即可生效，
    #    无需像以前那样再跑一次；跳过编译用 XIANMU_SKIP_RUST=1。
    Write-Host "[dev] 预生成 Rust 绑定 (gradle-rust-hook) ..." -ForegroundColor Cyan
    $hookScript = Join-Path $PSScriptRoot "gradle-rust-hook.ps1"
    try {
        & $hookScript
    } catch {
        throw "[dev] Rust 预生成失败：$($_.Exception.Message)（详见 build\rust-hook.log）"
    }
    if ($LASTEXITCODE -eq 3) {
        Write-Host "[dev] Rust 绑定已重新生成，随本次运行直接生效（一次性）" -ForegroundColor Green
    }

    # 3) 启动开发运行
    Write-Host "[dev] flutter run $($FlutterArgs -join ' ')" -ForegroundColor Cyan
    & $flutterBin run @FlutterArgs
} finally {
    Pop-Location
}
