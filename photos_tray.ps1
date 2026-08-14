# photos_tray.ps1 — Google フォトを必要なときだけ同期するタスクトレイホスト
#   - Pictures / Videos を FileSystemWatcher で監視し、待機中は Chrome を起動しない
#   - メディア変更時だけ専用 Chrome を画面外で可視状態にして Google フォトを動かす
#   - トレイ操作時だけ通常のウィンドウを表示する
#Requires -PSEdition Core
param(
    [string]$Url         = "https://photos.google.com/",
    [string]$UserDataDir = "$env:LOCALAPPDATA\GooglePhotosTray\profile",
    [ValidateRange(0, 300)]
    [int]$StartupDelaySeconds = 0,
    [switch]$OpenNow,
    [ValidateRange(30, 1800)]
    [int]$SyncQuietSeconds = 300,
    [ValidateRange(60, 3600)]
    [int]$RescanIntervalSeconds = 600,
    [ValidateRange(15, 3600)]
    [int]$FailureRetrySeconds = 60,
    [ValidateRange(1, 5)]
    [int]$MaxFailureRetries = 3
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $env:LOCALAPPDATA "GooglePhotosTray\logs"
$logFile = Join-Path $logDir "startup.log"
$stateFile = Join-Path $env:LOCALAPPDATA "GooglePhotosTray\media-state.json"
$authenticationStateFile = Join-Path $env:LOCALAPPDATA "GooglePhotosTray\authentication-required.json"

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

Write-StartupLog ("START pid={0} delay={1}s openNow={2}" -f $PID, $StartupDelaySeconds, $OpenNow.IsPresent)
if ($StartupDelaySeconds -gt 0) {
    Write-StartupLog ("Waiting {0} seconds for Windows startup." -f $StartupDelaySeconds)
    Start-Sleep -Seconds $StartupDelaySeconds
}

# --- 二重起動防止（同一ログインセッション内で1つだけ） ---
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "GooglePhotosTrayApp", ([ref]$createdNew))
if (-not $createdNew) {
    Write-StartupLog "Another tray host is already running; exiting."
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:uiAutomationAvailable = $false
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $script:uiAutomationAvailable = $true
}
catch {
    Write-StartupLog ("WARN: Google Photos UI detection unavailable: " + $_.Exception.Message)
}

Add-Type @"
using System;
using System.Text;
using System.IO;
using System.Threading;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
public static class Win32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint="GetWindowLongPtr", SetLastError=true)]
    static extern IntPtr GetWindowLongPtr64(IntPtr h, int index);
    [DllImport("user32.dll", EntryPoint="GetWindowLong", SetLastError=true)]
    static extern int GetWindowLong32(IntPtr h, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr", SetLastError=true)]
    static extern IntPtr SetWindowLongPtr64(IntPtr h, int index, IntPtr value);
    [DllImport("user32.dll", EntryPoint="SetWindowLong", SetLastError=true)]
    static extern int SetWindowLong32(IntPtr h, int index, int value);

    public static IntPtr GetWindowLongPtr(IntPtr h, int index) {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(h, index) : new IntPtr(GetWindowLong32(h, index));
    }
    public static IntPtr SetWindowLongPtr(IntPtr h, int index, IntPtr value) {
        return IntPtr.Size == 8 ? SetWindowLongPtr64(h, index, value) : new IntPtr(SetWindowLong32(h, index, value.ToInt32()));
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder text, int length);

    public static IntPtr FindWindowForProcess(int pid) {
        IntPtr fallback = IntPtr.Zero;
        IntPtr hiddenAppWindow = IntPtr.Zero;
        IntPtr visibleAppWindow = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            uint ownerPid;
            GetWindowThreadProcessId(hWnd, out ownerPid);
            if (ownerPid == (uint)pid) {
                if (fallback == IntPtr.Zero) { fallback = hWnd; }
                var className = new StringBuilder(128);
                var title = new StringBuilder(256);
                GetClassName(hWnd, className, className.Capacity);
                GetWindowText(hWnd, title, title.Capacity);
                if (className.ToString() == "Chrome_WidgetWin_1" && title.Length > 0) {
                    if (IsWindowVisible(hWnd) && visibleAppWindow == IntPtr.Zero) {
                        visibleAppWindow = hWnd;
                    }
                    else if (!IsWindowVisible(hWnd) && hiddenAppWindow == IntPtr.Zero) {
                        hiddenAppWindow = hWnd;
                    }
                }
            }
            return true;
        }, IntPtr.Zero);
        // Do not attach to Chrome's temporary untitled window.  The app window
        // becomes usable only after Google Photos has supplied its title.
        return visibleAppWindow != IntPtr.Zero ? visibleAppWindow :
               hiddenAppWindow != IntPtr.Zero ? hiddenAppWindow : IntPtr.Zero;
    }

    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOOLWINDOW = 0x00000080L;
    public const long WS_EX_APPWINDOW = 0x00040000L;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_FRAMECHANGED = 0x0020;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const int SW_HIDE = 0;
    public const int SW_RESTORE = 9;
    public const int SW_SHOWNOACTIVATE = 4;
    public const uint WM_KEYDOWN = 0x0100;
    public const uint WM_KEYUP = 0x0101;
    public const int VK_F5 = 0x74;
}

public sealed class TrayMediaWatcher : IDisposable {
    private readonly FileSystemWatcher watcher;
    private readonly ConcurrentQueue<string> queue;
    private int errorRequested;

    public TrayMediaWatcher(string root, ConcurrentQueue<string> queue) {
        this.queue = queue;
        this.watcher = new FileSystemWatcher(root);
        this.watcher.Filter = "*";
        this.watcher.IncludeSubdirectories = true;
        this.watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName |
                                     NotifyFilters.LastWrite | NotifyFilters.Size;
        this.watcher.InternalBufferSize = 65536;
        this.watcher.Created += OnChanged;
        this.watcher.Changed += OnChanged;
        this.watcher.Deleted += OnChanged;
        this.watcher.Renamed += OnRenamed;
        this.watcher.Error += OnError;
        this.watcher.EnableRaisingEvents = true;
    }

    private void OnChanged(object sender, FileSystemEventArgs e) {
        if (e != null && !String.IsNullOrEmpty(e.FullPath)) {
            queue.Enqueue(e.FullPath);
        }
    }

    private void OnRenamed(object sender, RenamedEventArgs e) {
        OnChanged(sender, e);
        if (e != null && !String.IsNullOrEmpty(e.OldFullPath)) {
            queue.Enqueue(e.OldFullPath);
        }
    }

    private void OnError(object sender, ErrorEventArgs e) {
        Interlocked.Exchange(ref errorRequested, 1);
    }

    public bool ConsumeErrorRequest() {
        return Interlocked.Exchange(ref errorRequested, 0) == 1;
    }

    public void Dispose() {
        watcher.EnableRaisingEvents = false;
        watcher.Created -= OnChanged;
        watcher.Changed -= OnChanged;
        watcher.Deleted -= OnChanged;
        watcher.Renamed -= OnRenamed;
        watcher.Error -= OnError;
        watcher.Dispose();
    }
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
$script:normalRect = $null
$script:backgrounded = $false
$script:manualVisible = $false
$script:starting = $false
$script:exitRequested = $false
$script:syncActive = $false
$script:lastMediaEventUtc = [DateTime]::MinValue
$script:syncStartedUtc = [DateTime]::MinValue
$script:lastStatusCheckUtc = [DateTime]::MinValue
$script:syncStatusSeenClear = $false
$script:syncCompletionObserved = $false
$script:syncCompletionUtc = [DateTime]::MinValue
$script:syncFailureObserved = $false
$script:syncFailureStatusSeenClear = $false
$script:syncFailureRetryCount = 0
$script:syncFailureNextRetryUtc = [DateTime]::MinValue
$script:syncFailureNoticeShown = $false
$script:syncFailureHoldNoticeWritten = $false
$script:syncFailureBrowserExitLogWritten = $false
$script:syncCompletionHoldNoticeWritten = $false
$script:syncStatusLogWritten = $false
$script:uiAutomationWarningWritten = $false
$script:lastUiReadUtc = [DateTime]::MinValue
$script:cachedUiNames = @()
$script:authenticationRequired = Test-Path -LiteralPath $authenticationStateFile
$script:authenticationClearChecks = 0
$script:lastAuthenticationCheckUtc = [DateTime]::MinValue
$script:authenticationNoticeShown = $false
$script:authenticationDetectedDuringSync = $false
$script:notifyIcon = $null
$script:lastRescanUtc = [DateTime]::MinValue
$script:rescanRequested = $false
$script:watchQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:watchers = New-Object 'System.Collections.Generic.List[TrayMediaWatcher]'
$script:candidates = @{}
$script:pendingSync = @{}
$script:mediaState = @{}
$script:stateLoaded = $false

$script:authenticationPatterns = @(
    '^ログイン$',
    '^サインイン$',
    'Google アカウントにログイン',
    'Google アカウントを使用',
    'アカウントを選択',
    '別のアカウントを使用',
    'ログイン.*Google',
    'Google フォトに移動',
    '(?i)^sign in$',
    '(?i)sign in (to|with) (google|your google account)',
    '(?i)use your google account',
    '(?i)^choose an account$',
    '(?i)^use another account$',
    '(?i)^go to google photos$',
    '(?i)^sign in\s*[-–—]\s*google'
)

$script:watchRoots = @(
    (Join-Path $env:USERPROFILE "Pictures"),
    (Join-Path $env:USERPROFILE "Videos")
) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

$script:mediaExtensions = @{}
@(
    # GoogleフォトのWebフォルダーバックアップが案内している形式だけを対象にする。
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".avif",
    ".mpg", ".mod", ".mmv", ".tod", ".wmv", ".asf", ".avi", ".divx", ".mov", ".m4v",
    ".3gp", ".3g2", ".mp4", ".m2t", ".m2ts", ".mts", ".mkv"
) | ForEach-Object { $script:mediaExtensions[$_] = $true }

function Test-IsMediaPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant() } catch { return $false }
    return $script:mediaExtensions.ContainsKey($extension)
}

function Get-MediaFingerprint {
    param($Item)
    return ("{0}|{1}" -f $Item.Length, $Item.LastWriteTimeUtc.Ticks)
}

function Get-GooglePhotosMediaIssue {
    param([System.IO.FileInfo]$Item)
    if (-not $Item) { return 'ファイルを読み取れません' }

    # GoogleフォトのWebバックアップの上限。超過ファイルを待ち続けない。
    if ($Item.Length -gt 200MB) { return '写真のサイズが200 MBを超えています' }
    if ($Item.Extension.ToLowerInvariant() -in @('.mpg','.mod','.mmv','.tod','.wmv','.asf','.avi','.divx','.mov','.m4v','.3gp','.3g2','.mp4','.m2t','.m2ts','.mts','.mkv')) {
        if ($Item.Length -gt 10GB) { return '動画のサイズが10 GBを超えています' }
        return $null
    }

    # Web版は写真の縦横が256ピクセル以下のファイルを受け付けない。
    # Windows標準デコーダーで読めない形式は、Google側の判定に任せる。
    if ($Item.Extension.ToLowerInvariant() -in @('.jpg','.jpeg','.png','.gif')) {
        $stream = $null
        $image = $null
        try {
            $stream = [IO.File]::Open($Item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $image = [System.Drawing.Image]::FromStream($stream, $false, $true)
            if ($image.Width -le 256 -or $image.Height -le 256) {
                return '写真の縦横が256ピクセル以下です'
            }
            if ([int64]$image.Width * [int64]$image.Height -gt 200000000) {
                return '写真の画素数が200 MPを超えています'
            }
        }
        catch {
            # HEIC/WebP/AVIFなど、System.Drawingで読めない形式は除外しない。
            return $null
        }
        finally {
            if ($image) { $image.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    return $null
}

function Get-CurrentMediaSnapshot {
    $snapshot = @{}
    foreach ($root in $script:watchRoots) {
        try {
            Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { Test-IsMediaPath $_.FullName } |
                ForEach-Object { $snapshot[$_.FullName] = Get-MediaFingerprint $_ }
        }
        catch {
            Write-StartupLog ("WARN: media scan failed for {0}: {1}" -f $root, $_.Exception.Message)
        }
    }
    return $snapshot
}

function Load-MediaState {
    $script:stateLoaded = Test-Path -LiteralPath $stateFile
    if (-not $script:stateLoaded) { return }
    try {
        $data = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($record in @($data)) {
            if ($record.Path -and $record.Fingerprint) {
                $script:mediaState[[string]$record.Path] = [string]$record.Fingerprint
            }
        }
    }
    catch {
        Write-StartupLog ("WARN: media state could not be loaded: {0}" -f $_.Exception.Message)
        $script:stateLoaded = $false
        $script:mediaState.Clear()
    }
}

function Save-MediaState {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $stateFile) -Force | Out-Null
        $records = @($script:mediaState.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{ Path = $_.Key; Fingerprint = $_.Value }
        })
        if ($records.Count -eq 0) {
            "[]" | Set-Content -LiteralPath $stateFile -Encoding UTF8
        }
        else {
            $records | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $stateFile -Encoding UTF8
        }
    }
    catch {
        Write-StartupLog ("WARN: media state could not be saved: {0}" -f $_.Exception.Message)
    }
}

function Add-MediaCandidate {
    param([string]$Path)
    if (-not (Test-IsMediaPath $Path)) { return }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $script:candidates.Remove($Path)
            return
        }
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $script:candidates[$Path] = [PSCustomObject]@{
            FirstSeenUtc = [DateTime]::UtcNow
            Length = $item.Length
            LastWriteTicks = $item.LastWriteTimeUtc.Ticks
        }
    }
    catch {
        # ファイル作成途中・一時ロック中は次のイベント/再スキャンで再確認する。
    }
}

function Queue-StableMedia {
    param([string]$Path, [string]$Fingerprint)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $issue = Get-GooglePhotosMediaIssue $item
        if ($issue) {
            $script:pendingSync.Remove($Path)
            if (-not $script:mediaState.ContainsKey($Path) -or $script:mediaState[$Path] -ne $Fingerprint) {
                $script:mediaState[$Path] = $Fingerprint
                Save-MediaState
                Write-StartupLog ("Media skipped (Google Photos does not accept this file): {0} - {1}" -f $Path, $issue)
            }
            return
        }
    }
    catch {
        return
    }
    if (-not $script:pendingSync.ContainsKey($Path) -or $script:pendingSync[$Path] -ne $Fingerprint) {
        $script:pendingSync[$Path] = $Fingerprint
        $script:lastMediaEventUtc = [DateTime]::UtcNow
        $script:syncStatusSeenClear = $false
        $script:syncCompletionObserved = $false
        $script:syncCompletionUtc = [DateTime]::MinValue
        Write-StartupLog ("Media change queued: {0}" -f $Path)
    }
}

function Process-WatchQueue {
    $path = $null
    while ($script:watchQueue.TryDequeue([ref]$path)) {
        Add-MediaCandidate $path
        $path = $null
    }

    foreach ($path in @($script:candidates.Keys)) {
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $script:candidates.Remove($path)
                continue
            }
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            $candidate = $script:candidates[$path]
            $same = $candidate.Length -eq $item.Length -and $candidate.LastWriteTicks -eq $item.LastWriteTimeUtc.Ticks
            if ($same -and ([DateTime]::UtcNow - $candidate.FirstSeenUtc).TotalSeconds -ge 2) {
                Queue-StableMedia $path (Get-MediaFingerprint $item)
                $script:candidates.Remove($path)
            }
            elseif (-not $same) {
                $script:candidates[$path] = [PSCustomObject]@{
                    FirstSeenUtc = [DateTime]::UtcNow
                    Length = $item.Length
                    LastWriteTicks = $item.LastWriteTimeUtc.Ticks
                }
            }
        }
        catch {
            # 次のイベントで再試行する。
        }
    }
}

function Invoke-MediaRescan {
    $current = Get-CurrentMediaSnapshot
    if (-not $script:stateLoaded) {
        $script:mediaState = $current
        $script:stateLoaded = $true
        Save-MediaState
        $script:lastRescanUtc = [DateTime]::UtcNow
        Write-StartupLog ("Initial media baseline created: {0} files." -f $current.Count)
        return
    }

    foreach ($path in $current.Keys) {
        if ((-not $script:mediaState.ContainsKey($path) -or $script:mediaState[$path] -ne $current[$path]) -and
            -not $script:pendingSync.ContainsKey($path) -and -not $script:candidates.ContainsKey($path)) {
            Add-MediaCandidate $path
        }
    }
    foreach ($path in @($script:mediaState.Keys)) {
        if (-not $current.ContainsKey($path)) { $script:mediaState.Remove($path) }
    }
    $script:lastRescanUtc = [DateTime]::UtcNow
}

function Initialize-MediaWatchers {
    foreach ($root in $script:watchRoots) {
        $watcher = [TrayMediaWatcher]::new($root, $script:watchQueue)
        $script:watchers.Add($watcher)
        Write-StartupLog ("Watching media root: {0}" -f $root)
    }
}

function Dispose-MediaWatchers {
    foreach ($watcher in $script:watchers) {
        try { $watcher.Dispose() } catch {}
    }
    $script:watchers.Clear()
}

function Get-PhotosProcess {
    $procs = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match [regex]::Escape($UserDataDir) -and
            $_.CommandLine -notmatch '--type='
        }
    foreach ($p in $procs) {
        $pp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($pp) { return $pp }
    }
    return $null
}

function Get-PhotosBrowser {
    $process = Get-PhotosProcess
    if ($process) {
        $handle = [Win32]::FindWindowForProcess($process.Id)
        if ($handle -ne [IntPtr]::Zero) {
            return [PSCustomObject]@{ Process = $process; Hwnd = $handle }
        }
    }
    return $null
}

function Get-DefaultWindowRect {
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $width = [Math]::Min(1200, [Math]::Max(800, [int]($screen.Width * 0.6)))
    $height = [Math]::Min(800, [Math]::Max(600, [int]($screen.Height * 0.7)))
    return [PSCustomObject]@{
        X = $screen.Left + [int](($screen.Width - $width) / 2)
        Y = $screen.Top + [int](($screen.Height - $height) / 2)
        Width = $width
        Height = $height
    }
}

function Capture-NormalWindowRect {
    if ($script:hwnd -eq [IntPtr]::Zero) { $script:normalRect = Get-DefaultWindowRect; return }
    $rect = New-Object Win32+RECT
    if ([Win32]::GetWindowRect($script:hwnd, [ref]$rect)) {
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $outside = ($rect.Right -lt $screen.Left -or $rect.Left -gt ($screen.Right) -or $rect.Bottom -lt $screen.Top -or $rect.Top -gt ($screen.Bottom))
        if ($width -ge 300 -and $height -ge 200 -and -not $outside) {
            $script:normalRect = [PSCustomObject]@{ X=$rect.Left; Y=$rect.Top; Width=$width; Height=$height }
            return
        }
    }
    $script:normalRect = Get-DefaultWindowRect
}

function Set-PhotosWindowStyle {
    param([bool]$Background)
    $style = [Win32]::GetWindowLongPtr($script:hwnd, [Win32]::GWL_EXSTYLE).ToInt64()
    if ($Background) {
        $style = ($style -band (-bnot [int64][Win32]::WS_EX_APPWINDOW)) -bor [int64][Win32]::WS_EX_TOOLWINDOW
    }
    else {
        $style = ($style -band (-bnot [int64][Win32]::WS_EX_TOOLWINDOW)) -bor [int64][Win32]::WS_EX_APPWINDOW
    }
    [Win32]::SetWindowLongPtr($script:hwnd, [Win32]::GWL_EXSTYLE, [IntPtr]$style) | Out-Null
}

function Set-PhotosBackground {
    if ($script:hwnd -eq [IntPtr]::Zero -or -not [Win32]::IsWindow($script:hwnd)) { return }
    if (-not $script:normalRect) { Capture-NormalWindowRect }
    # Keep the transition hidden. Chrome is launched minimized, and restoring
    # it while visible can flash the normal desktop rectangle for one frame.
    [Win32]::ShowWindow($script:hwnd, [Win32]::SW_HIDE) | Out-Null
    # SetWindowPos alone does not change the restored bounds of a minimized
    # window, so restore it while hidden before moving it off-screen.
    [Win32]::ShowWindow($script:hwnd, [Win32]::SW_RESTORE) | Out-Null
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $offX = $screen.Left - $script:normalRect.Width - 20
    $offY = $screen.Top + 10
    Set-PhotosWindowStyle $true
    [Win32]::SetWindowPos($script:hwnd, [IntPtr]::Zero, $offX, $offY, $script:normalRect.Width, $script:normalRect.Height,
        [Win32]::SWP_NOZORDER -bor [Win32]::SWP_NOACTIVATE -bor [Win32]::SWP_SHOWWINDOW -bor [Win32]::SWP_FRAMECHANGED) | Out-Null
    [Win32]::ShowWindow($script:hwnd, [Win32]::SW_SHOWNOACTIVATE) | Out-Null
    $script:backgrounded = $true
}

function Show-PhotosWindow {
    if ($script:hwnd -eq [IntPtr]::Zero -or -not [Win32]::IsWindow($script:hwnd)) { return }
    if (-not $script:normalRect) { Capture-NormalWindowRect }
    Set-PhotosWindowStyle $false
    [Win32]::SetWindowPos($script:hwnd, [IntPtr]::Zero, $script:normalRect.X, $script:normalRect.Y, $script:normalRect.Width, $script:normalRect.Height,
        [Win32]::SWP_NOZORDER -bor [Win32]::SWP_NOACTIVATE -bor [Win32]::SWP_SHOWWINDOW -bor [Win32]::SWP_FRAMECHANGED) | Out-Null
    [Win32]::ShowWindow($script:hwnd, [Win32]::SW_RESTORE) | Out-Null
    [Win32]::SetForegroundWindow($script:hwnd) | Out-Null
    $script:backgrounded = $false
}

function Start-Photos {
    param([switch]$ShowWindow)
    if ($script:starting -or $script:exitRequested) { return }
    if ($ShowWindow) { $script:manualVisible = $true }
    if ($script:proc -and -not $script:proc.HasExited -and $script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindow($script:hwnd)) {
        if ($script:manualVisible) { Show-PhotosWindow } else { Set-PhotosBackground }
        return
    }

    $script:starting = $true
    try {
        $existing = Get-PhotosBrowser
        if ($existing) {
            $script:proc = $existing.Process
            $script:hwnd = $existing.Hwnd
            Capture-NormalWindowRect
            Write-StartupLog ("Using existing Chrome process pid={0}." -f $script:proc.Id)
        }
        else {
            $chromeArgs = @(
                "--app=$Url",
                "--user-data-dir=`"$UserDataDir`"",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding"
            )
            Write-StartupLog "Starting dedicated Chrome profile."
            Start-Process -FilePath $chrome -ArgumentList $chromeArgs -WindowStyle Minimized | Out-Null
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                $browser = Get-PhotosBrowser
                if ($browser) {
                    $script:proc = $browser.Process
                    $script:hwnd = $browser.Hwnd
                    break
                }
                Start-Sleep -Milliseconds 200
            }
            if (-not $script:proc) { throw "Google Chrome window did not appear within 20 seconds." }
            Capture-NormalWindowRect
            Write-StartupLog ("Chrome window attached pid={0}." -f $script:proc.Id)
        }
        if ($script:manualVisible) { Show-PhotosWindow } else { Set-PhotosBackground }
    }
    finally {
        $script:starting = $false
    }
}

function Stop-Photos {
    if ($script:proc -and -not $script:proc.HasExited) {
        try { $script:proc.Kill() } catch {}
    }
    $script:proc = $null
    $script:hwnd = [IntPtr]::Zero
    $script:normalRect = $null
    $script:backgrounded = $false
    $script:lastUiReadUtc = [DateTime]::MinValue
    $script:cachedUiNames = @()
    $script:lastAuthenticationCheckUtc = [DateTime]::MinValue
}

function Reload-PhotosBackground {
    if ($script:proc -and -not $script:proc.HasExited -and
        $script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindow($script:hwnd)) {
        Set-PhotosBackground
        $postedDown = [Win32]::PostMessage($script:hwnd, [Win32]::WM_KEYDOWN, [IntPtr][Win32]::VK_F5, [IntPtr]::Zero)
        $postedUp = [Win32]::PostMessage($script:hwnd, [Win32]::WM_KEYUP, [IntPtr][Win32]::VK_F5, [IntPtr]::Zero)
        $script:lastUiReadUtc = [DateTime]::MinValue
        $script:cachedUiNames = @()
        if ($postedDown -and $postedUp) {
            Write-StartupLog 'Reloading Google Photos in the background to retry pending media.'
        }
        else {
            Write-StartupLog 'WARN: Google Photos background reload request was not accepted.'
        }
        return
    }

    Write-StartupLog 'Google Photos window was unavailable; reopening it in the background for retry.'
    Start-Photos
}

function Ensure-SyncBrowser {
    if (-not $script:syncActive -or $script:exitRequested) { return }
    if ($script:proc -and -not $script:proc.HasExited -and $script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindow($script:hwnd)) {
        if ($script:manualVisible) {
            if ($script:backgrounded) { Show-PhotosWindow }
        }
        elseif (-not $script:backgrounded) {
            Set-PhotosBackground
        }
        return
    }
    if ($script:manualVisible) {
        $script:manualVisible = $false
        Write-StartupLog 'Google Photos window disappeared; treating it as Hide.'
    }
    $script:proc = $null
    $script:hwnd = [IntPtr]::Zero
    if ($script:authenticationRequired) {
        Write-StartupLog 'Google Photos sign-in is required; waiting for the user to press Show.'
        return
    }
    if ($script:syncFailureObserved) {
        if (-not $script:syncFailureBrowserExitLogWritten) {
            Write-StartupLog 'Failed sync Chrome was closed; waiting for a manual retry without restarting it.'
            $script:syncFailureBrowserExitLogWritten = $true
        }
        return
    }
    try {
        Write-StartupLog "Sync Chrome disappeared; restarting it off-screen."
        Start-Photos
    }
    catch {
        Write-StartupLog ("WARN: sync Chrome restart failed: " + $_.Exception.Message)
    }
}

function Start-MediaSync {
    if (-not $script:syncActive) {
        $script:syncActive = $true
        $script:syncStartedUtc = [DateTime]::UtcNow
        $script:lastMediaEventUtc = $script:syncStartedUtc
        $script:lastStatusCheckUtc = [DateTime]::MinValue
        $script:syncStatusSeenClear = $false
        $script:syncCompletionObserved = $false
        $script:syncCompletionUtc = [DateTime]::MinValue
        $script:syncFailureObserved = $false
        $script:syncFailureStatusSeenClear = $false
        $script:syncFailureRetryCount = 0
        $script:syncFailureNextRetryUtc = [DateTime]::MinValue
        $script:syncFailureNoticeShown = $false
        $script:syncFailureHoldNoticeWritten = $false
        $script:syncFailureBrowserExitLogWritten = $false
        $script:syncCompletionHoldNoticeWritten = $false
        $script:syncStatusLogWritten = $false
        if ($script:authenticationRequired) { $script:authenticationDetectedDuringSync = $true }
        Write-StartupLog "Media sync session started."
    }
    Ensure-SyncBrowser
}

function Get-PhotosUiNames {
    if (-not $script:uiAutomationAvailable -or $script:hwnd -eq [IntPtr]::Zero -or -not [Win32]::IsWindow($script:hwnd)) {
        return @()
    }
    $now = [DateTime]::UtcNow
    if (($now - $script:lastUiReadUtc).TotalMilliseconds -lt 750) {
        return @($script:cachedUiNames)
    }
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:hwnd)
        if (-not $root) { return @() }
        $all = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($element in $all) {
            try {
                $name = [string]$element.Current.Name
                if ($name -and -not $names.Contains($name)) {
                    $names.Add($name)
                }
            }
            catch {
                # 動的に消えたUI要素は無視する。
            }
        }
        $script:cachedUiNames = @($names)
        $script:lastUiReadUtc = $now
        return @($script:cachedUiNames)
    }
    catch {
        if (-not $script:uiAutomationWarningWritten) {
            Write-StartupLog ("WARN: Google Photos UI status read failed: " + $_.Exception.Message)
            $script:uiAutomationWarningWritten = $true
        }
        return @()
    }
}

function Get-PhotosStatusMessages {
    return @(Get-PhotosUiNames | Where-Object {
        $_ -match 'バックアップ|アップロード|同期|Backup|Upload|Sync'
    })
}

function Test-PhotosBackupFailureMessage {
    param([AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    $text = $Message.Trim()

    # UI Automation also exposes permanent help/navigation labels such as
    # "写真の作成と追加 - バックアップ エラー". Only accept complete,
    # user-facing failure statements so those labels cannot hold a sync open.
    return $text -match '^(?:\d+\s*個のアイテムを)?バックアップできませんでした[。.]?$|^バックアップ(?:に)?失敗しました[。.]?$|^(?:\d+\s*個のアイテムを)?アップロードできませんでした[。.]?$|^アップロード(?:に)?失敗しました[。.]?$|^(?:\d+\s+items?\s+)?(?:could not|couldn''t) be backed up[.!]?$|^Backup failed[.!]?$|^(?:\d+\s+items?\s+)?(?:could not|couldn''t) be uploaded[.!]?$|^Upload failed[.!]?$'
}

function Test-PhotosAuthenticationRequiredFromNames {
    param([string[]]$Names)
    foreach ($name in @($Names)) {
        foreach ($pattern in $script:authenticationPatterns) {
            if ($name -match $pattern) { return $true }
        }
    }
    return $false
}

function Test-PhotosAuthenticatedFromNames {
    param([string[]]$Names)
    $navigationMarkers = @{}
    foreach ($name in @($Names)) {
        if ($name -match 'Google アカウント[:：]|(?i)Google Account:') {
            return $true
        }
        if ($name -match '^(フォト|写真|思い出|アルバム|コレクション|作成|お気に入り|最近追加した写真|アーカイブ|検索|共有|Photos|Memories|Albums|Collections|Create|Favorites|Recently added|Archive|Search|Sharing)$') {
            $navigationMarkers[$name.ToLowerInvariant()] = $true
        }
    }
    return $navigationMarkers.Count -ge 2
}

function Save-PhotosAuthenticationState {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $authenticationStateFile) -Force | Out-Null
        [ordered]@{
            schemaVersion = 1
            authenticationRequired = $true
            detectedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $authenticationStateFile -Encoding UTF8
    }
    catch {
        Write-StartupLog ("WARN: authentication state could not be saved: " + $_.Exception.Message)
    }
}

function Clear-PhotosAuthenticationState {
    try {
        if (Test-Path -LiteralPath $authenticationStateFile) {
            Remove-Item -LiteralPath $authenticationStateFile -Force
        }
    }
    catch {
        Write-StartupLog ("WARN: authentication state could not be cleared: " + $_.Exception.Message)
    }
}

function Show-PhotosAuthenticationNotice {
    param([switch]$Recovered)
    if (-not $script:notifyIcon) { return }
    if ($Recovered) {
        $script:notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $script:notifyIcon.BalloonTipTitle = 'Google フォトのログインを確認しました'
        $script:notifyIcon.BalloonTipText = '専用Chromeで同期を再開します。'
    }
    else {
        $script:notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $script:notifyIcon.BalloonTipTitle = 'Google フォトへの再ログインが必要です'
        $script:notifyIcon.BalloonTipText = '画面を表示するにはトレイの「Show」を押してください。ログイン後、保留中の同期を再開します。'
    }
    $script:notifyIcon.ShowBalloonTip(15000)
}

function Show-PhotosBackupFailureNotice {
    if (-not $script:notifyIcon) { return }
    $script:notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
    $script:notifyIcon.BalloonTipTitle = 'Google フォトのバックアップに失敗しました'
    $script:notifyIcon.BalloonTipText = '未同期のファイルは完了扱いにせず保留しています。トレイの「今すぐ同期」で再試行できます。'
    $script:notifyIcon.ShowBalloonTip(15000)
}

function Set-PhotosAuthenticationRequired {
    param([bool]$Required)
    if ($Required) {
        $newlyDetected = -not $script:authenticationRequired
        $script:authenticationRequired = $true
        $script:authenticationClearChecks = 0
        if ($script:syncActive) { $script:authenticationDetectedDuringSync = $true }
        if ($newlyDetected) {
            $script:authenticationNoticeShown = $false
            Save-PhotosAuthenticationState
            Write-StartupLog 'Google Photos sign-in is required; keeping Chrome in the background until the user presses Show.'
        }
        if (-not $script:authenticationNoticeShown -and $script:notifyIcon) {
            Show-PhotosAuthenticationNotice
            $script:authenticationNoticeShown = $true
        }
        return
    }

    if (-not $script:authenticationRequired) { return }
    $resumeBackgroundSync = $script:syncActive -and $script:authenticationDetectedDuringSync
    $script:authenticationRequired = $false
    $script:authenticationClearChecks = 0
    $script:authenticationNoticeShown = $false
    $script:authenticationDetectedDuringSync = $false
    Clear-PhotosAuthenticationState
    Write-StartupLog 'Google Photos sign-in recovery detected.'
    Show-PhotosAuthenticationNotice -Recovered
    if ($resumeBackgroundSync) {
        $script:lastMediaEventUtc = [DateTime]::UtcNow
        if ($script:manualVisible) {
            Show-PhotosWindow
        }
        elseif ($script:proc -and -not $script:proc.HasExited -and $script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindow($script:hwnd)) {
            Set-PhotosBackground
        }
    }
}

function Update-PhotosAuthenticationState {
    if (-not $script:uiAutomationAvailable -or $script:hwnd -eq [IntPtr]::Zero -or -not [Win32]::IsWindow($script:hwnd)) {
        return
    }
    $now = [DateTime]::UtcNow
    if (($now - $script:lastAuthenticationCheckUtc).TotalSeconds -lt 2) { return }
    $script:lastAuthenticationCheckUtc = $now
    $names = @(Get-PhotosUiNames)
    if ($names.Count -eq 0) { return }

    if (Test-PhotosAuthenticationRequiredFromNames $names) {
        Set-PhotosAuthenticationRequired $true
        return
    }
    if ($script:authenticationRequired -and (Test-PhotosAuthenticatedFromNames $names)) {
        $script:authenticationClearChecks++
        if ($script:authenticationClearChecks -ge 3) {
            Set-PhotosAuthenticationRequired $false
        }
    }
    elseif ($script:authenticationRequired) {
        $script:authenticationClearChecks = 0
    }
}

function Test-PhotosSyncCompleted {
    if (-not $script:syncActive -or -not $script:uiAutomationAvailable) { return $false }
    $now = [DateTime]::UtcNow
    if (($now - $script:lastStatusCheckUtc).TotalSeconds -lt 2) {
        return $script:syncCompletionObserved
    }
    $script:lastStatusCheckUtc = $now
    $messages = @(Get-PhotosStatusMessages)
    $success = @($messages | Where-Object {
        $_ -match 'バックアップしました|バックアップが完了|アップロードしました|アップロードが完了|同期が完了|Backup\s+(complete|completed)|Upload(ed)?\s+(complete|successfully)|Sync\s+(complete|completed)'
    })
    $failure = @($messages | Where-Object { Test-PhotosBackupFailureMessage $_ })
    $eligible = ($now - $script:syncStartedUtc).TotalSeconds -ge 5

    if ($success.Count -eq 0) {
        $script:syncStatusSeenClear = $true
    }
    if ($failure.Count -eq 0) {
        $script:syncFailureStatusSeenClear = $true
    }
    if ($eligible -and $script:syncFailureStatusSeenClear -and $failure.Count -gt 0) {
        if (-not $script:syncFailureObserved) {
            $script:syncFailureNextRetryUtc = $now.AddSeconds($FailureRetrySeconds)
        }
        $script:syncFailureObserved = $true
        if (-not $script:syncStatusLogWritten) {
            Write-StartupLog ("WARN: Google Photos reported a backup failure: " + (($failure | Select-Object -Unique) -join " | "))
            $script:syncStatusLogWritten = $true
        }
        if (-not $script:syncFailureNoticeShown) {
            Show-PhotosBackupFailureNotice
            $script:syncFailureNoticeShown = $true
        }
    }

    if ($eligible -and $script:syncStatusSeenClear -and -not $script:syncFailureObserved -and $success.Count -gt 0) {
        if (-not $script:syncCompletionObserved) {
            $script:syncCompletionObserved = $true
            $script:syncCompletionUtc = $now
            Write-StartupLog ("Google Photos backup completion detected: " + (($success | Select-Object -Unique) -join " | "))
        }
    }
    return $script:syncCompletionObserved
}

function Stop-MediaSync {
    if (-not $script:syncActive) { return }
    if ($script:authenticationRequired) {
        Write-StartupLog 'Media sync remains pending until Google Photos sign-in is restored.'
        return
    }
    if ($script:syncFailureObserved) {
        if (-not $script:syncFailureHoldNoticeWritten) {
            Write-StartupLog 'Media sync remains pending after a Google Photos backup failure; Chrome stays open for review or manual retry.'
            $script:syncFailureHoldNoticeWritten = $true
        }
        Set-PhotosBackground
        return
    }
    if (-not $script:syncCompletionObserved) {
        if (-not $script:syncCompletionHoldNoticeWritten) {
            Write-StartupLog 'Media sync remains pending because Google Photos has not confirmed completion; no files were marked as synced.'
            $script:syncCompletionHoldNoticeWritten = $true
        }
        Set-PhotosBackground
        return
    }
    foreach ($path in @($script:pendingSync.Keys)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { $script:mediaState[$path] = $script:pendingSync[$path] } catch {}
        }
    }
    $script:pendingSync.Clear()
    Save-MediaState
    if ($script:syncCompletionObserved) {
        Write-StartupLog "Google Photos backup complete; stopping Chrome."
    }
    else {
        Write-StartupLog "Media sync session quiet; stopping Chrome."
    }
    $script:syncActive = $false
    $script:syncStartedUtc = [DateTime]::MinValue
    $script:lastStatusCheckUtc = [DateTime]::MinValue
    $script:syncStatusSeenClear = $false
    $script:syncCompletionObserved = $false
    $script:syncCompletionUtc = [DateTime]::MinValue
    $script:syncFailureObserved = $false
    $script:syncFailureStatusSeenClear = $false
    $script:syncFailureNoticeShown = $false
    $script:syncFailureHoldNoticeWritten = $false
    $script:syncFailureBrowserExitLogWritten = $false
    $script:syncFailureRetryCount = 0
    $script:syncFailureNextRetryUtc = [DateTime]::MinValue
    $script:syncCompletionHoldNoticeWritten = $false
    $script:syncStatusLogWritten = $false
    $script:authenticationDetectedDuringSync = $false
    Stop-Photos
}

function Invoke-MainTick {
    foreach ($watcher in $script:watchers) {
        if ($watcher.ConsumeErrorRequest()) { $script:rescanRequested = $true }
    }
    Process-WatchQueue
    if ($script:rescanRequested -or ([DateTime]::UtcNow - $script:lastRescanUtc).TotalSeconds -ge $RescanIntervalSeconds) {
        $script:rescanRequested = $false
        Invoke-MediaRescan
    }

    if ($script:pendingSync.Count -gt 0) { Start-MediaSync }
    if ($script:syncActive) {
        Ensure-SyncBrowser
    }
    Update-PhotosAuthenticationState
    if ($script:authenticationRequired) { return }
    if ($script:syncActive) {
        $now = [DateTime]::UtcNow
        if (-not $script:syncCompletionObserved -and
            ($script:syncFailureObserved -or $script:syncFailureRetryCount -gt 0) -and
            $script:syncFailureRetryCount -lt $MaxFailureRetries -and
            $now -ge $script:syncFailureNextRetryUtc) {
            $script:syncFailureRetryCount++
            $delay = [int][Math]::Min(3600, $FailureRetrySeconds * [Math]::Pow(2, $script:syncFailureRetryCount))
            $script:syncFailureNextRetryUtc = $now.AddSeconds($delay)
            $script:syncFailureObserved = $false
            $script:syncFailureStatusSeenClear = $false
            $script:syncStatusSeenClear = $false
            $script:syncCompletionObserved = $false
            $script:syncCompletionUtc = [DateTime]::MinValue
            $script:syncCompletionHoldNoticeWritten = $false
            $script:syncStatusLogWritten = $false
            $script:lastStatusCheckUtc = [DateTime]::MinValue
            $script:lastUiReadUtc = [DateTime]::MinValue
            $script:cachedUiNames = @()
            Write-StartupLog ("Retrying Google Photos backup in the background (attempt {0}/{1})." -f $script:syncFailureRetryCount, $MaxFailureRetries)
            Reload-PhotosBackground
        }
        $completionDetected = Test-PhotosSyncCompleted
        if ($completionDetected -and
            ([DateTime]::UtcNow - $script:lastMediaEventUtc).TotalSeconds -ge 3 -and
            ([DateTime]::UtcNow - $script:syncCompletionUtc).TotalSeconds -ge 3) {
            Stop-MediaSync
            return
        }
        if (([DateTime]::UtcNow - $script:lastMediaEventUtc).TotalSeconds -ge $SyncQuietSeconds) {
            if ($script:syncCompletionObserved -or $script:syncFailureObserved) {
                Stop-MediaSync
            }
            elseif (-not $script:syncCompletionHoldNoticeWritten) {
                Write-StartupLog 'Media sync is quiet but completion was not confirmed; keeping pending files and Chrome in the background.'
                $script:syncCompletionHoldNoticeWritten = $true
            }
        }
    }
}

function Hide-PhotosWindow {
    $script:manualVisible = $false
    if ($script:proc -and -not $script:proc.HasExited -and $script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindow($script:hwnd)) {
        if ($script:syncActive) {
            Set-PhotosBackground
        }
        else {
            Stop-Photos
        }
    }
    Write-StartupLog 'Manual Chrome display cleared by Hide.'
}

function Toggle-Photos {
    $hasBrowser = $script:proc -and -not $script:proc.HasExited -and $script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindow($script:hwnd)
    if (-not $hasBrowser) {
        $script:manualVisible = $true
        Start-Photos -ShowWindow
        return
    }
    if ($script:manualVisible) {
        Hide-PhotosWindow
        return
    }
    $script:manualVisible = $true
    Show-PhotosWindow
    Write-StartupLog 'Manual Chrome display enabled by Show.'
}

function Reopen-Photos {
    $script:manualVisible = $true
    Stop-Photos
    Start-Photos -ShowWindow
}

function Request-MediaSync {
    if ($script:syncActive -and $script:syncFailureObserved) {
        $script:syncStartedUtc = [DateTime]::UtcNow
        $script:lastMediaEventUtc = $script:syncStartedUtc
        $script:lastStatusCheckUtc = [DateTime]::MinValue
        $script:syncStatusSeenClear = $false
        $script:syncCompletionObserved = $false
        $script:syncCompletionUtc = [DateTime]::MinValue
        $script:syncFailureObserved = $false
        $script:syncFailureStatusSeenClear = $false
        $script:syncFailureRetryCount = 0
        $script:syncFailureNextRetryUtc = [DateTime]::MinValue
        $script:syncFailureNoticeShown = $false
        $script:syncFailureHoldNoticeWritten = $false
        $script:syncFailureBrowserExitLogWritten = $false
        $script:syncCompletionHoldNoticeWritten = $false
        $script:syncStatusLogWritten = $false
        Write-StartupLog 'Manual media sync retry requested after the previous backup failure.'
        if ($script:manualVisible -and $script:hwnd -ne [IntPtr]::Zero -and [Win32]::IsWindow($script:hwnd)) {
            Show-PhotosWindow
        }
    }
    else {
        $script:lastMediaEventUtc = [DateTime]::UtcNow
    }
    Start-MediaSync
}

# --- 起動時の監視準備 ---
Load-MediaState
Initialize-MediaWatchers
Invoke-MediaRescan
if ($script:watchRoots.Count -eq 0) {
    Write-StartupLog "WARN: no Pictures or Videos root exists to watch."
}

$firstRun = -not (Test-Path -LiteralPath $UserDataDir)
if ($firstRun -or $OpenNow) {
    Start-Photos -ShowWindow
}
else {
    Write-StartupLog "Idle mode: Chrome is not started until a media change is detected."
}

# --- トレイアイコン ---
try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($chrome) }
catch { $icon = [System.Drawing.SystemIcons]::Application }

$ni = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon = $ni
$ni.Icon = $icon
$ni.Text = "Google Photos"
$ni.Visible = $true
Write-StartupLog "Tray icon is visible."

if ($firstRun) {
    $ni.BalloonTipTitle = "Google Photos tray started"
    $ni.BalloonTipText = "Sign in in the window that opened, then enable Google Photos folder backup. The tray will wake Google Photos only when media changes."
    $ni.ShowBalloonTip(15000)
}
elseif ($script:authenticationRequired) {
    Show-PhotosAuthenticationNotice
    $script:authenticationNoticeShown = $true
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miToggle = $menu.Items.Add("Show / Hide")
$miReopen = $menu.Items.Add("Reopen")
$miSync = $menu.Items.Add("Sync now")
$miExit = $menu.Items.Add("Exit")
$ni.ContextMenuStrip = $menu
$ni.add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Photos } })
$miToggle.add_Click({ Toggle-Photos })
$miReopen.add_Click({ Reopen-Photos })
$miSync.add_Click({ Request-MediaSync; Write-StartupLog "Manual sync requested." })
$miExit.add_Click({
    Write-StartupLog "Exit requested from tray menu."
    $script:exitRequested = $true
    $ni.Visible = $false
    Dispose-MediaWatchers
    Stop-Photos
    [System.Windows.Forms.Application]::Exit()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({ Invoke-MainTick })
$timer.Start()
Write-StartupLog ("Media watcher started roots={0} quiet={1}s rescan={2}s." -f ($script:watchRoots -join ","), $SyncQuietSeconds, $RescanIntervalSeconds)

[System.Windows.Forms.Application]::Run()
$timer.Stop()
Dispose-MediaWatchers
Stop-Photos
$ni.Visible = $false
$script:notifyIcon = $null
Write-StartupLog "Tray host stopped."
try { $mutex.ReleaseMutex() } catch {}
