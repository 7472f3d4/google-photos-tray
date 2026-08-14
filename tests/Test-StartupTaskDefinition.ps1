#Requires -PSEdition Core
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoRoot 'install_startup.ps1'
$launcherPath = Join-Path $repoRoot 'photos_tray_startup_hidden.vbs'

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath,
    [ref]$tokens,
    [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | ForEach-Object Message | Out-String)
}

function Get-AssignmentText {
    param([Parameter(Mandatory)][string]$Variable)

    $assignment = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq $Variable
    }, $true)
    if (-not $assignment) { throw "Assignment was not found: $Variable" }
    return $assignment.Extent.Text
}

$argumentsText = Get-AssignmentText '$arguments'
$actionText = Get-AssignmentText '$action'
$launcherText = Get-Content -LiteralPath $launcherPath -Raw

if ($actionText -notmatch 'New-ScheduledTaskAction\s+-Execute\s+\$wscript') {
    throw 'The scheduled task must execute wscript.exe through $wscript.'
}
if ($actionText -match '-Execute\s+\$pwsh\.FullName') {
    throw 'The scheduled task must not execute pwsh.exe directly.'
}
if ($argumentsText -notmatch '\$startupVbs' -or $argumentsText -notmatch '\$\(\$pwsh\.FullName\)') {
    throw 'The task arguments must pass the hidden launcher and selected PowerShell path.'
}
if ($launcherText -notmatch 'If WScript\.Arguments\.Count > 0 Then' -or
    $launcherText -notmatch 'pwsh = WScript\.Arguments\(0\)') {
    throw 'The hidden launcher must prefer the PowerShell path selected by the installer.'
}
if ($launcherText -notmatch 'exitCode = sh\.Run\(command, 0, True\)' -or
    $launcherText -notmatch 'WScript\.Quit exitCode') {
    throw 'The hidden launcher must run invisibly, wait, and propagate the exit code.'
}

Write-Host 'PASS: startup task uses the hidden VBS launcher.'
