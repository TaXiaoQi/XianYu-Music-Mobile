# build-rust-ohos.ps1 - 为 OpenHarmony/HarmonyOS NEXT 交叉编译 libxianyu_core.so
#
# 目标三元组: aarch64-unknown-linux-ohos（Rust Tier 2，rustup 官方分发）
# 工具链来源: DevEco Studio / Command-Line Tools 的 HarmonyOS SDK（native/llvm + native/sysroot）
#
# 用法:
#   ./scripts/build-rust-ohos.ps1                        # 自动探测 SDK
#   ./scripts/build-rust-ohos.ps1 -SdkRoot <OHOS SDK 根>  # 指定 SDK（其下应有 native/llvm/bin/clang.exe）
#
# 产物:
#   rust/target/aarch64-unknown-linux-ohos/release/libxianyu_core.so
#   若 poc_ohos/ohos/entry 已生成，自动拷贝到 poc_ohos/ohos/entry/libs/arm64-v8a/
param([string]$SdkRoot = "")

$ErrorActionPreference = 'Stop'

# ---- 0. 目录定位 ----
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path   # poc_ohos/scripts
$PocDir    = Split-Path -Parent $ScriptDir                     # poc_ohos
$MobileDir = Split-Path -Parent $PocDir                        # XianYu-Music-Mobile
$RustDir   = Join-Path $MobileDir 'rust'
$Target    = 'aarch64-unknown-linux-ohos'
$CargoEnvT = 'aarch64_unknown_linux_ohos'

Write-Host "== 弦予 xianyu_core -> OpenHarmony (arm64) =="

# ---- 1. cargo / rustup ----
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if (Test-Path $CargoBin) { $env:PATH = "$CargoBin;$env:PATH" }
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw '未找到 cargo，请先安装 Rust 工具链' }
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { throw '未找到 rustup' }

# ---- 2. 探测 OHOS SDK（找 native/llvm/bin/clang.exe）----
function Find-SdkRoot([string]$root) {
    if (-not $root -or -not (Test-Path $root)) { return $null }
    $cands = @(
        (Join-Path $root 'native\llvm\bin\clang.exe'),
        (Join-Path $root 'default\openharmony\native\llvm\bin\clang.exe')
    )
    foreach ($c in $cands) {
        if (Test-Path $c) {
            # clang.exe 位于 .../native/llvm/bin/ 下，向上三级取 native 目录
            return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $c)))
        }
    }
    # 版本目录两层 glob（如 sdk/HarmonyOS-NEXT-DB6/openharmony/native、sdk/default/openharmony/native）
    $hits = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue
    } | ForEach-Object { Join-Path $_.FullName 'native\llvm\bin\clang.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($hits) { return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $hits))) }
    return $null
}

$NativeRoot = $null
foreach ($cand in @(
        $SdkRoot, $env:DEVECO_SDK_HOME, $env:HOS_SDK_HOME, $env:OHOS_SDK_HOME, $env:OHOS_BASE_SDK_HOME,
        'C:\Program Files\Huawei\DevEco Studio\sdk',
        'D:\Program Files\Huawei\DevEco Studio\sdk',
        (Join-Path $env:LOCALAPPDATA 'Huawei\Sdk'),
        (Join-Path $env:USERPROFILE 'Huawei\Sdk'))) {
    if ($NativeRoot) { break }
    $NativeRoot = Find-SdkRoot $cand
}
if (-not $NativeRoot) {
    throw "未找到 HarmonyOS SDK（native/llvm/bin/clang.exe）。请先安装 DevEco Studio（含 SDK）后重试，或用参数显式指定：./scripts/build-rust-ohos.ps1 -SdkRoot '<SDK 根目录>'"
}
$Clang    = Join-Path $NativeRoot 'llvm\bin\clang.exe'
$Clangpp  = Join-Path $NativeRoot 'llvm\bin\clang++.exe'
$LlvmAr   = Join-Path $NativeRoot 'llvm\bin\llvm-ar.exe'
$LlvmRan  = Join-Path $NativeRoot 'llvm\bin\llvm-ranlib.exe'
$Sysroot  = Join-Path $NativeRoot 'sysroot'
Write-Host "SDK native: $NativeRoot"
if (-not (Test-Path $Sysroot)) { throw "未找到 sysroot：$Sysroot" }

# ---- 3. rustup target ----
$Installed = & rustup target list --installed 2>$null
if ($Installed -notcontains $Target) {
    Write-Host "安装 rust target: $Target"
    & rustup target add $Target
    if ($LASTEXITCODE -ne 0) { throw "rustup target add $Target 失败" }
}

# ---- 4. 生成 linker / CC wrapper（clang 需带 --target/--sysroot 参数）----
$ToolchainDir = Join-Path $PocDir '.toolchain-ohos'
New-Item -ItemType Directory -Force -Path $ToolchainDir | Out-Null
$LinkerCmd   = Join-Path $ToolchainDir "$Target-clang.cmd"
$LinkerxxCmd = Join-Path $ToolchainDir "$Target-clang++.cmd"
$inner   = '"{0}" --target=aarch64-linux-ohos --sysroot="{1}" -D__MUSL__ %*' -f $Clang, $Sysroot
[System.IO.File]::WriteAllText($LinkerCmd, "@echo off`r`n$inner`r`n", [System.Text.UTF8Encoding]::new($false))
$innerxx = '"{0}" --target=aarch64-linux-ohos --sysroot="{1}" -D__MUSL__ %*' -f $Clangpp, $Sysroot
[System.IO.File]::WriteAllText($LinkerxxCmd, "@echo off`r`n$innerxx`r`n", [System.Text.UTF8Encoding]::new($false))

# ---- 5. 编译环境变量 ----
Set-Item -Path "env:CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER" -Value $LinkerCmd
Set-Item -Path "env:CC_$CargoEnvT"  -Value $LinkerCmd
Set-Item -Path "env:CXX_$CargoEnvT" -Value $LinkerxxCmd
if (Test-Path $LlvmAr)  { Set-Item -Path "env:AR_$CargoEnvT" -Value $LlvmAr }
if (Test-Path $LlvmRan) { Set-Item -Path "env:RANLIB_$CargoEnvT" -Value $LlvmRan }

# bindgen（rquickjs 需 libclang）：优先 SDK 自带，其次本机 LLVM
$LibclangDir = Join-Path $NativeRoot 'llvm\bin'
if (-not (Test-Path (Join-Path $LibclangDir 'libclang.dll'))) {
    if (Test-Path 'C:\Program Files\LLVM\bin\libclang.dll') {
        $LibclangDir = 'C:\Program Files\LLVM\bin'
    } else {
        Write-Warning '未找到 libclang.dll：rquickjs(bindgen) 可能编译失败。可 winget install LLVM.LLVM 后重试'
    }
}
Set-Item -Path 'env:LIBCLANG_PATH' -Value $LibclangDir
$bindgenArgs = '--sysroot="{0}" -D__MUSL__ -I"{0}/usr/include"' -f $Sysroot
Set-Item -Path 'env:BINDGEN_EXTRA_CLANG_ARGS' -Value $bindgenArgs
Set-Item -Path "env:BINDGEN_EXTRA_CLANG_ARGS_$CargoEnvT" -Value $bindgenArgs

# ---- 6. cargo build ----
Write-Host "开始编译: cargo build --release --target $Target"
& cargo build --release --target $Target --manifest-path (Join-Path $RustDir 'Cargo.toml')
if ($LASTEXITCODE -ne 0) {
    throw "编译失败。常见排查：
  - rquickjs/bindgen 报错 -> 检查 LIBCLANG_PATH（当前: $LibclangDir）
  - C 编译找不到头文件    -> 检查 sysroot 路径与 BINDGEN_EXTRA_CLANG_ARGS
  - 链接器报错           -> 检查 $LinkerCmd 内容（SDK 路径含空格需引号）"
}

# ---- 7. 产物拷贝 ----
$So = Join-Path $RustDir "target\$Target\release\libxianyu_core.so"
if (-not (Test-Path $So)) { throw "产物缺失：$So" }
$SoInfo = Get-Item $So
Write-Host ("产物: {0}  ({1:N1} MB)" -f $So, ($SoInfo.Length / 1MB))

$DestDir = Join-Path $PocDir 'ohos\entry\libs\arm64-v8a'
if (Test-Path (Join-Path $PocDir 'ohos\entry')) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    Copy-Item $So (Join-Path $DestDir 'libxianyu_core.so') -Force
    Write-Host "已拷贝到: $DestDir\libxianyu_core.so"
} else {
    Write-Warning 'poc_ohos/ohos/entry 尚未生成（先跑 scripts/setup.ps1），产物保留在 rust/target 下'
}

Write-Host '== 完成 =='