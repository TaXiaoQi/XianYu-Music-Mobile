#requires -version 5.1
# 鸿蒙依赖态切换（Enter/Exit）：ohos 构建期间把 pub 依赖切到 fork 解析态
# （pubspec_overrides.yaml + pubspec.lock 的 ohos git 引用），结束后恢复
# Android/iOS 干净态。fork 包（audio_session/camera 等）Dart 源码引用
# TargetPlatform.ohos，官方 SDK 无法编译——主工程常态必须保持干净态，
# 覆盖文件只允许在 ohos 构建期间存在（见 2026-09-15 Android release 事故）。
#
# 使用方：build-ohos.ps1（步骤 5-8 全程包裹）与 profile 的 flutter 包装函数
# （flutter hap / build app / pub get 路由到 fork 时包裹）。
# 异常退出残留时的手工恢复：
#   git checkout -- pubspec.lock
#   Remove-Item pubspec_overrides.yaml -ErrorAction SilentlyContinue

function Enter-XianyuOhosPubState {
    param(
        [Parameter(Mandatory)] [string]$Root,      # 主工程（就地）或镜像目录（legacy）
        [Parameter(Mandatory)] [string]$ScriptDir  # scripts\ohos（模板所在）
    )
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
    # package_config 快照（android 态）同 lock 一起管理，见 Exit 侧说明
    $pcBackup = Join-Path $Root 'build\ohos\package_config.android.json'
    $pc = Join-Path $Root '.dart_tool\package_config.json'
    if (-not (Test-Path $pcBackup) -and (Test-Path $pc)) {
        Copy-Item $pc $pcBackup -Force
        Write-Host '[ohos-pub] package_config snapshot saved (android state)'
    }
    if (Test-Path $pcBackup) { Copy-Item $pcBackup $pc -Force }
    Write-Host '[ohos-pub] entered ohos dependency state (overrides + fork resolution)'
}

function Exit-XianyuOhosPubState {
    param([Parameter(Mandatory)] [string]$Root)
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
    Write-Host '[ohos-pub] restored android dependency state (lock restored, overrides removed)'
}
