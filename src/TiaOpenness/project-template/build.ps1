# {{MachineName}} - validate then generate the TIA project from this spec.
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
# Needs Windows PowerShell 5.1 + TIA Portal with Openness (see the engine's CLAUDE.md).
[CmdletBinding()]
param([switch]$KeepOpen)   # by default we dispose our headless instance so the .apXX unlocks
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'engine\src\TiaOpenness\TiaOpenness.psd1'
if (-not (Test-Path $engine)) { throw "Engine submodule missing. Run: git submodule update --init --recursive" }
Import-Module $engine -Force

Write-Host "== Validate spec (offline) ==" -ForegroundColor Cyan
$v = Test-TiaSpec -Path (Join-Path $here 'project.yaml')
$v.Warnings | ForEach-Object { Write-Host "  (warn) $_" -ForegroundColor DarkYellow }
if (-not $v.Ok) { $v.Errors | ForEach-Object { Write-Warning $_ }; throw "Spec invalid ($($v.Summary))." }
Write-Host "Spec OK ($($v.Summary))." -ForegroundColor Green

Write-Host "`n== Generate project ==" -ForegroundColor Cyan
$r = Invoke-TiaBuildFromSpec -Path (Join-Path $here 'project.yaml')
Write-Host ("`nBuild Ok = {0}" -f $r.Ok) -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
if ($r.Errors) { $r.Errors | ForEach-Object { Write-Warning $_ } }

if (-not $KeepOpen) { try { Disconnect-TiaPortal -Close } catch {} }
