#requires -version 5.1
param(
    [switch]$SkipCodegen,
    [switch]$SkipApk,
    [switch]$Release,
    [string]$Abi = "arm64-v8a,armeabi-v7a",
    [string]$SourceRoot = ""
)
<#
.SYNOPSIS
  一键编译 Rust 内核（.so）并打包移动端 APK。

.DESCRIPTION
  Rust 核心（xianyu_core）编译为 libxianyu_core.so 后预置在
  android/app/src/main/jniLibs/，flutter build 不会自动编译 Rust。
  本脚本封装三步：
    1.（可选）flutter_rust_bridge_codegen generate —— 改了 Rust API 才需要
    2. cargo ndk 交叉编译 .so 到 jniLibs（默认 arm64-v8a / armeabi-v7a）
    3. 打包 APK（默认 debug；-Release 走 build-release.ps1 出 release 包）

  用法示例：
    .\scripts\build-rust.ps1                     # 全流程：绑定 + .so + debug APK
    .\scripts\build-rust.ps1 -SkipCodegen        # 只改 Rust 内部逻辑：跳过绑定
    .\scripts\build-rust.ps1 -SkipApk            # 只编 .so，不打包
    .\scripts\build-rust.ps1 -Release            # 绑定 + .so + release APK

.PARAMETER SkipCodegen
  跳过绑定生成（只改了 Rust 内部逻辑、未动 api/mod.rs 时使用）。
.PARAMETER SkipApk
  只编译 .so，不打包 APK。
.PARAMETER Release
  打包 release APK（调用 build-release.ps1）；默认打 debug APK。
.PARAMETER Abi
  要编译的 ABI 列表，逗号分隔，默认 "arm64-v8a,armeabi-v7a"。
.PARAMETER SourceRoot
  项目源码根目录（默认取脚本所在目录的父目录）。
#>

$ErrorActionPreference = "Stop"

# ---------- 路径与常量 ----------
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot   # XianYu-Music-Mobile
}
$realSource = (Resolve-Path $SourceRoot).Path
$rustDir    = Join-Path $realSource "rust"
$jniLibsDir = Join-Path $realSource "android\app\src\main\jniLibs"
$cargoBin   = "C:\Users\小奇\.cargo\bin"
$flutterBin = "C:\flutter\sdk_tmp\flutter\bin\flutter.bat"

# ---------- 环境变量（构建所需） ----------
$env:ANDROID_HOME     = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = "$env:LOCALAPPDATA\Android\Sdk"
$env:JAVA_HOME        = "D:\Program Files\Java\jdk-25.0.2"
# cargo-ndk 依赖 ANDROID_NDK_HOME 定位 NDK，自动探测 SDK 下最新版本
$ndkRoot = Join-Path $env:ANDROID_HOME "ndk"
if (Test-Path $ndkRoot) {
    $ndkVer = Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($ndkVer) {
        $env:ANDROID_NDK_HOME = $ndkVer.FullName
        $env:ANDROID_NDK_ROOT = $ndkVer.FullName
    }
}
$env:Path = "$cargoBin;C:\Windows\System32;C:\Windows;C:\flutter\sdk_tmp\flutter\bin\cache\dart-sdk\bin;C:\flutter\sdk_tmp\flutter\bin;" + `
            "$env:LOCALAPPDATA\Android\Sdk\platform-tools;" + `
            [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
            [Environment]::GetEnvironmentVariable("Path","User")

# ---------- 1. 生成 Dart 绑定（可选，须在项目根目录执行） ----------
if (-not $SkipCodegen) {
    Write-Host "[build-rust] 生成 Dart 绑定 (flutter_rust_bridge_codegen generate) ..." -ForegroundColor Cyan
    Push-Location $realSource
    try {
        & "$cargoBin\flutter_rust_bridge_codegen.exe" generate
        if ($LASTEXITCODE -ne 0) { throw "[build-rust] 绑定生成失败 (exit=$LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[build-rust] 跳过绑定生成 (-SkipCodegen)" -ForegroundColor DarkGray
}

# ---------- 2. 交叉编译 .so 到 jniLibs ----------
Write-Host "[build-rust] 交叉编译 .so -> $jniLibsDir (ABI: $Abi) ..." -ForegroundColor Cyan
Push-Location $rustDir
try {
    $abiArgs = @()
    foreach ($a in ($Abi -split ",")) { $abiArgs += "-t"; $abiArgs += $a.Trim() }
    & cargo ndk @abiArgs -o $jniLibsDir build --release
    if ($LASTEXITCODE -ne 0) { throw "[build-rust] cargo ndk 编译失败 (exit=$LASTEXITCODE)" }
} finally {
    Pop-Location
}

# ---------- 3. 打包 APK（可选） ----------
if (-not $SkipApk) {
    if ($Release) {
        Write-Host "[build-rust] 打包 release APK (build-release.ps1) ..." -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot "build-release.ps1")
        if ($LASTEXITCODE -ne 0) { throw "[build-rust] release 打包失败 (exit=$LASTEXITCODE)" }
    } else {
        Write-Host "[build-rust] 打包 debug APK ..." -ForegroundColor Cyan
        Push-Location $realSource
        try {
            & $flutterBin build apk --debug
            if ($LASTEXITCODE -ne 0) { throw "[build-rust] debug 打包失败 (exit=$LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
    }
} else {
    Write-Host "[build-rust] 跳过 APK 打包 (-SkipApk)" -ForegroundColor DarkGray
}

Write-Host "[build-rust] 完成" -ForegroundColor Green
