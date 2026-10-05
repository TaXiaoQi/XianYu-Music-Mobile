# 跨仓共享代码漂移校验（方案 B：各仓保留副本 + 哈希对齐）
# 清单与脚本三仓各存一份（tools/code_sync/），清单由 -RegenManifest 生成。
#
# 用法：
#   check_shared_code.ps1                 # 本地跨仓比对（默认，需三仓同级目录）
#   check_shared_code.ps1 -Check          # 单仓自检：本仓文件 vs 清单哈希（CI 用）
#   check_shared_code.ps1 -Sync -From mobile   # 以 mobile 为源同步分组文件到其他仓并刷新清单
#   check_shared_code.ps1 -Root D:\XianYu-Music # 指定三仓共同父目录（默认取本仓上级）
# 退出码：0 全绿；1 漂移/错误。哈希口径=非空行 Trim 后排序的 SHA256 前 12 位，
# 与歌词同源维护的多重集合校验同手法（容忍 EOL/BOM/空行差异）。
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$RegenManifest,
    [switch]$Sync,
    [string]$From = 'mobile',
    [string]$Root
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$repoName = Split-Path $repoRoot -Leaf

$repos = [ordered]@{
    mobile  = [pscustomobject]@{ dir = 'XianYu-Music-Mobile';  src = 'rust/src' }
    watch   = [pscustomobject]@{ dir = 'XianYu-Music-Watch';   src = 'rust/src' }
    desktop = [pscustomobject]@{ dir = 'XianYu-Music-Desktop'; src = 'src-tauri/src' }
}

# 首批只收编已验证对齐的分组；分叉中的文件（ssrf/path_validator/lx_search/toolbox 等）
# 对齐后再加进来，避免 CI 常红失去信号价值
$groups = @(
    [pscustomobject]@{ name = 'playlist_fetcher_core'; files = @(
        'music/playlist_fetcher/mod.rs', 'music/playlist_fetcher/common.rs',
        'music/playlist_fetcher/kg.rs', 'music/playlist_fetcher/wy.rs',
        'music/playlist_fetcher/tx.rs', 'music/playlist_fetcher/kw.rs',
        'music/playlist_fetcher/qishui.rs') ; repoKeys = @('mobile', 'watch', 'desktop') },
    [pscustomobject]@{ name = 'playlist_fetcher_orchestrator'; files = @(
        'music/playlist_fetcher/orchestrator.rs') ; repoKeys = @('mobile', 'watch') },
    [pscustomobject]@{ name = 'lyric_formats'; files = @(
        'music/lyric_formats.rs') ; repoKeys = @('mobile', 'watch') },
    [pscustomobject]@{ name = 'lyrics_tracks'; files = @(
        'music/lyrics/tracks.rs') ; repoKeys = @('mobile', 'watch') },
    [pscustomobject]@{ name = 'player_channel_downmix'; files = @(
        'player/channel_downmix.rs') ; repoKeys = @('mobile', 'watch') },
    [pscustomobject]@{ name = 'player_silence_skip'; files = @(
        'player/silence_skip.rs') ; repoKeys = @('mobile', 'watch') },
    [pscustomobject]@{ name = 'remote_scanner'; files = @(
        'remote/scanner.rs') ; repoKeys = @('mobile', 'watch') },
    [pscustomobject]@{ name = 'lyric_fetcher_source_migu'; files = @(
        'music/lyric_fetcher/source_migu.rs') ; repoKeys = @('mobile', 'watch') }
)

function Get-CodeHash([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lines = [IO.File]::ReadAllLines($path)
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $lines) { $t = $l.Trim(); if ($t.Length -gt 0) { $kept.Add($t) } }
    $arr = $kept.ToArray()
    [System.Array]::Sort($arr, [StringComparer]::Ordinal)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($arr -join "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 12)
    } finally { $sha.Dispose() }
}

function Get-ManifestPath { Join-Path $PSScriptRoot 'shared_manifest.json' }

function Read-Manifest {
    if (-not (Test-Path (Get-ManifestPath))) {
        Write-Host "[shared-code] 清单缺失：$(Get-ManifestPath)（先在有全量仓的环境跑 -RegenManifest）" -ForegroundColor Red
        exit 1
    }
    return (Get-Content (Get-ManifestPath) -Raw | ConvertFrom-Json)
}

function Save-ManifestTo([string]$dir, $manifest) {
    $dst = Join-Path $dir 'tools/code_sync/shared_manifest.json'
    $json = $manifest | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($dst, $json, [Text.UTF8Encoding]::new($false))
    Write-Host "[shared-code] 清单已写 $dst"
}

function Build-Manifest([string]$workspaceRoot) {
    $g = foreach ($grp in $groups) {
        [pscustomobject]@{ name = $grp.name; files = @(
            foreach ($rel in $grp.files) {
                $hashes = @{}
                foreach ($k in $grp.repoKeys) {
                    $p = Join-Path (Join-Path $workspaceRoot $repos[$k].dir) ($repos[$k].src + '/' + $rel)
                    $h = Get-CodeHash $p
                    if ($null -ne $h) { $hashes[$k] = $h }
                }
                if ($hashes.Count -eq 0) { throw "分组 $($grp.name)：$rel 三仓均不存在" }
                if (($hashes.Values | Select-Object -Unique).Count -gt 1) {
                    $detail = ($hashes.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ' '
                    throw "分组 $($grp.name)：$rel 现存副本哈希不一致：$detail"
                }
                [pscustomobject]@{ rel = $rel; repos = @($grp.repoKeys); hash = ($hashes.Values | Select-Object -First 1) }
            }
        ) }
    }
    return [pscustomobject]@{ version = 1; groups = @($g) }
}

if ($RegenManifest) {
    $root = if ($Root) { $Root } else { Split-Path $repoRoot -Parent }
    $manifest = Build-Manifest $root
    foreach ($k in @($repos.Keys)) {
        $dir = Join-Path $root $repos[$k].dir
        if (Test-Path $dir) { Save-ManifestTo $dir $manifest }
    }
    exit 0
}

if ($Sync) {
    if (-not $repos.Contains($From)) { throw "-From 必须是 $($repos.Keys -join '/')" }
    $root = if ($Root) { $Root } else { Split-Path $repoRoot -Parent }
    $srcBase = Join-Path (Join-Path $root $repos[$From].dir) $repos[$From].src
    $copied = 0
    foreach ($grp in $groups) {
        if ($grp.repoKeys -notcontains $From) { continue }
        foreach ($rel in $grp.files) {
            $src = Join-Path $srcBase ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $src)) { throw "源仓缺文件：$src" }
            foreach ($k in $grp.repoKeys) {
                if ($k -eq $From) { continue }
                $dst = Join-Path (Join-Path $root $repos[$k].dir) (($repos[$k].src + '/' + $rel) -replace '/', '\')
                if (-not (Test-Path (Split-Path $dst -Parent))) { Write-Host "[shared-code] 跳过 $($k):$rel（目录不存在）"; continue }
                Copy-Item -LiteralPath $src -Destination $dst -Force
                $copied++
                Write-Host "[shared-code] $From -> ${k}: $rel"
            }
        }
    }
    Write-Host "[shared-code] 共复制 $copied 个文件，开始重算清单"
    $manifest = Build-Manifest $root
    foreach ($k in @($repos.Keys)) {
        $dir = Join-Path $root $repos[$k].dir
        if (Test-Path $dir) { Save-ManifestTo $dir $manifest }
    }
    exit 0
}

if ($Check) {
    $manifest = Read-Manifest
    $myKey = $null
    foreach ($k in @($repos.Keys)) { if ($repos[$k].dir -eq $repoName) { $myKey = $k } }
    if (-not $myKey) { throw "无法识别所在仓：$repoName" }
    $srcBase = Join-Path $repoRoot $repos[$myKey].src
    $drift = 0; $checked = 0
    foreach ($grp in $manifest.groups) {
        foreach ($f in $grp.files) {
            if ($f.repos -notcontains $myKey) { continue }
            $h = Get-CodeHash (Join-Path $srcBase ($f.rel -replace '/', '\'))
            $checked++
            if ($h -ne $f.hash) {
                $drift++
                Write-Host "[shared-code] 漂移 [$($grp.name)] $($f.rel)：本仓 $h ≠ 清单 $($f.hash)" -ForegroundColor Red
            }
        }
    }
    if ($drift -gt 0) {
        Write-Host "[shared-code] $myKey 校验失败：$drift/$checked 个文件漂移（改动后需三仓同步并 -RegenManifest）" -ForegroundColor Red
        exit 1
    }
    Write-Host "[shared-code] $myKey 校验通过：$checked 个共享文件与清单一致" -ForegroundColor Green
    exit 0
}

# 默认：本地跨仓比对（不依赖清单哈希，直接对现存副本两两比对）
$root = if ($Root) { $Root } else { Split-Path $repoRoot -Parent }
$drift = 0; $groupsChecked = 0
foreach ($grp in $groups) {
    $present = @{}
    foreach ($k in $grp.repoKeys) {
        $p = Join-Path (Join-Path $root $repos[$k].dir) (($repos[$k].src + '/' + $grp.files[0]) -replace '/', '\')
        if (Test-Path -LiteralPath $p) { $present[$k] = $true }
    }
    if ($present.Count -lt 2) { continue }
    $groupsChecked++
    foreach ($rel in $grp.files) {
        $hashes = @{}
        foreach ($k in @($present.Keys)) {
            $p = Join-Path (Join-Path $root $repos[$k].dir) (($repos[$k].src + '/' + $rel) -replace '/', '\')
            $hashes[$k] = Get-CodeHash $p
        }
        $uniq = ($hashes.Values | Select-Object -Unique)
        if ($uniq.Count -gt 1) {
            $drift++
            $detail = ($hashes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
            Write-Host "[shared-code] 漂移 [$($grp.name)] ${rel}: $detail" -ForegroundColor Red
        }
    }
}
if ($drift -gt 0) {
    Write-Host "[shared-code] 跨仓比对失败：$drift 处漂移（用 -Sync -From <仓> 同步后 -RegenManifest 刷清单）" -ForegroundColor Red
    exit 1
}
Write-Host "[shared-code] 跨仓比对通过：$groupsChecked 个分组全部一致" -ForegroundColor Green
exit 0
