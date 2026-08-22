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
#>
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FlutterArgs)

$ErrorActionPreference = "Stop"
$realSource = Split-Path -Parent $PSScriptRoot   # XianYu-Music-Mobile
$flutterBin = "C:\flutter\sdk_tmp\flutter\bin\flutter.bat"
$dartBin    = "C:\flutter\sdk_tmp\flutter\bin\cache\dart-sdk\bin\dart.bat"
# Rust 编译由 gradle 的 rustHook 自动处理（见 docs/build-guide.md），此处无需干预。

# 构建所需环境（与 build-release.ps1 保持一致）
$env:ANDROID_HOME     = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = "$env:LOCALAPPDATA\Android\Sdk"
$env:JAVA_HOME        = "D:\Program Files\Java\jdk-25.0.2"
$env:Path = "C:\Windows\System32;C:\Windows;C:\flutter\sdk_tmp\flutter\bin\cache\dart-sdk\bin;C:\flutter\sdk_tmp\flutter\bin;" + `
            "$env:LOCALAPPDATA\Android\Sdk\platform-tools;" + `
            [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
            [Environment]::GetEnvironmentVariable("Path","User")

Push-Location $realSource
try {
    # 1) 同步版本号（version.ts -> pubspec.yaml / account_api.dart）
    Write-Host "[dev] 同步版本号 (version.ts -> pubspec/account_api) ..." -ForegroundColor Cyan
    & $dartBin run tool/sync_version.dart
    if ($LASTEXITCODE -ne 0) { throw "[dev] 版本号同步失败 (exit=$LASTEXITCODE)" }

    # 2) 启动开发运行
    Write-Host "[dev] flutter run $($FlutterArgs -join ' ')" -ForegroundColor Cyan
    & $flutterBin run @FlutterArgs
} finally {
    Pop-Location
}