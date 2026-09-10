# verify.ps1 - full-chain verification: pub get -> flutter build hap --debug
# Must be run with: powershell -NoProfile -File scripts\verify.ps1
# (Dot-sources env-ohos.ps1 for toolchain + PUB_CACHE setup.)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

# ohpm does not quote --target_path: paths with spaces (e.g. "D:\Program Files\...")
# get truncated and fail. Map the project to a drive letter without spaces and
# run everything from there.
$PocDrive = 'V:'
$PocPath = "$PocDrive\"
if ($ProjectRoot -match ' ') {
    if (-not (Test-Path $PocPath)) {
        subst $PocDrive $ProjectRoot | Out-Null
        if (-not (Test-Path $PocPath)) { throw "subst $PocDrive failed" }
        Write-Host "Mapped $PocDrive -> $ProjectRoot"
    }
    $ProjectRoot = $PocPath
}

# 1. Load Flutter-OH env (sets PUB_CACHE=D:\pub-cache, mirrors, DevEco tools)
. (Join-Path $PSScriptRoot 'env-ohos.ps1')

# gitcode LFS server is missing some objects (e.g. audio_session example/ files);
# those are not needed for the build - skip LFS smudge.
$env:GIT_LFS_SKIP_SMUDGE = '1'

Set-Location $ProjectRoot
Write-Host "== PUB_CACHE = $env:PUB_CACHE ==" -ForegroundColor Cyan

# 2. Refresh dependency resolution (regenerates .flutter-plugins-dependencies
#    with plugin paths under the new D-drive pub cache)
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed: $LASTEXITCODE" }

# 3. Sanity check: plugin paths must be on the same drive as the project
$deps = Get-Content (Join-Path $ProjectRoot '.flutter-plugins-dependencies') -Raw
if ($deps -match 'C:/Users') {
    throw '.flutter-plugins-dependencies still references C:/Users - pub cache not switched'
}
Write-Host 'Plugin paths OK (no C:/Users references).' -ForegroundColor Green

# 4. Patch embedding for local SDK (idempotent; needed again after ohpm reinstall)
& (Join-Path $PSScriptRoot 'patch-embedding.ps1')

# 5. Build HAP (debug)
flutter build hap --debug
if ($LASTEXITCODE -ne 0) { throw "flutter build hap failed: $LASTEXITCODE" }

# 6. Report artifact
$hap = Get-ChildItem (Join-Path $ProjectRoot 'build') -Recurse -Filter *.hap -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($hap) {
    Write-Host "SUCCESS: $($hap.FullName) ($([math]::Round($hap.Length/1MB,1)) MB)" -ForegroundColor Green
} else {
    Write-Host 'Build finished but no .hap found under build/.' -ForegroundColor Yellow
}
