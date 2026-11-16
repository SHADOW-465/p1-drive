# Dev helper: run gates, tick the task in PROGRESS.md, commit. Usage: tools\done.ps1 T02 "note" "summary"
param([string]$id, [string]$note, [string]$msg)
$out = cmd /c tools\run_gates.bat
if ($LASTEXITCODE -ne 0) {
	$out
	Select-String -Path logs\*.log -Pattern 'ERROR|WARNING|FAIL|Parse Error' | Select-Object -First 20 | ForEach-Object { $_.Filename + ': ' + $_.Line }
	exit 1
}
$p = Join-Path $PSScriptRoot '..\docs\PROGRESS.md'
$t = [IO.File]::ReadAllText($p)
$t = $t -replace "- \[ \] $id ([^\r\n]*)", "- [x] $id `$1 — $note"
[IO.File]::WriteAllText($p, $t)
git add -A
git commit -qm "${id}: $msg`n`nCo-Authored-By: Claude <noreply@anthropic.com>"
git log --oneline -1
