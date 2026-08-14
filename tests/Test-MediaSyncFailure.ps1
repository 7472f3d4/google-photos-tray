#Requires -PSEdition Core
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'photos_tray.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | ForEach-Object Message | Out-String)
}

foreach ($functionName in @(
    'Test-PhotosBackupFailureMessage',
    'Ensure-SyncBrowser',
    'Stop-MediaSync'
)) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if (-not $functionAst) { throw "$functionName was not found." }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$detectionTests = @(
    [pscustomobject]@{ Name = 'Permanent Japanese help label'; Message = '写真の作成と追加 - バックアップ エラー'; Expected = $false },
    [pscustomobject]@{ Name = 'Permanent English help label'; Message = 'Create and add photos - Backup errors'; Expected = $false },
    [pscustomobject]@{ Name = 'Japanese item failure'; Message = '1 個のアイテムをバックアップできませんでした。'; Expected = $true },
    [pscustomobject]@{ Name = 'Japanese upload failure'; Message = 'アップロードに失敗しました。'; Expected = $true },
    [pscustomobject]@{ Name = 'English backup failure'; Message = 'Backup failed.'; Expected = $true },
    [pscustomobject]@{ Name = 'Successful status'; Message = 'バックアップしました'; Expected = $false }
)
$detectionFailures = @($detectionTests | Where-Object {
    (Test-PhotosBackupFailureMessage $_.Message) -ne $_.Expected
})
if ($detectionFailures.Count -gt 0) {
    $detectionFailures | Format-Table Name, Message, Expected
    throw "$($detectionFailures.Count) backup failure detection test(s) failed."
}

$messages = New-Object System.Collections.Generic.List[string]
$savedCount = 0
$shownCount = 0
$stoppedCount = 0
$startedCount = 0
function Write-StartupLog { param([string]$Message) $messages.Add($Message) }
function Save-MediaState { $script:savedCount++ }
function Show-PhotosWindow { $script:shownCount++ }
function Stop-Photos { $script:stoppedCount++ }
function Start-Photos { $script:startedCount++ }

$script:syncActive = $true
$script:exitRequested = $false
$script:proc = $null
$script:hwnd = [IntPtr]::Zero
$script:syncFailureObserved = $true
$script:syncFailureBrowserExitLogWritten = $false
Ensure-SyncBrowser
if ($startedCount -ne 0) { throw 'Chrome restarted after a failed sync was closed.' }

$script:syncFailureObserved = $false
Ensure-SyncBrowser
if ($startedCount -ne 1) { throw 'Chrome did not restart for an active sync without a failure.' }

$tempFile = [IO.Path]::GetTempFileName()
try {
    $script:syncActive = $true
    $script:authenticationRequired = $false
    $script:syncFailureObserved = $true
    $script:syncFailureHoldNoticeWritten = $false
    $script:pendingSync = @{ $tempFile = 'pending-fingerprint' }
    $script:mediaState = @{}
    $script:syncCompletionObserved = $false
    Stop-MediaSync

    if (-not $script:syncActive) { throw 'A failed sync was stopped.' }
    if (-not $script:pendingSync.ContainsKey($tempFile)) { throw 'A failed item was removed from pending state.' }
    if ($script:mediaState.ContainsKey($tempFile)) { throw 'A failed item was marked as synced.' }
    if ($savedCount -ne 0) { throw 'Media state was saved after a failed sync.' }
    if ($stoppedCount -ne 0) { throw 'Chrome was stopped after a failed sync.' }

    $script:syncFailureObserved = $false
    $script:syncCompletionObserved = $true
    Stop-MediaSync
    if ($script:syncActive) { throw 'A successful sync was not stopped.' }
    if (-not $script:mediaState.ContainsKey($tempFile)) { throw 'A successful item was not committed.' }
    if ($savedCount -ne 1) { throw 'Media state was not saved exactly once after success.' }
    if ($stoppedCount -ne 1) { throw 'Chrome was not stopped exactly once after success.' }
}
finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: media sync failure handling tests.'
