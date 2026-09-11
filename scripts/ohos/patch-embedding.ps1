# patch-embedding.ps1 - make Flutter-OH embedding HAR compile against local SDK (API 22)
#
# The embedding shipped with Flutter-OH 3.41.10-ohos-1.0.1 targets API 24/26
# symbols (CompetitionStrategy, autoFillManager.* types/methods) that are absent
# from the installed DevEco SDK d.ts. All call sites are runtime-guarded by
# sdkApiVersion checks, so these patches only satisfy the ArkTS compiler and
# stay dormant on older devices.
#
# Idempotent: files carry a "POC-PATCH" marker; re-running is a no-op.
# Re-run after oh_modules is rebuilt (ohpm reinstall).
#
# Targets the MIRROR build dir (space-free); pass -ProjectRoot to override.
param(
    [string]$ProjectRoot = ''
)
if (-not $ProjectRoot) {
    $ProjectRoot = if ($env:XIANYU_OHOS_MIRROR) { $env:XIANYU_OHOS_MIRROR } else { 'D:\xianyu-mobile-ohos' }
}

$ErrorActionPreference = 'Stop'
$Utf8 = [System.Text.UTF8Encoding]::new($false)

$pkgDir = Get-ChildItem (Join-Path $ProjectRoot 'ohos\oh_modules\.ohpm') -Directory -Filter '@ohos+flutter_ohos@*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkgDir) { Write-Host 'flutter_ohos package not installed yet - skip patch'; exit 0 }
$Embedding = Join-Path $pkgDir.FullName 'oh_modules\@ohos\flutter_ohos\src\main\ets'

function Patch-File([string]$Path, [scriptblock]$Mutate) {
    $txt = [System.IO.File]::ReadAllText($Path, $Utf8)
    if ($txt -match 'POC-PATCH') { Write-Host "already patched: $(Split-Path -Leaf $Path)"; return }
    $new = & $Mutate $txt
    [System.IO.File]::WriteAllText($Path, $new, $Utf8)
    Write-Host "patched: $Path"
}

# ---- 1. EmbeddingNodeController.ets: local CompetitionStrategy enum (API24 symbol) ----
$nodeCtrl = Join-Path $Embedding 'embedding\ohos\EmbeddingNodeController.ets'
Patch-File $nodeCtrl {
    param($txt)
    $anchor = "import { DVModel, DVModelChildren, DynamicView } from '../../view/DynamicView/dynamicView';"
    if (-not $txt.Contains($anchor)) { throw 'EmbeddingNodeController: anchor not found' }
    $inject = @"

// POC-PATCH: local SDK (API 22) lacks the API24 CompetitionStrategy enum.
// Call sites runtime-check postInputEventWithStrategy via typeof and fall
// back to postInputEvent below API 24, so this value is never used there.
enum CompetitionStrategy {
  DEFAULT = 0,
}
"@
    return $txt.Replace($anchor, $anchor + $inject)
}

# ---- 2. OhosAutoFillHelper.ets: shim API26 autoFillManager symbols ----
$autoFill = Join-Path $Embedding 'plugin\editing\OhosAutoFillHelper.ets'
Patch-File $autoFill {
    param($txt)
    $pairs = @(
        # interface field type
        ,@('autoFillType: autoFillManager.AutoFillType;', 'autoFillType: number;')
        # toSdkAutoFillType
        ,@('private static toSdkAutoFillType(value: number): autoFillManager.AutoFillType {
    return value as autoFillManager.AutoFillType;
  }', 'private static toSdkAutoFillType(value: number): number {
    return value;
  }')
        # toManagerViewData signature + return
        ,@('private static toManagerViewData(viewData: OhosViewData): autoFillManager.ViewData {', 'private static toManagerViewData(viewData: OhosViewData): AutoFillManagerViewData {')
        ,@('return managerViewData as autoFillManager.ViewData;', 'return managerViewData;')
        # parseFillResult signature
        ,@('static parseFillResult(viewData: autoFillManager.ViewData): Map<number, string> {', 'static parseFillResult(viewData: AutoFillManagerViewData): Map<number, string> {')
        # fillRequest literal
        ,@('triggerType: AUTOFILL_TRIGGER_AUTO_REQUEST as autoFillManager.AutoFillTriggerType,
    } as autoFillManager.FillRequest;', 'triggerType: AUTOFILL_TRIGGER_AUTO_REQUEST,
    } as FillRequestShim;')
        # callback literal
        ,@('const callback: autoFillManager.AutoFillCallback = {', 'const callback: AutoFillCallbackShim = {')
        ,@('onSuccess: (filledViewData: autoFillManager.ViewData): void => {', 'onSuccess: (filledViewData: AutoFillManagerViewData): void => {')
        ,@('onFailure: (result: autoFillManager.FillFailureResult): void => {', 'onFailure: (result: FillFailureResultShim): void => {')
        # dynamic invoke: requestAutoFill absent from API22 d.ts
        ,@('autoFillManager.requestAutoFill(uiContext, fillRequest, callback);', '(autoFillManager as ESObject).requestAutoFill(uiContext, fillRequest, callback);')
        # saveRequest literal
        ,@('const saveRequest: autoFillManager.SaveRequest = {', 'const saveRequest: SaveRequestShim = {')
        # dynamic invoke: 3-arg requestAutoSave is API24+ signature
        ,@('autoFillManager.requestAutoSave(uiContext, saveRequest, napiCallback);', '(autoFillManager as ESObject).requestAutoSave(uiContext, saveRequest, napiCallback);')
    )
    foreach ($pair in $pairs) {
        if (-not $txt.Contains($pair[0])) { throw "OhosAutoFillHelper: snippet not found: $($pair[0].Substring(0, [Math]::Min(60, $pair[0].Length)))" }
        $txt = $txt.Replace($pair[0], $pair[1])
    }
    # shim interfaces after AutoFillCustomData
    $anchor = 'interface AutoFillCustomData {
  data: Record<string, string>;
}'
    if (-not $txt.Contains($anchor)) { throw 'OhosAutoFillHelper: shim anchor not found' }
    $shims = @'

// POC-PATCH: local SDK (API 22) lacks API26 autoFillManager types. Runtime
// guards (sdkApiVersion < AUTOFILL_SUPPORT_API) keep these paths dormant;
// shims only satisfy the ArkTS compiler.
interface FillRequestShim {
  type: number;
  viewData: AutoFillManagerViewData;
  customData: AutoFillCustomData;
  isPopup: boolean;
  triggerType: number;
}
interface FillFailureResultShim {
  errCode: number;
}
interface AutoFillCallbackShim {
  onSuccess: (filledViewData: AutoFillManagerViewData) => void;
  onFailure: (result: FillFailureResultShim) => void;
}
interface SaveRequestShim {
  viewData: AutoFillManagerViewData;
}
'@
    return $txt.Replace($anchor, $anchor + $shims)
}

Write-Host 'embedding patch done.'
