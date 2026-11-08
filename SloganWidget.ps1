# ============================================================
#  桌面标语小部件  ·  Slogan Widget   (Windows / PowerShell 5.1)
#  · 置顶小卡片，定时轮播 学习 / 工作 标语，并提醒你休息
#  · 可拖动、双击换一句、右键菜单、记住位置、开机自启
# ============================================================
param(
    [switch]$Demo,              # 快速演示：20 秒进入休息模式
    [switch]$InstallAutostart,  # 只安装开机自启，不开窗口
    [switch]$Trace              # 诊断：写出 _trace.txt
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CfgPath  = Join-Path $script:Dir 'config.json'
$script:LogPath  = Join-Path $script:Dir 'widget.log'
$script:Launcher = Join-Path $script:Dir '启动标语小部件.vbs'
$script:TraceOn  = [bool]$Trace

function Trace-Log {
    param([string]$m)
    if (-not $script:TraceOn) { return }
    try {
        $t = (Get-Date -Format 'HH:mm:ss.fff') + ' ' + $m
        Add-Content -LiteralPath (Join-Path $script:Dir '_trace.txt') -Value $t -Encoding UTF8
    } catch { }
}

trap {
    $msg = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
    try { Add-Content -LiteralPath $script:LogPath -Value $msg -Encoding UTF8 } catch { }
    Trace-Log ('TRAP ' + $msg)
    exit 1
}

# ---------------- 单实例 ----------------
$script:Mutex = $null
try {
    $script:Mutex = New-Object System.Threading.Mutex -ArgumentList $false, 'Local\SloganWidget_DSH_Single'
    $owned = $false
    try { $owned = $script:Mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
} catch { }

# ---------------- 原生 API / 自绘面板 ----------------
if (-not ('WinNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr dc, int idx);
}
'@
}

if (-not ('WidgetPanel' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
public class WidgetPanel : Panel {
    public WidgetPanel() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.OptimizedDoubleBuffer |
                      ControlStyles.AllPaintingInWmPaint |
                      ControlStyles.UserPaint |
                      ControlStyles.ResizeRedraw, true);
        this.UpdateStyles();
        this.BackColor = Color.FromArgb(15, 16, 24);
    }
}
'@
}

# ---------------- 通用小工具 ----------------
function New-RoundPath {
    param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0.6) {
        $p.AddRectangle((New-Object System.Drawing.RectangleF -ArgumentList $X, $Y, $W, $H))
        return $p
    }
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Fill-RoundRect {
    param([System.Drawing.Graphics]$G, [System.Drawing.Brush]$B,
          [float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
    $p = New-RoundPath $X $Y $W $H $R
    $G.FillPath($B, $p)
    $p.Dispose()
}

function Format-MMSS {
    param([int]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $m = [int][math]::Floor($Seconds / 60)
    $s = [int]($Seconds % 60)
    '{0:00}:{1:00}' -f $m, $s
}

function Get-AutostartPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) '标语小部件.lnk'
}

function Set-Autostart {
    param([bool]$On)
    $lnk = Get-AutostartPath
    if ($On) {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath        = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $sc.Arguments         = '"' + $script:Launcher + '"'
        $sc.WorkingDirectory  = $script:Dir
        $sc.Description       = '桌面标语小部件'
        $sc.WindowStyle       = 7
        $sc.Save()
    } else {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    }
}

# ---------------- 配置读写 ----------------
function Save-Config {
    try {
        $S = $script:S
        $o = [ordered]@{
            x        = [int]$S.Form.Left
            y        = [int]$S.Form.Top
            topmost  = [bool]$S.TopMost
            paused   = [bool]$S.Paused
            rounds   = [int]$S.Rounds
            day      = (Get-Date -Format 'yyyy-MM-dd')
        }
        ($o | ConvertTo-Json) | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
    } catch { }
}

# ---------------- 文案 ----------------
function Get-SloganFont {
    param([double]$Size)
    $key = 'sz' + $Size
    if (-not $script:S.FontCache.ContainsKey($key)) {
        $px = [float]($Size * $script:S.K)
        $font = New-Object System.Drawing.Font -ArgumentList $script:FontFamily, $px, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $script:S.FontCache[$key] = $font
    }
    return $script:S.FontCache[$key]
}

function Get-RandomQuote {
    param([string]$Kind, [string]$Avoid = '')
    $S = $script:S
    if ($Kind -eq 'rest')      { $arr = $S.QuotesRest }
    elseif ($Kind -eq 'work')  { $arr = $S.QuotesWork }
    else                       { $arr = $S.QuotesStudy }
    if (-not $arr -or $arr.Count -eq 0) { return '' }
    for ($i = 0; $i -lt 10; $i++) {
        $q = $arr[(Get-Random -Minimum 0 -Maximum $arr.Count)]
        if ($q -ne $Avoid) { return $q }
    }
    return $arr[0]
}

function Start-Fade {
    param([string]$Text, [string]$Kind)
    $S = $script:S
    $S.PendingText = $Text
    $S.PendingKind = $Kind
    $S.FadeDir = -1
    $script:FadeTimer.Start()
}

function Show-NextQuote {
    param([string]$ForceKind = '')
    $S = $script:S
    $S.Rotation++
    if ($ForceKind) {
        $kind = $ForceKind
    } elseif ($S.Rotation % 4 -eq 0) {
        $kind = 'rest'
    } elseif ((Get-Random -Minimum 0 -Maximum 100) -lt 58) {
        $kind = 'work'
    } else {
        $kind = 'study'
    }
    $q = Get-RandomQuote -Kind $kind -Avoid $S.Text
    Start-Fade -Text $q -Kind $kind
}

function Start-Rest {
    $S = $script:S
    $S.Resting = $true
    $S.RestLeft = $S.RestTotal
    $nl = [Environment]::NewLine
    if ($S.FocusTarget -ge 60) {
        $mins = [int][math]::Round($S.FocusTarget / 60)
        $txt = "已经专注 $mins 分钟，${nl}站起来走走吧。"
    } else {
        $txt = "专注已完成，${nl}休息一下。"
    }
    Start-Fade -Text $txt -Kind 'rest'
}

function End-Rest {
    $S = $script:S
    $S.Resting = $false
    $S.FocusSeconds = 0
    $S.Rounds++
    Save-Config
    Show-NextQuote
}

# ---------------- 绘制 ----------------
function Draw-Widget {
    param([System.Drawing.Graphics]$g)

    $S = $script:S
    $k = [double]$S.K
    $W = [double]$S.WW
    $H = [double]$S.HH
    $pad = 22.0 * $k

    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    # ---- 背景渐变 ----
    $bgRect = New-Object System.Drawing.RectangleF -ArgumentList 0.0, 0.0, $W, $H
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $bgRect, ([System.Drawing.Color]::FromArgb(255, 27, 28, 42)), ([System.Drawing.Color]::FromArgb(255, 15, 16, 24)), ([System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillRectangle($lg, $bgRect)
    $lg.Dispose()

    # ---- 边框 ----
    if ($S.Hover) { $bc = [System.Drawing.Color]::FromArgb(255, 60, 64, 96) }
    else          { $bc = [System.Drawing.Color]::FromArgb(255, 42, 45, 66) }
    $rCard = 18.0 * $k
    $bp = New-RoundPath ([float](0.5 * $k)) ([float](0.5 * $k)) ([float]($W - 1.0 * $k)) ([float]($H - 1.0 * $k)) ([float]$rCard)
    $bPen = New-Object System.Drawing.Pen -ArgumentList $bc, ([float](1.0 * $k))
    $g.DrawPath($bPen, $bp)
    $bPen.Dispose(); $bp.Dispose()

    $accent = $S.Accents[$S.Kind]
    $dim    = [System.Drawing.Color]::FromArgb(255, 138, 143, 168)
    $foot   = [System.Drawing.Color]::FromArgb(255, 92, 98, 124)

    # ---- 顶部：状态点 + 计时 + 时钟 ----
    $dotCy = 22.0 * $k
    $dotR  = 3.4 * $k
    $halo = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(55, $accent.R, $accent.G, $accent.B))
    $g.FillEllipse($halo, [float](($pad + 3.0 * $k) - $dotR * 2.2), [float]($dotCy - $dotR * 2.2), [float]($dotR * 4.4), [float]($dotR * 4.4))
    $halo.Dispose()
    $dotBrush = New-Object System.Drawing.SolidBrush -ArgumentList $accent
    $g.FillEllipse($dotBrush, [float](($pad + 3.0 * $k) - $dotR), [float]($dotCy - $dotR), [float]($dotR * 2), [float]($dotR * 2))
    $dotBrush.Dispose()

    $dimBrush = New-Object System.Drawing.SolidBrush -ArgumentList $dim
    if ($S.Resting) {
        $label = '休息'
        $timeStr = Format-MMSS ([int]$S.RestLeft)
        $timeColor = [System.Drawing.Color]::FromArgb(255, 158, 206, 106)
    } else {
        $label = '专注'
        $timeStr = Format-MMSS ([int]$S.FocusSeconds)
        $timeColor = $accent
    }
    $headRect = New-Object System.Drawing.RectangleF -ArgumentList ([float]($pad + 13 * $k)), ([float](13 * $k)), ([float](150 * $k)), ([float](18 * $k))
    $g.DrawString($label, $S.FHead, $dimBrush, $headRect, $S.FmtNear)
    $labelW = $g.MeasureString($label, $S.FHead).Width
    $g.DrawString($timeStr, $S.FHeadBold, (New-Object System.Drawing.SolidBrush -ArgumentList $timeColor), [float]($pad + 13 * $k + $labelW + 4 * $k), [float](13 * $k))

    $clockRect = New-Object System.Drawing.RectangleF -ArgumentList ([float]($W - $pad - 90 * $k)), ([float](13 * $k)), ([float](90 * $k)), ([float](18 * $k))
    $g.DrawString($S.Clock, $S.FHead, $dimBrush, $clockRect, $S.FmtFar)
    $dimBrush.Dispose()

    # ---- 主标语 ----
    $tx = [float]$pad
    $ty = [float](38 * $k)
    $tw = [float]($W - 2 * $pad)
    $th = [float](92 * $k)

    $text = [string]$S.Text
    $chosen = $null
    foreach ($sz in $S.FontSizes) {
        $f = Get-SloganFont $sz
        $m = $g.MeasureString($text, $f, [int]$tw)
        if ($m.Height -le ($th + 4 * $k) -and $m.Width -le ($tw + 4 * $k)) { $chosen = $f; break }
    }
    if (-not $chosen) { $chosen = Get-SloganFont 10.0 }

    if ($S.Kind -eq 'rest') { $c = [System.Drawing.Color]::FromArgb(255, 200, 232, 160) }
    else                    { $c = [System.Drawing.Color]::FromArgb(255, 236, 239, 251) }
    $alpha = [int]$S.Alpha
    if ($alpha -lt 0) { $alpha = 0 }
    if ($alpha -gt 255) { $alpha = 255 }
    $txtBrush = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb($alpha, $c.R, $c.G, $c.B))
    $txtRect = New-Object System.Drawing.RectangleF -ArgumentList $tx, $ty, $tw, $th
    $g.DrawString($text, $chosen, $txtBrush, $txtRect, $S.FmtCenter)
    $txtBrush.Dispose()

    # ---- 底部提示 ----
    $footBrush = New-Object System.Drawing.SolidBrush -ArgumentList $foot
    $hintRect = New-Object System.Drawing.RectangleF -ArgumentList ([float]$pad), ([float](140 * $k)), ([float](250 * $k)), ([float](16 * $k))
    $g.DrawString('拖动移动 · 双击换一句 · 右键菜单', $S.FFoot, $footBrush, $hintRect, $S.FmtNear)
    $roundRect = New-Object System.Drawing.RectangleF -ArgumentList ([float]($W - $pad - 110 * $k)), ([float](140 * $k)), ([float](110 * $k)), ([float](16 * $k))
    $g.DrawString(('今日专注 {0} 轮' -f $S.Rounds), $S.FFoot, $footBrush, $roundRect, $S.FmtFar)
    $footBrush.Dispose()

    # ---- 进度条 ----
    $barY = [float]($H - 16 * $k)
    $barH = [float](4 * $k)
    $barW = [float]($W - 2 * $pad)
    $track = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(255, 34, 37, 54))
    Fill-RoundRect -G $g -B $track -X ([float]$pad) -Y $barY -W $barW -H $barH -R ([float]($barH / 2))
    $track.Dispose()

    if ($S.Resting) {
        if ($S.RestTotal -gt 0) { $ratio = [double]$S.RestLeft / [double]$S.RestTotal } else { $ratio = 0 }
    } else {
        if ($S.FocusTarget -gt 0) { $ratio = [double]$S.FocusSeconds / [double]$S.FocusTarget } else { $ratio = 0 }
    }
    if ($ratio -gt 1) { $ratio = 1 }
    if ($ratio -lt 0) { $ratio = 0 }
    if ($ratio -gt 0.004) {
        $fillW = $barW * $ratio
        if ($fillW -lt $barH) { $fillW = $barH }
        $fill = New-Object System.Drawing.SolidBrush -ArgumentList $accent
        Fill-RoundRect -G $g -B $fill -X ([float]$pad) -Y $barY -W ([float]$fillW) -H $barH -R ([float]($barH / 2))
        $fill.Dispose()
    }
}

# ---------------- 仅安装自启 ----------------
if ($InstallAutostart) {
    Set-Autostart $true
    exit 0
}

# ---------------- 状态初始化 ----------------
Trace-Log 'state-init'
$families = @()
try { $families = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name } } catch { }
if ($families -contains 'Microsoft YaHei UI') { $script:FontFamily = 'Microsoft YaHei UI' }
elseif ($families -contains 'Microsoft YaHei') { $script:FontFamily = 'Microsoft YaHei' }
else { $script:FontFamily = 'Segoe UI' }

$script:S = @{
    Form = $null; Panel = $null
    K = 1.0; WW = 404; HH = 178
    Text = ''; Kind = 'study'; Alpha = 255; FadeDir = 0
    PendingText = ''; PendingKind = 'study'
    Rotation = 0; Paused = $false; TopMost = $true; Hover = $false
    FocusSeconds = 0; FocusTarget = 2700; Resting = $false
    RestLeft = 0; RestTotal = 90; Rounds = 0
    Clock = (Get-Date -Format 'HH:mm')
    FontCache = @{}
    FontSizes = @(23.0, 21.0, 19.0, 17.0, 15.0, 13.0)
    Accents = @{
        study = [System.Drawing.Color]::FromArgb(255, 122, 162, 247)
        work  = [System.Drawing.Color]::FromArgb(255, 187, 154, 247)
        rest  = [System.Drawing.Color]::FromArgb(255, 158, 206, 106)
    }
}

$quotesStudy = @(
    '把今天该做的那一件事，|先做完再说。'
    '十分钟的专注，|比一小时的分心更值钱。'
    '你现在啃下的这一页，|是三个月后的底气。'
    '慢一点没关系，|别停。'
    '学不会的时候，|正是大脑在长肌肉。'
    '先完成，|再完美。'
    '笔记不是抄写，|是讲给未来的自己听。'
    '重复到不用想，|就成了你的。'
)
$quotesWork = @(
    '打开文档的那一刻，|最难的一半已经过去了。'
    '一次只做一件事，|做完再走下一步。'
    '交付比打磨，|更能让你活下去。'
    '把大任务，|切成今天能收尾的小块。'
    '今天的进度条，|得靠自己推一格。'
    '别等状态，|先动手，状态会跟上来。'
    '做完、记录、|然后忘掉它。'
    '你不是没时间，|是没有「现在就开始」。'
)
$quotesRest = @(
    '站起来，走两分钟，|喝口水再回来。'
    '眼睛也需要下课，|看看远处 20 秒。'
    '休息不是偷懒，|是给下一轮充电。'
    '肩膀松一下，|深呼吸三次。'
    '你已经专注很久了，|歇一会儿吧。'
    '今天的努力，|留点力气给明天。'
    '发会儿呆也挺好，|大脑在后台整理。'
    '喝口水，把背挺直，|回来继续。'
)

$nl = [Environment]::NewLine
$script:S.QuotesStudy = @($quotesStudy | ForEach-Object { $_ -replace '\|', $nl })
$script:S.QuotesWork  = @($quotesWork  | ForEach-Object { $_ -replace '\|', $nl })
$script:S.QuotesRest  = @($quotesRest  | ForEach-Object { $_ -replace '\|', $nl })

if ($Demo) {
    $script:S.FocusTarget = 20
    $script:S.RestTotal = 10
}

# ---------------- DPI 初始化 ----------------
$script:S.K = 1.0
$k = 1.0
try {
    $aware = [WinNative]::SetProcessDPIAware()
    $hdc = [WinNative]::GetDC([IntPtr]::Zero)
    $dpi = [WinNative]::GetDeviceCaps($hdc, 88)
    [WinNative]::ReleaseDC([IntPtr]::Zero, $hdc) | Out-Null
    Trace-Log ('aware=' + $aware + ' dpi=' + $dpi)
    if ($dpi -ge 96) { $k = [double]$dpi / 96.0 }
} catch { $k = 1.0; Trace-Log ('dpi-fail ' + $_.Exception.Message) }
if ($k -lt 1) { $k = 1.0 }
$script:S.K = $k
Trace-Log ('dpi k=' + $k)

# ---------------- 字体 ----------------
$script:S.FHead     = New-Object System.Drawing.Font -ArgumentList $script:FontFamily, ([float](12 * $k)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$script:S.FHeadBold = New-Object System.Drawing.Font -ArgumentList $script:FontFamily, ([float](12 * $k)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$script:S.FFoot     = New-Object System.Drawing.Font -ArgumentList $script:FontFamily, ([float](10.5 * $k)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)

function New-SF([System.Drawing.StringAlignment]$a) {
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = $a
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    return $sf
}
$script:S.FmtNear   = New-SF ([System.Drawing.StringAlignment]::Near)
$script:S.FmtFar    = New-SF ([System.Drawing.StringAlignment]::Far)
$script:S.FmtCenter = New-SF ([System.Drawing.StringAlignment]::Center)

# ---------------- 窗体 ----------------
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar   = $false
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.ShowIcon        = $false
$form.Text            = '标语小部件'
$form.BackColor       = [System.Drawing.Color]::FromArgb(15, 16, 24)
$form.TopMost         = $true
$form.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::None
$script:S.WW = [int][math]::Round(404 * $k)
$script:S.HH = [int][math]::Round(178 * $k)
$form.Size            = New-Object System.Drawing.Size -ArgumentList $script:S.WW, $script:S.HH

$panel = New-Object WidgetPanel
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($panel)

# 圆角
$regionPath = New-RoundPath 0 0 ([float]$script:S.WW) ([float]$script:S.HH) ([float](18 * $k))
$form.Region = New-Object System.Drawing.Region -ArgumentList $regionPath
$regionPath.Dispose()

Trace-Log 'form-created'
# ---------------- 位置与配置 ----------------
$cfg = $null
if (Test-Path -LiteralPath $script:CfgPath) {
    try { $cfg = Get-Content -LiteralPath $script:CfgPath -Raw | ConvertFrom-Json } catch { $cfg = $null }
}
$screens = [System.Windows.Forms.Screen]::AllScreens
if ($cfg) {
    $script:S.TopMost = [bool]$cfg.topmost
    $script:S.Paused  = [bool]$cfg.paused
    $script:S.Rounds  = [int]$cfg.rounds
    if ($cfg.day -ne (Get-Date -Format 'yyyy-MM-dd')) { $script:S.Rounds = 0 }
    $form.Left = [int]$cfg.x
    $form.Top  = [int]$cfg.y
} else {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Left = $wa.Right - $script:S.WW - [int](28 * $k)
    $form.Top  = $wa.Bottom - $script:S.HH - [int](28 * $k)
}
$form.TopMost = $script:S.TopMost

# 位置兜底：确保至少在一个屏幕内
$onScreen = $false
foreach ($sc in $screens) {
    $b = $sc.Bounds
    if ($form.Left -gt ($b.Left - 200) -and $form.Left -lt ($b.Right - 50) -and
        $form.Top  -gt ($b.Top  - 100) -and $form.Top  -lt ($b.Bottom - 40)) { $onScreen = $true; break }
}
if (-not $onScreen) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Left = $wa.Right - $script:S.WW - [int](28 * $k)
    $form.Top  = $wa.Bottom - $script:S.HH - [int](28 * $k)
}

# ---------------- 初始文案 ----------------
$first = Get-RandomQuote -Kind 'work'
$script:S.Text = $first
$script:S.Kind = 'work'
$script:S.Alpha = 255

$script:S.Form  = $form
$script:S.Panel = $panel

# ---------------- 右键菜单 ----------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miNext  = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '下一句'
$miPause = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '暂停轮播'
$miFocus = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '重置专注计时'
$miTop   = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '始终置顶'
$miAuto  = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '开机自启'
$miExit  = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '退出'
$miTop.Checked = $script:S.TopMost
$miAuto.Checked = Test-Path -LiteralPath (Get-AutostartPath)
$sep = New-Object System.Windows.Forms.ToolStripSeparator

[void]$menu.Items.Add($miNext)
[void]$menu.Items.Add($miPause)
[void]$menu.Items.Add($miFocus)
[void]$menu.Items.Add($sep)
[void]$menu.Items.Add($miTop)
[void]$menu.Items.Add($miAuto)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miExit)

$panel.ContextMenuStrip = $menu

function Set-PauseText {
    if ($script:S.Paused) { $script:MiPause.Text = '继续轮播' } else { $script:MiPause.Text = '暂停轮播' }
}

$script:MiPause = $miPause
Set-PauseText

$miNext.Add_Click({
    if ($script:S.Resting) { return }
    $script:S.Paused = $false
    Set-PauseText
    Show-NextQuote
})

$miPause.Add_Click({
    $script:S.Paused = -not $script:S.Paused
    Set-PauseText
})

$miFocus.Add_Click({
    $script:S.Resting = $false
    $script:S.FocusSeconds = 0
    $script:S.Paused = $false
    Set-PauseText
    Show-NextQuote
})

$miTop.Add_Click({
    $script:S.TopMost = -not $script:S.TopMost
    $script:S.Form.TopMost = $script:S.TopMost
    $miTop.Checked = $script:S.TopMost
    Save-Config
})

$miAuto.Add_Click({
    try {
        $on = -not (Test-Path -LiteralPath (Get-AutostartPath))
        Set-Autostart $on
        $miAuto.Checked = $on
    } catch { }
})

$miExit.Add_Click({
    Save-Config
    [System.Windows.Forms.Application]::Exit()
})

# ---------------- 交互 ----------------
$script:dragActive = $false
$script:dragStartCursor = New-Object System.Drawing.Point 0, 0
$script:dragStartForm   = New-Object System.Drawing.Point 0, 0

$panel.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragActive = $true
        $script:dragStartCursor = [System.Windows.Forms.Cursor]::Position
        $script:dragStartForm = New-Object System.Drawing.Point -ArgumentList $script:S.Form.Left, $script:S.Form.Top
    }
})

$panel.Add_MouseMove({
    param($s, $e)
    if ($script:dragActive) {
        if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::Left) {
            $script:dragActive = $false
            Save-Config
            return
        }
        $cp = [System.Windows.Forms.Cursor]::Position
        $script:S.Form.Left = $script:dragStartForm.X + ($cp.X - $script:dragStartCursor.X)
        $script:S.Form.Top  = $script:dragStartForm.Y + ($cp.Y - $script:dragStartCursor.Y)
    }
})

$panel.Add_MouseUp({
    param($s, $e)
    if ($script:dragActive) {
        $script:dragActive = $false
    }
})

$panel.Add_DoubleClick({
    if ($script:S.Resting) { return }
    $script:S.Paused = $false
    Set-PauseText
    Show-NextQuote
})

$panel.Add_MouseEnter({ $script:S.Hover = $true; $script:S.Panel.Invalidate() })
$panel.Add_MouseLeave({ $script:S.Hover = $false; $script:S.Panel.Invalidate() })

$panel.Add_Paint({
    param($s, $e)
    try { Draw-Widget -g $e.Graphics } catch { }
})

# ---------------- 定时器 ----------------
$script:ClockTimer = New-Object System.Windows.Forms.Timer
$script:ClockTimer.Interval = 1000
$script:ClockTimer.Add_Tick({
    $S = $script:S
    $S.Clock = (Get-Date -Format 'HH:mm')
    if ($S.Resting) {
        $S.RestLeft = $S.RestLeft - 1
        if ($S.RestLeft -le 0) { End-Rest }
    } else {
        $S.FocusSeconds = $S.FocusSeconds + 1
        if ($S.FocusSeconds -ge $S.FocusTarget) { Start-Rest }
    }
    $S.Panel.Invalidate()
})

$script:RotTimer = New-Object System.Windows.Forms.Timer
$script:RotTimer.Interval = 1350000
$script:RotTimer.Add_Tick({
    if (-not $script:S.Paused -and -not $script:S.Resting) { Show-NextQuote }
})

$script:FadeTimer = New-Object System.Windows.Forms.Timer
$script:FadeTimer.Interval = 20
$script:FadeTimer.Add_Tick({
    $S = $script:S
    if ($S.FadeDir -lt 0) { $step = 24 } else { $step = 14 }
    $S.Alpha = $S.Alpha + ($S.FadeDir * $step)
    if ($S.FadeDir -lt 0 -and $S.Alpha -le 0) {
        $S.Alpha = 0
        if ($S.PendingText) { $S.Text = $S.PendingText }
        $S.Kind = $S.PendingKind
        $S.FadeDir = 1
    } elseif ($S.FadeDir -gt 0 -and $S.Alpha -ge 255) {
        $S.Alpha = 255
        $S.FadeDir = 0
        $script:FadeTimer.Stop()
    }
    $S.Panel.Invalidate()
})

# ---------------- 收尾 ----------------
$form.Add_FormClosing({
    Save-Config
    try { $script:ClockTimer.Stop() } catch { }
    try { $script:RotTimer.Stop() } catch { }
    try { $script:FadeTimer.Stop() } catch { }
})

$form.Add_Shown({
    Trace-Log ('shown visible=' + $script:S.Form.Visible + ' bounds=' + $script:S.Form.Bounds)
    $script:S.Panel.Invalidate()
})

[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    try { Add-Content -LiteralPath $script:LogPath -Value ('[UI] ' + $e.Exception.Message) -Encoding UTF8 } catch { }
})

$script:ClockTimer.Start()
$script:RotTimer.Start()

Trace-Log 'enter-loop'
[System.Windows.Forms.Application]::Run($form)
