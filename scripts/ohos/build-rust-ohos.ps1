# build-rust-ohos.ps1 - cross-compile libxianyu_core.so for OpenHarmony/HarmonyOS NEXT
#
# Targets: aarch64-unknown-linux-ohos (real device) + x86_64-unknown-linux-ohos (emulator)
# Rust Tier 2 targets, distributed by rustup.
# Toolchain source: HarmonyOS SDK shipped with DevEco Studio (native/llvm + native/sysroot)
#
# Usage:
#   ./scripts/build-rust-ohos.ps1                          # both archs, auto-detect SDK
#   ./scripts/build-rust-ohos.ps1 -Archs aarch64           # single arch
#   ./scripts/build-rust-ohos.ps1 -SdkRoot <SDK root>      # SDK dir containing native/llvm/bin/clang.exe
#   ./scripts/build-rust-ohos.ps1 -RustDir <rust crate>    # xianyu_core crate dir (default: main project)
#
# Artifacts:
#   <rust>/target/<target>/release/libxianyu_core.so
#   auto-copied to ohos/entry/libs/{arm64-v8a,x86_64}/ when ohos/entry exists
param(
    [string]$SdkRoot = "",
    [string]$RustDir = "",
    [string[]]$Archs = @('aarch64', 'x86_64')
)

$ErrorActionPreference = 'Continue' # native tool stderr must not abort; explicit LASTEXITCODE checks below

# ---- 0. directory layout ----
# This script lives in <main project>\scripts\ohos\; the mirror build dir
# (space-free) receives the .so artifacts because hvigor/ohpm reject spaces.
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path        # scripts\ohos
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)    # main project
$MirrorDir  = if ($env:XIANYU_OHOS_MIRROR) { $env:XIANYU_OHOS_MIRROR } else { 'D:\xianyu-mobile-ohos' }

# Rust crate dir resolution: param > env > main project rust\
if (-not $RustDir -and $env:XIANYU_RUST_DIR) { $RustDir = $env:XIANYU_RUST_DIR }
if (-not $RustDir) { $RustDir = Join-Path $ProjectRoot 'rust' }
if (-not (Test-Path (Join-Path $RustDir 'Cargo.toml'))) { throw "xianyu_core crate not found: $RustDir" }

# ---- 1. cargo / rustup ----
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if (Test-Path $CargoBin) { $env:PATH = "$CargoBin;$env:PATH" }
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw 'cargo not found - install Rust toolchain first' }
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { throw 'rustup not found' }

# ---- 1.5 lld rejects non-ASCII paths (CN username breaks linking):
# junction/subst get canonicalized back by rustc, so hard-copy the toolchain
# to an ASCII path and call the real cargo/rustc (bypassing rustup proxies).
$SysrootProbe = (& rustc --print sysroot 2>$null | Select-Object -First 1)
if ($SysrootProbe -and ($SysrootProbe -match '[^\x00-\x7F]')) {
    $TcAscii = 'C:\rust-ohos-tc'
    if (-not (Test-Path "$TcAscii\bin\rustc.exe")) {
        Write-Host "Copying Rust toolchain to ASCII path $TcAscii (one-time, ~1GB, local copy)..."
        New-Item -ItemType Directory -Force -Path $TcAscii | Out-Null
        & robocopy $SysrootProbe $TcAscii /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy toolchain copy failed (exit=$LASTEXITCODE)" }
        Write-Host "Toolchain copy done"
    } else {
        # incremental sync: rustup target add installs std into the ORIGINAL
        # toolchain; the static copy must pick up new targets or rustc fails
        # with E0463 (can't find crate for core/std)
        & robocopy "$SysrootProbe\lib\rustlib" "$TcAscii\lib\rustlib" /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy rustlib sync failed (exit=$LASTEXITCODE)" }
    }
    Set-Item -Path 'env:RUSTUP_TOOLCHAIN' -Value 'stable-x86_64-pc-windows-msvc'
    $env:PATH = "$TcAscii\bin;$env:PATH"
    Write-Host "Switched to ASCII toolchain: $TcAscii"
}

# ---- 2. locate OHOS SDK (native/llvm/bin/clang.exe) ----
function Find-SdkRoot([string]$root) {
    if (-not $root -or -not (Test-Path $root)) { return $null }
    $cands = @(
        (Join-Path $root 'native\llvm\bin\clang.exe'),
        (Join-Path $root 'default\openharmony\native\llvm\bin\clang.exe')
    )
    foreach ($c in $cands) {
        if (Test-Path $c) {
            return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $c)))
        }
    }
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
    throw "HarmonyOS SDK not found (native/llvm/bin/clang.exe). Install DevEco Studio first or pass -SdkRoot explicitly."
}
$Clang    = Join-Path $NativeRoot 'llvm\bin\clang.exe'
$Clangpp  = Join-Path $NativeRoot 'llvm\bin\clang++.exe'
$LlvmAr   = Join-Path $NativeRoot 'llvm\bin\llvm-ar.exe'
$LlvmRan  = Join-Path $NativeRoot 'llvm\bin\llvm-ranlib.exe'
$Sysroot  = Join-Path $NativeRoot 'sysroot'
Write-Host "SDK native: $NativeRoot"
if (-not (Test-Path $Sysroot)) { throw "sysroot not found: $Sysroot" }

# bindgen (rquickjs needs libclang): prefer SDK-bundled, fallback to local LLVM
$LibclangDir = Join-Path $NativeRoot 'llvm\bin'
if (-not (Test-Path (Join-Path $LibclangDir 'libclang.dll'))) {
    if (Test-Path 'C:\Program Files\LLVM\bin\libclang.dll') {
        $LibclangDir = 'C:\Program Files\LLVM\bin'
    } else {
        Write-Warning 'libclang.dll not found: rquickjs(bindgen) may fail. Consider: winget install LLVM.LLVM'
    }
}
Set-Item -Path 'env:LIBCLANG_PATH' -Value $LibclangDir

# ---- 3. per-arch build ----
# map: rust arch triple -> clang target triple / env suffix / libs dir name
$ArchMap = @{
    'aarch64' = @{ Rust='aarch64-unknown-linux-ohos'; Clang='aarch64-linux-ohos'; Env='aarch64_unknown_linux_ohos'; Libs='arm64-v8a' }
    'x86_64'  = @{ Rust='x86_64-unknown-linux-ohos';  Clang='x86_64-linux-ohos';  Env='x86_64_unknown_linux_ohos';  Libs='x86_64' }
}

# linker wrapper dir must be space-free (cargo passes it through cc chains)
$ToolchainDir = 'D:\xianyu-ohos-toolchain'
New-Item -ItemType Directory -Force -Path $ToolchainDir | Out-Null

$failed = @()
foreach ($arch in $Archs) {
    $m = $ArchMap[$arch]
    if (-not $m) { throw "unknown arch: $arch (valid: aarch64, x86_64)" }
    $Target = $m.Rust; $ClangTarget = $m.Clang; $CargoEnvT = $m.Env
    Write-Host ""
    Write-Host "== building $Target ==" -ForegroundColor Cyan

    # rustup target
    $Installed = & rustup target list --installed 2>$null
    if ($Installed -notcontains $Target) {
        Write-Host "installing rust target: $Target"
        & rustup target add $Target
        if ($LASTEXITCODE -ne 0) { throw "rustup target add $Target failed" }
    }

    # linker / CC wrappers (clang needs --target/--sysroot)
    $LinkerCmd   = Join-Path $ToolchainDir "$Target-clang.cmd"
    $LinkerxxCmd = Join-Path $ToolchainDir "$Target-clang++.cmd"
    $inner   = '"{0}" --target={1} --sysroot="{2}" -D__MUSL__ %*' -f $Clang, $ClangTarget, $Sysroot
    [System.IO.File]::WriteAllText($LinkerCmd, "@echo off`r`n$inner`r`n", [System.Text.UTF8Encoding]::new($false))
    $innerxx = '"{0}" --target={1} --sysroot="{2}" -D__MUSL__ %*' -f $Clangpp, $ClangTarget, $Sysroot
    [System.IO.File]::WriteAllText($LinkerxxCmd, "@echo off`r`n$innerxx`r`n", [System.Text.UTF8Encoding]::new($false))

    # build env (per-target, uppercase var name for linker per cargo convention)
    Set-Item -Path "env:CARGO_TARGET_$($CargoEnvT.ToUpper())_LINKER" -Value $LinkerCmd
    Set-Item -Path "env:CC_$CargoEnvT"  -Value $LinkerCmd
    Set-Item -Path "env:CXX_$CargoEnvT" -Value $LinkerxxCmd
    if (Test-Path $LlvmAr)  { Set-Item -Path "env:AR_$CargoEnvT" -Value $LlvmAr }
    if (Test-Path $LlvmRan) { Set-Item -Path "env:RANLIB_$CargoEnvT" -Value $LlvmRan }

    $bindgenArgs = '--sysroot="{0}" -D__MUSL__ -I"{0}/usr/include"' -f $Sysroot
    Set-Item -Path 'env:BINDGEN_EXTRA_CLANG_ARGS' -Value $bindgenArgs
    Set-Item -Path "env:BINDGEN_EXTRA_CLANG_ARGS_$CargoEnvT" -Value $bindgenArgs

    Write-Host "cargo build --release --target $Target"
    & cargo build --release --target $Target --manifest-path (Join-Path $RustDir 'Cargo.toml')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "build FAILED for $Target" -ForegroundColor Red
        $failed += $Target
        continue
    }

    # copy artifact into the mirror build dir (hvigor rejects space paths)
    $So = Join-Path $RustDir "target\$Target\release\libxianyu_core.so"
    if (-not (Test-Path $So)) { throw "artifact missing: $So" }
    $SoInfo = Get-Item $So
    Write-Host ("artifact: {0}  ({1:N1} MB)" -f $So, ($SoInfo.Length / 1MB))

    $DestDir = Join-Path $MirrorDir "ohos\entry\libs\$($m.Libs)"
    if (Test-Path (Join-Path $MirrorDir 'ohos\entry')) {
        New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
        Copy-Item $So (Join-Path $DestDir 'libxianyu_core.so') -Force
        Write-Host "copied to: $DestDir\libxianyu_core.so"
    } else {
        Write-Warning "mirror ohos/entry missing ($MirrorDir) - run build-ohos.ps1 first; artifact kept under rust/target"
    }
}

if ($failed.Count -gt 0) {
    throw "some targets failed: $($failed -join ', '). Troubleshoot: LIBCLANG_PATH=$LibclangDir / sysroot / linker cmd in $ToolchainDir"
}
Write-Host ''
Write-Host '== all done ==' -ForegroundColor Green
