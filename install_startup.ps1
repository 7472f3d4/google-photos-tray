# install_startup.ps1 — Windows ログイン時に Google フォトのトレイ常駐を自動起動する
# タスクスケジューラへ、ログイン後に遅延起動・再試行するタスクを登録する。
#   実行:  pwsh -NoProfile -File .\install_startup.ps1
#   解除:  上記に  -Uninstall  を付けて実行
#Requires -Version 7.0
param([switch]$Uninstall)

$ErrorActionPreference = "Stop"

function Get-LatestPowerShellPath {
    $candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $installationRoots = @(
        (Join-Path $env:ProgramFiles 'PowerShell'),
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell')
    )
    foreach ($root in $installationRoots) {
        if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -Filter pwsh.exe -File -ErrorAction SilentlyContinue)) {
                $candidates.Add($file)
            }
        }
    }
    foreach ($command in @(Get-Command pwsh.exe -All -ErrorAction SilentlyContinue)) {
        if ($command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            $candidates.Add((Get-Item -LiteralPath $command.Source))
        }
    }
    $latest = $candidates |
        Sort-Object FullName -Unique |
        Sort-Object { $_.VersionInfo.FileVersionRaw } -Descending |
        Select-Object -First 1
    if (-not $latest -or $latest.VersionInfo.FileVersionRaw.Major -lt 7) {
        throw 'PowerShell 7 (pwsh.exe) was not found. Install the latest PowerShell first.'
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
Write-Host ("-> PowerShell host: {0} ({1})" -f $pwsh.FullName, $pwsh.VersionInfo.FileVersion)
Write-Host "-> Starts 25 seconds after Windows logon and retries up to 3 times if startup fails."
Write-Host "-> To try it now, run photos_tray_hidden.vbs."
