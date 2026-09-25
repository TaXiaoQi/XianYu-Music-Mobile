# 生成桌面组件选择器的静态预览位图（previewImage）。
#
# 背景：此前 previewImage 用 layer-list（矢量示意），部分 ROM（如 MagicOS）
# 的组件选择器对 layer-list 的 item 尺寸/gravity 渲染失效——同一张图在
# 方形/横形容器里被拉成怪异红块/红条，暗底与文字条全丢。位图（PNG）预览
# 所有 ROM 均像素级原样绘制，不会坏。
#
# 产物（drawable-nodpi）：
#   widget_preview_square.png    2×2 方形卡示意（512×512）
#   widget_preview_recognize.png 4×2 识曲卡示意（1024×512）
#
# 预览为示意卡：暗色圆角底 + 品牌红渐变封面占位 + 演示文案 + 控制键，
# 与真实卡片（widget_bg 深色态）观感一致。改动画面后重跑本脚本即可。
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$outDir = Join-Path $PSScriptRoot "..\android\app\src\main\res\drawable-nodpi"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ---- 调色板（对齐真实组件配色） ----
$bg      = [System.Drawing.Color]::FromArgb(255, 0x1C, 0x1C, 0x1E)  # widget_card 深色
$red     = [System.Drawing.Color]::FromArgb(255, 0xEC, 0x41, 0x42)  # 品牌红
$redMid  = [System.Drawing.Color]::FromArgb(255, 0x7A, 0x20, 0x26)
$redDark = [System.Drawing.Color]::FromArgb(255, 0x20, 0x14, 0x16)
$white   = [System.Drawing.Color]::White
$grey    = [System.Drawing.Color]::FromArgb(153, 255, 255, 255)    # 次级文字
$btnFill = [System.Drawing.Color]::FromArgb(26, 255, 255, 255)     # 圆形钮底
$track   = [System.Drawing.Color]::FromArgb(51, 255, 255, 255)     # 进度轨道

function New-RoundedPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Get-CoverBrush([System.Drawing.RectangleF]$rect) {
    # 品牌红 45° 三段渐变（对齐 widget_preview_cover）
    $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect, $red, $redDark,
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
    $cb = New-Object System.Drawing.Drawing2D.ColorBlend
    $cb.Colors = @($red, $redMid, $redDark)
    $cb.Positions = @(0.0, 0.5, 1.0)
    $b.InterpolationColors = $cb
    return $b
}

function Draw-Triangle($g, [float]$cx, [float]$cy, [float]$size, [bool]$flip) {
    # 播放/切歌三角（flip=$true 为向左）
    $s = $size / 2
    $pts = @()
    if ($flip) {
        $pts = @(
            (New-Object System.Drawing.PointF -ArgumentList (($cx + $s), ($cy - $s))),
            (New-Object System.Drawing.PointF -ArgumentList (($cx + $s), ($cy + $s))),
            (New-Object System.Drawing.PointF -ArgumentList (($cx - $s), $cy))
        )
    } else {
        $pts = @(
            (New-Object System.Drawing.PointF -ArgumentList (($cx - $s), ($cy - $s))),
            (New-Object System.Drawing.PointF -ArgumentList (($cx - $s), ($cy + $s))),
            (New-Object System.Drawing.PointF -ArgumentList (($cx + $s), $cy))
        )
    }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddPolygon($pts)
    $g.FillPath([System.Drawing.Brushes]::White, $p)
    $p.Dispose()
}

function Draw-CircleBtn($g, [float]$cx, [float]$cy, [float]$r) {
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $btnFill), $cx - $r, $cy - $r, $r * 2, $r * 2)
}

function New-Preview([string]$file, [int]$w, [int]$h, [scriptblock]$draw) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    & $draw $g $w $h
    $g.Dispose()
    $path = Join-Path $outDir $file
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "已生成 $path"
}

$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei', 34, [System.Drawing.FontStyle]::Bold)
$fontSub   = New-Object System.Drawing.Font('Microsoft YaHei', 24, [System.Drawing.FontStyle]::Regular)
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = [System.Drawing.StringAlignment]::Center
$fmt.LineAlignment = [System.Drawing.StringAlignment]::Center

# ================= 2×2 方形卡（512×512） =================
New-Preview 'widget_preview_square.png' 512 512 {
    param($g, $w, $h)
    # 暗色圆角底
    $bgPath = New-RoundedPath 0 0 $w $h 90
    $g.FillPath((New-Object System.Drawing.SolidBrush $bg), $bgPath)
    $bgPath.Dispose()
    # 封面（品牌红渐变占位）
    $cover = [System.Drawing.RectangleF]::new(146, 56, 220, 220)
    $brush = Get-CoverBrush $cover
    $cPath = New-RoundedPath $cover.X $cover.Y $cover.Width $cover.Height 44
    $g.FillPath($brush, $cPath)
    $brush.Dispose(); $cPath.Dispose()
    # 歌名 / 歌手
    $whiteBrush = New-Object System.Drawing.SolidBrush $white
    $greyBrush  = New-Object System.Drawing.SolidBrush $grey
    $g.DrawString('弦予音乐', $fontTitle, $whiteBrush, [System.Drawing.RectangleF]::new(0, 288, $w, 50), $fmt)
    $g.DrawString('未在播放', $fontSub, $greyBrush, [System.Drawing.RectangleF]::new(0, 342, $w, 36), $fmt)
    # 三键：上一首 / 播放（红） / 下一首
    Draw-CircleBtn $g 176 424 27
    Draw-Triangle  $g 172 424 22 $true
    $playBrush = New-Object System.Drawing.SolidBrush $red
    $g.FillEllipse($playBrush, 256 - 34, 424 - 34, 68, 68)
    $playBrush.Dispose()
    Draw-Triangle  $g 261 424 28 $false
    Draw-CircleBtn $g 336 424 27
    Draw-Triangle  $g 340 424 22 $false
    $whiteBrush.Dispose(); $greyBrush.Dispose()
}

# ================= 4×2 识曲卡（1024×512） =================
New-Preview 'widget_preview_recognize.png' 1024 512 {
    param($g, $w, $h)
    $bgPath = New-RoundedPath 0 0 $w $h 90
    $g.FillPath((New-Object System.Drawing.SolidBrush $bg), $bgPath)
    $bgPath.Dispose()
    # 左侧封面
    $cover = [System.Drawing.RectangleF]::new(64, 120, 272, 272)
    $brush = Get-CoverBrush $cover
    $cPath = New-RoundedPath $cover.X $cover.Y $cover.Width $cover.Height 56
    $g.FillPath($brush, $cPath)
    $brush.Dispose(); $cPath.Dispose()
    $whiteBrush = New-Object System.Drawing.SolidBrush $white
    $greyBrush  = New-Object System.Drawing.SolidBrush $grey
    $left = New-Object System.Drawing.StringFormat
    $left.Alignment = [System.Drawing.StringAlignment]::Near
    # 歌名 / 歌手（左对齐）
    $g.DrawString('Alone', $fontTitle, $whiteBrush, [System.Drawing.RectangleF]::new(372, 88, 500, 60), $left)
    $g.DrawString('Alan Walker', $fontSub, $greyBrush, [System.Drawing.RectangleF]::new(372, 150, 500, 40), $left)
    # 右上分享（material share 形：右上/左中/右下三个粗实心点 + 两连线。
    # 此前为沿对角线的三点连线简笔，点小线细，缩到桌面预览尺寸糊成一根
    # 斜线无辨识度；改标准 share 布点，点径/线宽对齐真实组件粗版图标。）
    $dotBrush = New-Object System.Drawing.SolidBrush $white
    foreach ($pt in @(@(1004, 70), @(942, 120), @(1004, 170))) {
        $g.FillEllipse($dotBrush, $pt[0] - 12, $pt[1] - 12, 24, 24)
    }
    $pen = New-Object System.Drawing.Pen($white, 7)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, 948, 116, 997, 75)
    $g.DrawLine($pen, 948, 124, 997, 165)
    $pen.Dispose(); $dotBrush.Dispose()
    # 三键（居中偏左，与真实卡一致）
    Draw-CircleBtn $g 470 330 27
    Draw-Triangle  $g 466 330 22 $true
    $playBrush = New-Object System.Drawing.SolidBrush $red
    $g.FillEllipse($playBrush, 572 - 34, 330 - 34, 68, 68)
    $playBrush.Dispose()
    Draw-Triangle  $g 577 330 28 $false
    Draw-CircleBtn $g 674 330 27
    Draw-Triangle  $g 678 330 22 $false
    # 底部进度条（45%）
    $trackPath = New-RoundedPath 372 440 588 10 5
    $g.FillPath((New-Object System.Drawing.SolidBrush $track), $trackPath)
    $trackPath.Dispose()
    $fillPath = New-RoundedPath 372 440 265 10 5
    $redBrush = New-Object System.Drawing.SolidBrush $red
    $g.FillPath($redBrush, $fillPath)
    $redBrush.Dispose(); $fillPath.Dispose()
    $whiteBrush.Dispose(); $greyBrush.Dispose()
}

Write-Host '组件预览位图生成完毕。'
