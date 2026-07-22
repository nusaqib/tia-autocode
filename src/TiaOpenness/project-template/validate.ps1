# {{MachineName}} - offline spec validation (no TIA needed). Used by CI and locally.
#   powershell -ExecutionPolicy Bypass -File .\validate.ps1
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'engine\src\TiaOpenness\TiaOpenness.psd1'
if (-not (Test-Path $engine)) { Write-Host "::error::Engine submodule missing. Run: git submodule update --init --recursive"; exit 2 }
Import-Module $engine -Force

$v = Test-TiaSpec -Path (Join-Path $here 'project.yaml')
$v.Warnings | ForEach-Object { Write-Host "::warning::$_" }
$v.Errors   | ForEach-Object { Write-Host "::error::$_" }
Write-Host "Spec: $($v.Summary)"
if (-not $v.Ok) { exit 1 }
Write-Host "Spec OK." -ForegroundColor Green
