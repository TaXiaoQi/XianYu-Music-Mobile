# manifest-ohos.ps1 - inject permissions / background modes into the mirror's
# ohos/entry/src/main/module.json5 (idempotent).
#
# Why scripted: `flutter create --platforms ohos` regenerates a bare template,
# and a fresh checkout of the mirror must reach a buildable state without
# manual DevEco edits. Mirrors what poc_ohos/scripts/setup.ps1 did.
#
# Permissions (P0): INTERNET (network stack), KEEP_BACKGROUND_RUNNING
# (audio_service long-running task - without it startBackgroundRunning's
# promise chain dies silently, see PoC AVSession investigation).
# Ability: backgroundModes ["audioPlayback"].
# P2 will append camera/mic/photo permissions via the same anchor logic.
param(
    [string]$ProjectRoot = ''
)
if (-not $ProjectRoot) {
    $ProjectRoot = if ($env:XIANYU_OHOS_MIRROR) { $env:XIANYU_OHOS_MIRROR } else { 'D:\xianyu-mobile-ohos' }
}

$ErrorActionPreference = 'Stop'
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$modFile = Join-Path $ProjectRoot 'ohos\entry\src\main\module.json5'
if (-not (Test-Path $modFile)) { throw "module.json5 missing: $modFile (run build-ohos.ps1 once to create ohos/)" }
$mod = [System.IO.File]::ReadAllText($modFile, $Utf8)

if ($mod -notmatch 'ohos\.permission\.INTERNET') {
    if ($mod -match '"requestPermissions"') {
        Write-Warning 'module.json5 has requestPermissions but lacks INTERNET; add manually'
    } elseif ($mod -match '"module"\s*:\s*\{') {
        $mod = [regex]::Replace($mod, '"module"\s*:\s*\{', "`$0`n    `"requestPermissions`": [`n      { `"name`": `"ohos.permission.INTERNET`" },`n      { `"name`": `"ohos.permission.KEEP_BACKGROUND_RUNNING`" }`n    ],", 1)
        Write-Host 'added requestPermissions: INTERNET + KEEP_BACKGROUND_RUNNING'
    }
} elseif ($mod -notmatch 'KEEP_BACKGROUND_RUNNING') {
    $mod = [regex]::Replace($mod, '("ohos\.permission\.INTERNET"\s*\})', "`$1,`n      { `"name`": `"ohos.permission.KEEP_BACKGROUND_RUNNING`" }", 1)
    Write-Host 'added KEEP_BACKGROUND_RUNNING (long-running task, required by audio_service)'
}

if ($mod -notmatch 'backgroundModes') {
    $mod2 = [regex]::Replace($mod, '("abilities"\s*:\s*\[\s*\{)', "`$1`n      `"backgroundModes`": [`"audioPlayback`"],", 1)
    if ($mod2 -ne $mod) {
        $mod = $mod2
        Write-Host 'added backgroundModes: [audioPlayback]'
    } else {
        Write-Warning 'abilities anchor not found; add "backgroundModes": ["audioPlayback"] manually'
    }
}

[System.IO.File]::WriteAllText($modFile, $mod, $Utf8)
Write-Host 'manifest patch done.'
