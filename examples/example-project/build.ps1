# build.ps1 - runnable clean example: validate this spec, then generate the project.
#
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
#
# Creates a throwaway TIA project under .\_out\ExampleMachine (gitignored) from the
# manifest + CSV data + SCL in this folder, compiles it, and reports. Requires a
# working Openness setup (see the repo README / CLAUDE.md). Nothing here is committed
# except the spec itself; the generated project and snapshots are ignored by git.
[CmdletBinding()]
param([switch]$ShowUI)
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here '..\..\src\TiaOpenness\TiaOpenness.psd1'
Import-Module $engine -Force

Write-Host "== Validating spec (offline) ==" -ForegroundColor Cyan
$v = Test-TiaSpec -Path (Join-Path $here 'project.yaml')
$v.Errors   | ForEach-Object { Write-Warning $_ }
$v.Warnings | ForEach-Object { Write-Host "  (warn) $_" -ForegroundColor DarkYellow }
if (-not $v.Ok) { throw "Spec validation failed ($($v.Summary)). Fix the errors above and re-run." }
Write-Host "Spec OK ($($v.Summary))." -ForegroundColor Green

Write-Host "`n== Generating project ==" -ForegroundColor Cyan
$r = Invoke-TiaBuildFromSpec -Path (Join-Path $here 'project.yaml')

Write-Host "`n== Result ==" -ForegroundColor Cyan
Write-Host ("Build Ok = {0}" -f $r.Ok) -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
if ($r.Errors) { Write-Host "Errors:"; $r.Errors | ForEach-Object { Write-Warning $_ } }
Write-Host "Project generated under: $(Join-Path $here '_out\ExampleMachine')  (gitignored)"
