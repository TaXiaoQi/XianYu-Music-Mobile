$ErrorActionPreference = "Stop"
$realSource = Split-Path -Parent $PSScriptRoot

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

$needSo = $true
if (Test-Path $soFile) {
    $soTime = (Get-Item $soFile).LastWriteTime
    $newestAll = @($newestRust, (($configFiles | Measure-Object LastWriteTime -Maximum).Maximum)) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    if ($newestAll -le $soTime) { $needSo = $false }
}

$needCodegen = $true
if (Test-Path $bindings) {
    if ($newestRust -le (Get-Item $bindings).LastWriteTime) { $needCodegen = $false }
}

if (-not $needSo -and -not $needCodegen) { exit 0 }

Write-Host "[rust-hook] Building Rust..." -ForegroundColor Yellow

$cargoBin = if ($env:CARGO_HOME) {
    Join-Path $env:CARGO_HOME "bin"
} else {
    Join-Path $env:USERPROFILE ".cargo\bin"
}
if (-not (Test-Path $cargoBin)) {
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargoCmd) { $cargoBin = Split-Path $cargoCmd.Source -Parent }
}
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

if ($needCodegen) {
    Write-Host "[rust-hook] Generating Dart bindings..." -ForegroundColor Cyan
    $codegenExe = Join-Path $cargoBin "flutter_rust_bridge_codegen.exe"
    if (-not (Test-Path $codegenExe)) { $codegenExe = "flutter_rust_bridge_codegen" }
    $uncPrefix = [string][char]92 + [char]92 + [char]63 + [char]92
    $rustRoot = $uncPrefix + (Join-Path $realSource 'rust')
    $rustOut = $uncPrefix + (Join-Path $realSource 'rust\src\frb_generated.rs')
    Push-Location $realSource
    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $codegenExe
        $pInfo.Arguments = "generate --rust-root `"$rustRoot`" --rust-output `"$rustOut`""
        $pInfo.WorkingDirectory = $realSource
        $pInfo.UseShellExecute = $false
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($pInfo)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $stdout = $tOut.Result
        $stderr = $tErr.Result
        Set-Content -Path $hookLog -Value ($stdout + "`n" + $stderr) -Encoding UTF8
        if ($p.ExitCode -ne 0) {
            Get-Content $hookLog -Tail 20 | Write-Host
            throw "[rust-hook] Codegen failed (exit=$($p.ExitCode))"
        }
    } finally { Pop-Location }
}

if ($needSo) {
    Write-Host "[rust-hook] Compiling .so..." -ForegroundColor Cyan
    Push-Location (Join-Path $realSource "rust")
    try {
        $cargoExe = Join-Path $cargoBin "cargo.exe"
        if (-not (Test-Path $cargoExe)) { $cargoExe = "cargo" }
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = $cargoExe
        $pInfo.Arguments = "ndk -t arm64-v8a build --release"
        $pInfo.WorkingDirectory = Join-Path $realSource "rust"
        $pInfo.UseShellExecute = $false
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($pInfo)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $stdout = $tOut.Result
        $stderr = $tErr.Result
        Set-Content -Path $hookLog -Value ($stdout + "`n" + $stderr) -Encoding UTF8
        if ($p.ExitCode -ne 0) {
            Get-Content $hookLog -Tail 30 | Write-Host
            throw "[rust-hook] cargo ndk build failed (exit=$($p.ExitCode))"
        }
    } finally { Pop-Location }
    $src = Join-Path $realSource "rust\target\aarch64-linux-android\release\libxianyu_core.so"
    $dst = Join-Path $realSource "android\app\src\main\jniLibs\arm64-v8a"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item $src -Destination $dst -Force
    Get-ChildItem (Join-Path $realSource "android\app\src\main\jniLibs") -Recurse -Filter "*.so" |
        Where-Object { $_.Directory.Name -ne "arm64-v8a" -or $_.Name -ne "libxianyu_core.so" } |
        Remove-Item -Force
}

if ($needCodegen) {
    Write-Host "[rust-hook] Rust API bindings regenerated. Please re-run flutter run." -ForegroundColor Yellow
    exit 3
}

Write-Host "[rust-hook] .so updated successfully" -ForegroundColor Green
exit 0
