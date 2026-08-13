# Main-only push policy installer for Codex and other Git clients.
[CmdletBinding()]
param(
    [string]$Remote = "origin"
)

$ErrorActionPreference = "Stop"
$root = (git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
    throw "Run this script from inside a Git worktree."
}
$gitDir = (git rev-parse --git-dir).Trim()
if (-not [IO.Path]::IsPathRooted($gitDir)) {
    $gitDir = Join-Path $root $gitDir
}
$hooksDir = Join-Path $gitDir "hooks"
New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
$policy = Join-Path $root "codex/pre-push-main-only.sh"
if (-not (Test-Path -LiteralPath $policy)) {
    throw "Policy file not found: $policy"
}
$hook = Join-Path $hooksDir "pre-push"
$previous = Join-Path $hooksDir "pre-push.previous"
if ((Test-Path -LiteralPath $hook) -and -not (Test-Path -LiteralPath $previous)) {
    $existing = Get-Content -LiteralPath $hook -Raw
    if ($existing -notmatch "CODEX_MAIN_ONLY_PUSH_POLICY") {
        Copy-Item -LiteralPath $hook -Destination $previous
    }
}
$wrapper = @'
#!/bin/sh
# CODEX_MAIN_ONLY_PUSH_POLICY
set -eu
repo_root="$(git rev-parse --show-toplevel)"
policy="$repo_root/codex/pre-push-main-only.sh"
if [ ! -f "$policy" ]; then
  echo "main-only push policy is missing: $policy" >&2
  exit 1
fi
 "$policy" "$@"
status=$?
if [ "$status" -ne 0 ]; then
  exit "$status"
fi
previous="$0.previous"
if [ -x "$previous" ]; then
  "$previous" "$@"
fi
exit 0
'@
[IO.File]::WriteAllText(
    $hook,
    $wrapper,
    [Text.UTF8Encoding]::new($false)
)
git config --local --replace-all "remote.$Remote.push" "HEAD:refs/heads/main"
git config --local "branch.main.remote" $Remote
git config --local "branch.main.merge" "refs/heads/main"
Write-Output "Installed main-only push policy for $Remote in $root"
