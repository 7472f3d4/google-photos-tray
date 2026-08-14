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

function Get-FunctionText {
    param([string]$Name)
    $node = $ast.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq $Name
    }, $true)
    if (-not $node) { throw "Function was not found: $Name" }
    return $node.Extent.Text
}

$requiredText = (Get-FunctionText 'Set-PhotosAuthenticationRequired')
$requiredDetectionText = $requiredText.Substring(0, $requiredText.IndexOf("if (-not `$script:authenticationRequired)"))
$startText = (Get-FunctionText 'Start-Photos')
$ensureText = (Get-FunctionText 'Ensure-SyncBrowser')
$toggleText = (Get-FunctionText 'Toggle-Photos')
$hideText = (Get-FunctionText 'Hide-PhotosWindow')
$reopenText = (Get-FunctionText 'Reopen-Photos')

if ($requiredDetectionText -match 'Show-PhotosWindow') {
    throw 'Authentication detection must not show Chrome automatically.'
}
if ($requiredText -notmatch 'Show-PhotosAuthenticationNotice') {
    throw 'Authentication detection must keep the tray notification.'
}
if ($startText -notmatch '\$script:manualVisible') {
    throw 'Start-Photos must honor the manual display latch.'
}
if ($ensureText -notmatch 'treating it as Hide') {
    throw 'A closed visible window must be treated as Hide.'
}
if ($toggleText -notmatch '\$script:manualVisible') {
    throw 'Toggle-Photos must update the manual display latch.'
}
if ($hideText -notmatch '\$script:manualVisible\s*=\s*\$false') {
    throw 'Hide-PhotosWindow must clear the manual display latch.'
}
if ($reopenText -notmatch '\$script:manualVisible\s*=\s*\$true') {
    throw 'Reopen-Photos must enable the manual display latch.'
}

Write-Host 'PASS: display state tests.'
