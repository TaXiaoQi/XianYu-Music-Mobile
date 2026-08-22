#requires -version 5.1
<#
.SYNOPSIS
  flutter run / flutter build 的 Rust 自动编译钩子（由 android/app/build.gradle.kts preBuild 调用）。

.DESCRIPTION
  目标：像桌面端 tauri dev 一样，直接敲 `flutter run` / `flutter build apk` 就能
  自动带上 Rust（绑定 + .so）。
    - Rust 内部逻辑改动：自动 cargo ndk 重编 .so，本次构建直接生效，无需重跑。
    - Rust API 改动：自动 flutter_rust_bridge_codegen generate 后中止本次构建，
      提示重跑一次（Dart kernel 编译发生在 gradle 之前，新绑定只能下次生效）。
    - Rust 无改动：1 秒内静默通过，不拖慢日常构建。
  设置环境变量 XIANMU_SKIP_RUST=1 可跳过本钩子。
#>
$ErrorActionPreference = "Stop"
$realSource = Split-Path -Parent $PSScriptRoot   # XianYu-Music-Mobile

if ($env:XIANMU_SKIP_RUST -eq "1") { exit 0 }

$soFile     = Join-Path $realSource "android\app\src\main\jniLibs\arm64-v8a\libxianyu_core.so"
$bindings   = Join-Path $realSource "lib\src\rust\frb_generated.dart"
$rustSrcDir = Join-Path $realSource "rust\src"
$hookLog    = Join-Path $realSource "build\rust-hook.log"
New-Item (Split-Path $hookLog) -ItemType Directory -Force | Out-Null

$rustFiles = Get-ChildItem $rustSrcDir -Recurse -Filter "*.rs" -File | Where-Object { $_.Name -ne "frb_generated.rs" }
$configFiles = @()
foreach ($f in @("rust\Cargo.toml", "rust\Cargo.lock", "flutter_rust_bridge.yaml")) {
    $p = Join-Path $realSource $f
    if (Test-Path $p) { $configFiles += Get-Item $p }
}
$newestRust = ($rustFiles | Measure-Object LastWriteTime -Maximum).Maximum

# ---------- 检测 1：.so 是否过期（内部逻辑/依赖配置改动） ----------
$needSo = $true
if (Test-Path $soFile) {
    $soTime = (Get-Item $soFile).LastWriteTime
    $newestAll = @($newestRust, (($configFiles | Measure-Object LastWriteTime -Maximum).Maximum)) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    if ($newestAll -lt $soTime) { $needSo = $false }
}

# ---------- 检测 2：API 绑定是否过期 ----------
# 只看 .rs 源码：Cargo.toml/Cargo.lock 改动（如 profile、依赖版本）不会改变 API
# 形状，若纳入会误判为"API 变化"导致不必要的中止重跑。
$needCodegen = $true
if (Test-Path $bindings) {
    if ($newestRust -lt (Get-Item $bindings).LastWriteTime) { $needCodegen = $false }
}

if (-not $needSo -and -not $needCodegen) { exit 0 }

Write-Host "[rust-hook] 检测到 Rust 改动，开始自动编译 ..." -ForegroundColor Yellow

# ---------- 环境（中文用户名路径会导致 NDK ld.lld 链接失败，必须走 ASCII 拷贝） ----------
$cargoBin   = "C:\Users\小奇\.cargo\bin"
$asciiNdk   = "D:\ascii-env\ndk-copy"
$asciiRustc = "D:\ascii-env\rust-tc-real\bin\rustc.exe"
$env:ANDROID_HOME     = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
if (Test-Path $asciiNdk) {
    $env:ANDROID_NDK_HOME = $asciiNdk
    $env:ANDROID_NDK_ROOT = $asciiNdk
} else {
    $ndkRoot = Join-Path $env:ANDROID_HOME "ndk"
    if (Test-Path $ndkRoot) {
        $ndkVer = Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($ndkVer) { $env:ANDROID_NDK_HOME = $ndkVer.FullName; $env:ANDROID_NDK_ROOT = $ndkVer.FullName }
    }
}
if (Test-Path $asciiRustc) { $env:RUSTC = $asciiRustc }
$env:Path = "$cargoBin;" + $env:Path

# ---------- 1) 绑定（API 改动才需要） ----------
if ($needCodegen) {
    Write-Host "[rust-hook] 重新生成 Dart 绑定 (flutter_rust_bridge_codegen generate) ..." -ForegroundColor Cyan
    # 用 cmd /c 做输出重定向：PS5.1 下 native 命令写 stderr 会因 Stop 偏好被误判为致命错误
    Push-Location $realSource
    try {
        & cmd /c "`"$cargoBin\flutter_rust_bridge_codegen.exe`" generate > `"$hookLog`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Get-Content $hookLog -Tail 20 | Write-Host
            throw "[rust-hook] 绑定生成失败 (exit=$LASTEXITCODE)"
        }
    } finally { Pop-Location }
}

# ---------- 2) 交叉编译 .so ----------
if ($needSo) {
    Write-Host "[rust-hook] 交叉编译 .so（输出记录于 $hookLog）..." -ForegroundColor Cyan
    # 不用 cargo ndk 的 -o：它会把依赖 crate 的 cdylib（libboa_engine 等）一起拷进
    # jniLibs。这里只编译，再手动拷贝唯一的最终产物 libxianyu_core.so。
    Push-Location (Join-Path $realSource "rust")
    try {
        & cmd /c "cargo ndk -t arm64-v8a -t armeabi-v7a build --release > `"$hookLog`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Get-Content $hookLog -Tail 30 | Write-Host
            throw "[rust-hook] cargo ndk 编译失败 (exit=$LASTEXITCODE)"
        }
    } finally { Pop-Location }
    $soMap = @{
        "aarch64-linux-android"     = "arm64-v8a"
        "armv7-linux-androideabi"   = "armeabi-v7a"
    }
    foreach ($t in $soMap.Keys) {
        $src = Join-Path $realSource "rust\target\$t\release\libxianyu_core.so"
        $dst = Join-Path $realSource "android\app\src\main\jniLibs\$($soMap[$t])"
        Copy-Item $src -Destination $dst -Force
    }
    # 清掉历史上 -o 误拷进来的依赖 cdylib
    Get-ChildItem (Join-Path $realSource "android\app\src\main\jniLibs") -Recurse -Filter "*.so" |
        Where-Object { $_.Name -ne "libxianyu_core.so" } | Remove-Item -Force
}

# ---------- API 改动：新绑定只能在下次构建的 Dart 编译中生效，中止本次 ----------
if ($needCodegen) {
    Write-Host ""
    Write-Host "[rust-hook] Rust API 绑定已重新生成（.so 也已更新）。" -ForegroundColor Yellow
    Write-Host "[rust-hook] 本次构建的 Dart 部分仍使用旧绑定，为避免哈希不匹配已中止。" -ForegroundColor Yellow
    Write-Host "[rust-hook] => 请重新运行一次 flutter run / flutter build 即可。" -ForegroundColor Green
    exit 3
}

Write-Host "[rust-hook] .so 已更新" -ForegroundColor Green
exit 0
