<#
.SYNOPSIS
    启动 卓越播放器 并截取窗口截图，用于人工核对窗口材质（亚克力 / Mica）是否真的生效。

.DESCRIPTION
    为什么必须靠截图而不是"看代码里调了 DwmSetWindowAttribute"：
    设置系统材质要同时满足三个条件 —— 窗口句柄找对、DWM 调用成功、
    **Flutter 的渲染面真的带 alpha**。第三条最容易失败，而且失败时
    代码路径完全正常（HRESULT 是 0），界面上只表现为"看起来是个实色窗口"。
    唯一的验证方式就是把它显示出来截一张图。

    截图走 CopyFromScreen 而不是 PrintWindow：后者对 DWM 合成出来的
    毛玻璃背景通常抓到的是黑块，只有抓屏幕区域才是用户真正看到的画面。

.EXAMPLE
    pwsh -File scripts/capture-window.ps1
    pwsh -File scripts/capture-window.ps1 -Out docs\images\screenshot-simulated.png
#>
[CmdletBinding()]
param(
    [string]$Exe = 'build\windows\x64\runner\Debug\zhuoyue_player.exe',
    [string]$Out = 'docs\images\screenshot-window.png',
    [int]$WaitSeconds = 30,
    [int]$SettleSeconds = 6,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

if (-not (Test-Path $Exe)) { throw "找不到可执行文件：$Exe（请先执行 flutter build windows --debug）" }
$OutPath = Join-Path $RepoRoot $Out
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Zhy -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
'@

# 必须在做任何窗口/屏幕坐标查询之前声明 DPI 感知。
#
# 否则 PowerShell 进程是 DPI 不感知的：拿到的窗口/客户区坐标是"虚拟化"过的
# （按 96 DPI 缩放），而 GDI+ 的 CopyFromScreen 最终仍按物理像素采样。
# 两套坐标系混用会让截图整体错位 —— 本机 150% 缩放下实测错位约 170 像素，
# 表现为窗口底部被裁掉、右侧一列控件整个消失，
# 极容易被误判成"界面里根本没渲染那个控件"（这次就为此白查了很久）。
[void][Zhy.Win]::SetProcessDPIAware()

$proc = Start-Process -FilePath $Exe -PassThru
Write-Host "已启动 PID=$($proc.Id)，等待窗口出现…" -ForegroundColor Cyan

$handle = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    $proc.Refresh()
    if ($proc.HasExited) { throw "进程在窗口出现前就退出了（退出码 $($proc.ExitCode)）" }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        $handle = $proc.MainWindowHandle
        if ([Zhy.Win]::IsWindowVisible($handle)) { break }
    }
}
if ($handle -eq [IntPtr]::Zero) { throw "在 $WaitSeconds 秒内没有拿到主窗口句柄" }
Write-Host "窗口句柄：$handle" -ForegroundColor Cyan

# 让窗口到前台并留出时间让主题、封面、取色都跑完。
[void][Zhy.Win]::ShowWindow($handle, 9)   # SW_RESTORE
[void][Zhy.Win]::SetForegroundWindow($handle)
Write-Host "等待界面稳定（$SettleSeconds 秒）…" -ForegroundColor Cyan
Start-Sleep -Seconds $SettleSeconds

# 用**客户区**而不是窗口矩形。
#
# 这里踩过一个很隐蔽的坑，值得记下来：`GetWindowRect` 在 DPI 不感知的进程里
# 返回的是"虚拟化"过的坐标，而且本项目的窗口用了
# `DwmExtendFrameIntoClientArea(-1)` + `TitleBarStyle.hidden`，
# 于是窗口矩形比真正的客户区**左移了约 145 像素**。
# 结果按窗口矩形截图会整体右移，把最右侧约 145 像素（也就是窗口按钮、
# 设置页里的「登录」「刷新」按钮所在的那一列）裁在画面之外 ——
# 看上去就像"按钮没渲染出来"，实际去打印渲染坐标才发现它们好好地在那儿。
# 用 GetClientRect + ClientToScreen 拿到的才是真正要拍的区域。
$clientRect = New-Object Zhy.Win+RECT
if (-not [Zhy.Win]::GetClientRect($handle, [ref]$clientRect)) { throw "GetClientRect 失败" }
$origin = New-Object Zhy.Win+POINT
[void][Zhy.Win]::ClientToScreen($handle, [ref]$origin)

$width = $clientRect.Right - $clientRect.Left
$height = $clientRect.Bottom - $clientRect.Top
if ($width -le 0 -or $height -le 0) { throw "客户区尺寸异常：${width}x${height}" }

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bitmap.Size)
} finally {
    $graphics.Dispose()
}
try {
    $bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $bitmap.Dispose()
}

Write-Host "截图已保存：$OutPath  (${width}x${height}，客户区原点 $($origin.X),$($origin.Y))" -ForegroundColor Green

if (-not $KeepRunning) {
    # 优雅关闭，好让应用有机会收掉内嵌的 node 子进程。
    $proc.CloseMainWindow() | Out-Null
    if (-not $proc.WaitForExit(8000)) {
        Write-Host "优雅关闭超时，强制结束" -ForegroundColor Yellow
        $proc.Kill()
    }
    Write-Host "应用已退出" -ForegroundColor Green
} else {
    Write-Host "应用保持运行中（PID=$($proc.Id)）" -ForegroundColor Yellow
}
