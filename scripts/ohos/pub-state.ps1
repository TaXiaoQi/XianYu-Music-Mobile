#requires -version 5.1
# 鸿蒙/安卓双 SDK 依赖态切换（驻留态模型）：
#
# 主工程只有一份 .dart_tool/package_config.json + .flutter-plugins-dependencies，
# 官方 SDK（安卓）与 Flutter-OH fork（鸿蒙）各自生成的解析互不兼容——fork 包
# （audio_session/camera 等）引用 TargetPlatform.ohos，官方 SDK 编译不了；反之
# 官方态文件没有 ohos 段，hvigor/DevEco 直接崩 00305010。
#
# 驻留态模型（2026-09-15 起）：依赖态停留在「最后一次构建的平台」——
#   · ohos 命令结束后保持 ohos 态（overrides + ohos lock/package_config/plugins），
#     DevEco 里的 hvigor FlutterTask 随时可用 fork 态编译，无需预处理；
#   · 安卓命令执行前若发现驻留 ohos 态，自动还原 android 态（Restore-
#     XianyuAndroidPubState）+ 重跑官方 pub get，结束后驻留 android 态。
# 后果：构建 APK 之后 DevEco 会暂时不可用，跑一次任意鸿蒙 flutter 命令即可恢复。
#
# 使用方：build-ohos.ps1 与 profile 的 flutter 包装函数（hap / build app /
# pub get 路由到 fork 时进入 ohos 态；apk / 裸 run / pub 路由官方前先还原）。
# 异常退出残留时的手工恢复：
#   . .\scripts\ohos\pub-state.ps1; Restore-XianyuAndroidPubState -Root (Get-Location).Path

function Enter-XianyuOhosPubState {
    param(
        [Parameter(Mandatory)] [string]$Root,      # 主工程（就地）或镜像目录（legacy）
        [Parameter(Mandatory)] [string]$ScriptDir  # scripts\ohos（模板所在）
    )
    # 互斥标记：鸿蒙依赖态是全工程唯一的（lock/overrides/package_config/
    # plugins 文件共享），鸿蒙构建进行中若并发跑官方安卓构建，官方 flutter
    # 会读到中间态重写 .flutter-plugins-dependencies（无 ohos 段）→ hvigor
    # 00305010（2026-09-15 二次复发）。标记含 PID+时间，进程已死则自动清陈旧。
    $mutex = Join-Path $Root 'build\ohos\.pub-state-active'
    if (Test-Path $mutex) {
        $info = (Get-Content $mutex -Raw -ErrorAction SilentlyContinue) -as [string[]]
        $ownerPid = 0; [void]([int]::TryParse(($info | Select-Object -First 1), [ref]$ownerPid))
        $alive = $false
        if ($ownerPid -gt 0) { $alive = [bool](Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) }
        if ($alive) {
            throw "鸿蒙依赖态被 PID $ownerPid 占用（另一场 ohos 构建进行中）。请等它结束后再试，切勿并发跑安卓构建。"
        }
        Write-Host '[ohos-pub] 清理陈旧互斥标记（属主进程已退出）' -ForegroundColor Yellow
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mutex) | Out-Null
    Set-Content $mutex "$PID`n$(Get-Date -Format o)" -Force
    # 驻留态标记：Enter 置 ohos（Exit -KeepState 保持，Restore 置回 android）
    Set-Content (Join-Path $Root 'build\ohos\.pub-state-current') 'ohos' -Force
    # overrides：模板是唯一事实源，每次强制重写（防模板新增条目后旧文件滞留、
    # 依赖静默停在旧 fork 上）
    Copy-Item (Join-Path $ScriptDir 'pubspec-ohos-overrides.yaml') `
        (Join-Path $Root 'pubspec_overrides.yaml') -Force
    # lock 备份：首次进入时快照 Android/iOS 干净解析态（build/ 已 gitignore +
    # robocopy 排除）；之后每次进入都先回到干净态再让 pub get 重解析，
    # 保证 ohos 解析只由「干净态 + overrides 模板」决定，可复现
    $backup = Join-Path $Root 'build\ohos\pubspec.lock.android'
    $lock = Join-Path $Root 'pubspec.lock'
    if (-not (Test-Path $backup) -and (Test-Path $lock)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        Copy-Item $lock $backup -Force
        Write-Host '[ohos-pub] pubspec.lock snapshot saved (android state)'
    }
    if (Test-Path $backup) { Copy-Item $backup $lock -Force }
    # 强制 fork 重新 pub get：android 快照的 package_config 会让 fork 的依赖新鲜
    # 度检查误判"无需解析"，跳过 pub get → .flutter-plugins-dependencies 停留在
    # 官方格式（无 ohos 段），hvigor 插件读之即崩（00305010 'filter'，2026-09-15
    # 二次复发）。删掉两者强制重生成完整 ohos 态，代价是每次 ohos 命令多一次
    # pub get（热缓存 ~10s）。
    Remove-Item (Join-Path $Root '.dart_tool\package_config.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Root '.flutter-plugins-dependencies') -Force -ErrorAction SilentlyContinue
    Write-Host '[ohos-pub] entered ohos dependency state (overrides + forced re-resolution)'
}

# 退出鸿蒙态。-KeepState（驻留态模型默认）：仅释放互斥标记，overrides/
# ohos lock/package_config/plugins 全部保留，DevEco 的 hvigor FlutterTask
# 可继续用 fork 态编译。不带开关（legacy/手工）：完整还原 android 态。
function Exit-XianyuOhosPubState {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [switch]$KeepState
    )
    Remove-Item (Join-Path $Root 'build\ohos\.pub-state-active') -Force -ErrorAction SilentlyContinue
    if ($KeepState) {
        Write-Host '[ohos-pub] released mutex; ohos dependency state kept for DevEco/hvigor' -ForegroundColor DarkGray
        return
    }
    $backup = Join-Path $Root 'build\ohos\pubspec.lock.android'
    $lock = Join-Path $Root 'pubspec.lock'
    if (Test-Path $backup) { Copy-Item $backup $lock -Force }
    # package_config 同样要还原：它直接决定 kernel 快照编译哪个源。若只还原
    # lock，残留的 ohos package_config 指向 git fork 源，且 flutter 的依赖新鲜
    # 度检查不会触发重新 pub get，Android 构建会继续用 fork 源码编译报
    # TargetPlatform.ohos 错（2026-09-15）。无快照时删除之，强制下次 pub get。
    $pcBackup = Join-Path $Root 'build\ohos\package_config.android.json'
    $pc = Join-Path $Root '.dart_tool\package_config.json'
    if (Test-Path $pcBackup) {
        Copy-Item $pcBackup $pc -Force
    } elseif (Test-Path $pc) {
        Remove-Item $pc -Force
        Write-Host '[ohos-pub] package_config removed (will re-run pub get on next flutter command)'
    }
    Remove-Item (Join-Path $Root 'pubspec_overrides.yaml') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $Root 'build\ohos\.pub-state-current') 'android' -Force
    Write-Host '[ohos-pub] restored android dependency state (lock restored, overrides removed)'
}

# 安卓命令进入前的自愈：驻留 ohos 态（或异常残留）→ 还原 android 态。
# 返回 $true 表示发生了还原（调用方需自行重跑官方 pub get），$false 已是干净态。
function Restore-XianyuAndroidPubState {
    param([Parameter(Mandatory)] [string]$Root)
    $stateFile = Join-Path $Root 'build\ohos\.pub-state-current'
    $overrides = Join-Path $Root 'pubspec_overrides.yaml'
    $state = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
    if ($state -ne 'ohos' -and -not (Test-Path $overrides)) { return $false }
    # 陈旧互斥标记（属主进程已死）顺手清掉；活进程仍在占用则拒绝还原
    $mutex = Join-Path $Root 'build\ohos\.pub-state-active'
    if (Test-Path $mutex) {
        $info = (Get-Content $mutex -Raw -ErrorAction SilentlyContinue) -as [string[]]
        $ownerPid = 0; [void]([int]::TryParse(($info | Select-Object -First 1), [ref]$ownerPid))
        if ($ownerPid -gt 0 -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
            throw "鸿蒙依赖态被 PID $ownerPid 占用（另一场 ohos 构建进行中），无法还原 android 态。"
        }
        Remove-Item $mutex -Force -ErrorAction SilentlyContinue
    }
    Exit-XianyuOhosPubState -Root $Root
    return $true
}
