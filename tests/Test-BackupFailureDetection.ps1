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

$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-PhotosBackupFailureMessage'
}, $true)
if (-not $functionAst) { throw 'Test-PhotosBackupFailureMessage was not found.' }
. ([scriptblock]::Create($functionAst.Extent.Text))

$tests = @(
    [pscustomobject]@{ Name = 'Permanent help label is ignored'; Text = '写真の作成と追加 - バックアップ エラー'; Expected = $false },
    [pscustomobject]@{ Name = 'Japanese item failure is detected'; Text = '1 個のアイテムをバックアップできませんでした。'; Expected = $true },
    [pscustomobject]@{ Name = 'Japanese generic failure is detected'; Text = 'バックアップに失敗しました。'; Expected = $true },
    [pscustomobject]@{ Name = 'English upload failure is detected'; Text = '2 items could not be uploaded.'; Expected = $true },
    [pscustomobject]@{ Name = 'Progress text is ignored'; Text = 'バックアップしています'; Expected = $false }
)

$failed = @($tests | Where-Object {
    (Test-PhotosBackupFailureMessage $_.Text) -ne $_.Expected
})
$tests | Format-Table Name, Text, Expected, @{ Label = 'Actual'; Expression = { Test-PhotosBackupFailureMessage $_.Text } }
if ($failed.Count -gt 0) { throw "$($failed.Count) backup failure detection test(s) failed." }
Write-Host 'PASS: backup failure detection tests.'
