#requires -version 5.1
<#
.SYNOPSIS
  HarmonyOS build entry: toolchain -> ohos HAP, all automated.

.DESCRIPTION
  Builds the HarmonyOS HAP in the main project directory IN PLACE (the
  project now lives at a space-free path, which is all ohpm/hvigor require).
  Rust (cargo) and FRB codegen run in the main project too.

  LEGACY MIRROR MODE: setting XIANYU_OHOS_MIRROR to a space-free directory
  restores the old mirror workflow (robocopy /MIR source -> mirror, Dart /
  hvigor / ohpm run in the mirror, ohos/ sources back-synced). Only needed
  if the project ever moves back under a path containing spaces.

  Usage:
    .\scripts\ohos\build-ohos.ps1                    # build RELEASE HAP (archives to releases\ohos)
    .\scripts\ohos\build-ohos.ps1 -Run               # flutter run (foreground; daily testing)
    .\scripts\ohos\build-ohos.ps1 -Run -d 127.0.0.1:5555
    .\scripts\ohos\build-ohos.ps1 -SkipRust          # reuse existing .so
    .\scripts\ohos\build-ohos.ps1 -Codegen           # force FRB regeneration
    .\scripts\ohos\build-ohos.ps1 -AppPack           # HAP + signed .app for AppGallery
#>
param(
    [switch]$Run,
    [switch]$SkipRust,
    [switch]$SkipMirror,
    [switch]$Codegen,
    # Also pack the signed .app (App Pack) for AppGallery upload, after the HAP
    # build succeeds. Ignored with -Run (no build artifacts).
    [switch]$AppPack,
    [string]$Device = '',
    # Target CPU ABI for `flutter build hap` (default: auto-detect from the
    # connected device). flutter run picks the device ABI automatically, but
    # `flutter build hap` defaults to ohos-arm64 ONLY — installing that HAP on
    # an x86_64 emulator crashes at startup with "Cannot read property
    # nativeInit of undefined" (missing libs/x86_64/libflutter.so).
    [ValidateSet('', 'x64', 'arm64')]
    [string]$Abi = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$FlutterArgs
)

$ErrorActionPreference = 'Continue' # native tool stderr must not abort; explicit LASTEXITCODE checks below
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path            # scripts\ohos
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)         # main project
# In-place build by default (space-free path). XIANYU_OHOS_MIRROR points at a
# separate mirror dir to restore the legacy mirror workflow (see DESCRIPTION).
$MirrorDir   = if ($env:XIANYU_OHOS_MIRROR) { $env:XIANYU_OHOS_MIRROR } else { $ProjectRoot }
$InPlace     = $MirrorDir -ieq $ProjectRoot
. (Join-Path $ScriptDir 'pub-state.ps1')   # Enter/Exit-XianyuOhosPubState

# ---- signing password auto-encryption ----
# hvigor ALWAYS reads storePassword/keyPassword as an ENCRYPTED hex blob
# (DecipherUtil.decryptPwd): an even, >=32-char plain-text password passes the
# length checks but then fails with 00304032 "Signing materials <dir> is an
# empty directory" because it looks for the material key tree. This helper
# re-encodes a PLAIN password to the DevEco encrypted hex using the machine-wide
# material tree at <storeFile parent>\material before the canonical write.
function Invoke-EncryptSignPassword {
    param([string]$StoreFile, [string]$Password)
    if (-not $Password) { return '' }
    # already-encrypted blobs are long & pure hex -> leave untouched
    if ($Password -match '^[0-9a-fA-F]+$' -and $Password.Length -ge 64 -and ($Password.Length % 2) -eq 0) {
        return $Password
    }
    $nodeJs = Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $nodeJs) { throw 'node not found - required to encrypt the signing password' }
    $helper  = Join-Path $ScriptDir 'ohos-sign-password.mjs'
    $materialDir = Split-Path $StoreFile -Parent
    $out = & $nodeJs $helper $materialDir $Password 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $out -notmatch 'encryptedHex:\s*([0-9a-fA-F]+)') {
        throw "signing password encryption failed (storeFile=$StoreFile): $($out.Trim())"
    }
    return $Matches[1].Trim()
}

function Update-SigningPasswords {
    param([string]$SignJson)
    if (-not $SignJson -or $SignJson -eq '[]') { return $SignJson }
    try { $arr = $SignJson | ConvertFrom-Json } catch { return $SignJson }
    foreach ($cfg in $arr) {
        $m = $cfg.material
        if (-not $m -or -not $m.storeFile) { continue }
        foreach ($f in @('storePassword','keyPassword')) {
            if ($m.PSObject.Properties.Name -contains $f) {
                $m.$f = Invoke-EncryptSignPassword -StoreFile $m.storeFile -Password $m.$f
            }
        }
    }
    return (ConvertTo-Json -InputObject $arr.PSObject.BaseObject -Depth 8 -Compress)
}

# ---- 1. session -> Flutter-OH toolchain ----
. (Join-Path $ScriptDir 'env-ohos.ps1')

# ---- 2. version sync (version.ts -> pubspec / account_api) ----
# official flutter's dart first (bin\dart.bat), Flutter-OH cache dart.exe fallback
$DartOfficial = 'C:\flutter\sdk_tmp\flutter\bin\dart.bat'
$DartOhos     = Join-Path $FlutterOhos 'bin\cache\dart-sdk\bin\dart.exe'
$DartBin = if (Test-Path $DartOfficial) { $DartOfficial }
           elseif (Test-Path $DartOhos) { $DartOhos }
           else { 'dart.bat' }
Write-Host "[ohos] sync version (version.ts -> pubspec/account_api) ..." -ForegroundColor Cyan
Push-Location $ProjectRoot
try { & $DartBin run tool/sync_version.dart; if ($LASTEXITCODE -ne 0) { throw "sync_version failed ($LASTEXITCODE)" } }
finally { Pop-Location }

# ---- 3. FRB codegen (optional, main project, space-safe via \\?\ prefix) ----
if ($Codegen) {
    Write-Host "[ohos] FRB codegen ..." -ForegroundColor Cyan
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }
    $codegenExe = Join-Path $cargoBin 'flutter_rust_bridge_codegen.exe'
    if (-not (Test-Path $codegenExe)) { $codegenExe = 'flutter_rust_bridge_codegen' }
    $unc = [string][char]92 + [char]92 + [char]63 + [char]92
    $rustRoot = $unc + (Join-Path $ProjectRoot 'rust')
    $rustOut  = $unc + (Join-Path $ProjectRoot 'rust\src\frb_generated.rs')
    # libclang for rquickjs-sys bindgen: SDK llvm first, local LLVM fallback
    $llvmCandidates = @(
        (Join-Path $env:DEVECO_SDK_HOME 'native\llvm\bin'),
        'C:\Program Files\LLVM\bin'
    )
    foreach ($l in $llvmCandidates) {
        if (Test-Path (Join-Path $l 'libclang.dll')) { $env:LIBCLANG_PATH = $l; break }
    }
    Push-Location $ProjectRoot
    try {
        & $codegenExe generate --rust-root "$rustRoot" --rust-output "$rustOut"
        if ($LASTEXITCODE -ne 0) { throw "FRB codegen failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}

# ---- 4. mirror sync (only in legacy XIANYU_OHOS_MIRROR mode) ----
if (-not $InPlace -and -not $SkipMirror) {
    Write-Host "[ohos] mirroring project -> $MirrorDir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $MirrorDir | Out-Null
    # /XD names match at any depth. Kept out of the mirror on purpose: VCS,
    # other-platform builds, rust (built in-place), generated caches. `libs` and
    # `oh_modules` preserve mirror-only artifacts (the .so copies, ohpm install)
    # from being wiped by /MIR. build-profile.json5 excluded via /XF so the
    # user's local signing config in the mirror is never overwritten.
    # /XF matches SOURCE paths for copy and DEST paths for deletion: bare
    # names exclude main->mirror copy of files the mirror must own.
    # (pubspec.lock: mirror keeps its ohos-resolved lock - main's would churn
    # pub get + ohpm prune every run, unmaterializing patches)
    & robocopy $ProjectRoot $MirrorDir /MIR /NFL /NDL /NJH /NJS /NP `
        /XD .git .dart_tool .idea build .gradle releases poc_ohos android ios docs test tool oh_modules node_modules .hvigor "$MirrorDir\rust" "$MirrorDir\ohos\entry\libs" `
        /XF pubspec_overrides.yaml pubspec.lock "$ProjectRoot\ohos\build-profile.json5" "$MirrorDir\ohos\build-profile.json5" local.properties *.hap *.so
    if ($LASTEXITCODE -ge 8) { throw "robocopy mirror failed (exit=$LASTEXITCODE)" }
    # robocopy success codes 0-7; normalize for the rest of the script
    $global:LASTEXITCODE = 0
}

# ---- 5. in-project: ohos dependency state (overrides + lock) -> pub get ----
# 进入 fork 解析态（写 overrides + 从 android 快照恢复 lock），整个构建期持有，
# 结束（含失败）由外层 finally 恢复 Android/iOS 干净态 —— fork 包引用
# TargetPlatform.ohos，覆盖文件绝不能滞留主工程，否则 Android/iOS pub get 被劫持。
Enter-XianyuOhosPubState -Root $MirrorDir -ScriptDir $ScriptDir
try {

Push-Location $MirrorDir
try {
    # overrides 由 Enter-XianyuOhosPubState 从模板写入（唯一事实源，强制重写）
    Write-Host '[ohos] pubspec_overrides.yaml synced from template'

    # create/repair the ohos template: trigger on the entry module profile
    # (a bare `ohos/` existence check is not enough - partial trees from an
    # interrupted bootstrap would skip create and leave the template broken)
    if (-not (Test-Path (Join-Path $MirrorDir 'ohos\entry\build-profile.json5'))) {
        Write-Host '[ohos] flutter create --platforms ohos (first run) ...' -ForegroundColor Cyan
        & flutter create --platforms ohos --project-name xianyu_music_mobile .
        if ($LASTEXITCODE -ne 0) { throw "flutter create failed ($LASTEXITCODE)" }
    }

    # bundle name: NO rewrite - the main project's ohos/AppScope/app.json5 is
    # the single source of truth (com.xianyumusic.app since the AGC release
    # alignment, commit 36704e1). Earlier revisions forced the PoC debug
    # profile's bundle name here; that material is now obsolete and any
    # rewrite would clobber the release-aligned name.

    # useNormalizedOHMUrl: tencent_kit's @tencent/qq-open-sdk is a BYTECODE har
    # and hvigor refuses it without normalized OHM urls (00306046). DevEco 6 /
    # hvigor schema requires buildOption INSIDE the product object (root-level
    # buildOption is rejected: allowed root keys are app/modules only).
    # The file is REWRITTEN canonically every run (signingConfigs preserved) -
    # immune to stale-buffer writebacks and mirror recreation.
    $bpJson5 = Join-Path $MirrorDir 'ohos\build-profile.json5'

    # signingConfigs source, in order of preference:
    # 1. main project ohos/build-profile.json5 (DevEco "Automatically generate
    #    signature" run on the main project - the project the user actually
    #    opens; material is machine-wide in ~\.ohos\config and bound to the
    #    release bundle name com.xianyumusic.app). Main FIRST: fresh signing
    #    immediately wins over stale mirror material.
    # 2. the mirror's existing signingConfigs (auto-signing run on the mirror
    #    project, or a prior canonical write).
    # 3. PoC debug profile (D:\xianyu-poc) - LAST RESORT ONLY: bound to the
    #    retired cn.xianyumusic.xianyu_ohos_poc name, cannot sign
    #    com.xianyumusic.app (kept for a legacy-name rebuild only).
    $sign = '[]'
    foreach ($src in @(
        @{ Label = 'MAIN project build-profile'; Path = (Join-Path $ProjectRoot 'ohos\build-profile.json5') },
        @{ Label = 'mirror build-profile';       Path = $bpJson5 }
    )) {
        if ($sign -eq '[]' -and (Test-Path $src.Path)) {
            $content = [System.IO.File]::ReadAllText($src.Path, [System.Text.UTF8Encoding]::new($false))
            if ($content -match '"signingConfigs"\s*:\s*(\[[^\]]*\])') {
                $sign = $Matches[1].Trim()
                Write-Host "[ohos] signingConfigs imported from $($src.Label)"
            }
        }
    }
    if ($sign -eq '[]') {
        $pocBp = 'D:\xianyu-poc\ohos\build-profile.json5'
        if (Test-Path $pocBp) {
            $poc = [System.IO.File]::ReadAllText($pocBp, [System.Text.UTF8Encoding]::new($false))
            if ($poc -match '"signingConfigs"\s*:\s*(\[[^\]]*\])') {
                $sign = $Matches[1].Trim()
                Write-Host '[ohos] signingConfigs imported from PoC debug profile (BOUND TO RETIRED BUNDLE NAME - signing will fail for com.xianyumusic.app)' -ForegroundColor Yellow
            }
        }
    }
    # auto-encrypt PLAIN signing passwords -> DevEco encrypted hex (mirror build only)
    if ($sign -ne '[]') {
        $sign = Update-SigningPasswords -SignJson $sign
    }
    if (Test-Path $bpJson5) {
        $existing = [System.IO.File]::ReadAllText($bpJson5, [System.Text.UTF8Encoding]::new($false))
        $canonical = @'

{
  "app": {
    "signingConfigs": SIGNING,
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
        "compatibleSdkVersion": "5.1.0(18)",
        "runtimeOS": "HarmonyOS",
        "buildOption": {
          "strictMode": {
            "useNormalizedOHMUrl": true
          }
        }
      }
    ],
    "buildModeSet": [
      {
        "name": "debug"
      },
      {
        "name": "profile"
      },
      {
        "name": "release"
      }
    ]
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        {
          "name": "default",
          "applyToProducts": [
            "default"
          ]
        }
      ]
    }
  ]
}
'@.Replace('SIGNING', $sign)
        if ($existing.Trim() -ne $canonical.Trim()) {
            [System.IO.File]::WriteAllText($bpJson5, $canonical, [System.Text.UTF8Encoding]::new($false))
            Write-Host "[ohos] build-profile.json5 canonicalized (signingConfigs: $($sign.Substring(0, [Math]::Min(40, $sign.Length)))...)"
        }
    }

    Write-Host '[ohos] flutter pub get (mirror) ...' -ForegroundColor Cyan
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "pub get failed ($LASTEXITCODE)" }

    # NOTE: no manual `ohpm install` here - outside hvigor it only PRUNES the
    # materialized oh_modules without reinstalling (which would discard the
    # applied embedding patch and force a wasted first attempt every build).
    # oh_modules is materialized by hvigor during `flutter build hap`; if the
    # embedding package is (re)installed unpatched, attempt 1 fails and the
    # retry below patches + rebuilds. Steady state passes attempt 1 directly.
    & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
    & (Join-Path $ScriptDir 'manifest-ohos.ps1') -ProjectRoot $MirrorDir

    # ---- 6. legacy mirror mode: back-sync ohos/ template (source only) ----
    if (-not $InPlace) {
    $srcOhos = Join-Path $MirrorDir 'ohos'
    $dstOhos = Join-Path $ProjectRoot 'ohos'
    if (Test-Path $srcOhos) {
        New-Item -ItemType Directory -Force -Path $dstOhos | Out-Null
    # /XF matches SOURCE paths for copy: exclude the mirror's build-profile
    # (carries machine-local signing material) and local.properties from the
    # back-sync; entry's template build-profile.json5 still syncs.
    & robocopy $srcOhos $dstOhos /E /NFL /NDL /NJH /NJS /NP `
        /XD build oh_modules libs node_modules .hvigor .clangd `
        /XF "$srcOhos\build-profile.json5" local.properties *.hap *.so
        if ($LASTEXITCODE -ge 8) { throw "ohos/ back-sync failed (exit=$LASTEXITCODE)" }
        $global:LASTEXITCODE = 0
    }
    } # end legacy back-sync
} finally { Pop-Location }

# ---- 7. rust .so (built in the main project; artifact -> ohos/entry/libs,
#         which lives in the mirror only in legacy mirror mode) ----
if (-not $SkipRust) {
    & (Join-Path $ScriptDir 'build-rust-ohos.ps1')
    if ($LASTEXITCODE -ge 8) { throw "rust build failed" }
}

# ---- 8. build / run ----
# Target ABI: explicit -Abi wins; otherwise probe the connected device's ABI
# list (emulator = x86_64, phones = arm64). Falls back to arm64 when no device
# is reachable — matching the historical default.
$targetAbi = $Abi
if ($targetAbi -eq '') {
    $hdcExe = Join-Path $env:DEVECO_SDK_HOME 'default\openharmony\toolchains\hdc.exe'
    $abilist = ''
    if (Test-Path $hdcExe) {
        $abilist = (& $hdcExe shell param get const.product.cpu.abilist 2>$null | Out-String)
    }
    if ($abilist -match 'x86_64') { $targetAbi = 'x64' } else { $targetAbi = 'arm64' }
    Write-Host "[ohos] target ABI (auto-detected): $targetAbi" -ForegroundColor Cyan
} else {
    Write-Host "[ohos] target ABI (explicit): $targetAbi" -ForegroundColor Cyan
}

Push-Location $MirrorDir
try {
    if ($Run) {
        $runArgs = @('run')
        if ($Device) { $runArgs += @('-d', $Device) }
        if ($FlutterArgs) { $runArgs += $FlutterArgs }
        Write-Host "[ohos] flutter $($runArgs -join ' ')" -ForegroundColor Cyan
        & flutter @runArgs
        if ($LASTEXITCODE -ne 0) {
            # Same two-stage logic as build-hap below: DevEco opening the mirror
            # project (or any ohpm re-materialization) swaps the embedding
            # package to an unpatched instance, which fails attempt 1. Patch
            # (now-materialized) oh_modules and retry once. A SUCCESSFUL run
            # stays alive in this foreground session, so nonzero exit here
            # means a build failure, not an app exit.
            Write-Host '[ohos] flutter run attempt 1 failed - patch embedding and retry ...' -ForegroundColor Yellow
            & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
            & flutter @runArgs
            if ($LASTEXITCODE -ne 0) { throw "flutter run failed ($LASTEXITCODE)" }
        }
    } else {
        $buildArgs = @('build', 'hap')
        # Mode flag: honor an explicit --release/--profile/--debug passed through
        # in $FlutterArgs. Default is --release: archives are release-only (same as
        # the Android flow); debug testing goes through -Run, never build.
        $hasModeFlag = $false
        foreach ($a in $FlutterArgs) { if ($a -in @('--release', '--profile', '--debug')) { $hasModeFlag = $true } }
        if (-not $hasModeFlag) { $buildArgs += '--release' }
        if ($targetAbi -eq 'x64') { $buildArgs += @('--target-platform', 'ohos-x64') }
        elseif ($targetAbi -eq 'arm64') { $buildArgs += @('--target-platform', 'ohos-arm64') }
        if ($FlutterArgs) { $buildArgs += $FlutterArgs }
        Write-Host "[ohos] flutter $($buildArgs -join ' ') ..." -ForegroundColor Cyan
        & flutter @buildArgs
        if ($LASTEXITCODE -ne 0) {
            # First build on a fresh mirror fails by design: the embedding HAR
            # and plugin deps are only materialized DURING the build (ohpm
            # install runs inside hvigor, after the FlutterTask writes entry's
            # oh-package.json5), so the pre-build patch had no package to hit.
            # oh_modules is materialized now - patch and retry once. Steady-state
            # runs (oh_modules kept) already pass attempt 1.
            Write-Host '[ohos] attempt 1 failed - patch embedding (now materialized) and retry ...' -ForegroundColor Yellow
            & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
            & flutter @buildArgs
            if ($LASTEXITCODE -ne 0) { throw "build hap failed ($LASTEXITCODE)" }
        }
        $haps = Get-ChildItem (Join-Path $MirrorDir 'build') -Recurse -Filter *.hap -ErrorAction SilentlyContinue
        foreach ($h in $haps) { Write-Host ("  HAP: {0}  ({1:N1} MB)" -f $h.FullName, ($h.Length / 1MB)) -ForegroundColor Green }

        # ---- archive to releases\ohos (parity with the Android release flow) ----
        # Naming: 弦予音乐v<version>-Mobile-<arch>.hap, version verbatim from
        # version.ts (the single version source; '1.0.2-beta1' →
        # 弦予音乐v1.0.2-beta1-Mobile-arm64.hap, matching 弦予音乐v1.0.2-Mobile-arm64.apk
        # on Android). Arch suffix from -Abi: arm64/x64 → arm64/x86 (三端命名体系).
        # Explicit --debug builds are NOT archived - debug testing runs via -Run.
        # Folder is gitignored (/releases/).
        $buildMode = 'debug'
        foreach ($a in $FlutterArgs) {
            if ($a -eq '--release') { $buildMode = 'release' }
            elseif ($a -eq '--profile') { $buildMode = 'profile' }
        }
        $appVersion = '0.0.0'
        $versionTs = [System.IO.File]::ReadAllText((Join-Path $ProjectRoot 'version.ts'))
        if ($versionTs -match "APP_VERSION\s*=\s*'([^']+)'") { $appVersion = $Matches[1] }
        $relDir = Join-Path $ProjectRoot 'releases\ohos'
        $archSuffix = if ($targetAbi -eq 'x64') { 'x86' } else { 'arm64' }
        if ($buildMode -ne 'debug') {
            New-Item -ItemType Directory -Force -Path $relDir | Out-Null
            foreach ($h in $haps) {
                $dst = Join-Path $relDir ("弦予音乐v{0}-Mobile-{1}.hap" -f $appVersion, $archSuffix)
                Copy-Item $h.FullName $dst -Force
                Write-Host ("  archived: {0}" -f $dst) -ForegroundColor Green
            }
        }
        if ($AppPack) {
            # flutter build hap 只出 HAP（真机安装/调试）；上架 AppGallery 需要
            # .app（App Pack，一个或多个 HAP + pack.info）。assembleApp 是工程级
            # 任务（hvigor 根节点，勿带 --mode module 否则切到 entry 上下文找不到）。
            # $buildMode 已在上方 HAP 归档处解析（--release/--profile/--debug）。
            Push-Location (Join-Path $MirrorDir 'ohos')
            try {
                Write-Host "[ohos] hvigorw assembleApp (buildMode=$buildMode) ..." -ForegroundColor Cyan
                & hvigorw assembleApp -p product=default -p buildMode=$buildMode
                if ($LASTEXITCODE -ne 0) {
                    # hvigor 每次启动的 ohpm install 会重物化 @ohos/flutter_ohos 实例
                    # （哈希变化）冲掉 patch-embedding 补丁，ArkTS 编译报 AutoFill/
                    # CompetitionStrategy 缺失 - 与 hap 构建同款两段式：patch 后重试一次。
                    Write-Host '[ohos] assembleApp attempt 1 failed - patch embedding and retry ...' -ForegroundColor Yellow
                    & (Join-Path $ScriptDir 'patch-embedding.ps1') -ProjectRoot $MirrorDir
                    & hvigorw assembleApp -p product=default -p buildMode=$buildMode
                    if ($LASTEXITCODE -ne 0) { throw "assembleApp failed ($LASTEXITCODE)" }
                }
                $apps = Get-ChildItem (Join-Path $MirrorDir 'ohos\build\outputs') -Recurse -Filter '*signed.app' -ErrorAction SilentlyContinue
                foreach ($a in $apps) {
                    Write-Host ("  APP: {0}  ({1:N1} MB)" -f $a.FullName, ($a.Length / 1MB)) -ForegroundColor Green
                    if ($buildMode -ne 'debug') {
                        $dst = Join-Path $relDir ("弦予音乐v{0}-Mobile.app" -f $appVersion)
                        Copy-Item $a.FullName $dst -Force
                        Write-Host ("  archived: {0}" -f $dst) -ForegroundColor Green
                    }
                }
            } finally { Pop-Location }
        }
    }
} finally { Pop-Location }
} finally {
    # 无论成败（含 rust 步骤、构建失败、Ctrl-C）：仅释放互斥标记。依赖态驻留
    # ohos（驻留态模型，2026-09-15）：DevEco/hvigor 的 FlutterTask 需要 fork 态
    # package_config 才能编译；切回 android 由下一次安卓命令的
    # Restore-XianyuAndroidPubState 自愈（见 pub-state.ps1 头注释）
    Exit-XianyuOhosPubState -Root $MirrorDir -KeepState
}

Write-Host ''
Write-Host '== ohos build done ==' -ForegroundColor Green
