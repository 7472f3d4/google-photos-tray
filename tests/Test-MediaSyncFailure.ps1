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

$stopAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Stop-MediaSync'
}, $true)
if (-not $stopAst) { throw 'Stop-MediaSync was not found.' }

$messages = New-Object System.Collections.Generic.List[string]
$savedCount = 0
$shownCount = 0
$backgroundCount = 0
$stoppedCount = 0
function Write-StartupLog { param([string]$Message) $messages.Add($Message) }
function Save-MediaState { $script:savedCount++ }
function Show-PhotosWindow { $script:shownCount++ }
function Set-PhotosBackground { $script:backgroundCount++ }
function Stop-Photos { $script:stoppedCount++ }
. ([scriptblock]::Create($stopAst.Extent.Text))

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
    if ($shownCount -ne 0) { throw 'Chrome was shown after a failed sync.' }
    if ($backgroundCount -ne 1) { throw 'Failed sync was not kept in the background.' }

    $script:syncFailureObserved = $false
    $script:syncCompletionObserved = $false
    $script:syncCompletionHoldNoticeWritten = $false
    $script:pendingSync = @{ $tempFile = 'pending-fingerprint' }
    Stop-MediaSync
    if (-not $script:syncActive) { throw 'A sync without confirmation was stopped.' }
    if (-not $script:pendingSync.ContainsKey($tempFile)) { throw 'An unconfirmed item was removed from pending state.' }
    if ($script:mediaState.ContainsKey($tempFile)) { throw 'An unconfirmed item was marked as synced.' }
    if ($savedCount -ne 0) { throw 'Media state was saved without completion confirmation.' }
    if ($stoppedCount -ne 0) { throw 'Chrome was stopped without completion confirmation.' }

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
