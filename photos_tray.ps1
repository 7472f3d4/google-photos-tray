# photos_tray.ps1 — Google フォト (PWA) を Windows のタスクトレイに常駐させる。
#   - 外部ツール不要（Windows 標準の PowerShell + .NET の NotifyIcon だけ）
#   - 専用プロファイルで Chrome をアプリ表示（--app）→ ウィンドウ管理が確定的
#   - トレイアイコン: 左クリックで表示/非表示トグル、右クリックでメニュー
param(
    [string]$Url         = "https://photos.google.com/",
    [string]$UserDataDir = "$env:LOCALAPPDATA\GooglePhotosTray\profile",
    [ValidateRange(0, 300)]
    [int]$StartupDelaySeconds = 0
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $env:LOCALAPPDATA "GooglePhotosTray\logs"
$logFile = Join-Path $logDir "startup.log"

function Write-StartupLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Add-Content -LiteralPath $logFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message) -Encoding UTF8
    }
    catch {
        # ログ出力の失敗で本体の起動を妨げない。
    }
}

trap {
    Write-StartupLog ("ERROR: " + $_.Exception.ToString())
    exit 1
}

Write-StartupLog ("START pid={0} delay={1}s profile={2}" -f $PID, $StartupDelaySeconds, $UserDataDir)
if ($StartupDelaySeconds -gt 0) {
    Write-StartupLog ("Waiting {0} seconds for Windows and Chrome startup." -f $StartupDelaySeconds)
    Start-Sleep -Seconds $StartupDelaySeconds
}

# --- 二重起動防止（同一ログインセッション内で 1 つだけ） ---
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "GooglePhotosTrayApp", ([ref]$createdNew))
if (-not $createdNew) {
    Write-StartupLog "Another tray host is already running; exiting."
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public const int SW_HIDE = 0;
    public const int SW_RESTORE = 9;
}
"@

function Get-ChromePath {
    $registryKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
    )
    foreach ($key in $registryKeys) {
        $value = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue)."(default)"
        if ($value -and (Test-Path -LiteralPath $value)) { return $value }
    }
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $command = Get-Command chrome.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "chrome.exe was not found."
}

$chrome = Get-ChromePath
Write-StartupLog ("Chrome={0}" -f $chrome)
$script:proc = $null
$script:hwnd = [IntPtr]::Zero

function Get-PhotosBrowser {
    # 専用プロファイルでウィンドウを持つ Chrome 本体プロセスを探す。
    # Start-Process が返すプロセスはランチャーとして即終了し、実際のウィンドウは
    # 別 PID のブラウザ本体が持つことがあるため、戻り値に頼らずコマンドラインで特定する。
    # （--type= 付きはレンダラ等の子プロセスなので除外し、本体だけを拾う。）
    $procs = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
             Where-Object {
                 $_.CommandLine -and
                 $_.CommandLine -match [regex]::Escape($UserDataDir) -and
                 $_.CommandLine -notmatch '--type='
             }
    foreach ($p in $procs) {
        $pp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($pp -and $pp.MainWindowHandle -ne [IntPtr]::Zero) { return $pp }
    }
    return $null
}

function Start-Photos {
    if ($script:proc -and -not $script:proc.HasExited -and $script:hwnd -ne [IntPtr]::Zero) { return }
    # すでに本体プロセスが起動済みなら、それを採用する（ホスト再起動時の取り直しも兼ねる）。
    $existing = Get-PhotosBrowser
    if ($existing) {
        $script:proc = $existing
        $script:hwnd = $existing.MainWindowHandle
        Write-StartupLog ("Using existing Chrome process pid={0}." -f $existing.Id)
        return
    }
    $chromeArgs = @(
        "--app=$Url",
        "--user-data-dir=`"$UserDataDir`"",
        "--no-first-run",
        "--no-default-browser-check",
        # トレイ非表示中も Google フォトのフォルダ自動バックアップが止まらないように、
        # Chrome のバックグラウンド抑制（タイマー間引き・非表示ウィンドウの省電力化）を無効化する。
        "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding"
    )
    Write-StartupLog "Starting dedicated Chrome profile."
    Start-Process -FilePath $chrome -ArgumentList $chromeArgs -WindowStyle Minimized | Out-Null
    # ランチャーの受け渡しを挟んでも確実に本体ウィンドウを掴めるよう、コマンドライン基準でポーリング。
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $b = Get-PhotosBrowser
        if ($b) {
            $script:proc = $b
            $script:hwnd = $b.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not $script:proc) {
        throw "Google Chrome window did not appear within 20 seconds."
    }
    Write-StartupLog ("Chrome window attached pid={0}." -f $script:proc.Id)
}

function Show-Photos {
    if (-not $script:proc -or $script:proc.HasExited -or $script:hwnd -eq [IntPtr]::Zero) {
        $script:proc = $null; $script:hwnd = [IntPtr]::Zero
        Start-Photos
    }
    if ($script:hwnd -ne [IntPtr]::Zero) {
        [Win32]::ShowWindow($script:hwnd, [Win32]::SW_RESTORE) | Out-Null
        [Win32]::SetForegroundWindow($script:hwnd) | Out-Null
    }
}

function Hide-Photos {
    if ($script:hwnd -ne [IntPtr]::Zero) {
        [Win32]::ShowWindow($script:hwnd, [Win32]::SW_HIDE) | Out-Null
    }
}

function Toggle-Photos {
    if ($script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindowVisible($script:hwnd)) {
        Hide-Photos
    } else {
        Show-Photos
    }
}

# 初回（専用プロファイル未作成）はログインと「フォルダをバックアップ」設定が必要なので
# ウィンドウを表示する。2回目以降はトレイのみで静かに起動。
$firstRun = -not (Test-Path -LiteralPath $UserDataDir)
Write-StartupLog ("FirstRun={0}" -f $firstRun)
Start-Photos
if (-not $firstRun) { Hide-Photos }

# --- トレイアイコン ---
try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($chrome) }
catch { $icon = [System.Drawing.SystemIcons]::Application }

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $icon
$ni.Text = "Google Photos"
$ni.Visible = $true
Write-StartupLog "Tray icon is visible."

if ($firstRun) {
    $ni.BalloonTipTitle = "Google Photos tray started"
    $ni.BalloonTipText  = "Sign in on the window that opened, then go to Settings -> `"Back up folder`" to choose a folder to back up. After that, use the tray icon's left click to show/hide the window."
    $ni.ShowBalloonTip(15000)
}

$menu     = New-Object System.Windows.Forms.ContextMenuStrip
$miToggle = $menu.Items.Add("Show / Hide")
$miReopen = $menu.Items.Add("Reopen")
$miExit   = $menu.Items.Add("Exit")
$ni.ContextMenuStrip = $menu

$ni.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Photos }
})
$miToggle.add_Click({ Toggle-Photos })
$miReopen.add_Click({
    try { if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill() } } catch {}
    $script:proc = $null; $script:hwnd = [IntPtr]::Zero
    Show-Photos
})
$miExit.add_Click({
    Write-StartupLog "Exit requested from tray menu."
    $ni.Visible = $false
    try { if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill() } } catch {}
    [System.Windows.Forms.Application]::Exit()
})

[System.Windows.Forms.Application]::Run()
Write-StartupLog "Tray host stopped."
try { $mutex.ReleaseMutex() } catch {}
