# install_startup.ps1 — Windows ログイン時に Google フォトのトレイ常駐を自動起動する
# タスクスケジューラへ、ログイン後に遅延起動・再試行するタスクを登録する。
#   実行:  pwsh -NoProfile -File .\install_startup.ps1
#   解除:  上記に  -Uninstall  を付けて実行
#Requires -PSEdition Core
param([switch]$Uninstall)

$ErrorActionPreference = "Stop"

function Get-PowerShellCandidate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$LaunchPath = $Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ($Path -match '(?i)\\(?:preview|pre-release|nightly)(?:\\|$)') { return $null }
    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $file) { return $null }
    $version = $file.VersionInfo.FileVersionRaw
    if (-not $version -or $version.Major -lt 7) { return $null }
    [pscustomobject]@{
        FullName = $LaunchPath
        Path = $Path
        Version = $version
    }
}

function Get-LatestPowerShellPath {
    $candidates = New-Object System.Collections.Generic.List[object]
    $installationRoots = @(
        (Join-Path $env:ProgramFiles 'PowerShell'),
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell')
    )
    foreach ($root in $installationRoots) {
        if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -Filter pwsh.exe -File -ErrorAction SilentlyContinue)) {
                $candidate = Get-PowerShellCandidate -Path $file.FullName
                if ($candidate) { $candidates.Add($candidate) }
            }
        }
    }
    foreach ($command in @(Get-Command pwsh.exe -All -ErrorAction SilentlyContinue)) {
        if ($command.Source -and
            $command.Source -notmatch '(?i)\\WindowsApps\\' -and
            (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            $candidate = Get-PowerShellCandidate -Path $command.Source
            if ($candidate) { $candidates.Add($candidate) }
        }
    }

    # Microsoft Store / MSIX installations live below WindowsApps and expose a
    # stable per-user alias. Resolve the package path for version comparison,
    # but launch through the alias so package updates remain automatic.
    foreach ($package in @(Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue | Sort-Object Version -Descending)) {
        $packagePwsh = Join-Path $package.InstallLocation 'pwsh.exe'
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
        $launchPath = if (Test-Path -LiteralPath $alias -PathType Leaf) { $alias } else { $packagePwsh }
        $candidate = Get-PowerShellCandidate -Path $packagePwsh -LaunchPath $launchPath
        if ($candidate) { $candidates.Add($candidate) }
    }

    $latest = $candidates |
        Sort-Object Path -Unique |
        Sort-Object Version, Path -Descending |
        Select-Object -First 1
    if (-not $latest) {
        throw 'A supported stable PowerShell Core (pwsh.exe) was not found. Install the latest stable PowerShell first.'
    }
    return $latest
}

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$photos     = Join-Path $scriptDir "photos_tray.ps1"
$taskName   = "Google Photos Tray"
$startup    = [Environment]::GetFolderPath("Startup")
$lnk        = Join-Path $startup "Google Photos Tray.lnk"

if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "removed scheduled task: $taskName"
    }
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "removed legacy shortcut: $lnk"
    }
    if (-not $task -and -not (Test-Path -LiteralPath $lnk)) {
        Write-Host "not installed (nothing to remove)."
    }
    return
}

if (-not (Test-Path -LiteralPath $photos)) { throw "not found: $photos" }
$pwsh = Get-LatestPowerShellPath

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = "-NoProfile -STA -WindowStyle Hidden -File `"$photos`" -StartupDelaySeconds 25"
$action = New-ScheduledTaskAction -Execute $pwsh.FullName -Argument $arguments -WorkingDirectory $scriptDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    throw "scheduled task registration failed: $taskName"
}

# 旧方式のショートカットが残っている場合は、タスク登録成功後にだけ削除する。
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }

Write-Host "installed scheduled task: $taskName"
Write-Host ("-> PowerShell host: {0} ({1})" -f $pwsh.FullName, $pwsh.Version)
Write-Host "-> Starts 25 seconds after Windows logon and retries up to 3 times if startup fails."
Write-Host "-> To try it now, run photos_tray_hidden.vbs."
