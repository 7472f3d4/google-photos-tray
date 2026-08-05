# install_startup.ps1 — Windows ログイン時に Google フォトのトレイ常駐を自動起動する
# タスクスケジューラへ、ログイン後に遅延起動・再試行するタスクを登録する。
#   実行:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_startup.ps1
#   解除:  上記に  -Uninstall  を付けて実行
param([switch]$Uninstall)

$ErrorActionPreference = "Stop"

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$photos     = Join-Path $scriptDir "photos_tray.ps1"
$startupVbs = Join-Path $scriptDir "photos_tray_startup_hidden.vbs"
$taskName   = "Google Photos Tray"
$wscript    = Join-Path $env:SystemRoot "System32\wscript.exe"
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
if (-not (Test-Path -LiteralPath $startupVbs)) { throw "not found: $startupVbs" }

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = "`"$startupVbs`""
$action = New-ScheduledTaskAction -Execute $wscript -Argument $arguments -WorkingDirectory $scriptDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 24)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    throw "scheduled task registration failed: $taskName"
}

# 旧方式のショートカットが残っている場合は、タスク登録成功後にだけ削除する。
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }

Write-Host "installed scheduled task: $taskName"
Write-Host "-> Starts 25 seconds after Windows logon and retries up to 3 times if startup fails."
Write-Host "-> To try it now, run photos_tray_hidden.vbs."
