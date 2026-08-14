#Requires -Version 7.0
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

$patternAssignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$script:authenticationPatterns'
}, $true)
if (-not $patternAssignment) { throw 'Authentication patterns were not found.' }
$script:authenticationPatterns = @(& ([scriptblock]::Create($patternAssignment.Right.Extent.Text)))

foreach ($functionName in @(
    'Test-PhotosAuthenticationRequiredFromNames',
    'Test-PhotosAuthenticatedFromNames'
)) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if (-not $functionAst) { throw "Function was not found: $functionName" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$japaneseSignIn = -join @([char]0x30ED, [char]0x30B0, [char]0x30A4, [char]0x30F3)
$japanesePhotos = -join @([char]0x30D5, [char]0x30A9, [char]0x30C8)
$japaneseMemories = -join @([char]0x601D, [char]0x3044, [char]0x51FA)
$japaneseAlbums = -join @([char]0x30A2, [char]0x30EB, [char]0x30D0, [char]0x30E0)

$tests = @(
    [pscustomobject]@{ Name = 'Japanese sign-in'; Actual = (Test-PhotosAuthenticationRequiredFromNames @($japaneseSignIn)); Expected = $true },
    [pscustomobject]@{ Name = 'English sign-in title'; Actual = (Test-PhotosAuthenticationRequiredFromNames @('Sign in - Google Accounts')); Expected = $true },
    [pscustomobject]@{ Name = 'Japanese signed-in navigation'; Actual = (Test-PhotosAuthenticatedFromNames @($japanesePhotos, $japaneseMemories, $japaneseAlbums)); Expected = $true },
    [pscustomobject]@{ Name = 'Signed-in account menu'; Actual = (Test-PhotosAuthenticatedFromNames @('Google Account: signed-in user')); Expected = $true },
    [pscustomobject]@{ Name = 'Backup status is not sign-in'; Actual = (Test-PhotosAuthenticationRequiredFromNames @('Backup completed', 'Google Photos')); Expected = $false }
)

$failed = @($tests | Where-Object { $_.Actual -ne $_.Expected })
$tests | Format-Table Name, Actual, Expected, @{ Label = 'Pass'; Expression = { $_.Actual -eq $_.Expected } }
if ($failed.Count -gt 0) { throw "$($failed.Count) authentication detection test(s) failed." }
Write-Host 'PASS: authentication detection tests.'
